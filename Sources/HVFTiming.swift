/// HVF timing instrumentation — per-vCPU counters that split guest execution
/// time from host (Hypervisor.framework + dispatch) time and classify exits
/// by ESR exception class.
///
/// The hypervisor brackets every `hv_vcpu_run` call with `mach_absolute_time()`
/// reads. Time spent inside `hv_vcpu_run` is attributed to `guest_ticks`; time
/// spent in the exit handler before the next `hv_vcpu_run` is attributed to
/// `host_ticks`. Exit classifications come from the ESR exception class for
/// HV_EXIT_REASON_EXCEPTION exits, plus a vtimer slot for HV_EXIT_REASON_VTIMER.
///
/// `mach_absolute_time()` on Apple Silicon ticks at the same 24 MHz rate as the
/// guest's `CNTVCT_EL0`, so values are directly comparable to the kernel's
/// `read_cycle_counter()` without unit conversion.
///
/// Counters live inside guest RAM at a fixed GPA so the kernel can read them
/// via its existing identity map (`phys_to_virt(gpa)`), with no extra mapping
/// machinery on the guest side. The DTB advertises the location so neither
/// side hardcodes the address.
///
/// Wire format (must match `kernel/src/frame/arch/aarch64/hvf_timing.rs`):
///   Header (16 bytes):
///     u32 magic         = 0x48564654 ("HVFT" little-endian)
///     u32 version       = 1
///     u32 nr_vcpus      max vCPUs the hypervisor will report
///     u32 slot_stride   bytes per per-vCPU slot
///   Per-vCPU slot (64 bytes), index = vcpu_index:
///     u64 guest_ticks       mach_absolute_time ticks inside hv_vcpu_run
///     u64 host_ticks        mach_absolute_time ticks in handlers
///     u64 exits_total       total VMEXITs counted
///     u64 exits_data_abort  EC 0x24 (MMIO faults)
///     u64 exits_hvc         EC 0x16 (HVC instruction)
///     u64 exits_sysreg      EC 0x18 (MSR/MRS trap, e.g., PMU)
///     u64 exits_wfx         EC 0x01 (WFI/WFE)
///     u64 exits_vtimer      HV_EXIT_REASON_VTIMER_ACTIVATED
///
/// Single-writer-per-slot: only the owning vCPU's thread writes its slot.
/// The kernel reads with volatile loads — no further synchronization needed
/// because individual u64 stores are atomic on aarch64 and the kernel
/// tolerates skewed snapshots (the bench reads delta around an interval).

import Foundation

/// Maximum vCPUs supported. Matches kernel/src/config.rs MAX_CORES.
let HVF_TIMING_MAX_VCPUS: Int = 8

/// Page size used for the counter region. 16 KiB matches the guest kernel's
/// page granule, simplifying any future move to a separate hv_vm_map region.
let HVF_TIMING_PAGE_SIZE: Int = 16 * 1024

/// Bytes per per-vCPU counter slot. Must match the guest reader.
let HVF_TIMING_SLOT_STRIDE: Int = 64

/// Header size in bytes. Must match the guest reader.
let HVF_TIMING_HEADER_SIZE: Int = 16

/// Magic value stamped at offset 0. Matches the kernel reader.
let HVF_TIMING_MAGIC: UInt32 = 0x4856_4654

/// Wire format version.
let HVF_TIMING_VERSION: UInt32 = 1

/// Field offsets within a per-vCPU slot, in bytes.
enum HVFExitClass: Int {
    case guestTicks      = 0
    case hostTicks       = 8
    case exitsTotal      = 16
    case exitsDataAbort  = 24
    case exitsHvc        = 32
    case exitsSysReg     = 40
    case exitsWfx        = 48
    case exitsVtimer     = 56
}

/// Per-vCPU mutable view onto a slot in the shared counter page.
///
/// Each `VCPU` owns one of these and writes only its own slot. The pointer
/// references guest RAM (mapped read-write into the VM via `hv_vm_map`), so
/// the kernel sees writes immediately.
final class HVFTimingSlot {
    private let base: UnsafeMutableRawPointer

    init(base: UnsafeMutableRawPointer) {
        self.base = base
    }

    @inline(__always)
    private func add(_ field: HVFExitClass, _ ticks: UInt64) {
        let p = base.advanced(by: field.rawValue).assumingMemoryBound(to: UInt64.self)
        p.pointee = p.pointee &+ ticks
    }

    @inline(__always)
    private func inc(_ field: HVFExitClass) {
        let p = base.advanced(by: field.rawValue).assumingMemoryBound(to: UInt64.self)
        p.pointee = p.pointee &+ 1
    }

    @inline(__always)
    func addGuestTicks(_ ticks: UInt64) {
        add(.guestTicks, ticks)
    }

    @inline(__always)
    func addHostTicks(_ ticks: UInt64) {
        add(.hostTicks, ticks)
    }

    /// Record a single exit: bumps the total and the per-class bucket.
    /// `esrExceptionClass` is the ARM ESR EC field (bits 31:26).
    func recordExit(reason: UInt32, esrExceptionClass: UInt8) {
        inc(.exitsTotal)

        // HV_EXIT_REASON_VTIMER_ACTIVATED = 2.
        if reason == 2 {
            inc(.exitsVtimer)
            return
        }

        // Other reasons surface only as HV_EXIT_REASON_EXCEPTION (1) on
        // the M-series HVF backend; classify by ESR EC.
        switch esrExceptionClass {
        case 0x01: inc(.exitsWfx)
        case 0x16: inc(.exitsHvc)
        case 0x18: inc(.exitsSysReg)
        case 0x24: inc(.exitsDataAbort)
        default:   break
        }
    }
}

/// Owner of the shared counter page. Allocated once during VM construction,
/// retained for the lifetime of the VM.
final class HVFTimingPage {
    /// Guest physical address of the counter page. Matches the value
    /// advertised in the DTB and consumed by the kernel.
    let gpa: UInt64
    /// Per-vCPU slots — one per supported vCPU.
    private(set) var slots: [HVFTimingSlot] = []

    /// Initialize the counter page inside the guest's RAM mmap. The page is
    /// zeroed, then the header is written and one `HVFTimingSlot` is exposed
    /// per vCPU.
    ///
    /// - Parameters:
    ///   - hostBase: host pointer to the start of guest RAM
    ///   - gpa: guest physical address where the counter page lives
    ///   - nrVcpus: number of slots to expose (≤ HVF_TIMING_MAX_VCPUS)
    init(hostBase: UnsafeMutableRawPointer, gpa: UInt64, nrVcpus: Int) {
        precondition(nrVcpus > 0 && nrVcpus <= HVF_TIMING_MAX_VCPUS,
                     "HVF timing: vcpu count out of range")
        self.gpa = gpa

        memset(hostBase, 0, HVF_TIMING_PAGE_SIZE)

        // Header.
        hostBase.assumingMemoryBound(to: UInt32.self).pointee = HVF_TIMING_MAGIC
        hostBase.advanced(by: 4).assumingMemoryBound(to: UInt32.self).pointee = HVF_TIMING_VERSION
        hostBase.advanced(by: 8).assumingMemoryBound(to: UInt32.self).pointee = UInt32(nrVcpus)
        hostBase.advanced(by: 12).assumingMemoryBound(to: UInt32.self).pointee = UInt32(HVF_TIMING_SLOT_STRIDE)

        // Per-vCPU slots.
        for i in 0..<nrVcpus {
            let slotBase = hostBase.advanced(by: HVF_TIMING_HEADER_SIZE + i * HVF_TIMING_SLOT_STRIDE)
            slots.append(HVFTimingSlot(base: slotBase))
        }
    }

    /// Return the slot for `vcpuIndex`, or nil if the index is out of range.
    func slot(forVcpu vcpuIndex: Int) -> HVFTimingSlot? {
        guard vcpuIndex >= 0 && vcpuIndex < slots.count else { return nil }
        return slots[vcpuIndex]
    }
}
