/// Virtual machine: Hypervisor.framework wrapper for guest memory and vCPU management.

import Foundation
import Hypervisor

/// Check Hypervisor.framework return codes.
func hvCheck(_ result: hv_return_t, _ msg: String) throws {
    guard result == HV_SUCCESS else {
        throw HypervisorError.frameworkError(msg, result)
    }
}

enum HypervisorError: Error, CustomStringConvertible {
    case frameworkError(String, hv_return_t)
    case elfError(String)
    case vmError(String)

    var description: String {
        switch self {
        case .frameworkError(let msg, let code):
            return "\(msg): hv error \(code)"
        case .elfError(let msg):
            return "ELF: \(msg)"
        case .vmError(let msg):
            return "VM: \(msg)"
        }
    }
}

final class VirtualMachine {
    let ramBase: UInt64
    let ramSize: Int
    let verbose: Bool

    /// Host pointer to guest RAM (mmap'd, shared with VM).
    private let ramPtr: UnsafeMutableRawPointer

    /// PL011 UART emulation.
    let uart = PL011()

    /// pvpanic device — paravirtual panic notification.
    let pvpanic = PVPanic()

    /// Virtio MMIO devices, indexed by slot number (0-31).
    var virtioDevices: [Int: VirtioMMIOTransport] = [:]

    /// PSCI: tracks which vCPUs have been started and their entry points.
    /// Protected by `psciLock` — accessed from multiple vCPU threads during CPU_ON.
    var vcpuEntries: [(entryAddr: UInt64, contextId: UInt64)] = []
    var vcpuStarted: [Bool] = []
    let psciLock = NSLock()

    /// VM configuration (set after init for crash report metadata).
    var config: Config?

    /// Physical counter value at VM creation. Set as CNTVOFF_EL2 on each vCPU
    /// so the guest's virtual counter (CNTVCT_EL0) reads as time-since-boot.
    let bootTimestamp: UInt64

    init(ramSize: Int, ramBase: UInt64, verbose: Bool) throws {
        self.ramBase = ramBase
        self.ramSize = ramSize
        self.verbose = verbose

        // Capture the physical counter before VM creation so all vCPUs share
        // the same epoch. mach_absolute_time() on Apple Silicon returns the raw
        // CNTPCT_EL0 value (timebase ratio is 1:1).
        self.bootTimestamp = mach_absolute_time()

        // Create the VM
        try hvCheck(hv_vm_create(nil), "hv_vm_create")
        // Ensure hv_vm_destroy runs even if exit() is called (bypassing deinit).
        atexit { hv_vm_destroy() }
        if verbose { print("  VM created") }

        // Create hardware GIC (must be after VM, before vCPUs)
        let gicConfig = hv_gic_config_create()
        try hvCheck(hv_gic_config_set_distributor_base(gicConfig, 0x0800_0000), "gic_set_dist_base")
        try hvCheck(hv_gic_config_set_redistributor_base(gicConfig, 0x080A_0000), "gic_set_redist_base")
        try hvCheck(hv_gic_create(gicConfig), "hv_gic_create")
        if verbose { print("  GIC created (distributor=0x8000000, redistributor=0x80A0000)") }

        // Allocate guest RAM via mmap (page-aligned, zeroed)
        guard let ptr = mmap(nil, ramSize, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0),
              ptr != MAP_FAILED else {
            throw HypervisorError.vmError("mmap failed for \(ramSize) bytes")
        }
        self.ramPtr = ptr

        // Map guest RAM into the VM at the guest physical address
        try hvCheck(
            hv_vm_map(ptr, ramBase, ramSize, UInt64(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)),
            "hv_vm_map RAM"
        )
        if verbose {
            print("  Mapped \(ramSize / (1024*1024)) MiB RAM at PA 0x\(String(ramBase, radix: 16))")
        }
    }

    deinit {
        munmap(ramPtr, ramSize)
        hv_vm_destroy()
    }

    // MARK: - Guest memory access

    /// Convert guest physical address to host pointer. Returns nil if out of range.
    func guestToHost(_ gpa: UInt64) -> UnsafeMutableRawPointer? {
        let offset = gpa - ramBase
        guard offset < UInt64(ramSize) else { return nil }
        return ramPtr.advanced(by: Int(offset))
    }

    /// Write data into guest memory at a guest physical address.
    /// Validates both start and end of the write fall within guest RAM.
    func writeGuest(at gpa: UInt64, data: Data) {
        let offset = gpa &- ramBase
        guard offset < UInt64(ramSize),
              offset &+ UInt64(data.count) <= UInt64(ramSize) else {
            print("WARNING: writeGuest out of range: 0x\(String(gpa, radix: 16)) len=\(data.count)")
            return
        }
        let host = ramPtr.advanced(by: Int(offset))
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Void in
            memcpy(host, buf.baseAddress!, buf.count)
        }
    }

    /// Write bytes into guest memory.
    /// Validates both start and end of the write fall within guest RAM.
    func writeGuest(at gpa: UInt64, bytes: UnsafeRawPointer, count: Int) {
        let offset = gpa &- ramBase
        guard offset < UInt64(ramSize),
              offset &+ UInt64(count) <= UInt64(ramSize) else {
            print("WARNING: writeGuest out of range: 0x\(String(gpa, radix: 16)) len=\(count)")
            return
        }
        let host = ramPtr.advanced(by: Int(offset))
        memcpy(host, bytes, count)
    }

    // MARK: - Virtio device registration

    /// Register a virtio device at the given MMIO slot (0-31).
    /// The device will be placed at PA 0x0A000000 + slot * 0x200 with IRQ 48 + slot.
    func addVirtioDevice(slot: Int, backend: VirtioDeviceBackend) {
        let pa = UInt64(0x0A00_0000) + UInt64(slot) * 0x200
        let irq = UInt32(48 + slot)  // SPI 16+slot = hardware IRQ 48+slot
        let transport = VirtioMMIOTransport(backend: backend, guestPA: pa, irq: irq)
        transport.vm = self
        virtioDevices[slot] = transport
        if verbose {
            print("  Virtio slot \(slot): device_id=\(backend.deviceId) PA=0x\(String(pa, radix: 16)) IRQ=\(irq)")
        }
    }

    /// Look up a virtio transport by guest physical address.
    func virtioTransport(for pa: UInt64) -> (VirtioMMIOTransport, UInt64)? {
        let base = UInt64(0x0A00_0000)
        guard pa >= base && pa < base + 0x4000 else { return nil }
        let offset = pa - base
        let slot = Int(offset / 0x200)
        let regOffset = offset % 0x200
        if let transport = virtioDevices[slot] {
            return (transport, regOffset)
        }
        return nil
    }

    // MARK: - ELF loading

    /// Load an ELF64 binary into guest memory. Returns the entry point address.
    func loadKernelELF(_ data: Data) throws -> UInt64 {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UInt64 in
            let base = buf.baseAddress!

            // Verify ELF magic
            let magic = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard magic == 0x464C457F else {  // "\x7FELF" little-endian
                throw HypervisorError.elfError("bad magic: 0x\(String(magic, radix: 16))")
            }

            // ELF64 header fields
            let elfClass = base.load(fromByteOffset: 4, as: UInt8.self)
            guard elfClass == 2 else {  // ELFCLASS64
                throw HypervisorError.elfError("not ELF64 (class=\(elfClass))")
            }

            let entry = base.loadUnaligned(fromByteOffset: 0x18, as: UInt64.self)
            let phoff = base.loadUnaligned(fromByteOffset: 0x20, as: UInt64.self)
            let phentsize = base.loadUnaligned(fromByteOffset: 0x36, as: UInt16.self)
            let phnum = base.loadUnaligned(fromByteOffset: 0x38, as: UInt16.self)

            if verbose {
                print("  ELF: entry=0x\(String(entry, radix: 16)), \(phnum) program headers")
            }

            // Load PT_LOAD segments, recording VA→PA mappings for entry point resolution.
            struct SegmentMapping {
                let vaddr: UInt64
                let paddr: UInt64
                let memsz: UInt64
            }
            var segments: [SegmentMapping] = []

            for i in 0..<Int(phnum) {
                let phdr = base.advanced(by: Int(phoff) + i * Int(phentsize))
                let pType = phdr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

                guard pType == 1 else { continue }  // PT_LOAD = 1

                let fileOffset = phdr.loadUnaligned(fromByteOffset: 0x08, as: UInt64.self)
                let vaddr = phdr.loadUnaligned(fromByteOffset: 0x10, as: UInt64.self)
                let paddr = phdr.loadUnaligned(fromByteOffset: 0x18, as: UInt64.self)
                let filesz = phdr.loadUnaligned(fromByteOffset: 0x20, as: UInt64.self)
                let memsz = phdr.loadUnaligned(fromByteOffset: 0x28, as: UInt64.self)

                segments.append(SegmentMapping(vaddr: vaddr, paddr: paddr, memsz: memsz))

                // Use physical address (LMA) for loading into guest memory.
                let loadAddr = paddr

                if verbose {
                    print("  LOAD: va=0x\(String(vaddr, radix: 16)) " +
                          "pa=0x\(String(paddr, radix: 16)) " +
                          "filesz=\(filesz) memsz=\(memsz)")
                }

                // Validate the load address is within guest RAM
                guard loadAddr >= ramBase,
                      loadAddr + memsz <= ramBase + UInt64(ramSize) else {
                    if verbose {
                        print("    SKIP (outside RAM range)")
                    }
                    continue
                }

                // Copy file data
                if filesz > 0 {
                    let src = base.advanced(by: Int(fileOffset))
                    writeGuest(at: loadAddr, bytes: src, count: Int(filesz))
                }

                // Zero BSS (memsz > filesz)
                if memsz > filesz {
                    let bssAddr = loadAddr + filesz
                    let bssSize = Int(memsz - filesz)
                    if let host = guestToHost(bssAddr) {
                        memset(host, 0, bssSize)
                    }
                }
            }

            // Resolve entry point: the ELF header reports a virtual address, but the
            // CPU boots with MMU off and needs the physical address. Find the PT_LOAD
            // segment containing the entry VA and compute the corresponding PA.
            for seg in segments {
                if entry >= seg.vaddr && entry < seg.vaddr + seg.memsz {
                    let physEntry = seg.paddr + (entry - seg.vaddr)
                    if verbose {
                        print("  Entry VA 0x\(String(entry, radix: 16)) → PA 0x\(String(physEntry, radix: 16))")
                    }
                    return physEntry
                }
            }

            // No segment contains the entry VA — use it directly (may already be a PA).
            if verbose {
                print("  Entry 0x\(String(entry, radix: 16)) (no VA→PA mapping, using as-is)")
            }
            return entry
        }
    }

    // MARK: - vCPU execution

    /// Run the VM with the given number of vCPUs.
    func run(entryPoint: UInt64, dtbAddress: UInt64, cpuCount: Int) throws {
        // Initialize PSCI tracking
        vcpuEntries = Array(repeating: (0, 0), count: cpuCount)
        vcpuStarted = Array(repeating: false, count: cpuCount)
        vcpuStarted[0] = true  // CPU 0 starts running
        vcpuEntries[0] = (entryPoint, 0)

        // Create and run vCPU 0 on the main thread
        // (Secondary vCPUs will be created when PSCI CPU_ON is called)
        let vcpu = try VCPU(vm: self, index: 0, entryPoint: entryPoint, dtbAddress: dtbAddress)
        try vcpu.run()
    }
}
