/// Shared texture handle table for Metal and video decode device backends.
///
/// Both VirtioMetal and VirtioVideoDecode hold a reference to the same registry.
/// VirtioMetal reads during draw calls; VirtioVideoDecode writes during session
/// create/destroy. Thread-safe: accesses serialized by an internal lock.
///
/// Handle ranges:
///   0x00000001 – 0x7FFFFFFF: guest-assigned (VirtioMetal CREATE_TEXTURE)
///   0x80000000 – 0xFFFFFFFE: host-assigned (VirtioVideoDecode sessions)
///   0x00000000: invalid
///   0xFFFFFFFF: DRAWABLE_HANDLE (reserved, resolved at render time)

import Foundation
import Metal

final class TextureRegistry: @unchecked Sendable {
    private var textures: [UInt32: MTLTexture] = [:]
    private var nextHostHandle: UInt32 = 0x8000_0000
    private let lock = NSLock()

    func register(guest handle: UInt32, texture: MTLTexture) {
        lock.lock()
        textures[handle] = texture
        lock.unlock()
    }

    func registerHost(texture: MTLTexture) -> UInt32 {
        lock.lock()
        let handle = nextHostHandle
        nextHostHandle += 1
        textures[handle] = texture
        lock.unlock()
        return handle
    }

    func update(handle: UInt32, texture: MTLTexture) {
        lock.lock()
        textures[handle] = texture
        lock.unlock()
    }

    func lookup(_ handle: UInt32) -> MTLTexture? {
        lock.lock()
        let tex = textures[handle]
        lock.unlock()
        return tex
    }

    func remove(_ handle: UInt32) {
        lock.lock()
        textures.removeValue(forKey: handle)
        lock.unlock()
    }
}
