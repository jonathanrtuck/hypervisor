/// Virtio block device backend — file-backed block I/O for the guest.
///
/// Implements the virtio-blk spec (device ID 2) with read, write, and flush.
/// The backing store is a raw disk image file on the host. Flush uses
/// `fcntl(F_FULLFSYNC)` for real hardware durability on macOS (not just
/// `fsync`, which only guarantees kernel buffer cache flush).
///
/// Config space: capacity (u64 at offset 0) in 512-byte sectors.

import Foundation

// virtio-blk request types (virtio spec §5.2.6).
private let VIRTIO_BLK_T_IN:    UInt32 = 0  // Read
private let VIRTIO_BLK_T_OUT:   UInt32 = 1  // Write
private let VIRTIO_BLK_T_FLUSH: UInt32 = 4  // Flush

// virtio-blk status codes.
private let VIRTIO_BLK_S_OK:     UInt8 = 0
private let VIRTIO_BLK_S_IOERR:  UInt8 = 1
private let VIRTIO_BLK_S_UNSUPP: UInt8 = 2

// virtio-blk feature bits.
private let VIRTIO_BLK_F_FLUSH: UInt64 = 1 << 9

private let SECTOR_SIZE: Int = 512

final class VirtioBlockBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 2  // virtio-blk
    let deviceFeatures: UInt64 = VIRTIO_BLK_F_FLUSH
    let numQueues: Int = 1
    let maxQueueSize: UInt32 = 128
    weak var transport: VirtioMMIOTransport?

    /// Capacity in 512-byte sectors.
    private let capacitySectors: UInt64

    /// File descriptor for the backing image (kept open for pread/pwrite).
    private let fd: Int32

    /// Last-seen available ring index.
    private var lastAvailIdx: UInt16 = 0

    /// Open a disk image file. The capacity is derived from the file size.
    init(imagePath: String) throws {
        let fd = open(imagePath, O_RDWR)
        guard fd >= 0 else {
            throw HypervisorError.vmError("failed to open disk image: \(imagePath)")
        }
        self.fd = fd

        // Get file size via fstat.
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw HypervisorError.vmError("fstat failed on \(imagePath)")
        }
        self.capacitySectors = UInt64(st.st_size) / UInt64(SECTOR_SIZE)
    }

    deinit {
        Darwin.close(fd)
    }

    // MARK: - Config space

    /// Config space layout (virtio spec §5.2.4):
    ///   offset 0: capacity (u64, in 512-byte sectors)
    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0:
            return UInt32(capacitySectors & 0xFFFF_FFFF)
        case 4:
            return UInt32(capacitySectors >> 32)
        default:
            return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {
        // Config is read-only for block devices.
    }

    // MARK: - Request processing

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx) {
            processRequest(request.headIndex, request.buffers, state: state, vm: vm)
        }
    }

    private func processRequest(_ headIdx: UInt16, _ buffers: [VirtqueueBuffer],
                                 state: VirtqueueState, vm: VirtualMachine) {
        // Virtio-blk request layout:
        //   descriptor 0: header (device-readable, 16 bytes)
        //     u32 type, u32 reserved, u64 sector
        //   descriptor 1: data (device-readable for write, device-writable for read)
        //     variable length, absent for flush
        //   last descriptor: status (device-writable, 1 byte)
        guard buffers.count >= 2,
              let headerPtr = vm.guestToHost(buffers[0].guestAddr) else {
            return
        }

        let reqType = headerPtr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let sector  = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt64.self)

        // The status byte is always the last buffer in the chain.
        let statusBuf = buffers[buffers.count - 1]
        guard let statusPtr = vm.guestToHost(statusBuf.guestAddr) else { return }

        let status: UInt8

        switch reqType {
        case VIRTIO_BLK_T_IN:
            // Read: data descriptor(s) are device-writable.
            status = handleRead(sector: sector, buffers: buffers, vm: vm)

        case VIRTIO_BLK_T_OUT:
            // Write: data descriptor(s) are device-readable.
            status = handleWrite(sector: sector, buffers: buffers, vm: vm)

        case VIRTIO_BLK_T_FLUSH:
            status = handleFlush()

        default:
            status = VIRTIO_BLK_S_UNSUPP
        }

        // Write status byte.
        statusPtr.storeBytes(of: status, toByteOffset: 0, as: UInt8.self)

        // Total bytes written to device-writable buffers: for reads, it's the data
        // length + 1 (status). For writes/flush, it's just 1 (status).
        var bytesWritten: UInt32 = 1  // status byte
        if reqType == VIRTIO_BLK_T_IN && status == VIRTIO_BLK_S_OK {
            for i in 1..<(buffers.count - 1) {
                bytesWritten += buffers[i].length
            }
        }

        virtqueuePushUsed(state: state, vm: vm, headIndex: headIdx, bytesWritten: bytesWritten)

        if let transport = self.transport {
            transport.raiseInterrupt()
        }
    }

    /// Read sectors from the disk image into guest memory.
    private func handleRead(sector: UInt64, buffers: [VirtqueueBuffer],
                             vm: VirtualMachine) -> UInt8 {
        var diskOffset = Int64(sector) * Int64(SECTOR_SIZE)

        // Data descriptors are buffers[1] through buffers[count-2].
        for i in 1..<(buffers.count - 1) {
            let buf = buffers[i]
            guard let hostPtr = vm.guestToHost(buf.guestAddr) else {
                return VIRTIO_BLK_S_IOERR
            }

            let len = Int(buf.length)
            let result = pread(fd, hostPtr, len, diskOffset)
            if result != len {
                return VIRTIO_BLK_S_IOERR
            }

            diskOffset += Int64(len)
        }

        return VIRTIO_BLK_S_OK
    }

    /// Write sectors from guest memory to the disk image.
    private func handleWrite(sector: UInt64, buffers: [VirtqueueBuffer],
                              vm: VirtualMachine) -> UInt8 {
        var diskOffset = Int64(sector) * Int64(SECTOR_SIZE)

        // Data descriptors are buffers[1] through buffers[count-2].
        for i in 1..<(buffers.count - 1) {
            let buf = buffers[i]
            guard let hostPtr = vm.guestToHost(buf.guestAddr) else {
                return VIRTIO_BLK_S_IOERR
            }

            let len = Int(buf.length)
            let result = pwrite(fd, hostPtr, len, diskOffset)
            if result != len {
                return VIRTIO_BLK_S_IOERR
            }

            diskOffset += Int64(len)
        }

        return VIRTIO_BLK_S_OK
    }

    /// Flush all writes to stable storage using F_FULLFSYNC.
    ///
    /// macOS `fsync` only flushes the kernel buffer cache — it does NOT
    /// guarantee data reaches the physical storage controller. `F_FULLFSYNC`
    /// issues a hardware flush command, providing actual durability. This is
    /// critical for the COW filesystem's two-flush commit protocol.
    private func handleFlush() -> UInt8 {
        let result = fcntl(fd, F_FULLFSYNC)
        return result == 0 ? VIRTIO_BLK_S_OK : VIRTIO_BLK_S_IOERR
    }
}
