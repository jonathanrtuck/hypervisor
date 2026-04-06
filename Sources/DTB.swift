/// Minimal FDT (Flattened Device Tree) generator.
///
/// Generates a DTB with the minimum nodes needed to boot the OS kernel:
/// - Root node with address/size cells
/// - Memory node (RAM range)
/// - UART (PL011) node at 0x09000000
/// - Chosen node (stdout-path)
///
/// FDT format: https://devicetree-specification.readthedocs.io/
/// The kernel's device_tree.rs parser expects #address-cells=2, #size-cells=2.

import Foundation

enum DTB {
    // FDT structure tokens
    private static let FDT_MAGIC: UInt32       = 0xD00D_FEED
    private static let FDT_BEGIN_NODE: UInt32  = 0x0000_0001
    private static let FDT_END_NODE: UInt32    = 0x0000_0002
    private static let FDT_PROP: UInt32        = 0x0000_0003
    private static let FDT_END: UInt32         = 0x0000_0009

    /// Device descriptor for DTB generation.
    struct DeviceInfo {
        let slot: Int
        let deviceId: UInt32
    }

    /// Generate a DTB with memory, GIC, timer, UART, PSCI, CPUs, and virtio devices.
    static func minimal(ramBase: UInt64, ramSize: Int, cpuCount: Int = 4, virtioDevices: [DeviceInfo] = []) -> Data {
        var b = FDTBuilder()

        let gicPhandle: UInt32 = 1

        // Root node
        b.beginNode("")
        b.prop_u32("#address-cells", 2)
        b.prop_u32("#size-cells", 2)
        b.prop_string("compatible", "linux,dummy-virt")
        b.prop_string("model", "hypervisor-virt")
        b.prop_u32("interrupt-parent", gicPhandle)

        // Memory node
        b.beginNode("memory@\(String(ramBase, radix: 16))")
        b.prop_string("device_type", "memory")
        b.prop_reg(ramBase, UInt64(ramSize))
        b.endNode()

        // GICv3 interrupt controller — describes the hardware GIC created
        // by hv_gic_create(). The kernel can discover GIC base addresses
        // from this node instead of hardcoding them.
        b.beginNode("intc@8000000")
        b.prop_string("compatible", "arm,gic-v3")
        b.prop_u32("#interrupt-cells", 3)
        b.prop_empty("interrupt-controller")
        b.prop_reg2(0x0800_0000, 0x10000, 0x080A_0000, 0x100000)
        b.prop_u32("phandle", gicPhandle)
        b.endNode()

        // ARM generic timer — describes the 4 timer PPIs. The virtual timer
        // (PPI 11 = INTID 27) is the one the kernel uses.
        b.beginNode("timer")
        b.prop_string("compatible", "arm,armv8-timer")
        b.prop_interrupts_multi([
            (type: 1, number: 13, flags: 4),  // Secure physical timer
            (type: 1, number: 14, flags: 4),  // Non-secure physical timer
            (type: 1, number: 11, flags: 4),  // Virtual timer
            (type: 1, number: 10, flags: 4),  // Hypervisor timer
        ])
        b.endNode()

        // UART (PL011) node
        b.beginNode("pl011@9000000")
        b.prop_string("compatible", "arm,pl011\0arm,primecell")
        b.prop_reg(0x0900_0000, 0x1000)
        b.prop_u32("clock-names-hack", 0)  // Kernel doesn't need clocks
        b.endNode()

        // PL031 RTC node — provides wall-clock time from the host.
        b.beginNode("pl031@9010000")
        b.prop_string("compatible", "arm,pl031\0arm,primecell")
        b.prop_reg(0x0901_0000, 0x1000)
        b.endNode()

        // pvpanic node — paravirtual panic notification device.
        b.beginNode("pvpanic@9020000")
        b.prop_string("compatible", "qemu,pvpanic-mmio")
        b.prop_reg(0x0902_0000, 0x2)
        b.endNode()

        // Chosen node (tells kernel where stdout is)
        b.beginNode("chosen")
        b.prop_string("stdout-path", "/pl011@9000000")
        b.endNode()

        // psci node (for CPU_ON)
        b.beginNode("psci")
        b.prop_string("compatible", "arm,psci-1.0")
        b.prop_string("method", "hvc")
        b.endNode()

        // cpus node
        b.beginNode("cpus")
        b.prop_u32("#address-cells", 1)
        b.prop_u32("#size-cells", 0)
        for i in 0..<cpuCount {
            b.beginNode("cpu@\(i)")
            b.prop_string("device_type", "cpu")
            b.prop_u32("reg", UInt32(i))
            b.prop_string("enable-method", "psci")
            b.endNode()
        }
        b.endNode()

        // Virtio MMIO device nodes
        for dev in virtioDevices {
            let pa = UInt64(0x0A00_0000) + UInt64(dev.slot) * 0x200
            let irq = UInt32(16 + dev.slot)  // SPI number (hardware IRQ = irq + 32)
            b.beginNode("virtio_mmio@\(String(pa, radix: 16))")
            b.prop_string("compatible", "virtio,mmio")
            b.prop_reg(pa, 0x200)
            // Interrupts: GIC SPI encoding (type=0, number=irq, flags=4=level-high)
            b.prop_interrupts(type: 0, number: irq, flags: 4)
            b.endNode()
        }

        b.endNode()  // root

        return b.finish()
    }
}

// MARK: - FDT Builder

/// Low-level FDT binary builder.
private struct FDTBuilder {
    private var structData = Data()
    private var strings = Data()
    private var stringOffsets: [String: UInt32] = [:]

    mutating func beginNode(_ name: String) {
        appendU32(0x0000_0001)  // FDT_BEGIN_NODE
        appendString(name)
        alignTo4()
    }

    mutating func endNode() {
        appendU32(0x0000_0002)  // FDT_END_NODE
    }

    mutating func prop_u32(_ name: String, _ value: UInt32) {
        let nameOff = addString(name)
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(4)            // len
        appendU32(nameOff)      // nameoff
        appendU32(value)        // value
    }

    mutating func prop_string(_ name: String, _ value: String) {
        let nameOff = addString(name)
        let valueBytes = Array(value.utf8) + [0]  // null-terminated
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(UInt32(valueBytes.count))
        appendU32(nameOff)
        structData.append(contentsOf: valueBytes)
        alignTo4()
    }

    /// Property with no value — used for flag properties like `interrupt-controller`.
    mutating func prop_empty(_ name: String) {
        let nameOff = addString(name)
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(0)             // len = 0
        appendU32(nameOff)
    }

    /// Property with GIC interrupt specifier (3 cells: type, number, flags).
    mutating func prop_interrupts(type: UInt32, number: UInt32, flags: UInt32) {
        let nameOff = addString("interrupts")
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(12)           // len = 3 x 4 bytes
        appendU32(nameOff)
        appendU32(type)         // 0=SPI, 1=PPI
        appendU32(number)       // Interrupt number (for SPI: offset from 32)
        appendU32(flags)        // 1=edge-rising, 4=level-high
    }

    /// Property with multiple GIC interrupt specifiers (3 cells each).
    mutating func prop_interrupts_multi(_ specs: [(type: UInt32, number: UInt32, flags: UInt32)]) {
        let nameOff = addString("interrupts")
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(UInt32(specs.count * 12))
        appendU32(nameOff)
        for spec in specs {
            appendU32(spec.type)
            appendU32(spec.number)
            appendU32(spec.flags)
        }
    }

    /// Property with a reg entry (address + size, both 64-bit for #cells=2).
    mutating func prop_reg(_ address: UInt64, _ size: UInt64) {
        let nameOff = addString("reg")
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(16)           // len = 2x8 bytes (two 64-bit values)
        appendU32(nameOff)
        appendU64(address)
        appendU64(size)
    }

    /// Property with two reg entries (e.g., GIC distributor + redistributor).
    mutating func prop_reg2(_ addr1: UInt64, _ size1: UInt64, _ addr2: UInt64, _ size2: UInt64) {
        let nameOff = addString("reg")
        appendU32(0x0000_0003)  // FDT_PROP
        appendU32(32)           // len = 4x8 bytes
        appendU32(nameOff)
        appendU64(addr1)
        appendU64(size1)
        appendU64(addr2)
        appendU64(size2)
    }

    mutating func finish() -> Data {
        appendU32(0x0000_0009)  // FDT_END

        // Build the FDT header (40 bytes)
        let headerSize: UInt32 = 40
        let memRsvmapSize: UInt32 = 16  // One empty entry (two u64 zeros)
        let structOff = headerSize + memRsvmapSize
        let stringsOff = structOff + UInt32(structData.count)
        let totalSize = stringsOff + UInt32(strings.count)

        var header = Data()
        appendU32BE(&header, 0xD00D_FEED)  // magic
        appendU32BE(&header, totalSize)     // totalsize
        appendU32BE(&header, structOff)     // off_dt_struct
        appendU32BE(&header, stringsOff)    // off_dt_strings
        appendU32BE(&header, structOff)     // off_mem_rsvmap (= struct offset, rsvmap is before)

        // Actually, mem_rsvmap is between header and struct
        let memRsvmapOff = headerSize
        header.removeLast(4)
        appendU32BE(&header, memRsvmapOff)

        appendU32BE(&header, 17)            // version
        appendU32BE(&header, 16)            // last_comp_version
        appendU32BE(&header, 0)             // boot_cpuid_phys
        appendU32BE(&header, UInt32(strings.count))  // size_dt_strings
        appendU32BE(&header, UInt32(structData.count))  // size_dt_struct

        // Memory reservation map: one empty entry (terminates the list)
        let rsvmap = Data(count: 16)  // 16 bytes of zeros

        var result = header
        result.append(rsvmap)
        result.append(structData)
        result.append(strings)

        return result
    }

    // MARK: - Helpers

    private mutating func appendU32(_ val: UInt32) {
        var be = val.bigEndian
        structData.append(Data(bytes: &be, count: 4))
    }

    private mutating func appendU64(_ val: UInt64) {
        var be = val.bigEndian
        structData.append(Data(bytes: &be, count: 8))
    }

    private func appendU32BE(_ data: inout Data, _ val: UInt32) {
        var be = val.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    private mutating func appendString(_ s: String) {
        structData.append(contentsOf: Array(s.utf8))
        structData.append(0)  // null terminator
    }

    private mutating func alignTo4() {
        while structData.count % 4 != 0 {
            structData.append(0)
        }
    }

    private mutating func addString(_ name: String) -> UInt32 {
        if let existing = stringOffsets[name] {
            return existing
        }
        let offset = UInt32(strings.count)
        stringOffsets[name] = offset
        strings.append(contentsOf: Array(name.utf8))
        strings.append(0)
        return offset
    }
}
