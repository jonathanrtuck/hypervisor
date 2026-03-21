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
    /// True if we masked the vtimer's IMASK bit (need to unmask when timer condition clears).
    private var timerMaskedByUs = false

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
        var exitCount: UInt64 = 0
        let maxExits: UInt64 = 100_000_000  // Safety limit

        while running && exitCount < maxExits {
            // If we masked the vtimer, check if the guest has re-armed it
            // (ISTATUS cleared means the timer condition no longer holds).
            // Unmask so the next expiry generates a VTIMER exit.
            if timerMaskedByUs {
                let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
                let istatus = (ctl >> 2) & 1
                if istatus == 0 {
                    // Timer re-armed by guest — clear IMASK
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
                    let sp = try getReg(HV_REG_FP)  // x29
                    let x0 = try getReg(HV_REG_X0)
                    let x1 = try getReg(HV_REG_X1)
                    let x24 = try getReg(hv_reg_t(rawValue: HV_REG_X0.rawValue + 24))
                    print("    ELR_EL1=0x\(String(elr, radix: 16)) (return addr from exception)")
                    print("    ESR_EL1=0x\(String(esr, radix: 16)) (guest exception syndrome)")
                    print("    FAR_EL1=0x\(String(far, radix: 16)) (fault address)")
                    print("    SPSR_EL1=0x\(String(spsr, radix: 16))")
                    print("    x0=0x\(String(x0, radix: 16)) x1=0x\(String(x1, radix: 16))")
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

    // MARK: - Exit handling

    private func handleExit(_ reason: UInt32) throws {
        switch reason {
        case 1:  // HV_EXIT_REASON_EXCEPTION
            try handleException()

        case 2:  // HV_EXIT_REASON_VTIMER_ACTIVATED
            // Virtual timer fired — inject IRQ to deliver timer interrupt.
            // The GICv3 hardware maps this to PPI 27 (virtual timer INTID).
            //
            // Mask the timer at EL2 level (IMASK bit) to prevent re-fire while
            // the guest handles the interrupt. The guest's timer handler will
            // re-arm the timer by writing a new CNTV_CVAL, which clears ISTATUS.
            // We unmask before each vCPU run (see below).
            let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
            try setSysReg(HV_SYS_REG_CNTV_CTL_EL0, ctl | 2)  // Set IMASK
            timerMaskedByUs = true

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

        case 0x01:  // WFI/WFE
            // Guest executed WFI — the core is idle, waiting for an interrupt.
            // Don't advance PC — the guest should re-execute WFI after waking.
            // Brief sleep to avoid burning host CPU while guest is idle.
            Thread.sleep(forTimeInterval: 0.001)  // 1ms

            // Check if timer needs unmasking
            if timerMaskedByUs {
                let ctl = try getSysReg(HV_SYS_REG_CNTV_CTL_EL0)
                if (ctl >> 2) & 1 == 0 {
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

    private func handleDataAbort(_ syndrome: UInt64) throws {
        let isWrite = (syndrome >> 6) & 1 == 1
        let srt = Int((syndrome >> 16) & 0x1F)  // Transfer register
        let _ = Int((syndrome >> 22) & 0x3)       // Access size (unused in Phase 1)
        let pa = exitInfo.pointee.exception.physical_address

        let pc = try getReg(HV_REG_PC)

        if pa >= UART_BASE && pa < UART_BASE + UART_SIZE {
            // PL011 UART
            let offset = pa - UART_BASE
            if isWrite {
                let val = try getReg(hv_reg_t(rawValue: UInt32(srt)))
                vm.uart.write(offset: offset, value: UInt32(val & 0xFFFF_FFFF))
            } else {
                let val = vm.uart.read(offset: offset)
                try setReg(hv_reg_t(rawValue: UInt32(srt)), UInt64(val))
            }
        } else if pa >= GIC_DIST_BASE && pa < GIC_DIST_BASE + 0x10000 {
            // GIC distributor — handled by Apple's hv_gic hardware emulation.
            // This shouldn't be reached if hv_gic_create was called.
            if vm.verbose {
                let rw = isWrite ? "W" : "R"
                print("  GIC DIST \(rw) offset=0x\(String(pa - GIC_DIST_BASE, radix: 16)) at PC=0x\(String(pc, radix: 16))")
            }
            if !isWrite {
                try setReg(hv_reg_t(rawValue: UInt32(srt)), 0)
            }
        } else if pa >= GIC_REDIST_BASE && pa < GIC_REDIST_BASE + 0x100000 {
            // GIC redistributor — handled by Apple's hv_gic hardware emulation.
            if !isWrite {
                try setReg(hv_reg_t(rawValue: UInt32(srt)), 0)
            }
        } else if pa >= VIRTIO_BASE && pa < VIRTIO_BASE + VIRTIO_SIZE {
            // Virtio MMIO — dispatch to registered transports
            if let (transport, regOffset) = vm.virtioTransport(for: pa) {
                if isWrite {
                    let val = try getReg(hv_reg_t(rawValue: UInt32(srt)))
                    transport.write(offset: regOffset, value: UInt32(val & 0xFFFF_FFFF))

                    // After QUEUE_NOTIFY or any write that may generate a response,
                    // check if the device raised an interrupt and inject SPI via GIC.
                    if transport.interruptStatus != 0 {
                        hv_gic_set_spi(transport.irq, true)
                    }
                } else {
                    let val = transport.read(offset: regOffset)
                    try setReg(hv_reg_t(rawValue: UInt32(srt)), UInt64(val))
                }
            } else {
                // No device at this slot — return 0 (device_id=0 means empty)
                if !isWrite {
                    try setReg(hv_reg_t(rawValue: UInt32(srt)), 0)
                }
            }
        } else {
            print("vCPU[\(index)]: unhandled MMIO \(isWrite ? "write" : "read") " +
                  "PA=0x\(String(pa, radix: 16)) at PC=0x\(String(pc, radix: 16))")
            running = false
            return
        }

        // Advance PC past the faulting instruction
        try setReg(HV_REG_PC, pc + 4)
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

            if targetCpu < vm.vcpuStarted.count && !vm.vcpuStarted[targetCpu] {
                vm.vcpuStarted[targetCpu] = true
                vm.vcpuEntries[targetCpu] = (entryAddr, contextId)

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

        // ICC_* (GICv3 CPU interface) — stub for Phase 1
        // The kernel will try to initialize the GIC; return 0 for reads.
        if isRead {
            try setReg(hv_reg_t(rawValue: UInt32(rt)), 0)
        }

        if vm.verbose {
            let dir = isRead ? "MRS" : "MSR"
            print("  \(dir) op0=\(op0) op1=\(op1) crn=\(crn) crm=\(crm) op2=\(op2) " +
                  "at PC=0x\(String(pc, radix: 16))")
        }

        // Advance PC
        try setReg(HV_REG_PC, pc + 4)
    }
}
