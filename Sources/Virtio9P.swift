/// Virtio 9P filesystem backend — serves host files to the guest via 9P2000.L.
///
/// The guest's virtio-9p driver sends 9P messages through the virtqueue.
/// This backend reads the T-message, executes the filesystem operation on the
/// host macOS filesystem, and writes the R-message response.
///
/// Supported operations: Tversion, Tattach, Twalk, Tlopen, Tread, Tclunk.
/// This is enough for the guest to load fonts and test images from the share dir.

import Foundation

// 9P2000.L message types
private let P9_RLERROR:  UInt8 = 7
private let P9_RLOPEN:   UInt8 = 13
private let P9_RVERSION: UInt8 = 101
private let P9_RATTACH:  UInt8 = 105
private let P9_RWALK:    UInt8 = 111
private let P9_RREAD:    UInt8 = 117
private let P9_RCLUNK:   UInt8 = 121

private let P9_TVERSION: UInt8 = 100
private let P9_TATTACH:  UInt8 = 104
private let P9_TWALK:    UInt8 = 110
private let P9_TLOPEN:   UInt8 = 12
private let P9_TREAD:    UInt8 = 116
private let P9_TCLUNK:   UInt8 = 120

/// A 9P "qid" — unique file identifier (13 bytes: type + version + path).
private struct Qid {
    let type_: UInt8     // 0x80 = dir, 0x00 = file
    let version: UInt32
    let path: UInt64
}

private let QID_DIR:  UInt8 = 0x80
private let QID_FILE: UInt8 = 0x00

final class Virtio9PBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 9
    let deviceFeatures: UInt64 = 1  // VIRTIO_9P_MOUNT_TAG
    let numQueues: Int = 1
    let maxQueueSize: UInt32 = 128

    /// Root directory on the host to serve.
    let rootPath: String

    /// FID → host file path mapping.
    private var fids: [UInt32: String] = [:]

    /// Open file handles (FID → FileHandle).
    private var openFiles: [UInt32: FileHandle] = [:]

    /// Last seen available ring index (for tracking new requests).
    private var lastAvailIdx: UInt16 = 0

    /// Mount tag (shown in virtio config space).
    private let mountTag = "hostshare"

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    // MARK: - Config space

    /// virtio-9p config: u16 tag_len + tag bytes
    func configRead(offset: UInt64) -> UInt32 {
        let tagBytes = Array(mountTag.utf8)
        let configData = withUnsafeBytes(of: UInt16(tagBytes.count).littleEndian) { Array($0) } + tagBytes

        let off = Int(offset)
        var result: UInt32 = 0
        for i in 0..<4 {
            if off + i < configData.count {
                result |= UInt32(configData[off + i]) << (i * 8)
            }
        }
        return result
    }

    func configWrite(offset: UInt64, value: UInt32) {
        // Config is read-only for 9p
    }

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        // Process all available requests
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx) {
            processRequest(request.headIndex, request.buffers, state: state, vm: vm)
        }
    }

    // MARK: - 9P message processing

    private func processRequest(_ headIdx: UInt16, _ buffers: [VirtqueueBuffer],
                                 state: VirtqueueState, vm: VirtualMachine) {
        // Buffer 0 = T-message (readable), Buffer 1 = R-message (writable)
        guard buffers.count >= 2,
              let tBuf = vm.guestToHost(buffers[0].guestAddr),
              let rBuf = vm.guestToHost(buffers[1].guestAddr) else {
            return
        }

        let tLen = buffers[0].length
        let rCapacity = buffers[1].length

        // Parse T-message header: size(4) + type(1) + tag(2)
        guard tLen >= 7 else { return }
        let msgType = tBuf.load(fromByteOffset: 4, as: UInt8.self)
        let tag = tBuf.loadUnaligned(fromByteOffset: 5, as: UInt16.self)

        var writer = P9Writer(buf: rBuf, capacity: Int(rCapacity))

        switch msgType {
        case P9_TVERSION:
            handleVersion(tBuf: tBuf, tag: tag, writer: &writer)
        case P9_TATTACH:
            handleAttach(tBuf: tBuf, tag: tag, writer: &writer)
        case P9_TWALK:
            handleWalk(tBuf: tBuf, tag: tag, writer: &writer)
        case P9_TLOPEN:
            handleLopen(tBuf: tBuf, tag: tag, writer: &writer)
        case P9_TREAD:
            handleRead(tBuf: tBuf, tag: tag, writer: &writer)
        case P9_TCLUNK:
            handleClunk(tBuf: tBuf, tag: tag, writer: &writer)
        default:
            // Unknown message — return ENOSYS
            writeError(&writer, tag: tag, errno: 38)  // ENOSYS
        }

        let responseLen = writer.finish()

        // Push to used ring
        virtqueuePushUsed(state: state, vm: vm, headIndex: headIdx, bytesWritten: UInt32(responseLen))

        // Raise interrupt so guest knows response is ready
        if let transport = vm.virtioDevices.values.first(where: { $0.backend === self }) {
            transport.raiseInterrupt()
        }
    }

    // MARK: - 9P handlers

    private func handleVersion(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        // Tversion: size(4) + type(1) + tag(2) + msize(4) + version_string
        let msize = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)
        let negotiatedMsize = min(msize, 32768)

        writer.putU8(P9_RVERSION)
        writer.putU16(tag)
        writer.putU32(negotiatedMsize)
        writer.putString("9P2000.L")
    }

    private func handleAttach(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        // Tattach: size + type + tag + fid(4) + afid(4) + uname + aname + n_uname(4)
        let fid = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)

        // Map FID 0 to the root directory
        fids[fid] = rootPath

        writer.putU8(P9_RATTACH)
        writer.putU16(tag)
        // Return root qid (directory)
        writeQid(&writer, Qid(type_: QID_DIR, version: 0, path: 0))
    }

    private func handleWalk(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        // Twalk: size + type + tag + fid(4) + newfid(4) + nwname(2) + [name_strings]
        let fid = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)
        let newfid = tBuf.loadUnaligned(fromByteOffset: 11, as: UInt32.self)
        let nwname = tBuf.loadUnaligned(fromByteOffset: 15, as: UInt16.self)

        guard let basePath = fids[fid] else {
            writeError(&writer, tag: tag, errno: 2)  // ENOENT
            return
        }

        var currentPath = basePath
        var qids: [Qid] = []
        var offset = 17  // Past the fixed header

        for _ in 0..<nwname {
            // Read string: u16 len + bytes
            let nameLen = tBuf.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            offset += 2

            let namePtr = tBuf.advanced(by: offset)
            let name = String(bytes: UnsafeRawBufferPointer(start: namePtr, count: Int(nameLen)), encoding: .utf8) ?? ""
            offset += Int(nameLen)

            // SECURITY: Reject path traversal and invalid components.
            // Layer 1: Component-level validation — no "..", ".", path separators, or null bytes.
            if name == ".." || name == "." || name.contains("/") || name.contains("\0") || name.isEmpty {
                fputs("[9p] REJECTED path component: '\(name)' (traversal attempt)\n", stderr)
                writeError(&writer, tag: tag, errno: 1)  // EPERM
                return
            }

            currentPath = (currentPath as NSString).appendingPathComponent(name)

            // SECURITY: Layer 2 — Resolve symlinks and verify the path stays within the root.
            // This catches symlink-based escapes that component validation alone cannot prevent.
            let resolvedPath = (currentPath as NSString).resolvingSymlinksInPath
            let resolvedRoot = (rootPath as NSString).resolvingSymlinksInPath
            guard resolvedPath.hasPrefix(resolvedRoot + "/") || resolvedPath == resolvedRoot else {
                fputs("[9p] REJECTED path escape: '\(resolvedPath)' outside root '\(resolvedRoot)'\n", stderr)
                writeError(&writer, tag: tag, errno: 1)  // EPERM
                return
            }

            // Check if the path exists on the host
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDir) {
                let qidType: UInt8 = isDir.boolValue ? QID_DIR : QID_FILE
                let pathHash = UInt64(currentPath.hashValue & 0x7FFF_FFFF_FFFF_FFFF)
                qids.append(Qid(type_: qidType, version: 0, path: pathHash))
            } else {
                writeError(&writer, tag: tag, errno: 2)  // ENOENT
                return
            }
        }

        // Map newfid to the final path
        fids[newfid] = currentPath

        writer.putU8(P9_RWALK)
        writer.putU16(tag)
        writer.putU16(UInt16(qids.count))
        for qid in qids {
            writeQid(&writer, qid)
        }
    }

    private func handleLopen(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        // Tlopen: size + type + tag + fid(4) + flags(4)
        let fid = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)

        guard let path = fids[fid] else {
            writeError(&writer, tag: tag, errno: 2)
            return
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            writeError(&writer, tag: tag, errno: 13)  // EACCES
            return
        }

        openFiles[fid] = handle

        // Get file size for iounit
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? UInt64) ?? 0

        let pathHash = UInt64(path.hashValue & 0x7FFF_FFFF_FFFF_FFFF)

        writer.putU8(P9_RLOPEN)
        writer.putU16(tag)
        writeQid(&writer, Qid(type_: QID_FILE, version: 0, path: pathHash))
        writer.putU32(min(UInt32(fileSize), 32768 - 24))  // iounit
    }

    private func handleRead(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        // Tread: size + type + tag + fid(4) + offset(8) + count(4)
        let fid = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)
        let readOffset = tBuf.loadUnaligned(fromByteOffset: 11, as: UInt64.self)
        let count = tBuf.loadUnaligned(fromByteOffset: 19, as: UInt32.self)

        guard let handle = openFiles[fid] else {
            writeError(&writer, tag: tag, errno: 9)  // EBADF
            return
        }

        handle.seek(toFileOffset: readOffset)
        let data = handle.readData(ofLength: Int(count))

        writer.putU8(P9_RREAD)
        writer.putU16(tag)
        writer.putU32(UInt32(data.count))
        writer.putData(data)
    }

    private func handleClunk(tBuf: UnsafeMutableRawPointer, tag: UInt16, writer: inout P9Writer) {
        let fid = tBuf.loadUnaligned(fromByteOffset: 7, as: UInt32.self)

        openFiles[fid]?.closeFile()
        openFiles.removeValue(forKey: fid)
        fids.removeValue(forKey: fid)

        writer.putU8(P9_RCLUNK)
        writer.putU16(tag)
    }

    // MARK: - Helpers

    private func writeError(_ writer: inout P9Writer, tag: UInt16, errno: UInt32) {
        writer.putU8(P9_RLERROR)
        writer.putU16(tag)
        writer.putU32(errno)
    }

    private func writeQid(_ writer: inout P9Writer, _ qid: Qid) {
        writer.putU8(qid.type_)
        writer.putU32(qid.version)
        writer.putU64(qid.path)
    }
}

// MARK: - P9Writer

/// Writes 9P response messages into a guest memory buffer.
private struct P9Writer {
    let buf: UnsafeMutableRawPointer
    let capacity: Int
    var pos: Int = 4  // Skip size field (written at finish)

    mutating func putU8(_ v: UInt8) {
        guard pos + 1 <= capacity else { return }
        buf.storeBytes(of: v, toByteOffset: pos, as: UInt8.self)
        pos += 1
    }

    mutating func putU16(_ v: UInt16) {
        guard pos + 2 <= capacity else { return }
        buf.storeBytes(of: v.littleEndian, toByteOffset: pos, as: UInt16.self)
        pos += 2
    }

    mutating func putU32(_ v: UInt32) {
        guard pos + 4 <= capacity else { return }
        buf.storeBytes(of: v.littleEndian, toByteOffset: pos, as: UInt32.self)
        pos += 4
    }

    mutating func putU64(_ v: UInt64) {
        guard pos + 8 <= capacity else { return }
        buf.storeBytes(of: v.littleEndian, toByteOffset: pos, as: UInt64.self)
        pos += 8
    }

    mutating func putString(_ s: String) {
        let bytes = Array(s.utf8)
        putU16(UInt16(bytes.count))
        guard pos + bytes.count <= capacity else { return }
        for (i, byte) in bytes.enumerated() {
            buf.storeBytes(of: byte, toByteOffset: pos + i, as: UInt8.self)
        }
        pos += bytes.count
    }

    mutating func putData(_ data: Data) {
        guard pos + data.count <= capacity else { return }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            buf.advanced(by: pos).copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        pos += data.count
    }

    /// Write the size field and return total response length.
    mutating func finish() -> Int {
        buf.storeBytes(of: UInt32(pos).littleEndian, toByteOffset: 0, as: UInt32.self)
        return pos
    }
}
