/// Virtio input device backend — forwards host keyboard/mouse events to guest.
///
/// The guest pre-posts writable buffers to the event queue (queue 0).
/// When input occurs, we write an 8-byte evdev event to an available buffer,
/// push it to the used ring, and raise an interrupt.
///
/// Event format (8 bytes, matches Linux evdev without timeval):
///   type:  u16 — EV_KEY (1), EV_ABS (3), EV_SYN (0)
///   code:  u16 — Linux keycode or axis code
///   value: u32 — 1=press, 0=release (keys), coordinate (abs)

import Foundation
import Hypervisor

// Linux evdev constants
let EV_SYN: UInt16 = 0
let EV_KEY: UInt16 = 1
let EV_ABS: UInt16 = 3

// Virtio input config space select values
private let VIRTIO_INPUT_CFG_UNSET:    UInt8 = 0x00
private let VIRTIO_INPUT_CFG_ID_NAME:  UInt8 = 0x01
private let VIRTIO_INPUT_CFG_ID_SERIAL: UInt8 = 0x02
private let VIRTIO_INPUT_CFG_ID_DEVIDS: UInt8 = 0x03
private let VIRTIO_INPUT_CFG_PROP_BITS: UInt8 = 0x10
private let VIRTIO_INPUT_CFG_EV_BITS:  UInt8 = 0x11
private let VIRTIO_INPUT_CFG_ABS_INFO: UInt8 = 0x12

final class VirtioInputBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 18  // virtio-input
    let deviceFeatures: UInt64 = 0
    let numQueues: Int = 2     // event queue + status queue
    let maxQueueSize: UInt32 = 64

    /// Config select/subsel state (written by guest to query different configs).
    private var configSelect: UInt8 = 0
    private var configSubsel: UInt8 = 0

    /// Device name shown to guest.
    let deviceName: String

    /// Whether this is a keyboard or tablet.
    let isKeyboard: Bool

    /// Last seen available ring index for the event queue.
    private var lastAvailIdx: UInt16 = 0

    /// Pending events to be delivered when buffers become available.
    /// Capped at 256 entries — if the guest isn't consuming buffers, oldest events are dropped.
    private var pendingEvents: [(UInt16, UInt16, UInt32)] = []  // (type, code, value)
    private let maxPendingEvents = 256

    init(name: String, keyboard: Bool) {
        self.deviceName = name
        self.isKeyboard = keyboard
    }

    // MARK: - Config space

    /// virtio-input config space layout:
    /// offset 0: select (u8) — written by guest to choose config type
    /// offset 1: subsel (u8) — written by guest for sub-selection
    /// offset 2: size (u8) — read by guest to get data length
    /// offset 8+: data — config data bytes
    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0:
            return UInt32(configSelect)
        case 1:
            return UInt32(configSubsel)
        case 2:
            // Size of data for current select/subsel
            return UInt32(configDataSize())
        default:
            // Data bytes (offset 8+)
            if offset >= 8 {
                return configDataRead(at: Int(offset - 8))
            }
            return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {
        switch offset {
        case 0:
            configSelect = UInt8(value & 0xFF)
        case 1:
            configSubsel = UInt8(value & 0xFF)
        default:
            break
        }
    }

    private func configDataSize() -> UInt8 {
        switch configSelect {
        case VIRTIO_INPUT_CFG_ID_NAME:
            return UInt8(deviceName.utf8.count)
        case VIRTIO_INPUT_CFG_EV_BITS:
            if configSubsel == UInt8(EV_KEY) {
                return 16  // Enough bitmap for common keys
            } else if configSubsel == UInt8(EV_ABS) && !isKeyboard {
                return 1   // ABS_X, ABS_Y
            }
            return 0
        case VIRTIO_INPUT_CFG_ABS_INFO:
            if !isKeyboard {
                return 20  // absinfo struct: min(4) + max(4) + fuzz(4) + flat(4) + res(4)
            }
            return 0
        default:
            return 0
        }
    }

    private func configDataRead(at offset: Int) -> UInt32 {
        switch configSelect {
        case VIRTIO_INPUT_CFG_ID_NAME:
            let bytes = Array(deviceName.utf8)
            var result: UInt32 = 0
            for i in 0..<4 {
                if offset + i < bytes.count {
                    result |= UInt32(bytes[offset + i]) << (i * 8)
                }
            }
            return result
        case VIRTIO_INPUT_CFG_ABS_INFO:
            // Return abs info: min=0, max=32767 for tablet
            if offset == 0 { return 0 }       // min
            if offset == 4 { return 32767 }    // max
            return 0
        default:
            return 0
        }
    }

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        if queue == 0 {
            // Event queue — guest posted new writable buffers.
            // Deliver any pending events.
            deliverPendingEvents(state: state, vm: vm)
        }
        // Queue 1 (status) — guest config queries, ignore for now.
    }

    // MARK: - Event injection

    /// Inject an input event. Called from the host (keyboard/mouse handler).
    /// If guest buffers are available, delivers immediately. Otherwise queues.
    func injectEvent(type: UInt16, code: UInt16, value: UInt32,
                     state: VirtqueueState, vm: VirtualMachine) {
        // Drop oldest events if the queue is full (guest not consuming buffers).
        if pendingEvents.count >= maxPendingEvents {
            pendingEvents.removeFirst()
        }
        pendingEvents.append((type, code, value))
        deliverPendingEvents(state: state, vm: vm)
    }

    private func deliverPendingEvents(state: VirtqueueState, vm: VirtualMachine) {
        while !pendingEvents.isEmpty {
            guard let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx) else {
                break  // No buffers available
            }

            // Find the first writable buffer
            guard let writeBuf = request.buffers.first(where: { $0.isDeviceWritable }),
                  writeBuf.length >= 8,
                  let hostPtr = vm.guestToHost(writeBuf.guestAddr) else {
                break
            }

            let (type, code, value) = pendingEvents.removeFirst()

            // Write 8-byte evdev event
            hostPtr.storeBytes(of: type.littleEndian, toByteOffset: 0, as: UInt16.self)
            hostPtr.storeBytes(of: code.littleEndian, toByteOffset: 2, as: UInt16.self)
            hostPtr.storeBytes(of: value.littleEndian, toByteOffset: 4, as: UInt32.self)

            // Push to used ring
            virtqueuePushUsed(state: state, vm: vm, headIndex: request.headIndex, bytesWritten: 8)

            // Raise interrupt
            if let transport = vm.virtioDevices.values.first(where: { $0.backend === self }) {
                transport.raiseInterrupt()
                hv_gic_set_spi(transport.irq, true)
            }
        }
    }
}
