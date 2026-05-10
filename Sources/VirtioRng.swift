/// Virtio entropy device backend — provides random bytes to the guest.
///
/// The simplest possible virtio device (spec §5.4, device ID 4). Guest posts
/// writable buffers to queue 0; the host fills them with cryptographically
/// secure random bytes via SecRandomCopyBytes and returns them on the used ring.
/// No config space, no feature bits. Always registered (tiny, harmless).

import Foundation
import Security

final class VirtioRngBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 4  // virtio-rng
    let deviceFeatures: UInt64 = 0
    let numQueues: Int = 1
    let maxQueueSize: UInt32 = 128
    weak var transport: VirtioMMIOTransport?

    private var lastAvailIdx: UInt16 = 0

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        guard queue == 0 else { return }

        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx) {
            var totalWritten: UInt32 = 0

            for buf in request.buffers where buf.isDeviceWritable {
                guard let hostPtr = vm.guestToHost(buf.guestAddr) else { continue }
                let len = Int(buf.length)
                let status = SecRandomCopyBytes(kSecRandomDefault, len, hostPtr)
                if status == errSecSuccess {
                    totalWritten += buf.length
                }
            }

            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: totalWritten)
        }

        transport?.raiseInterrupt()
    }

    func configRead(offset: UInt64) -> UInt32 { 0 }
    func configWrite(offset: UInt64, value: UInt32) {}
}
