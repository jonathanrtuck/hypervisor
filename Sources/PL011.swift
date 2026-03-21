/// PL011 UART emulation — minimal implementation for serial output.
///
/// The OS kernel uses PL011 at 0x09000000 with two register accesses:
/// - Read  FR (offset 0x18): check TXFF (bit 5) — TX FIFO full
/// - Write DR (offset 0x00): transmit a character
///
/// This emulation always reports FIFO not full and prints characters to stdout.

import Foundation

final class PL011 {
    /// PL011 register offsets
    private static let DR:   UInt64 = 0x00  // Data register (TX/RX)
    private static let FR:   UInt64 = 0x18  // Flag register
    private static let IBRD: UInt64 = 0x24  // Integer baud rate
    private static let FBRD: UInt64 = 0x28  // Fractional baud rate
    private static let LCR:  UInt64 = 0x2C  // Line control
    private static let CR:   UInt64 = 0x30  // Control register
    private static let IMSC: UInt64 = 0x38  // Interrupt mask
    private static let ICR:  UInt64 = 0x44  // Interrupt clear

    /// Flag register bits
    private static let FR_TXFF: UInt32 = 1 << 5  // TX FIFO full
    private static let FR_RXFE: UInt32 = 1 << 4  // RX FIFO empty

    /// Total bytes transmitted (for diagnostics)
    private(set) var txCount: Int = 0

    /// Handle a write to a PL011 register.
    func write(offset: UInt64, value: UInt32) {
        switch offset {
        case PL011.DR:
            // Transmit character
            let ch = UInt8(value & 0xFF)
            txCount += 1

            // Write to stdout
            var byte = ch
            _ = Foundation.write(STDOUT_FILENO, &byte, 1)

        case PL011.CR, PL011.IMSC, PL011.ICR, PL011.IBRD, PL011.FBRD, PL011.LCR:
            // Control registers — ignore writes (we don't need baud rate etc.)
            break

        default:
            break
        }
    }

    /// Handle a read from a PL011 register.
    func read(offset: UInt64) -> UInt32 {
        switch offset {
        case PL011.DR:
            // No input in Phase 1 — return 0
            return 0

        case PL011.FR:
            // TX FIFO never full (always ready), RX FIFO always empty
            return PL011.FR_RXFE

        default:
            return 0
        }
    }
}
