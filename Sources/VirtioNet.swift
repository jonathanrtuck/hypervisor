/// Virtio network device backend — networking via vmnet.framework.
///
/// Implements virtio-net (spec §5.1, device ID 1). Two queues: receiveq (0)
/// for host→guest packets, transmitq (1) for guest→host packets. The host
/// uses macOS vmnet.framework in shared (NAT) mode.
///
/// Features: VIRTIO_NET_F_MAC (bit 5) — device has a fixed MAC address.
///           VIRTIO_NET_F_STATUS (bit 16) — device has link status in config.

import Foundation
import Security
import vmnet

private let VIRTIO_NET_F_MAC:    UInt64 = 1 << 5
private let VIRTIO_NET_F_STATUS: UInt64 = 1 << 16

private let VIRTIO_NET_HDR_SIZE: Int = 12

// vmnet C enum constants not imported by Swift's ClangImporter.
private let VMNET_SUCCESS_STATUS = vmnet_return_t(rawValue: 1000)!
private let VMNET_SHARED_MODE_VALUE = operating_modes_t(rawValue: 1001)!
private let VMNET_PACKETS_AVAILABLE = interface_event_t(rawValue: 1)

final class VirtioNetBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 1  // virtio-net
    let deviceFeatures: UInt64 = VIRTIO_NET_F_MAC | VIRTIO_NET_F_STATUS
    let numQueues: Int = 2     // receiveq, transmitq
    let maxQueueSize: UInt32 = 256
    weak var transport: VirtioMMIOTransport?

    private var lastAvailIdx: [UInt16] = [0, 0]

    private let mac: [UInt8]
    private let iface: interface_ref
    private let vmnetQueue: DispatchQueue
    private let maxPacketSize: Int

    private let packetLock = NSLock()
    private var pendingPackets: [Data] = []
    private let maxPendingPackets = 256

    private let verbose: Bool

    // MARK: - Factory

    static func create(verbose: Bool) -> VirtioNetBackend? {
        var mac = [UInt8](repeating: 0, count: 6)
        mac[0] = 0x02  // locally-administered
        mac[1] = 0xAC
        mac[2] = 0x05
        guard SecRandomCopyBytes(kSecRandomDefault, 3, &mac[3]) == errSecSuccess else {
            return nil
        }

        let queue = DispatchQueue(label: "vmnet", qos: .userInteractive)

        let dict = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(dict, vmnet_operation_mode_key,
                                  UInt64(VMNET_SHARED_MODE_VALUE.rawValue))

        var maxPkt: Int = 1514

        let sem = DispatchSemaphore(value: 0)
        let iface: interface_ref? = vmnet_start_interface(dict, queue) { status, params in
            guard status == VMNET_SUCCESS_STATUS, let params = params else {
                sem.signal()
                return
            }
            let val = xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key)
            if val > 0 { maxPkt = Int(val) }
            sem.signal()
        }

        guard let iface = iface else {
            fputs("warning: vmnet_start_interface returned nil (check entitlements)\n", stderr)
            return nil
        }

        _ = sem.wait(timeout: .now() + 5)

        let backend = VirtioNetBackend(iface: iface, queue: queue, mac: mac,
                                        maxPacketSize: maxPkt, verbose: verbose)

        vmnet_interface_set_event_callback(iface, VMNET_PACKETS_AVAILABLE, queue) { [weak backend] _, _ in
            backend?.receivePackets()
        }

        return backend
    }

    private init(iface: interface_ref, queue: DispatchQueue, mac: [UInt8],
                 maxPacketSize: Int, verbose: Bool) {
        self.iface = iface
        self.vmnetQueue = queue
        self.mac = mac
        self.maxPacketSize = maxPacketSize
        self.verbose = verbose
    }

    deinit {
        let sem = DispatchSemaphore(value: 0)
        vmnet_stop_interface(iface, vmnetQueue) { _ in
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }

    // MARK: - Config space

    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0:
            return UInt32(mac[0]) | (UInt32(mac[1]) << 8) |
                   (UInt32(mac[2]) << 16) | (UInt32(mac[3]) << 24)
        case 4:
            return UInt32(mac[4]) | (UInt32(mac[5]) << 8) |
                   (UInt32(1) << 16)  // VIRTIO_NET_S_LINK_UP
        default:
            return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {}

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        switch queue {
        case 0:
            packetLock.lock()
            deliverPendingPacketsLocked(state: state, vm: vm)
            packetLock.unlock()
        case 1:
            handleTx(state: state, vm: vm)
        default:
            break
        }
    }

    // MARK: - TX (guest → host)

    private func handleTx(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[1]) {
            var frameData = Data()

            for i in 0..<request.buffers.count {
                let buf = request.buffers[i]
                guard !buf.isDeviceWritable,
                      let hostPtr = vm.guestToHost(buf.guestAddr) else { continue }

                if i == 0 {
                    let hdrSize = min(Int(buf.length), VIRTIO_NET_HDR_SIZE)
                    if buf.length > UInt32(hdrSize) {
                        frameData.append(Data(bytes: hostPtr.advanced(by: hdrSize),
                                              count: Int(buf.length) - hdrSize))
                    }
                } else {
                    frameData.append(Data(bytes: hostPtr, count: Int(buf.length)))
                }
            }

            if !frameData.isEmpty {
                sendFrame(frameData)
            }

            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: 0)
        }
        transport?.raiseInterrupt()
    }

    private func sendFrame(_ frameData: Data) {
        frameData.withUnsafeBytes { rawBuf in
            guard let baseAddr = rawBuf.baseAddress else { return }
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: baseAddr),
                            iov_len: frameData.count)
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(
                    vm_pkt_size: frameData.count,
                    vm_pkt_iov: iovPtr,
                    vm_pkt_iovcnt: 1,
                    vm_flags: 0
                )
                var pktCount: Int32 = 1
                vmnet_write(iface, &pkt, &pktCount)
            }
        }
    }

    // MARK: - RX (host → guest)

    private func receivePackets() {
        let batchSize = 16
        let iovStorage = UnsafeMutablePointer<iovec>.allocate(capacity: batchSize)
        let bufStorage = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: batchSize)
        let pktStorage = UnsafeMutablePointer<vmpktdesc>.allocate(capacity: batchSize)

        for i in 0..<batchSize {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: maxPacketSize, alignment: 16)
            bufStorage[i] = buf
            iovStorage[i] = iovec(iov_base: buf, iov_len: maxPacketSize)
            pktStorage[i] = vmpktdesc(
                vm_pkt_size: maxPacketSize,
                vm_pkt_iov: iovStorage.advanced(by: i),
                vm_pkt_iovcnt: 1,
                vm_flags: 0
            )
        }

        var pktCount: Int32 = Int32(batchSize)
        let status = vmnet_read(iface, pktStorage, &pktCount)
        guard status == VMNET_SUCCESS_STATUS, pktCount > 0 else {
            for i in 0..<batchSize { bufStorage[i].deallocate() }
            iovStorage.deallocate()
            bufStorage.deallocate()
            pktStorage.deallocate()
            return
        }

        packetLock.lock()
        for i in 0..<Int(pktCount) {
            let pktSize = pktStorage[i].vm_pkt_size
            let frameData = Data(bytes: bufStorage[i], count: pktSize)
            if pendingPackets.count >= maxPendingPackets {
                pendingPackets.removeFirst()
            }
            pendingPackets.append(frameData)
        }

        if let transport = self.transport, let vm = transport.vm {
            let rxState = transport.currentQueueState(queue: 0)
            deliverPendingPacketsLocked(state: rxState, vm: vm)
        }
        packetLock.unlock()

        for i in 0..<batchSize { bufStorage[i].deallocate() }
        iovStorage.deallocate()
        bufStorage.deallocate()
        pktStorage.deallocate()
    }

    private func deliverPendingPacketsLocked(state: VirtqueueState, vm: VirtualMachine) {
        while !pendingPackets.isEmpty {
            guard let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[0]) else {
                break
            }

            let frameData = pendingPackets.removeFirst()

            let netHeader = [UInt8](repeating: 0, count: VIRTIO_NET_HDR_SIZE)
            var payload = Data(netHeader)
            payload.append(frameData)

            var bytesWritten: UInt32 = 0
            var payloadOffset = 0

            for buf in request.buffers where buf.isDeviceWritable {
                guard let hostPtr = vm.guestToHost(buf.guestAddr) else { continue }
                let remaining = payload.count - payloadOffset
                let toWrite = min(Int(buf.length), remaining)
                guard toWrite > 0 else { break }

                payload.withUnsafeBytes { rawBuf in
                    hostPtr.copyMemory(from: rawBuf.baseAddress!.advanced(by: payloadOffset),
                                       byteCount: toWrite)
                }
                payloadOffset += toWrite
                bytesWritten += UInt32(toWrite)
            }

            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: bytesWritten)
            transport?.raiseInterrupt()
        }
    }
}
