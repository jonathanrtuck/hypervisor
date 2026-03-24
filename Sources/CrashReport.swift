/// Crash report generation for kernel panics.
///
/// When the kernel panics, it outputs diagnostic information through the PL011 UART.
/// The hypervisor captures additional state from outside the VM (vCPU registers via
/// Hypervisor.framework) and combines both into a timestamped crash report file.
///
/// The hypervisor-side register dump is valuable because:
/// - It doesn't depend on the kernel's own reporting being complete or correct
/// - It captures state the kernel might not be able to report (corrupted stack)
/// - System registers (ELR_EL1, ESR_EL1, FAR_EL1) still hold the original fault
///   context since the fault handler runs with DAIF masked (no interrupts)

import Foundation
import Hypervisor

/// vCPU register state captured at panic detection time.
///
/// PC reflects the instruction being executed during panic output (UART write path),
/// not the original faulting instruction. ELR_EL1 holds the original fault PC.
struct CrashSnapshot {
    let vcpuIndex: Int
    let exitCount: UInt64
    let timestamp: Date

    // Program state
    let pc: UInt64
    let cpsr: UInt64

    // General purpose registers (x0-x30)
    let gprs: [UInt64]

    // System registers — these hold the original fault context
    let elr_el1: UInt64     // Faulting instruction address
    let esr_el1: UInt64     // Exception syndrome (fault type + details)
    let far_el1: UInt64     // Faulting data address (for data aborts)
    let spsr_el1: UInt64    // Saved processor state at fault time
    let sp_el1: UInt64      // Kernel stack pointer
    let sctlr_el1: UInt64   // System control (MMU, caches)
    let tcr_el1: UInt64     // Translation control
    let ttbr0_el1: UInt64   // Page table base (user)
    let ttbr1_el1: UInt64   // Page table base (kernel)
    let mpidr_el1: UInt64   // CPU affinity
    let tpidr_el1: UInt64   // Thread pointer (points to kernel thread context)
    let vbar_el1: UInt64    // Exception vector base
    let cntv_ctl: UInt64    // Virtual timer control
    let cntv_cval: UInt64   // Virtual timer compare value
}

/// Format a crash report and write it to disk.
///
/// Returns the file path on success, nil on failure.
@discardableResult
func writeCrashReport(snapshot: CrashSnapshot, serialLog: String, config: Config?) -> String? {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let stamp = formatter.string(from: snapshot.timestamp)
    let path = "/tmp/hypervisor-crash-\(stamp).log"

    var r = ""

    // ── Header ──────────────────────────────────────────────────────────

    let readable = DateFormatter()
    readable.dateFormat = "yyyy-MM-dd HH:mm:ss"

    r += "══════════════════════════════════════════════════════════\n"
    r += "  HYPERVISOR CRASH REPORT\n"
    r += "  \(readable.string(from: snapshot.timestamp))\n"
    r += "══════════════════════════════════════════════════════════\n\n"

    // ── Configuration ───────────────────────────────────────────────────

    if let config = config {
        r += "── Configuration ─────────────────────────────────────────\n"
        r += "  Kernel:  \(config.kernelPath)\n"
        r += "  RAM:     \(config.ramMiB) MiB\n"
        r += "  CPUs:    \(config.cpuCount)\n"
        r += "  GPU:     \(config.noGpu ? "disabled" : "Metal")\n"
        r += "\n"
    }

    // ── vCPU state ──────────────────────────────────────────────────────

    r += "── vCPU \(snapshot.vcpuIndex) "
    r += "─────────────────────────────────────────────────\n"
    r += "  Exit count:  \(snapshot.exitCount)\n\n"

    r += "── Registers (hypervisor-side) "
    r += "───────────────────────────────\n"
    r += "  PC   = 0x\(hex16(snapshot.pc))  "
    r += "(during panic output, not the faulting instruction)\n"
    r += "  CPSR = 0x\(hex16(snapshot.cpsr))\n\n"

    // GPRs in two columns
    for i in stride(from: 0, to: 31, by: 2) {
        let left = String(format: "  x%-2d  = 0x%016llx", i, snapshot.gprs[i])
        if i + 1 <= 30 {
            let right = String(format: "  x%-2d  = 0x%016llx", i + 1, snapshot.gprs[i + 1])
            r += "\(left)\(right)\n"
        } else {
            r += "\(left)\n"
        }
    }
    r += "\n"

    // ── System registers ────────────────────────────────────────────────

    r += "── System Registers ──────────────────────────────────────\n"

    r += "  ELR_EL1    = 0x\(hex16(snapshot.elr_el1))"
    r += "  ← faulting instruction\n"

    r += "  ESR_EL1    = 0x\(hex16(snapshot.esr_el1))"
    let ec = (snapshot.esr_el1 >> 26) & 0x3F
    r += "  (EC=0x\(String(format: "%02x", ec)): \(decodeEC(ec)))\n"

    r += "  FAR_EL1    = 0x\(hex16(snapshot.far_el1))"
    r += "  ← faulting address\n"

    r += "  SPSR_EL1   = 0x\(hex16(snapshot.spsr_el1))\n"
    r += "  SP_EL1     = 0x\(hex16(snapshot.sp_el1))\n"
    r += "  SCTLR_EL1  = 0x\(hex16(snapshot.sctlr_el1))\n"
    r += "  TCR_EL1    = 0x\(hex16(snapshot.tcr_el1))\n"
    r += "  TTBR0_EL1  = 0x\(hex16(snapshot.ttbr0_el1))\n"
    r += "  TTBR1_EL1  = 0x\(hex16(snapshot.ttbr1_el1))\n"
    r += "  MPIDR_EL1  = 0x\(hex16(snapshot.mpidr_el1))\n"
    r += "  TPIDR_EL1  = 0x\(hex16(snapshot.tpidr_el1))\n"
    r += "  VBAR_EL1   = 0x\(hex16(snapshot.vbar_el1))\n"
    r += "  CNTV_CTL   = 0x\(hex16(snapshot.cntv_ctl))\n"
    r += "  CNTV_CVAL  = 0x\(hex16(snapshot.cntv_cval))\n"
    r += "\n"

    // ── Serial output ───────────────────────────────────────────────────

    r += "══════════════════════════════════════════════════════════\n"
    r += "  SERIAL OUTPUT\n"
    r += "══════════════════════════════════════════════════════════\n\n"
    r += serialLog
    if !serialLog.hasSuffix("\n") {
        r += "\n"
    }

    // ── Write to disk ───────────────────────────────────────────────────

    do {
        try r.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    } catch {
        // Last resort: dump to stderr
        FileHandle.standardError.write(Data(r.utf8))
        return nil
    }
}

// MARK: - Helpers

/// Format a UInt64 as zero-padded 16-digit hex.
private func hex16(_ value: UInt64) -> String {
    String(format: "%016llx", value)
}

/// Decode ARM64 Exception Class (EC) to a human-readable string.
private func decodeEC(_ ec: UInt64) -> String {
    switch ec {
    case 0x00: return "Unknown reason"
    case 0x01: return "WFI/WFE"
    case 0x07: return "SVE/SIMD/FP access"
    case 0x15: return "SVC (EL0)"
    case 0x16: return "HVC (EL1)"
    case 0x18: return "MSR/MRS trap"
    case 0x20: return "Instruction abort (EL0)"
    case 0x21: return "Instruction abort (EL1)"
    case 0x22: return "PC alignment fault"
    case 0x24: return "Data abort (EL0)"
    case 0x25: return "Data abort (EL1)"
    case 0x26: return "SP alignment fault"
    case 0x2C: return "Floating-point exception"
    case 0x30: return "Breakpoint (EL0)"
    case 0x31: return "Breakpoint (EL1)"
    case 0x32: return "Software step (EL0)"
    case 0x33: return "Software step (EL1)"
    case 0x34: return "Watchpoint (EL0)"
    case 0x35: return "Watchpoint (EL1)"
    case 0x3C: return "BRK instruction"
    default:   return "EC=0x\(String(format: "%02x", ec))"
    }
}
