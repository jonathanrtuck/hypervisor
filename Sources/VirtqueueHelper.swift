/// Helpers for reading virtqueue structures from guest memory.
///
/// The guest sets up descriptor tables, available rings, and used rings in
/// guest physical memory. The host reads requests from the available ring,
/// processes them, and writes completions to the used ring.
///
/// Descriptor layout (16 bytes each):
///   addr: u64  — guest physical address of buffer
///   len:  u32  — buffer length
///   flags: u16 — NEXT (1), WRITE (2), INDIRECT (4)
///   next: u16  — next descriptor index (if NEXT flag set)
///
/// Available ring layout:
///   flags: u16, idx: u16, ring: [u16; queue_size], used_event: u16
///
/// Used ring layout:
///   flags: u16, idx: u16, ring: [(id: u32, len: u32); queue_size], avail_event: u16

import Foundation

private let DESC_F_NEXT:  UInt16 = 1
private let DESC_F_WRITE: UInt16 = 2

/// A descriptor chain element.
struct VirtqueueBuffer {
    let guestAddr: UInt64
    let length: UInt32
    let isDeviceWritable: Bool  // true = device writes to this buffer
}

/// Process one request from the virtqueue.
/// Returns the descriptor chain buffers and the head descriptor index,
/// or nil if no requests are available.
func virtqueuePopAvail(
    state: VirtqueueState,
    vm: VirtualMachine,
    lastSeenIdx: inout UInt16
) -> (headIndex: UInt16, buffers: [VirtqueueBuffer])? {
    guard state.ready, state.availPA != 0, state.descPA != 0, state.usedPA != 0 else {
        return nil
    }

    // Read available ring idx
    guard let availBase = vm.guestToHost(state.availPA) else { return nil }
    let availIdx = availBase.load(fromByteOffset: 2, as: UInt16.self)

    if availIdx == lastSeenIdx {
        return nil  // No new requests
    }

    // Read the head descriptor index from the available ring
    let queueSize = state.num
    let ringOffset = 4 + Int(lastSeenIdx % UInt16(queueSize)) * 2
    let headIdx = availBase.load(fromByteOffset: ringOffset, as: UInt16.self)
    lastSeenIdx &+= 1

    // Follow the descriptor chain
    var buffers: [VirtqueueBuffer] = []
    var descIdx = headIdx
    var safety = 0

    while safety < 64 {
        safety += 1
        guard let descBase = vm.guestToHost(state.descPA + UInt64(descIdx) * 16) else { break }

        let addr = descBase.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
        let len = descBase.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let flags = descBase.loadUnaligned(fromByteOffset: 12, as: UInt16.self)
        let next = descBase.loadUnaligned(fromByteOffset: 14, as: UInt16.self)

        buffers.append(VirtqueueBuffer(
            guestAddr: addr,
            length: len,
            isDeviceWritable: (flags & DESC_F_WRITE) != 0
        ))

        if (flags & DESC_F_NEXT) != 0 {
            descIdx = next
        } else {
            break
        }
    }

    return (headIndex: headIdx, buffers: buffers)
}

/// Push a completion into the used ring.
func virtqueuePushUsed(
    state: VirtqueueState,
    vm: VirtualMachine,
    headIndex: UInt16,
    bytesWritten: UInt32
) {
    guard let usedBase = vm.guestToHost(state.usedPA) else { return }

    let queueSize = state.num
    let usedIdx = usedBase.load(fromByteOffset: 2, as: UInt16.self)
    let ringOffset = 4 + Int(usedIdx % UInt16(queueSize)) * 8

    // Write used element: (id: u32, len: u32)
    usedBase.storeBytes(of: UInt32(headIndex), toByteOffset: ringOffset, as: UInt32.self)
    usedBase.storeBytes(of: bytesWritten, toByteOffset: ringOffset + 4, as: UInt32.self)

    // Increment used idx (with memory barrier for guest visibility)
    usedBase.storeBytes(of: usedIdx &+ 1, toByteOffset: 2, as: UInt16.self)
}
