/// Virtio MMIO transport emulation (spec section 4.2).
///
/// Each VirtioMMIOTransport wraps a device backend and handles the standard
/// MMIO register set: magic, version, device_id, feature negotiation,
/// status transitions, virtqueue setup, notify, and interrupts.
///
/// The guest driver interacts via MMIO reads/writes. When the guest writes
/// to QUEUE_NOTIFY, the transport calls into the device backend to process
/// available buffers.

import Foundation

// MARK: - Virtio MMIO register offsets

private let REG_MAGIC:             UInt64 = 0x000
private let REG_VERSION:           UInt64 = 0x004
private let REG_DEVICE_ID:         UInt64 = 0x008
private let REG_VENDOR_ID:         UInt64 = 0x00C
private let REG_DEVICE_FEATURES:   UInt64 = 0x010
private let REG_DEVICE_FEATURES_SEL: UInt64 = 0x014
private let REG_DRIVER_FEATURES:   UInt64 = 0x020
private let REG_DRIVER_FEATURES_SEL: UInt64 = 0x024
private let REG_QUEUE_SEL:         UInt64 = 0x030
private let REG_QUEUE_NUM_MAX:     UInt64 = 0x034
private let REG_QUEUE_NUM:         UInt64 = 0x038
private let REG_QUEUE_READY:       UInt64 = 0x044
private let REG_QUEUE_NOTIFY:      UInt64 = 0x050
private let REG_INTERRUPT_STATUS:  UInt64 = 0x060
private let REG_INTERRUPT_ACK:     UInt64 = 0x064
private let REG_STATUS:            UInt64 = 0x070
private let REG_QUEUE_DESC_LOW:    UInt64 = 0x080
private let REG_QUEUE_DESC_HIGH:   UInt64 = 0x084
private let REG_QUEUE_DRIVER_LOW:  UInt64 = 0x090
private let REG_QUEUE_DRIVER_HIGH: UInt64 = 0x094
private let REG_QUEUE_DEVICE_LOW:  UInt64 = 0x0A0
private let REG_QUEUE_DEVICE_HIGH: UInt64 = 0x0A4
private let REG_CONFIG_BASE:       UInt64 = 0x100

// Status bits
private let STATUS_ACKNOWLEDGE: UInt32 = 1
private let STATUS_DRIVER:      UInt32 = 2
private let STATUS_DRIVER_OK:   UInt32 = 4
private let STATUS_FEATURES_OK: UInt32 = 8

// MARK: - Virtqueue state

struct VirtqueueState {
    var num: UInt32 = 0
    var ready: Bool = false
    var descPA: UInt64 = 0
    var availPA: UInt64 = 0
    var usedPA: UInt64 = 0
}

// MARK: - Device backend protocol

/// Protocol for virtio device backends. Each device type (9p, gpu, input, etc.)
/// implements this to provide device-specific behavior.
protocol VirtioDeviceBackend: AnyObject {
    /// Virtio device ID (1=blk, 2=net, 9=9p, 16=gpu, 18=input).
    var deviceId: UInt32 { get }

    /// Device features (64-bit).
    var deviceFeatures: UInt64 { get }

    /// Maximum number of virtqueues this device uses.
    var numQueues: Int { get }

    /// Maximum queue size per queue.
    var maxQueueSize: UInt32 { get }

    /// Called when the guest writes to QUEUE_NOTIFY for the given queue index.
    /// The transport provides the queue state and a reference to guest memory.
    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine)

    /// Read from device-specific config space.
    func configRead(offset: UInt64) -> UInt32

    /// Write to device-specific config space.
    func configWrite(offset: UInt64, value: UInt32)
}

// MARK: - MMIO Transport

/// Virtio MMIO transport for one device slot.
final class VirtioMMIOTransport {
    let backend: VirtioDeviceBackend
    let guestPA: UInt64  // Guest physical address of this MMIO region
    let irq: UInt32      // IRQ number (GIC SPI)

    private var status: UInt32 = 0
    private var deviceFeaturesSel: UInt32 = 0
    private var driverFeaturesSel: UInt32 = 0
    private var driverFeatures: UInt64 = 0
    private var selectedQueue: UInt32 = 0
    private var queues: [VirtqueueState]
    private(set) var interruptStatus: UInt32 = 0

    weak var vm: VirtualMachine?

    init(backend: VirtioDeviceBackend, guestPA: UInt64, irq: UInt32) {
        self.backend = backend
        self.guestPA = guestPA
        self.irq = irq
        self.queues = Array(repeating: VirtqueueState(), count: backend.numQueues)
    }

    /// Handle an MMIO read from the guest.
    func read(offset: UInt64) -> UInt32 {
        switch offset {
        case REG_MAGIC:
            return 0x7472_6976  // "virt"

        case REG_VERSION:
            return 2  // Modern virtio

        case REG_DEVICE_ID:
            return backend.deviceId

        case REG_VENDOR_ID:
            return 0x4143_4F53  // "ACOS" — Arts & Crafts OS hypervisor

        case REG_DEVICE_FEATURES:
            if deviceFeaturesSel == 0 {
                return UInt32(backend.deviceFeatures & 0xFFFF_FFFF)
            } else {
                return UInt32(backend.deviceFeatures >> 32)
            }

        case REG_QUEUE_NUM_MAX:
            if Int(selectedQueue) < backend.numQueues {
                return backend.maxQueueSize
            }
            return 0

        case REG_QUEUE_READY:
            if Int(selectedQueue) < queues.count {
                return queues[Int(selectedQueue)].ready ? 1 : 0
            }
            return 0

        case REG_INTERRUPT_STATUS:
            return interruptStatus

        case REG_STATUS:
            return status

        default:
            // Device-specific config space
            if offset >= REG_CONFIG_BASE {
                return backend.configRead(offset: offset - REG_CONFIG_BASE)
            }
            return 0
        }
    }

    /// Handle an MMIO write from the guest.
    func write(offset: UInt64, value: UInt32) {
        switch offset {
        case REG_DEVICE_FEATURES_SEL:
            deviceFeaturesSel = value

        case REG_DRIVER_FEATURES_SEL:
            driverFeaturesSel = value

        case REG_DRIVER_FEATURES:
            if driverFeaturesSel == 0 {
                driverFeatures = (driverFeatures & 0xFFFF_FFFF_0000_0000) | UInt64(value)
            } else {
                driverFeatures = (driverFeatures & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
            }

        case REG_QUEUE_SEL:
            selectedQueue = value

        case REG_QUEUE_NUM:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].num = value
            }

        case REG_QUEUE_READY:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].ready = value != 0
            }

        case REG_QUEUE_DESC_LOW:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].descPA = (queues[Int(selectedQueue)].descPA & 0xFFFF_FFFF_0000_0000) | UInt64(value)
            }
        case REG_QUEUE_DESC_HIGH:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].descPA = (queues[Int(selectedQueue)].descPA & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
            }

        case REG_QUEUE_DRIVER_LOW:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].availPA = (queues[Int(selectedQueue)].availPA & 0xFFFF_FFFF_0000_0000) | UInt64(value)
            }
        case REG_QUEUE_DRIVER_HIGH:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].availPA = (queues[Int(selectedQueue)].availPA & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
            }

        case REG_QUEUE_DEVICE_LOW:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].usedPA = (queues[Int(selectedQueue)].usedPA & 0xFFFF_FFFF_0000_0000) | UInt64(value)
            }
        case REG_QUEUE_DEVICE_HIGH:
            if Int(selectedQueue) < queues.count {
                queues[Int(selectedQueue)].usedPA = (queues[Int(selectedQueue)].usedPA & 0x0000_0000_FFFF_FFFF) | (UInt64(value) << 32)
            }

        case REG_QUEUE_NOTIFY:
            let queueIdx = Int(value)
            if queueIdx < queues.count, let vm = self.vm {
                backend.handleNotify(queue: queueIdx, state: queues[queueIdx], vm: vm)
            }

        case REG_INTERRUPT_ACK:
            interruptStatus &= ~value

        case REG_STATUS:
            if value == 0 {
                // Reset
                status = 0
                driverFeatures = 0
                for i in 0..<queues.count {
                    queues[i] = VirtqueueState()
                }
            } else {
                status = value
            }

        default:
            if offset >= REG_CONFIG_BASE {
                backend.configWrite(offset: offset - REG_CONFIG_BASE, value: value)
            }
        }
    }

    /// Raise an interrupt (set status bit, to be delivered to guest via GIC).
    func raiseInterrupt() {
        interruptStatus |= 1  // Used buffer notification
    }

    /// Access the current state of a virtqueue (for input event injection from the host).
    func currentQueueState(queue: Int) -> VirtqueueState {
        guard queue < queues.count else { return VirtqueueState() }
        return queues[queue]
    }
}

// MARK: - Null device backend (for testing transport)

/// A do-nothing device backend — useful for testing that the transport works.
final class NullDeviceBackend: VirtioDeviceBackend {
    let deviceId: UInt32
    let deviceFeatures: UInt64 = 0
    let numQueues: Int = 1
    let maxQueueSize: UInt32 = 128

    init(deviceId: UInt32) {
        self.deviceId = deviceId
    }

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        // No-op
    }

    func configRead(offset: UInt64) -> UInt32 { 0 }
    func configWrite(offset: UInt64, value: UInt32) {}
}
