/// PL011 UART emulation — minimal implementation for serial output.
///
/// The OS kernel uses PL011 at 0x09000000 with two register accesses:
/// - Read  FR (offset 0x18): check TXFF (bit 5) — TX FIFO full
/// - Write DR (offset 0x00): transmit a character
///
/// This emulation always reports FIFO not full and prints characters to stdout.
/// All output is accumulated in a log buffer for inclusion in crash reports
/// (written by the pvpanic handler when the kernel signals a panic).

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
    private static let FR_TXFE: UInt32 = 1 << 7  // TX FIFO empty
    private static let FR_TXFF: UInt32 = 1 << 5  // TX FIFO full
    private static let FR_RXFE: UInt32 = 1 << 4  // RX FIFO empty
    private static let FR_CTS:  UInt32 = 1 << 0  // Clear to send

    /// Total bytes transmitted (for diagnostics)
    private(set) var txCount: Int = 0

    /// Accumulated serial output for crash reporting (interleaved, all cores).
    private var logData = Data()

    /// Lock protecting logData from concurrent vCPU access.
    /// Multiple guest cores can write to UART simultaneously (the kernel's
    /// panic_puts bypasses locks to avoid deadlock).
    private let lock = NSLock()

    /// Full serial log as a string (for crash reports).
    ///
    /// Uses lossy UTF-8 decoding — invalid byte sequences (from multi-core
    /// interleaving of emoji markers) become U+FFFD replacement characters.
    /// Thread-safe — acquires the lock to read logData.
    var serialLog: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: logData, as: UTF8.self)
    }

    /// Handle a write to a PL011 register.
    func write(offset: UInt64, value: UInt32) {
        switch offset {
        case PL011.DR:
            // Transmit character
            let ch = UInt8(value & 0xFF)
            txCount += 1

            // Accumulate for crash log
            lock.lock()
            logData.append(ch)
            lock.unlock()

            // Write to stdout (outside lock — stdout has its own buffering)
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
            // Match real PL011 flag state for an idle, empty UART:
            // TXFE=1 (TX done), TXFF=0 (not full), RXFE=1 (no RX data),
            // BUSY=0 (not transmitting), CTS=1 (clear to send).
            return PL011.FR_TXFE | PL011.FR_RXFE | PL011.FR_CTS

        default:
            return 0
        }
    }
}
