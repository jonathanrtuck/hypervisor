/// pvpanic device emulation — paravirtual panic notification.
///
/// Implements the QEMU pvpanic-mmio specification: a single-byte MMIO register
/// that the guest writes to signal panic events to the hypervisor.
///
/// Register layout (2 bytes at base address):
///   Offset 0x00 (read):  Bitmask of supported events
///   Offset 0x00 (write): Event notification
///
/// Events:
///   Bit 0 (0x01) — PANICKED: guest kernel panic
///   Bit 1 (0x02) — CRASHLOADED: guest crash dump complete
///
/// DTB: compatible = "qemu,pvpanic-mmio", reg = <0x09020000 0x2>
///
/// Reference: https://www.qemu.org/docs/master/specs/pvpanic.html

import Foundation

final class PVPanic {
    /// Event bit definitions (matches QEMU spec).
    static let PANICKED: UInt8    = 0x01
    static let CRASHLOADED: UInt8 = 0x02

    /// Events this hypervisor supports (returned on read).
    private let supportedEvents: UInt8 = PVPanic.PANICKED

    /// Whether a panic event has been received.
    private(set) var panicReceived = false

    /// Handle a read from the pvpanic register.
    /// Returns the supported events bitmask.
    func read(offset: UInt64) -> UInt32 {
        if offset == 0 {
            return UInt32(supportedEvents)
        }
        return 0
    }

    /// Handle a write to the pvpanic register.
    /// Returns true if the write signals a panic event.
    func write(offset: UInt64, value: UInt32) -> Bool {
        guard offset == 0 else { return false }
        let event = UInt8(value & 0xFF)
        if event & PVPanic.PANICKED != 0 {
            panicReceived = true
            return true
        }
        return false
    }
}
