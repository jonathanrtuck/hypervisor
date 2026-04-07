/// vCPU: Creates and runs a single virtual CPU via Hypervisor.framework.
///
/// Handles exits for:
/// - MMIO (PL011 UART reads/writes)
/// - HVC (PSCI calls: CPU_ON for secondary core boot)
/// - System register traps (timer, GIC — logged but not emulated in Phase 1)

import Foundation
import Hypervisor

/// ARM64 system register encoding: op0, op1, crn, crm, op2 → 16-bit ID
func sysRegId(_ op0: UInt16, _ op1: UInt16, _ crn: UInt16, _ crm: UInt16, _ op2: UInt16) -> UInt16 {
    return (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2
}

/// PSCI function IDs
let PSCI_CPU_ON_64: UInt64  = 0xC400_0003
let PSCI_CPU_OFF: UInt64    = 0x8400_0002
let PSCI_SYSTEM_OFF: UInt64 = 0x8400_0008
let PSCI_VERSION: UInt64    = 0x8400_0000

/// Well-known MMIO ranges
let UART_BASE: UInt64     = 0x0900_0000
let UART_SIZE: UInt64     = 0x1000
let PL031_BASE: UInt64    = 0x0901_0000
let PL031_SIZE: UInt64    = 0x1000
let PVPANIC_BASE: UInt64  = 0x0902_0000
let PVPANIC_SIZE: UInt64  = 0x1000
let GIC_DIST_BASE: UInt64 = 0x0800_0000
let GIC_REDIST_BASE: UInt64 = 0x080A_0000
let VIRTIO_BASE: UInt64   = 0x0A00_0000
let VIRTIO_SIZE: UInt64   = 0x4000

final class VCPU {
    let vm: VirtualMachine
    let index: Int
    let vcpuId: UInt64
    let exitInfo: UnsafeMutablePointer<hv_vcpu_exit_t>

    private var running = true
    /// vCPU exit count — tracks how many times hv_vcpu_run has returned.
    private(set) var exitCount: UInt64 = 0
    /// True if we masked the vtimer's IMASK bit (need to unmask when timer condition clears).
    private var timerMaskedByUs = false
    /// CNTV_CVAL at the time we masked IMASK — used to detect guest timer re-arm.
    private var timerMaskedCval: UInt64 = 0
    /// Suppresses repeated "unsupported granule" warnings in translateGuestVA.
    private var loggedGranuleWarning = false

    init(vm: VirtualMachine, index: Int, entryPoint: UInt64, dtbAddress: UInt64) throws {
        self.vm = vm
        self.index = index

        // Create vCPU
        var vcpu: UInt64 = 0
        var exit: UnsafeMutablePointer<hv_vcpu_exit_t>?
        try hvCheck(hv_vcpu_create(&vcpu, &exit, nil), "hv_vcpu_create[\(index)]")
        self.vcpuId = vcpu
        self.exitInfo = exit!

        // Set initial register state
        // PC = physical entry point (0x40080000 for _start)
        try setReg(HV_REG_PC, entryPoint)

        // x0 = DTB physical address (aarch64 boot protocol)
        try setReg(HV_REG_X0, dtbAddress)

        // Clear other GPRs
        for i: UInt32 in 1...30 {
            try setReg(hv_reg_t(rawValue: HV_REG_X0.rawValue + i), 0)
        }

        // CPSR/PSTATE: EL1h with all interrupts masked (DAIF = 0xF)
        // M[3:0] = 0b0101 = EL1h, DAIF bits [9:6] = all set
        try setReg(HV_REG_CPSR, 0x3C5)

        // CPACR_EL1: Enable FP/SIMD (FPEN bits 21:20 = 0b11)
        // Without this, the kernel's FP instructions will trap.
        try setSysReg(HV_SYS_REG_CPACR_EL1, 3 << 20)

        // SCTLR_EL1: ARM reset default = 0x00C50838.
        // MMU off, caches off. Kernel boot.S enables these after page table setup.
        try setSysReg(HV_SYS_REG_SCTLR_EL1, 0x00C5_0838)

        // MPIDR_EL1: Set affinity for this CPU (Aff0 = index)
        try setSysReg(HV_SYS_REG_MPIDR_EL1, UInt64(index))

        // Note: CNTFRQ_EL0 is not a trappable sys reg in Hypervisor.framework.
        // The host's counter frequency is used directly by the guest.

        // Virtual counter offset: CNTVCT_EL0 = CNTPCT_EL0 - vtimer_offset.
        // Set to 0 so CNTVCT == CNTPCT, matching real hardware where the
        // kernel zeroes CNTVOFF_EL2 during EL2→EL1 transition in boot.S.
        try hvCheck(hv_vcpu_set_vtimer_offset(vcpuId, 0), "vtimer_offset[\(index)]")

        // Timer control: disabled initially
        try setSysReg(HV_SYS_REG_CNTV_CTL_EL0, 0)

        if vm.verbose {
            // Read back actual values to verify HVF applied them
            let actualPC = try getReg(HV_REG_PC)
            let actualMPIDR = try getSysReg(HV_SYS_REG_MPIDR_EL1)
            let actualSCTLR = try getSysReg(HV_SYS_REG_SCTLR_EL1)
            let actualCPACR = try getSysReg(HV_SYS_REG_CPACR_EL1)
            print("  vCPU[\(index)]: created")
            print("    PC=0x\(String(actualPC, radix: 16))")
            print("    MPIDR_EL1=0x\(String(actualMPIDR, radix: 16))")
            print("    SCTLR_EL1=0x\(String(actualSCTLR, radix: 16))")
            print("    CPACR_EL1=0x\(String(actualCPACR, radix: 16))")
        }
    }

    // MARK: - Register access

    func setReg(_ reg: hv_reg_t, _ val: UInt64) throws {
        try hvCheck(hv_vcpu_set_reg(vcpuId, reg, val), "set_reg")
    }

    func getReg(_ reg: hv_reg_t) throws -> UInt64 {
        var val: UInt64 = 0
        try hvCheck(hv_vcpu_get_reg(vcpuId, reg, &val), "get_reg")
        return val
    }

    func setSysReg(_ reg: hv_sys_reg_t, _ val: UInt64) throws {
        try hvCheck(hv_vcpu_set_sys_reg(vcpuId, reg, val), "set_sys_reg")
    }

    func getSysReg(_ reg: hv_sys_reg_t) throws -> UInt64 {
        var val: UInt64 = 0
        try hvCheck(hv_vcpu_get_sys_reg(vcpuId, reg, &val), "get_sys_reg")
        return val
    }

    // MARK: - Execution loop

    func run() throws {
        let maxExits: UInt64 = 100_000_000  // Safety limit

        while running && exitCount < maxExits {
            // If we masked the vtimer, check if the guest has re-armed it.
            // Compare CNTV_CVAL: if it changed since we masked, the guest wrote
            // a new timer deadline. Unmask so the next expiry generates a VTIMER
            // exit. (We can't use ISTATUS==0 as the re-arm signal because a fast
            // timer may have already fired, setting ISTATUS=1 again.)
            if timerMaskedByUs {
                let cval = try getSysReg(HV_SYS_REG_CNTV_CVAL_EL0)
                if cval != timerMaskedCval {
                    let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
                    try setSysReg(HV_SYS_REG_CNTV_CTL_EL0, ctl & ~2)
                    timerMaskedByUs = false
                }
            }

            let result = hv_vcpu_run(vcpuId)
            if result != HV_SUCCESS {
                let pc = try getReg(HV_REG_PC)
                print("vCPU[\(index)]: hv_vcpu_run failed: \(result) at PC=0x\(String(pc, radix: 16))")
                break
            }

            exitCount += 1
            let reason = exitInfo.pointee.reason.rawValue

            // Verbose logging for first exits to debug boot
            if vm.verbose && exitCount <= 10 {
                let pc = try getReg(HV_REG_PC)
                let syndrome = exitInfo.pointee.exception.syndrome
                let ec = (syndrome >> 26) & 0x3F
                let pa = exitInfo.pointee.exception.physical_address
                print("  EXIT[\(exitCount)] reason=\(reason) PC=0x\(String(pc, radix: 16)) " +
                      "EC=0x\(String(ec, radix: 16)) PA=0x\(String(pa, radix: 16))")

                // On first exit, dump full register state for debugging
                if exitCount == 1 {
                    let elr = try getSysReg(HV_SYS_REG_ELR_EL1)
                    let spsr = try getSysReg(HV_SYS_REG_SPSR_EL1)
                    let esr = try getSysReg(HV_SYS_REG_ESR_EL1)
                    let far = try getSysReg(HV_SYS_REG_FAR_EL1)
                    let fp = try getReg(HV_REG_FP)  // x29 (frame pointer)
                    let x0 = try getReg(HV_REG_X0)
                    let x1 = try getReg(HV_REG_X1)
                    let x24 = try getReg(hv_reg_t(rawValue: HV_REG_X0.rawValue + 24))
                    print("    ELR_EL1=0x\(String(elr, radix: 16)) (return addr from exception)")
                    print("    ESR_EL1=0x\(String(esr, radix: 16)) (guest exception syndrome)")
                    print("    FAR_EL1=0x\(String(far, radix: 16)) (fault address)")
                    print("    SPSR_EL1=0x\(String(spsr, radix: 16))")
                    print("    FP=0x\(String(fp, radix: 16)) x0=0x\(String(x0, radix: 16)) x1=0x\(String(x1, radix: 16))")
                    print("    x24=0x\(String(x24, radix: 16)) (saved DTB addr)")
                }
            }

            try handleExit(reason)
        }

        if exitCount >= maxExits {
            print("vCPU[\(index)]: hit exit limit (\(maxExits))")
        }
        print("vCPU[\(index)]: stopped after \(exitCount) exits")
    }

    // MARK: - Crash snapshot

    /// Capture full vCPU register state for crash reporting.
    ///
    /// Must be called from this vCPU's thread during an exit handler (not while
    /// hv_vcpu_run is active). Reads all GPRs and key system registers.
    func captureSnapshot(exitCount: UInt64) -> CrashSnapshot? {
        do {
            var gprs: [UInt64] = []
            gprs.reserveCapacity(31)
            for i: UInt32 in 0...30 {
                gprs.append(try getReg(hv_reg_t(rawValue: HV_REG_X0.rawValue + i)))
            }

            return CrashSnapshot(
                vcpuIndex: index,
                exitCount: exitCount,
                timestamp: Date(),
                pc: try getReg(HV_REG_PC),
                cpsr: try getReg(HV_REG_CPSR),
                gprs: gprs,
                elr_el1: try getSysReg(HV_SYS_REG_ELR_EL1),
                esr_el1: try getSysReg(HV_SYS_REG_ESR_EL1),
                far_el1: try getSysReg(HV_SYS_REG_FAR_EL1),
                spsr_el1: try getSysReg(HV_SYS_REG_SPSR_EL1),
                sp_el1: try getSysReg(HV_SYS_REG_SP_EL1),
                sctlr_el1: try getSysReg(HV_SYS_REG_SCTLR_EL1),
                tcr_el1: try getSysReg(HV_SYS_REG_TCR_EL1),
                ttbr0_el1: try getSysReg(HV_SYS_REG_TTBR0_EL1),
                ttbr1_el1: try getSysReg(HV_SYS_REG_TTBR1_EL1),
                mpidr_el1: try getSysReg(HV_SYS_REG_MPIDR_EL1),
                tpidr_el1: try getSysReg(HV_SYS_REG_TPIDR_EL1),
                vbar_el1: try getSysReg(HV_SYS_REG_VBAR_EL1),
                cntv_ctl: try getSysReg(HV_SYS_REG_CNTV_CTL_EL0),
                cntv_cval: try getSysReg(HV_SYS_REG_CNTV_CVAL_EL0)
            )
        } catch {
            print("vCPU[\(index)]: failed to capture crash snapshot: \(error)")
            return nil
        }
    }

    // MARK: - Exit handling

    private func handleExit(_ reason: UInt32) throws {
        switch reason {
        case 1:  // HV_EXIT_REASON_EXCEPTION
            try handleException()

        case 2:  // HV_EXIT_REASON_VTIMER_ACTIVATED
            // Virtual timer fired — inject IRQ to deliver timer interrupt.
            // Mask the timer at EL2 level (IMASK bit) to prevent re-fire while
            // the guest handles the interrupt. Record CNTV_CVAL so we can detect
            // when the guest re-arms the timer (CVAL changes = new timer set up).
            let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
            try setSysReg(HV_SYS_REG_CNTV_CTL_EL0, ctl | 2)  // Set IMASK
            timerMaskedByUs = true
            timerMaskedCval = try getSysReg(HV_SYS_REG_CNTV_CVAL_EL0)

            // Inject IRQ to the vCPU — the hardware GIC will present INTID 27
            hv_vcpu_set_pending_interrupt(vcpuId, HV_INTERRUPT_TYPE_IRQ, true)

        default:
            let pc = try getReg(HV_REG_PC)
            print("vCPU[\(index)]: unknown exit reason \(reason) at PC=0x\(String(pc, radix: 16))")
            running = false
        }
    }

    private func handleException() throws {
        let syndrome = exitInfo.pointee.exception.syndrome
        let ec = (syndrome >> 26) & 0x3F  // Exception Class

        switch ec {
        case 0x24:  // Data abort from lower EL (MMIO)
            try handleDataAbort(syndrome)

        case 0x16:  // HVC instruction (PSCI)
            try handleHVC()

        case 0x18:  // MSR/MRS trap (system register access)
            try handleSysRegTrap(syndrome)

        case 0x01:  // WFI/WFE trap
            // ISS bit [0] (TI): 0 = WFI, 1 = WFE.
            let isWFE = syndrome & 1 == 1

            if !isWFE {
                // WFI (Wait For Interrupt): guest is idle, waiting for an
                // interrupt. Brief sleep to avoid burning host CPU.
                Thread.sleep(forTimeInterval: 0.001)  // 1ms
            }
            // WFE (Wait For Event): return immediately. Used in spinlocks
            // (WFE/SEV pattern) — sleeping here would make lock acquisition
            // ~1000x slower than real hardware.

            // Don't advance PC — the guest re-executes the hint instruction.

            // Check if timer needs unmasking (CVAL changed = guest re-armed).
            if timerMaskedByUs {
                let cval = try getSysReg(HV_SYS_REG_CNTV_CVAL_EL0)
                if cval != timerMaskedCval {
                    let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
                    try setSysReg(HV_SYS_REG_CNTV_CTL_EL0, ctl & ~2)
                    timerMaskedByUs = false
                }
            }

        default:
            let pc = try getReg(HV_REG_PC)
            print("vCPU[\(index)]: unhandled exception EC=0x\(String(ec, radix: 16)) " +
                  "syndrome=0x\(String(syndrome, radix: 16)) " +
                  "at PC=0x\(String(pc, radix: 16))")
            running = false
        }
    }

    // MARK: - Data abort (MMIO)

    /// Read a guest GPR in load/store context. Register 31 is the zero register
    /// (XZR), not SP — Hypervisor.framework returns SP for index 31, so this
    /// must be special-cased.
    private func readGPR(_ reg: Int) throws -> UInt64 {
        if reg == 31 { return 0 }
        return try getReg(hv_reg_t(rawValue: UInt32(reg)))
    }

    /// Write a guest GPR in load/store context. Writes to register 31 (XZR) are
    /// silently discarded.
    private func writeGPR(_ reg: Int, _ val: UInt64) throws {
        if reg == 31 { return }
        try setReg(hv_reg_t(rawValue: UInt32(reg)), val)
    }

    private func handleDataAbort(_ syndrome: UInt64) throws {
        let pa = exitInfo.pointee.exception.physical_address
        let pc = try getReg(HV_REG_PC)
        let isv = (syndrome >> 24) & 1 == 1

        if isv {
            // Fast path: ESR syndrome contains register, size, and direction.
            let isWrite = (syndrome >> 6) & 1 == 1
            let reg = Int((syndrome >> 16) & 0x1F)
            let accessSize = Int((syndrome >> 22) & 0x3)

            guard try performMMIO(pa: pa, isWrite: isWrite, reg: reg, pc: pc) else {
                print("vCPU[\(index)]: unhandled MMIO \(isWrite ? "write" : "read") " +
                      "PA=0x\(String(pa, radix: 16)) size=\(1 << accessSize) " +
                      "at PC=0x\(String(pc, radix: 16))")
                running = false
                return
            }
        } else {
            // Slow path: ISV=0 — decode the faulting instruction to determine
            // register(s), access size, and direction.
            guard try decodeAndPerformMMIO(pa: pa, pc: pc) else {
                return  // Error already logged, vCPU stopped.
            }
        }

        // Advance PC past the faulting instruction.
        try setReg(HV_REG_PC, pc + 4)
    }

    /// Route a single MMIO access to the appropriate emulated device.
    /// Returns true if handled, false if the address is not a known device.
    private func performMMIO(pa: UInt64, isWrite: Bool, reg: Int, pc: UInt64) throws -> Bool {
        if pa >= UART_BASE && pa < UART_BASE + UART_SIZE {
            let offset = pa - UART_BASE
            if isWrite {
                vm.uart.write(offset: offset, value: UInt32(try readGPR(reg) & 0xFFFF_FFFF))
            } else {
                try writeGPR(reg, UInt64(vm.uart.read(offset: offset)))
            }
        } else if pa >= PL031_BASE && pa < PL031_BASE + PL031_SIZE {
            // PL031 RTC — read-only, returns host wall-clock time.
            // Like QEMU's `-rtc base=localtime`, we add the local timezone offset.
            if !isWrite {
                let offset = pa - PL031_BASE
                if offset == 0 {
                    var now = time(nil)
                    var local = tm()
                    localtime_r(&now, &local)
                    let localEpoch = now + local.tm_gmtoff
                    try writeGPR(reg, UInt64(UInt32(truncatingIfNeeded: localEpoch)))
                } else {
                    try writeGPR(reg, 0)
                }
            }
        } else if pa >= PVPANIC_BASE && pa < PVPANIC_BASE + PVPANIC_SIZE {
            let offset = pa - PVPANIC_BASE
            if isWrite {
                let val = try readGPR(reg)
                if vm.pvpanic.write(offset: offset, value: UInt32(val & 0xFF)) {
                    if let snapshot = captureSnapshot(exitCount: exitCount) {
                        let path = writeCrashReport(
                            snapshot: snapshot,
                            serialLog: vm.uart.serialLog,
                            config: vm.config
                        )
                        if let path = path {
                            FileHandle.standardError.write(
                                Data("\n── Crash report written to \(path) ──\n".utf8)
                            )
                        }
                    }
                    exit(1)
                }
            } else {
                try writeGPR(reg, UInt64(vm.pvpanic.read(offset: offset)))
            }
        } else if pa >= GIC_DIST_BASE && pa < GIC_DIST_BASE + 0x10000 {
            // GIC distributor — should be handled by hv_gic. If we reach here,
            // GIC registers not handled by hv_gic (e.g., IPRIORITYR).
            // Verbose-only — kernels write hundreds of these during init.
            if vm.verbose {
                let rw = isWrite ? "W" : "R"
                print("vCPU[\(index)]: GIC DIST fallback \(rw) offset=0x\(String(pa - GIC_DIST_BASE, radix: 16)) at PC=0x\(String(pc, radix: 16))")
            }
            if !isWrite {
                try writeGPR(reg, 0)
            }
        } else if pa >= GIC_REDIST_BASE && pa < GIC_REDIST_BASE + 0x100000 {
            if vm.verbose {
                let rw = isWrite ? "W" : "R"
                print("vCPU[\(index)]: GIC REDIST fallback \(rw) offset=0x\(String(pa - GIC_REDIST_BASE, radix: 16)) at PC=0x\(String(pc, radix: 16))")
            }
            if !isWrite {
                try writeGPR(reg, 0)
            }
        } else if pa >= VIRTIO_BASE && pa < VIRTIO_BASE + VIRTIO_SIZE {
            if let (transport, regOffset) = vm.virtioTransport(for: pa) {
                if isWrite {
                    let val = try readGPR(reg)
                    transport.write(offset: regOffset, value: UInt32(val & 0xFFFF_FFFF))
                    if transport.interruptStatus != 0 {
                        hv_gic_set_spi(transport.irq, true)
                    }
                } else {
                    try writeGPR(reg, UInt64(transport.read(offset: regOffset)))
                }
            } else {
                if !isWrite {
                    try writeGPR(reg, 0)
                }
            }
        } else {
            return false
        }
        return true
    }

    // MARK: - ISV=0 instruction decoding

    /// Translate a guest virtual address to physical address by walking the
    /// guest's stage-1 page tables (TTBR0/TTBR1 → multi-level descriptor walk).
    ///
    /// Returns the VA unchanged when the MMU is disabled (SCTLR_EL1.M = 0).
    /// Returns nil if the walk encounters an invalid descriptor.
    ///
    /// Supports 4KB (TG=12), 16KB (TG=14), and 64KB (TG=16) granules.
    /// The walk is parameterized by page bits and bits-per-level (page bits - 3).
    private func translateGuestVA(_ va: UInt64) throws -> UInt64? {
        let sctlr = try getSysReg(HV_SYS_REG_SCTLR_EL1)

        // MMU disabled — VA == PA.
        if sctlr & 1 == 0 {
            return va
        }

        let tcr = try getSysReg(HV_SYS_REG_TCR_EL1)
        let isKernelVA = (va >> 63) & 1 == 1

        let ttbr: UInt64
        let tsz: Int
        let pageBits: Int

        if isKernelVA {
            ttbr = try getSysReg(HV_SYS_REG_TTBR1_EL1)
            tsz = Int((tcr >> 16) & 0x3F)  // T1SZ
            switch (tcr >> 30) & 0x3 {      // TG1
            case 0b01: pageBits = 14  // 16KB
            case 0b10: pageBits = 12  // 4KB
            case 0b11: pageBits = 16  // 64KB
            default:
                if !loggedGranuleWarning {
                    print("vCPU[\(index)]: VA translation: reserved TG1 in TCR " +
                          "0x\(String(tcr, radix: 16)), falling back to VA==PA")
                    loggedGranuleWarning = true
                }
                return va
            }
        } else {
            ttbr = try getSysReg(HV_SYS_REG_TTBR0_EL1)
            tsz = Int(tcr & 0x3F)  // T0SZ
            switch (tcr >> 14) & 0x3 {      // TG0
            case 0b00: pageBits = 12  // 4KB
            case 0b01: pageBits = 16  // 64KB
            case 0b10: pageBits = 14  // 16KB
            default:
                if !loggedGranuleWarning {
                    print("vCPU[\(index)]: VA translation: reserved TG0 in TCR " +
                          "0x\(String(tcr, radix: 16)), falling back to VA==PA")
                    loggedGranuleWarning = true
                }
                return va
            }
        }

        // Bits resolved per level = log2(page_size / 8) = pageBits - 3.
        // 4KB → 9, 16KB → 11, 64KB → 13.
        let bitsPerLevel = pageBits - 3
        let vaBits = 64 - tsz

        // Start level: highest level where pageBits + (3-L)*bitsPerLevel < vaBits.
        let startLevel: Int
        if vaBits <= pageBits + bitsPerLevel { startLevel = 3 }
        else if vaBits <= pageBits + 2 * bitsPerLevel { startLevel = 2 }
        else if vaBits <= pageBits + 3 * bitsPerLevel { startLevel = 1 }
        else { startLevel = 0 }

        // OA mask: bits [47:pageBits] — used for table, block, and page addresses.
        let oaMask = UInt64(0x0000_FFFF_FFFF_FFFF) & ~((UInt64(1) << pageBits) - 1)
        var tablePA = ttbr & oaMask

        for level in startLevel...3 {
            let shift = pageBits + (3 - level) * bitsPerLevel

            // At the start level the index may use fewer than bitsPerLevel bits
            // (e.g., 64KB L1 with 48-bit VA uses only 6 bits).
            let indexBits = min(bitsPerLevel, vaBits - shift)
            let indexMask = (UInt64(1) << indexBits) - 1
            let index = Int((va >> shift) & indexMask)
            let pteAddr = tablePA &+ UInt64(index * 8)

            guard let ptePtr = vm.guestToHost(pteAddr) else { return nil }
            let pte = ptePtr.load(as: UInt64.self)

            // Valid bit [0] must be set.
            guard pte & 1 == 1 else { return nil }

            if level < 3 && (pte & 2 == 0) {
                // Block descriptor — OA from PTE, low bits from VA.
                let blockMask = (UInt64(1) << shift) - 1
                return (pte & oaMask & ~blockMask) | (va & blockMask)
            }

            if level == 3 {
                // Page descriptor at L3 — bit[1] must be 1.
                guard pte & 2 == 2 else { return nil }
                let pageMask = (UInt64(1) << pageBits) - 1
                return (pte & oaMask) | (va & pageMask)
            }

            // Table descriptor — descend to next level.
            tablePA = pte & oaMask
        }

        return nil
    }

    /// Decode the faulting load/store instruction and perform MMIO operation(s).
    ///
    /// Called when the ESR syndrome has ISV=0, meaning the hardware did not
    /// provide register/size/direction information. Translates PC (VA) to PA
    /// via a stage-1 page table walk, fetches the instruction, and decodes it.
    ///
    /// Handles LDP/STP (the primary ISV=0 case on Apple Silicon) and
    /// pre/post-index LDR/STR. SIMD/FP load/stores and exclusives are not
    /// supported — they are architecturally unpredictable on Device memory.
    private func decodeAndPerformMMIO(pa: UInt64, pc: UInt64) throws -> Bool {
        // Translate PC (a virtual address) to physical address. When the guest
        // MMU is enabled, PC may map to a different PA than its numeric value.
        guard let instrPA = try translateGuestVA(pc) else {
            print("vCPU[\(index)]: ISV=0 data abort at PC=0x\(String(pc, radix: 16)): " +
                  "VA→PA translation failed (invalid page table entry)")
            running = false
            return false
        }

        guard let hostPtr = vm.guestToHost(instrPA) else {
            print("vCPU[\(index)]: ISV=0 data abort at PC=0x\(String(pc, radix: 16)) " +
                  "(PA=0x\(String(instrPA, radix: 16))): instruction outside guest RAM")
            running = false
            return false
        }

        let insn = hostPtr.load(as: UInt32.self)

        // LDP/STP (GPR pair): bits [29:27] = 101, bit [26] = 0 (not SIMD)
        if (insn >> 27) & 0b111 == 0b101 && (insn >> 26) & 1 == 0 {
            return try decodeLdpStp(insn: insn, pa: pa, pc: pc)
        }

        // LDR/STR pre/post-index: bits [29:27] = 111, [25:24] = 00, [21] = 0,
        // bit [26] = 0 (not SIMD), [11:10] = 01 (post) or 11 (pre)
        if (insn >> 27) & 0b111 == 0b111 && (insn >> 24) & 0b11 == 0b00 &&
           (insn >> 21) & 1 == 0 && (insn >> 26) & 1 == 0 {
            let indexType = (insn >> 10) & 0b11
            if indexType == 0b01 || indexType == 0b11 {
                return try decodeLdrStrIndexed(insn: insn, pa: pa, pc: pc)
            }
        }

        print("vCPU[\(index)]: ISV=0 data abort: cannot decode instruction " +
              "0x\(String(insn, radix: 16)) at PC=0x\(String(pc, radix: 16))")
        running = false
        return false
    }

    /// Decode and emulate LDP/STP (load/store pair, GPR).
    ///
    /// Encoding: `opc[31:30] 101 V[26] type[25:23] L[22] imm7[21:15] Rt2[14:10] Rn[9:5] Rt[4:0]`
    ///
    /// Emulates both element accesses and applies base register writeback for
    /// pre/post-index forms.
    ///
    /// Note: the two pair elements are emulated as separate MMIO accesses.
    /// If the first succeeds but the second targets an unhandled address,
    /// the first access cannot be rolled back. This matches ARM architecture
    /// (LDP/STP to Device memory is architecturally UNPREDICTABLE).
    private func decodeLdpStp(insn: UInt32, pa: UInt64, pc: UInt64) throws -> Bool {
        let opc = (insn >> 30) & 0b11
        let indexType = (insn >> 23) & 0b111
        let isLoad = (insn >> 22) & 1 == 1
        let imm7Raw = Int32(bitPattern: (insn >> 15) & 0x7F)
        let rt2 = Int((insn >> 10) & 0x1F)
        let rn = Int((insn >> 5) & 0x1F)
        let rt = Int(insn & 0x1F)

        // Element size from opc: 00 = 32-bit, 10 = 64-bit, 01 = LDPSW (32-bit sign-extended)
        let elementSize: Int
        let signExtend: Bool
        switch opc {
        case 0b00:
            elementSize = 4; signExtend = false
        case 0b01 where isLoad:
            elementSize = 4; signExtend = true   // LDPSW
        case 0b10:
            elementSize = 8; signExtend = false
        default:
            print("vCPU[\(index)]: LDP/STP reserved opc=\(opc) " +
                  "at PC=0x\(String(pc, radix: 16))")
            running = false
            return false
        }

        // First element: Rt at PA.
        guard try performMMIO(pa: pa, isWrite: !isLoad, reg: rt, pc: pc) else {
            print("vCPU[\(index)]: unhandled MMIO in LDP/STP " +
                  "at PA=0x\(String(pa, radix: 16))")
            running = false
            return false
        }
        if isLoad && signExtend {
            let raw = try readGPR(rt)
            try writeGPR(rt, UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: raw))))
        }

        // Second element: Rt2 at PA + element_size.
        let pa2 = pa &+ UInt64(elementSize)
        guard try performMMIO(pa: pa2, isWrite: !isLoad, reg: rt2, pc: pc) else {
            print("vCPU[\(index)]: unhandled MMIO in LDP/STP " +
                  "at PA=0x\(String(pa2, radix: 16))")
            running = false
            return false
        }
        if isLoad && signExtend {
            let raw = try readGPR(rt2)
            try writeGPR(rt2, UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: raw))))
        }

        // Base register writeback for pre/post-index forms.
        // type 001 = post-index, 011 = pre-index (both writeback)
        // type 000 = non-temporal, 010 = signed-offset (no writeback)
        if indexType == 0b001 || indexType == 0b011 {
            let signedImm = (imm7Raw << 25) >> 25  // sign-extend 7-bit
            let offset = Int64(signedImm) * Int64(elementSize)
            let base = try readGPR(rn)
            try writeGPR(rn, UInt64(bitPattern: Int64(bitPattern: base) &+ offset))
        }

        return true
    }

    /// Decode and emulate LDR/STR with pre/post-index writeback.
    ///
    /// Encoding: `size[31:30] 111 V[26] 00 opc[23:22] 0 imm9[20:12] type[11:10] Rn[9:5] Rt[4:0]`
    ///
    /// opc: 00 = store, 01 = unsigned load, 10 = signed load → Xt (or PRFM
    /// when size=11), 11 = signed load → Wt.
    ///
    /// On ARMv8.2+ (Apple Silicon), simple LDR/STR set ISV=1, so this path
    /// is a safety net. But it must be correct for signed loads (LDRSB, LDRSH,
    /// LDRSW) which sign-extend the result based on the access size.
    private func decodeLdrStrIndexed(insn: UInt32, pa: UInt64, pc: UInt64) throws -> Bool {
        let size = Int((insn >> 30) & 0b11)  // 0=byte, 1=halfword, 2=word, 3=doubleword
        let opc = (insn >> 22) & 0b11
        let imm9Raw = Int32(bitPattern: (insn >> 12) & 0x1FF)
        let rn = Int((insn >> 5) & 0x1F)
        let rt = Int(insn & 0x1F)

        let isStore = opc == 0b00

        // PRFM (prefetch memory hint) — size=11, opc=10. No register transfer;
        // skip the MMIO access but still perform writeback.
        let isPrefetch = size == 3 && opc == 0b10

        if !isPrefetch {
            guard try performMMIO(pa: pa, isWrite: isStore, reg: rt, pc: pc) else {
                print("vCPU[\(index)]: unhandled MMIO in indexed LDR/STR " +
                      "at PA=0x\(String(pa, radix: 16))")
                running = false
                return false
            }

            // Sign extension for LDRS* variants (opc >= 10).
            if !isStore && opc >= 0b10 {
                let raw = try readGPR(rt)
                let accessBits = 8 << size  // 8, 16, 32
                if accessBits < 64 {
                    // Arithmetic left-shift then right-shift to sign-extend.
                    let shift = 64 - accessBits
                    let extended = UInt64(bitPattern: (Int64(bitPattern: raw) << shift) >> shift)
                    if opc == 0b11 {
                        // Wt destination — zero upper 32 bits.
                        try writeGPR(rt, extended & 0xFFFF_FFFF)
                    } else {
                        try writeGPR(rt, extended)
                    }
                }
            }
        }

        // Writeback: Rn = Rn + SignExtend(imm9).
        // Unlike unsigned-offset LDR/STR, the pre/post-index immediate is a
        // raw byte offset (not scaled by access size).
        let signedImm = (imm9Raw << 23) >> 23  // sign-extend 9-bit
        let base = try readGPR(rn)
        try writeGPR(rn, UInt64(bitPattern: Int64(bitPattern: base) &+ Int64(signedImm)))

        return true
    }

    // MARK: - HVC (PSCI)

    private func handleHVC() throws {
        let funcId = try getReg(HV_REG_X0)
        let pc = try getReg(HV_REG_PC)

        switch funcId {
        case PSCI_VERSION:
            // Return PSCI 1.0
            try setReg(HV_REG_X0, 0x0001_0000)

        case PSCI_CPU_ON_64:
            let targetMpidr = try getReg(HV_REG_X1)
            let entryAddr = try getReg(HV_REG_X2)
            let contextId = try getReg(HV_REG_X3)
            let targetCpu = Int(targetMpidr & 0xFF)

            if vm.verbose {
                print("  PSCI CPU_ON: cpu=\(targetCpu) entry=0x\(String(entryAddr, radix: 16))")
            }

            // Lock protects vcpuStarted/vcpuEntries — multiple vCPUs may issue CPU_ON concurrently.
            vm.psciLock.lock()
            let shouldStart = targetCpu < vm.vcpuStarted.count && !vm.vcpuStarted[targetCpu]
            if shouldStart {
                vm.vcpuStarted[targetCpu] = true
                vm.vcpuEntries[targetCpu] = (entryAddr, contextId)
            }
            vm.psciLock.unlock()

            if shouldStart {
                // Spawn secondary vCPU on a new thread
                let vm = self.vm
                let cpuIdx = targetCpu
                let entry = entryAddr
                let ctx = contextId
                Thread.detachNewThread {
                    do {
                        let vcpu = try VCPU(vm: vm, index: cpuIdx,
                                           entryPoint: entry, dtbAddress: ctx)
                        // x0 = context_id for secondary cores
                        try vcpu.setReg(HV_REG_X0, ctx)
                        try vcpu.run()
                    } catch {
                        print("vCPU[\(cpuIdx)]: failed to start: \(error)")
                    }
                }

                // Return PSCI_SUCCESS (0)
                try setReg(HV_REG_X0, 0)
            } else {
                // Already started or invalid
                try setReg(HV_REG_X0, UInt64(bitPattern: -2))  // PSCI_ERROR_ALREADY_ON
            }

        case PSCI_CPU_OFF:
            if vm.verbose {
                print("  PSCI CPU_OFF: cpu=\(index)")
            }
            running = false

        case PSCI_SYSTEM_OFF:
            print("\n── Guest requested system off ──")
            exit(0)

        default:
            if vm.verbose {
                print("  HVC: unknown func 0x\(String(funcId, radix: 16)) at PC=0x\(String(pc, radix: 16))")
            }
            // Return error
            try setReg(HV_REG_X0, UInt64(bitPattern: -1))
        }

        // Advance PC past HVC instruction
        try setReg(HV_REG_PC, pc + 4)
    }

    // MARK: - System register trap

    private func handleSysRegTrap(_ syndrome: UInt64) throws {
        let isRead = (syndrome >> 0) & 1 == 1  // Direction: 1=read (MRS), 0=write (MSR)
        let rt = Int((syndrome >> 5) & 0x1F)
        let crm = (syndrome >> 1) & 0xF
        let crn = (syndrome >> 10) & 0xF
        let op1 = (syndrome >> 14) & 0x7
        let op2 = (syndrome >> 17) & 0x7
        let op0 = (syndrome >> 20) & 0x3
        let pc = try getReg(HV_REG_PC)

        // Catch-all: return 0 for reads, ignore writes. This handles system
        // registers that HVF traps but doesn't emulate natively (the hardware
        // GIC handles ICC_* registers via hv_gic_create, and EL1 registers
        // like SCTLR/TCR/TTBR are passed through without trapping).
        //
        // Always log — a trapped register that reaches this handler means
        // the guest read/wrote something the hypervisor doesn't understand.
        // Silent 0 returns are the hardest bugs to debug.
        let dir = isRead ? "MRS" : "MSR"
        let regName = "S\(op0)_\(op1)_C\(crn)_C\(crm)_\(op2)"
        print("vCPU[\(index)]: unhandled \(dir) \(regName) " +
              "(rt=x\(rt)) at PC=0x\(String(pc, radix: 16))")

        if isRead {
            if rt != 31 {
                try setReg(hv_reg_t(rawValue: UInt32(rt)), 0)
            }
        }

        // Advance PC
        try setReg(HV_REG_PC, pc + 4)
    }
}
