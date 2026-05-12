/// Virtio video decode device backend — hardware-accelerated video decoding via
/// macOS VideoToolbox (Apple Media Engine).
///
/// The guest submits compressed video frames over virtio; the host decodes them
/// via VideoToolbox; decoded BGRA pixels are written back to guest memory and/or
/// made available as Metal textures for zero-copy compositing.
///
/// Two virtqueues:
///   - Queue 0 (controlq): session management (create/destroy/flush)
///   - Queue 1 (decodeq): frame submission and decode

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import VideoToolbox

// MARK: - Protocol constants

private let VDEC_CREATE_SESSION: UInt32 = 0x01
private let VDEC_DESTROY_SESSION: UInt32 = 0x02
private let VDEC_FLUSH_SESSION: UInt32 = 0x03

private let VDEC_OK: UInt32 = 0x0000
private let VDEC_ERR_INVALID_SESSION: UInt32 = 0x0001
private let VDEC_ERR_UNSUPPORTED: UInt32 = 0x0002
private let VDEC_ERR_DECODE_FAILED: UInt32 = 0x0003
private let VDEC_ERR_BAD_DATA: UInt32 = 0x0004
private let VDEC_ERR_NO_MEMORY: UInt32 = 0x0005
private let VDEC_ERR_BAD_REQUEST: UInt32 = 0x0006

private let CODEC_MJPEG: UInt8 = 0
private let CODEC_H264: UInt8 = 1
private let CODEC_HEVC: UInt8 = 2
private let CODEC_VP9: UInt8 = 3
private let CODEC_AV1: UInt8 = 4

private let kCodecJPEG: CMVideoCodecType = 0x6A70_6567 // 'jpeg'
private let kCodecH264: CMVideoCodecType = 0x6176_6331 // 'avc1'
private let kCodecHEVC: CMVideoCodecType = 0x6876_6331 // 'hvc1'
private let kCodecVP9: CMVideoCodecType = 0x7670_3039 // 'vp09'
private let kCodecAV1: CMVideoCodecType = 0x6176_3031 // 'av01'

// MARK: - Decode result (passed per-frame via sourceFrameRefCon)

private final class FrameDecodeResult {
    var status: OSStatus = noErr
    var pixelBuffer: CVPixelBuffer?
}

/// C-compatible callback for VTDecompressionSession. Fires synchronously (inline)
/// when decode flags = [] (no async). Writes decoded output to the FrameDecodeResult
/// passed as sourceFrameRefCon.
private func vtDecodeCallback(
    _: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _: VTDecodeInfoFlags,
    _ imageBuffer: CVImageBuffer?,
    _: CMTime,
    _: CMTime
) {
    guard let refCon = sourceFrameRefCon else { return }
    let result = Unmanaged<FrameDecodeResult>.fromOpaque(refCon).takeUnretainedValue()
    result.status = status
    result.pixelBuffer = imageBuffer
}

// MARK: - Per-session state

private final class VideoDecodeSession {
    let sessionId: UInt32
    let codec: UInt8
    let width: UInt32
    let height: UInt32
    let formatDesc: CMVideoFormatDescription
    var vtSession: VTDecompressionSession
    let textureHandle: UInt32
    var lastDecodedBuffer: CVPixelBuffer?

    init(sessionId: UInt32, codec: UInt8, width: UInt32, height: UInt32,
         formatDesc: CMVideoFormatDescription, vtSession: VTDecompressionSession,
         textureHandle: UInt32)
    {
        self.sessionId = sessionId
        self.codec = codec
        self.width = width
        self.height = height
        self.formatDesc = formatDesc
        self.vtSession = vtSession
        self.textureHandle = textureHandle
    }
}

// MARK: - VirtioVideoDecodeBackend

final class VirtioVideoDecodeBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 30
    let deviceFeatures: UInt64 = (1 << 32) // VIRTIO_F_VERSION_1
    let numQueues: Int = 2 // controlq + decodeq
    let maxQueueSize: UInt32 = 64
    weak var transport: VirtioMMIOTransport?

    private let textureRegistry: TextureRegistry
    private let metalDevice: MTLDevice
    private var sessions: [UInt32: VideoDecodeSession] = [:]
    private var lastAvailIdx: [UInt16] = [0, 0]
    private let supportedCodecs: UInt32
    private var decodeCount: Int = 0

    init(textureRegistry: TextureRegistry, metalDevice: MTLDevice) {
        self.textureRegistry = textureRegistry
        self.metalDevice = metalDevice

        var codecs: UInt32 = 0
        codecs |= (1 << 0) // MJPEG — always available via VideoToolbox
        codecs |= (1 << 1) // H.264 — always available on Apple Silicon
        if VTIsHardwareDecodeSupported(kCodecHEVC) { codecs |= (1 << 2) }
        if VTIsHardwareDecodeSupported(kCodecVP9) { codecs |= (1 << 3) }
        if VTIsHardwareDecodeSupported(kCodecAV1) { codecs |= (1 << 4) }
        self.supportedCodecs = codecs
    }

    // MARK: - Config space

    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0x00: return supportedCodecs
        case 0x04: return 8192 // max_width
        case 0x08: return 8192 // max_height
        default: return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {}

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        switch queue {
        case 0: handleControlQueue(state: state, vm: vm)
        case 1: handleDecodeQueue(state: state, vm: vm)
        default: break
        }
    }

    // MARK: - Control queue

    private func handleControlQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[0]) {
            let bytesWritten = processControlRequest(request.buffers, vm: vm)
            virtqueuePushUsed(
                state: state, vm: vm,
                headIndex: request.headIndex, bytesWritten: bytesWritten)
        }
        transport?.raiseInterrupt()
    }

    private func processControlRequest(_ buffers: [VirtqueueBuffer],
                                        vm: VirtualMachine) -> UInt32
    {
        guard let firstBuf = buffers.first,
              !firstBuf.isDeviceWritable,
              firstBuf.length >= 4,
              let headerPtr = vm.guestToHost(firstBuf.guestAddr)
        else {
            return 0
        }

        let requestType = headerPtr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

        guard let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
              let responsePtr = vm.guestToHost(responseBuf.guestAddr)
        else {
            return 0
        }

        switch requestType {
        case VDEC_CREATE_SESSION:
            return handleCreateSession(
                buffers: buffers, headerPtr: headerPtr,
                headerLen: firstBuf.length, responsePtr: responsePtr, vm: vm)
        case VDEC_DESTROY_SESSION:
            return handleDestroySession(headerPtr: headerPtr, responsePtr: responsePtr)
        case VDEC_FLUSH_SESSION:
            return handleFlushSession(headerPtr: headerPtr, responsePtr: responsePtr)
        default:
            responsePtr.storeBytes(
                of: VDEC_ERR_BAD_REQUEST.littleEndian,
                toByteOffset: 0, as: UInt32.self)
            return 4
        }
    }

    // MARK: - Create session

    private func handleCreateSession(
        buffers: [VirtqueueBuffer],
        headerPtr: UnsafeMutableRawPointer,
        headerLen: UInt32,
        responsePtr: UnsafeMutableRawPointer,
        vm: VirtualMachine
    ) -> UInt32 {
        guard headerLen >= 24 else {
            writeError(responsePtr, VDEC_ERR_BAD_REQUEST)
            return 12
        }

        let sessionId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let codec = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt8.self)
        let width = headerPtr.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let height = headerPtr.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        let codecDataSize = headerPtr.loadUnaligned(fromByteOffset: 20, as: UInt32.self)

        guard codec <= CODEC_AV1, (supportedCodecs & (1 << UInt32(codec))) != 0 else {
            writeError(responsePtr, VDEC_ERR_UNSUPPORTED)
            return 12
        }

        // Read optional codec data from second readable descriptor
        var codecData: Data?
        if codecDataSize > 0 {
            if let dataBuf = buffers.dropFirst().first(where: { !$0.isDeviceWritable }),
               dataBuf.length >= codecDataSize,
               let dataPtr = vm.guestToHost(dataBuf.guestAddr)
            {
                codecData = Data(bytes: dataPtr, count: Int(codecDataSize))
            } else {
                writeError(responsePtr, VDEC_ERR_BAD_REQUEST)
                return 12
            }
        }

        // Create CMVideoFormatDescription
        guard let formatDesc = createFormatDescription(
            codec: codec, width: width, height: height, codecData: codecData)
        else {
            writeError(responsePtr, VDEC_ERR_BAD_DATA)
            return 12
        }

        // Configure output: IOSurface-backed BGRA pixel buffers
        let outputAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtDecodeCallback,
            decompressionOutputRefCon: nil
        )

        var vtSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &vtSession
        )

        guard createStatus == noErr, let vtSession else {
            print("VirtioVideoDecode: VTDecompressionSessionCreate failed: \(createStatus)")
            writeError(responsePtr, VDEC_ERR_NO_MEMORY)
            return 12
        }

        // Register a placeholder texture — updated after first decode with the
        // real IOSurface-backed texture from the decoded CVPixelBuffer.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(width), height: Int(height), mipmapped: false)
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .private

        guard let placeholderTex = metalDevice.makeTexture(descriptor: texDesc) else {
            VTDecompressionSessionInvalidate(vtSession)
            writeError(responsePtr, VDEC_ERR_NO_MEMORY)
            return 12
        }

        let textureHandle = textureRegistry.registerHost(texture: placeholderTex)

        let session = VideoDecodeSession(
            sessionId: sessionId, codec: codec,
            width: width, height: height,
            formatDesc: formatDesc, vtSession: vtSession,
            textureHandle: textureHandle)
        sessions[sessionId] = session

        responsePtr.storeBytes(of: VDEC_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        responsePtr.storeBytes(of: textureHandle.littleEndian, toByteOffset: 4, as: UInt32.self)
        responsePtr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 8, as: UInt32.self)

        print("VirtioVideoDecode: session \(sessionId) created"
              + " (codec=\(codec), \(width)×\(height),"
              + " texture=0x\(String(textureHandle, radix: 16)))")
        return 12
    }

    // MARK: - Destroy session

    private func handleDestroySession(
        headerPtr: UnsafeMutableRawPointer,
        responsePtr: UnsafeMutableRawPointer
    ) -> UInt32 {
        let sessionId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)

        guard let session = sessions.removeValue(forKey: sessionId) else {
            writeError(responsePtr, VDEC_ERR_INVALID_SESSION)
            return 4
        }

        VTDecompressionSessionInvalidate(session.vtSession)
        textureRegistry.remove(session.textureHandle)
        session.lastDecodedBuffer = nil

        responsePtr.storeBytes(of: VDEC_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        print("VirtioVideoDecode: session \(sessionId) destroyed")
        return 4
    }

    // MARK: - Flush session

    private func handleFlushSession(
        headerPtr: UnsafeMutableRawPointer,
        responsePtr: UnsafeMutableRawPointer
    ) -> UInt32 {
        let sessionId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)

        guard let session = sessions[sessionId] else {
            writeError(responsePtr, VDEC_ERR_INVALID_SESSION)
            return 4
        }

        // Invalidate and recreate with the same format description.
        VTDecompressionSessionInvalidate(session.vtSession)
        session.lastDecodedBuffer = nil

        let outputAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferWidthKey as String: Int(session.width),
            kCVPixelBufferHeightKey as String: Int(session.height),
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtDecodeCallback,
            decompressionOutputRefCon: nil
        )

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: session.formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            sessions.removeValue(forKey: sessionId)
            textureRegistry.remove(session.textureHandle)
            writeError(responsePtr, VDEC_ERR_DECODE_FAILED)
            return 4
        }

        session.vtSession = newSession
        responsePtr.storeBytes(of: VDEC_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        return 4
    }

    // MARK: - Decode queue

    private func handleDecodeQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[1]) {
            let bytesWritten = processDecodeRequest(request.buffers, vm: vm)
            virtqueuePushUsed(
                state: state, vm: vm,
                headIndex: request.headIndex, bytesWritten: bytesWritten)
        }
        transport?.raiseInterrupt()
    }

    private func processDecodeRequest(_ buffers: [VirtqueueBuffer],
                                       vm: VirtualMachine) -> UInt32
    {
        // Descriptor 0: frame header (readable, 20 bytes)
        guard let headerBuf = buffers.first,
              !headerBuf.isDeviceWritable,
              headerBuf.length >= 20,
              let headerPtr = vm.guestToHost(headerBuf.guestAddr)
        else {
            return 0
        }

        let sessionId = headerPtr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let _ = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self) // flags
        let compressedSize = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let timestampNs = headerPtr.loadUnaligned(fromByteOffset: 16, as: UInt64.self)

        // Descriptor 1: compressed data (readable)
        guard buffers.count >= 3,
              !buffers[1].isDeviceWritable,
              buffers[1].length >= compressedSize,
              let compressedPtr = vm.guestToHost(buffers[1].guestAddr)
        else {
            return writeDecodeError(buffers: buffers, vm: vm, status: VDEC_ERR_BAD_REQUEST)
        }

        guard let session = sessions[sessionId] else {
            return writeDecodeError(buffers: buffers, vm: vm, status: VDEC_ERR_INVALID_SESSION)
        }

        // Find writable descriptors: optional pixel output + mandatory status
        let writableBuffers = buffers.filter { $0.isDeviceWritable }
        guard let statusBuf = writableBuffers.last,
              let statusPtr = vm.guestToHost(statusBuf.guestAddr),
              statusBuf.length >= 24
        else {
            return 0
        }

        // Pixel output descriptor is the first writable buffer (if there are 2+ writable)
        let pixelBuf: VirtqueueBuffer?
        let pixelPtr: UnsafeMutableRawPointer?
        if writableBuffers.count >= 2 {
            pixelBuf = writableBuffers[0]
            pixelPtr = vm.guestToHost(writableBuffers[0].guestAddr)
        } else {
            pixelBuf = nil
            pixelPtr = nil
        }

        // Build CMSampleBuffer from compressed data
        let pts = CMTimeMake(value: Int64(timestampNs), timescale: 1_000_000_000)

        guard let sampleBuffer = createSampleBuffer(
            data: compressedPtr, size: Int(compressedSize),
            formatDesc: session.formatDesc, pts: pts)
        else {
            writeDecodeStatus(
                statusPtr, status: VDEC_ERR_BAD_DATA,
                bytesWritten: 0, timestampNs: timestampNs, durationNs: 0)
            return statusBuf.length
        }

        // Synchronous decode — callback fires inline
        let result = FrameDecodeResult()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session.vtSession,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: Unmanaged.passUnretained(result).toOpaque(),
            infoFlagsOut: nil
        )

        guard decodeStatus == noErr, result.status == noErr,
              let decodedBuffer = result.pixelBuffer
        else {
            writeDecodeStatus(
                statusPtr, status: VDEC_ERR_DECODE_FAILED,
                bytesWritten: 0, timestampNs: timestampNs, durationNs: 0)
            return statusBuf.length
        }

        // Update the shared texture with the decoded IOSurface
        session.lastDecodedBuffer = decodedBuffer
        updateTexture(for: session, pixelBuffer: decodedBuffer)

        decodeCount += 1
        if decodeCount == 1 {
            print("VirtioVideoDecode: first frame decoded via VideoToolbox"
                  + " (\(session.width)×\(session.height),"
                  + " \(compressedSize) bytes compressed)")
        }

        // Copy pixels to guest memory if pixel output descriptor is present
        var bytesWritten: UInt32 = 0
        if let pixelPtr, let pixelBuf {
            bytesWritten = copyPixels(
                from: decodedBuffer, to: pixelPtr,
                maxBytes: pixelBuf.length)
        }

        let durationNs = UInt64(session.width) > 0 ? UInt64(0) : 0

        writeDecodeStatus(
            statusPtr, status: VDEC_OK,
            bytesWritten: bytesWritten,
            timestampNs: timestampNs, durationNs: durationNs)

        // Total bytes written to all writable descriptors
        return bytesWritten + statusBuf.length
    }

    // MARK: - Texture update (IOSurface → Metal)

    private func updateTexture(for session: VideoDecodeSession,
                                pixelBuffer: CVPixelBuffer)
    {
        guard let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = ioSurface.takeUnretainedValue()

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(session.width), height: Int(session.height),
            mipmapped: false)
        texDesc.usage = [.shaderRead]

        guard let texture = metalDevice.makeTexture(
            descriptor: texDesc, iosurface: surface, plane: 0)
        else { return }

        textureRegistry.update(handle: session.textureHandle, texture: texture)
    }

    // MARK: - Pixel copy (CVPixelBuffer → guest memory)

    private func copyPixels(from pixelBuffer: CVPixelBuffer,
                             to dst: UnsafeMutableRawPointer,
                             maxBytes: UInt32) -> UInt32
    {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let expectedBpr = width * 4

        let totalBytes = UInt32(expectedBpr * height)
        guard totalBytes <= maxBytes else { return 0 }

        if bytesPerRow == expectedBpr {
            dst.copyMemory(from: baseAddr, byteCount: Int(totalBytes))
        } else {
            // Row padding differs — copy row by row
            for row in 0..<height {
                let srcRow = baseAddr.advanced(by: row * bytesPerRow)
                let dstRow = dst.advanced(by: row * expectedBpr)
                dstRow.copyMemory(from: srcRow, byteCount: expectedBpr)
            }
        }

        return totalBytes
    }

    // MARK: - CMSampleBuffer creation

    private func createSampleBuffer(
        data: UnsafeMutableRawPointer, size: Int,
        formatDesc: CMVideoFormatDescription, pts: CMTime
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: data,
            blockLength: size,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = size
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Format description creation

    private func createFormatDescription(
        codec: UInt8, width: UInt32, height: UInt32, codecData: Data?
    ) -> CMVideoFormatDescription? {
        switch codec {
        case CODEC_H264:
            if let data = codecData {
                return createH264FormatDescription(data: data)
            }
            return createGenericFormatDescription(codecType: kCodecH264, width: width, height: height)
        case CODEC_HEVC:
            if let data = codecData {
                return createHEVCFormatDescription(data: data)
            }
            return createGenericFormatDescription(codecType: kCodecHEVC, width: width, height: height)
        case CODEC_MJPEG:
            return createGenericFormatDescription(codecType: kCodecJPEG, width: width, height: height)
        case CODEC_VP9:
            return createGenericFormatDescription(codecType: kCodecVP9, width: width, height: height)
        case CODEC_AV1:
            return createGenericFormatDescription(codecType: kCodecAV1, width: width, height: height)
        default:
            return nil
        }
    }

    private func createGenericFormatDescription(
        codecType: CMVideoCodecType, width: UInt32, height: UInt32
    ) -> CMVideoFormatDescription? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        return status == noErr ? formatDesc : nil
    }

    private func createH264FormatDescription(data: Data) -> CMVideoFormatDescription? {
        guard data.count >= 4 else { return nil }

        return data.withUnsafeBytes { rawBuf -> CMVideoFormatDescription? in
            let base = rawBuf.baseAddress!
            let nalLengthSize = Int32(base.load(fromByteOffset: 0, as: UInt8.self))
            let numParamSets = Int(base.load(fromByteOffset: 1, as: UInt8.self))
            guard numParamSets >= 2 else { return nil }

            var offset = 4
            var ptrs = [UnsafePointer<UInt8>]()
            var sizes = [Int]()

            for _ in 0..<numParamSets {
                guard offset + 4 <= data.count else { return nil }
                let nalSize = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                guard offset + nalSize <= data.count else { return nil }
                ptrs.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
                sizes.append(nalSize)
                offset += nalSize
            }

            var formatDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: numParamSets,
                parameterSetPointers: ptrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: nalLengthSize,
                formatDescriptionOut: &formatDesc
            )
            return status == noErr ? formatDesc : nil
        }
    }

    private func createHEVCFormatDescription(data: Data) -> CMVideoFormatDescription? {
        guard data.count >= 4 else { return nil }

        return data.withUnsafeBytes { rawBuf -> CMVideoFormatDescription? in
            let base = rawBuf.baseAddress!
            let nalLengthSize = Int32(base.load(fromByteOffset: 0, as: UInt8.self))
            let numParamSets = Int(base.load(fromByteOffset: 1, as: UInt8.self))
            guard numParamSets >= 3 else { return nil }

            var offset = 4
            var ptrs = [UnsafePointer<UInt8>]()
            var sizes = [Int]()

            for _ in 0..<numParamSets {
                guard offset + 4 <= data.count else { return nil }
                let nalSize = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                guard offset + nalSize <= data.count else { return nil }
                ptrs.append(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self))
                sizes.append(nalSize)
                offset += nalSize
            }

            var formatDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: numParamSets,
                parameterSetPointers: ptrs,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: nalLengthSize,
                extensions: nil,
                formatDescriptionOut: &formatDesc
            )
            return status == noErr ? formatDesc : nil
        }
    }

    // MARK: - Codec mapping

    private func vtCodecType(for codec: UInt8) -> CMVideoCodecType {
        switch codec {
        case CODEC_MJPEG: return kCodecJPEG
        case CODEC_H264: return kCodecH264
        case CODEC_HEVC: return kCodecHEVC
        case CODEC_VP9: return kCodecVP9
        case CODEC_AV1: return kCodecAV1
        default: return kCodecJPEG
        }
    }

    // MARK: - Response helpers

    private func writeError(_ ptr: UnsafeMutableRawPointer, _ status: UInt32) {
        ptr.storeBytes(of: status.littleEndian, toByteOffset: 0, as: UInt32.self)
        ptr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
        ptr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 8, as: UInt32.self)
    }

    private func writeDecodeStatus(
        _ ptr: UnsafeMutableRawPointer,
        status: UInt32, bytesWritten: UInt32,
        timestampNs: UInt64, durationNs: UInt64
    ) {
        ptr.storeBytes(of: status.littleEndian, toByteOffset: 0, as: UInt32.self)
        ptr.storeBytes(of: bytesWritten.littleEndian, toByteOffset: 4, as: UInt32.self)
        ptr.storeBytes(of: timestampNs.littleEndian, toByteOffset: 8, as: UInt64.self)
        ptr.storeBytes(of: durationNs.littleEndian, toByteOffset: 16, as: UInt64.self)
    }

    private func writeDecodeError(
        buffers: [VirtqueueBuffer], vm: VirtualMachine, status: UInt32
    ) -> UInt32 {
        guard let statusBuf = buffers.last(where: { $0.isDeviceWritable }),
              let statusPtr = vm.guestToHost(statusBuf.guestAddr),
              statusBuf.length >= 24
        else {
            return 0
        }
        writeDecodeStatus(
            statusPtr, status: status,
            bytesWritten: 0, timestampNs: 0, durationNs: 0)
        return statusBuf.length
    }
}
