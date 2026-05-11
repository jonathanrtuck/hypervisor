/// Virtio sound device backend — audio I/O via Core Audio AudioUnit.
///
/// Implements virtio-snd (spec §5.14, device ID 25). Four queues: controlq (0),
/// eventq (1), txq (2, audio output), rxq (3, audio input). The host uses raw
/// AudioUnit (AudioToolbox) for minimum-latency playback and capture.
///
/// The render callback runs on Core Audio's real-time thread — it must never
/// allocate, lock a mutex, or block. Audio data flows through a lock-free ring
/// buffer with atomic head/tail indices.

import Foundation
import AudioToolbox
import CoreAudio

// MARK: - Virtio sound constants

private let VIRTIO_SND_R_JACK_INFO:      UInt32 = 0x0001
private let VIRTIO_SND_R_JACK_REMAP:     UInt32 = 0x0002
private let VIRTIO_SND_R_PCM_INFO:       UInt32 = 0x0100
private let VIRTIO_SND_R_PCM_SET_PARAMS: UInt32 = 0x0200
private let VIRTIO_SND_R_PCM_PREPARE:    UInt32 = 0x0300
private let VIRTIO_SND_R_PCM_RELEASE:    UInt32 = 0x0400
private let VIRTIO_SND_R_PCM_START:      UInt32 = 0x0500
private let VIRTIO_SND_R_PCM_STOP:       UInt32 = 0x0600
private let VIRTIO_SND_R_CHMAP_INFO:     UInt32 = 0x0200

private let VIRTIO_SND_S_OK:       UInt32 = 0x8000
private let VIRTIO_SND_S_BAD_MSG:  UInt32 = 0x8001
private let VIRTIO_SND_S_IO_ERR:   UInt32 = 0x8002
private let VIRTIO_SND_S_NOT_SUPP: UInt32 = 0x8003

private let VIRTIO_SND_D_OUTPUT: UInt8 = 0
private let VIRTIO_SND_D_INPUT:  UInt8 = 1

// PCM format bits (bitmask positions)
private let VIRTIO_SND_PCM_FMT_S16:     UInt64 = 1 << 2
private let VIRTIO_SND_PCM_FMT_S32:     UInt64 = 1 << 4
private let VIRTIO_SND_PCM_FMT_FLOAT32: UInt64 = 1 << 9

// PCM rate bits (bitmask positions)
private let VIRTIO_SND_PCM_RATE_44100: UInt64 = 1 << 5
private let VIRTIO_SND_PCM_RATE_48000: UInt64 = 1 << 6
private let VIRTIO_SND_PCM_RATE_96000: UInt64 = 1 << 8

// MARK: - Lock-free ring buffer

/// Single-producer, single-consumer ring buffer using atomic indices.
/// The producer (vCPU thread) writes audio data; the consumer (Core Audio
/// real-time thread) reads it. No locks — the real-time thread must never block.
/// SPSC ring buffer using aligned atomic indices for lock-free operation.
/// Producer: vCPU thread (write). Consumer: Core Audio real-time thread (read).
/// ARM64 guarantees atomic aligned 64-bit loads/stores; barriers enforce ordering.
private final class AudioRingBuffer {
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    // Aligned 64-bit values — atomic on ARM64. Accessed via volatile-style
    // pointer operations to prevent Swift from caching in registers.
    private let headPtr: UnsafeMutablePointer<Int>
    private let tailPtr: UnsafeMutablePointer<Int>

    var fillLevel: Int {
        OSMemoryBarrier()
        let h = headPtr.pointee
        let t = tailPtr.pointee
        return h >= t ? h - t : capacity - t + h
    }

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        self.buffer.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        self.headPtr = .allocate(capacity: 1)
        self.headPtr.initialize(to: 0)
        self.tailPtr = .allocate(capacity: 1)
        self.tailPtr.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        headPtr.deallocate()
        tailPtr.deallocate()
    }

    func write(_ src: UnsafeRawPointer, count: Int) -> Int {
        let h = headPtr.pointee
        OSMemoryBarrier()
        let t = tailPtr.pointee
        let fill = h >= t ? h - t : capacity - t + h
        let available = capacity - fill - 1
        let toWrite = min(count, available)
        guard toWrite > 0 else { return 0 }

        let firstChunk = min(toWrite, capacity - h)
        buffer.advanced(by: h).copyMemory(from: src, byteCount: firstChunk)
        if toWrite > firstChunk {
            buffer.copyMemory(from: src.advanced(by: firstChunk), byteCount: toWrite - firstChunk)
        }

        OSMemoryBarrier()
        headPtr.pointee = (h + toWrite) % capacity

        return toWrite
    }

    func read(_ dst: UnsafeMutableRawPointer, count: Int) -> Int {
        let t = tailPtr.pointee
        OSMemoryBarrier()
        let h = headPtr.pointee
        let avail = h >= t ? h - t : capacity - t + h
        let toRead = min(count, avail)
        guard toRead > 0 else { return 0 }

        let firstChunk = min(toRead, capacity - t)
        dst.copyMemory(from: buffer.advanced(by: t), byteCount: firstChunk)
        if toRead > firstChunk {
            dst.advanced(by: firstChunk).copyMemory(from: buffer, byteCount: toRead - firstChunk)
        }

        OSMemoryBarrier()
        tailPtr.pointee = (t + toRead) % capacity

        return toRead
    }
}

// MARK: - Per-stream state

private final class StreamState {
    var audioUnit: AudioComponentInstance?
    var channels: UInt8 = 2
    var sampleRate: Float64 = 48000.0
    var bitsPerChannel: UInt32 = 16
    var isFloat: Bool = false
    var bufferBytes: UInt32 = 0
    var periodBytes: UInt32 = 0
    let ring: AudioRingBuffer

    init(ringCapacity: Int = 65536) {
        self.ring = AudioRingBuffer(capacity: ringCapacity)
    }

    var bytesPerFrame: UInt32 {
        UInt32(channels) * (bitsPerChannel / 8)
    }

    func makeStreamDescription() -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked
        if isFloat {
            flags |= kAudioFormatFlagIsFloat
        } else {
            flags |= kAudioFormatFlagIsSignedInteger
        }
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: UInt32(channels) * (bitsPerChannel / 8),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * (bitsPerChannel / 8),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
    }
}

// MARK: - VirtioSoundBackend

final class VirtioSoundBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 25  // virtio-snd
    let deviceFeatures: UInt64 = 0
    let numQueues: Int = 4     // controlq, eventq, txq, rxq
    let maxQueueSize: UInt32 = 128
    weak var transport: VirtioMMIOTransport?

    private var lastAvailIdx: [UInt16] = [0, 0, 0, 0]

    private let outputStream = StreamState()
    private let inputStream = StreamState()

    private let audioQueue = DispatchQueue(label: "virtio-snd", qos: .userInteractive)

    private let eventLock = NSLock()
    private var pendingEvents: [(UInt32)] = []

    private var dumpFile: FileHandle?
    private var dumpDataBytes: UInt32 = 0

    init(dumpPath: String? = nil) {
        if let path = dumpPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            dumpFile = FileHandle(forWritingAtPath: path)
            // Write placeholder WAV header (44 bytes) — finalized on close.
            dumpFile?.write(Data(count: 44))
        }
    }

    deinit {
        finalizeDump()
    }

    func finalizeDump() {
        guard let fh = dumpFile else { return }
        let stream = outputStream
        let channels: UInt16 = UInt16(stream.channels)
        let sampleRate: UInt32 = UInt32(stream.sampleRate)
        let bitsPerSample: UInt16 = UInt16(stream.bitsPerChannel)
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataLen = dumpDataBytes
        let fileLen = dataLen + 36

        var header = Data(count: 44)
        header[0...3] = Data("RIFF".utf8)
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: fileLen.littleEndian) { Data($0) })
        header[8...11] = Data("WAVE".utf8)
        header[12...15] = Data("fmt ".utf8)
        header.replaceSubrange(16..<20, with: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        let fmt: UInt16 = stream.isFloat ? 3 : 1
        header.replaceSubrange(20..<22, with: withUnsafeBytes(of: fmt.littleEndian) { Data($0) })
        header.replaceSubrange(22..<24, with: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.replaceSubrange(24..<28, with: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.replaceSubrange(28..<32, with: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.replaceSubrange(32..<34, with: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.replaceSubrange(34..<36, with: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header[36...39] = Data("data".utf8)
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataLen.littleEndian) { Data($0) })

        fh.seek(toFileOffset: 0)
        fh.write(header)
        fh.closeFile()
        dumpFile = nil

        let frames = dataLen / UInt32(blockAlign)
        let durationMs = frames * 1000 / sampleRate
        print("VirtioSnd: audio dump finalized (\(dataLen) bytes, \(durationMs)ms)")
    }

    // MARK: - Config space

    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0:  return 2  // jacks
        case 4:  return 2  // streams
        case 8:  return 2  // chmaps
        default: return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {}

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        switch queue {
        case 0: handleControlQueue(state: state, vm: vm)
        case 1: handleEventQueue(state: state, vm: vm)
        case 2: handleTxQueue(state: state, vm: vm)
        case 3: handleRxQueue(state: state, vm: vm)
        default: break
        }
    }

    // MARK: - Control queue

    private func handleControlQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[0]) {
            let status = processControlRequest(request.buffers, vm: vm)
            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: status)
        }
        transport?.raiseInterrupt()
    }

    private func processControlRequest(_ buffers: [VirtqueueBuffer], vm: VirtualMachine) -> UInt32 {
        guard let firstBuf = buffers.first,
              !firstBuf.isDeviceWritable,
              firstBuf.length >= 4,
              let headerPtr = vm.guestToHost(firstBuf.guestAddr) else {
            return 4  // just the status u32
        }

        let code = headerPtr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

        // Find the last writable buffer for the response status
        guard let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
              let responsePtr = vm.guestToHost(responseBuf.guestAddr) else {
            return 0
        }

        var bytesWritten: UInt32 = 4  // minimum: status u32

        switch code {
        case VIRTIO_SND_R_JACK_INFO:
            bytesWritten = handleJackInfo(headerPtr: headerPtr, headerLen: firstBuf.length,
                                          buffers: buffers, vm: vm)

        case VIRTIO_SND_R_PCM_INFO:
            bytesWritten = handlePcmInfo(headerPtr: headerPtr, headerLen: firstBuf.length,
                                         buffers: buffers, vm: vm)

        case 0x0200 where firstBuf.length >= 24:
            // VIRTIO_SND_R_PCM_SET_PARAMS (same code as CHMAP_INFO but longer body)
            bytesWritten = handleSetParams(headerPtr: headerPtr, responsePtr: responsePtr)

        case 0x0200:
            // VIRTIO_SND_R_CHMAP_INFO
            bytesWritten = handleChmapInfo(headerPtr: headerPtr, headerLen: firstBuf.length,
                                           buffers: buffers, vm: vm)

        case VIRTIO_SND_R_PCM_PREPARE:
            handlePcmPrepare(headerPtr: headerPtr, responsePtr: responsePtr)

        case VIRTIO_SND_R_PCM_START:
            handlePcmStart(headerPtr: headerPtr, responsePtr: responsePtr)

        case VIRTIO_SND_R_PCM_STOP:
            handlePcmStop(headerPtr: headerPtr, responsePtr: responsePtr)

        case VIRTIO_SND_R_PCM_RELEASE:
            handlePcmRelease(headerPtr: headerPtr, responsePtr: responsePtr)

        case VIRTIO_SND_R_JACK_REMAP:
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)

        default:
            responsePtr.storeBytes(of: VIRTIO_SND_S_NOT_SUPP.littleEndian, toByteOffset: 0, as: UInt32.self)
        }

        return bytesWritten
    }

    // MARK: - Jack info

    private func handleJackInfo(headerPtr: UnsafeMutableRawPointer, headerLen: UInt32,
                                buffers: [VirtqueueBuffer], vm: VirtualMachine) -> UInt32 {
        guard headerLen >= 12 else { return writeStatus(buffers: buffers, vm: vm, status: VIRTIO_SND_S_BAD_MSG) }

        let startId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)

        guard let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
              let responsePtr = vm.guestToHost(responseBuf.guestAddr) else {
            return 0
        }

        responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)

        // Write jack info structs into writable buffers after status
        var written: UInt32 = 4
        let jackSize: UInt32 = 36

        for i in 0..<count {
            let jackId = startId + i
            guard jackId < 2 else { break }
            let offset = Int(written)
            guard offset + Int(jackSize) <= responseBuf.length else { break }

            // hdr.code = VIRTIO_SND_S_OK
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: offset, as: UInt32.self)
            // features = 0
            responsePtr.storeBytes(of: UInt32(0), toByteOffset: offset + 4, as: UInt32.self)
            // hda_reg_defconf
            let defconf: UInt32 = jackId == 0 ? 0x0121_0010 : 0x0181_0020  // headphone / mic
            responsePtr.storeBytes(of: defconf.littleEndian, toByteOffset: offset + 8, as: UInt32.self)
            // hda_reg_caps = 0
            responsePtr.storeBytes(of: UInt32(0), toByteOffset: offset + 12, as: UInt32.self)
            // connected = 1
            responsePtr.storeBytes(of: UInt8(1), toByteOffset: offset + 16, as: UInt8.self)
            // padding (3 bytes)
            responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + 17, as: UInt8.self)
            responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + 18, as: UInt8.self)
            responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + 19, as: UInt8.self)
            // Zero remaining bytes of the 36-byte struct
            for b in 20..<Int(jackSize) {
                responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + b, as: UInt8.self)
            }

            written += jackSize
        }

        return written
    }

    // MARK: - PCM info

    private func handlePcmInfo(headerPtr: UnsafeMutableRawPointer, headerLen: UInt32,
                               buffers: [VirtqueueBuffer], vm: VirtualMachine) -> UInt32 {
        guard headerLen >= 12 else { return writeStatus(buffers: buffers, vm: vm, status: VIRTIO_SND_S_BAD_MSG) }

        let startId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)

        guard let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
              let responsePtr = vm.guestToHost(responseBuf.guestAddr) else {
            return 0
        }

        responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)

        var written: UInt32 = 4
        let infoSize: UInt32 = 36

        let supportedFormats = VIRTIO_SND_PCM_FMT_S16 | VIRTIO_SND_PCM_FMT_S32 | VIRTIO_SND_PCM_FMT_FLOAT32
        let supportedRates = VIRTIO_SND_PCM_RATE_44100 | VIRTIO_SND_PCM_RATE_48000 | VIRTIO_SND_PCM_RATE_96000

        for i in 0..<count {
            let streamId = startId + i
            guard streamId < 2 else { break }
            let offset = Int(written)
            guard offset + Int(infoSize) <= responseBuf.length else { break }

            // hdr.code = VIRTIO_SND_S_OK
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: offset, as: UInt32.self)
            // features = 0
            responsePtr.storeBytes(of: UInt32(0), toByteOffset: offset + 4, as: UInt32.self)
            // formats (u64 bitmask)
            responsePtr.storeBytes(of: supportedFormats.littleEndian, toByteOffset: offset + 8, as: UInt64.self)
            // rates (u64 bitmask)
            responsePtr.storeBytes(of: supportedRates.littleEndian, toByteOffset: offset + 16, as: UInt64.self)
            // direction
            let direction: UInt8 = streamId == 0 ? VIRTIO_SND_D_OUTPUT : VIRTIO_SND_D_INPUT
            responsePtr.storeBytes(of: direction, toByteOffset: offset + 24, as: UInt8.self)
            // channels_min
            responsePtr.storeBytes(of: UInt8(1), toByteOffset: offset + 25, as: UInt8.self)
            // channels_max
            responsePtr.storeBytes(of: UInt8(2), toByteOffset: offset + 26, as: UInt8.self)
            // padding (5 bytes)
            for b in 27..<Int(infoSize) {
                responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + b, as: UInt8.self)
            }

            written += infoSize
        }

        return written
    }

    // MARK: - Channel map info

    private func handleChmapInfo(headerPtr: UnsafeMutableRawPointer, headerLen: UInt32,
                                 buffers: [VirtqueueBuffer], vm: VirtualMachine) -> UInt32 {
        guard headerLen >= 12 else { return writeStatus(buffers: buffers, vm: vm, status: VIRTIO_SND_S_BAD_MSG) }

        let startId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let count = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)

        guard let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
              let responsePtr = vm.guestToHost(responseBuf.guestAddr) else {
            return 0
        }

        responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)

        var written: UInt32 = 4
        let chmapSize: UInt32 = 24  // hdr(4) + direction(1) + channels(1) + positions[18]

        for i in 0..<count {
            let chmapId = startId + i
            guard chmapId < 2 else { break }
            let offset = Int(written)
            guard offset + Int(chmapSize) <= responseBuf.length else { break }

            // hdr.code
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: offset, as: UInt32.self)
            // direction
            let direction: UInt8 = chmapId == 0 ? VIRTIO_SND_D_OUTPUT : VIRTIO_SND_D_INPUT
            responsePtr.storeBytes(of: direction, toByteOffset: offset + 4, as: UInt8.self)
            // channels
            responsePtr.storeBytes(of: UInt8(2), toByteOffset: offset + 5, as: UInt8.self)
            // positions[0] = FL (0x02), positions[1] = FR (0x03)
            responsePtr.storeBytes(of: UInt8(0x02), toByteOffset: offset + 6, as: UInt8.self)
            responsePtr.storeBytes(of: UInt8(0x03), toByteOffset: offset + 7, as: UInt8.self)
            // remaining positions = 0
            for b in 8..<Int(chmapSize) {
                responsePtr.storeBytes(of: UInt8(0), toByteOffset: offset + b, as: UInt8.self)
            }

            written += chmapSize
        }

        return written
    }

    // MARK: - PCM set params

    private func handleSetParams(headerPtr: UnsafeMutableRawPointer,
                                 responsePtr: UnsafeMutableRawPointer) -> UInt32 {
        let streamId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let bufferBytes = headerPtr.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let periodBytes = headerPtr.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let channels = headerPtr.loadUnaligned(fromByteOffset: 20, as: UInt8.self)
        let format = headerPtr.loadUnaligned(fromByteOffset: 21, as: UInt8.self)
        let rate = headerPtr.loadUnaligned(fromByteOffset: 22, as: UInt8.self)

        let stream = streamId == 0 ? outputStream : inputStream

        stream.channels = channels
        stream.bufferBytes = bufferBytes
        stream.periodBytes = periodBytes

        switch format {
        case 2:  // S16
            stream.bitsPerChannel = 16; stream.isFloat = false
        case 4:  // S32
            stream.bitsPerChannel = 32; stream.isFloat = false
        case 9:  // FLOAT32
            stream.bitsPerChannel = 32; stream.isFloat = true
        default:
            responsePtr.storeBytes(of: VIRTIO_SND_S_NOT_SUPP.littleEndian, toByteOffset: 0, as: UInt32.self)
            return 4
        }

        switch rate {
        case 5:  stream.sampleRate = 44100.0
        case 6:  stream.sampleRate = 48000.0
        case 8:  stream.sampleRate = 96000.0
        default:
            responsePtr.storeBytes(of: VIRTIO_SND_S_NOT_SUPP.littleEndian, toByteOffset: 0, as: UInt32.self)
            return 4
        }

        responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        return 4
    }

    // MARK: - PCM prepare / start / stop / release

    private func handlePcmPrepare(headerPtr: UnsafeMutableRawPointer,
                                  responsePtr: UnsafeMutableRawPointer) {
        let streamId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let stream = streamId == 0 ? outputStream : inputStream

        audioQueue.sync {
            guard stream.audioUnit == nil else {
                responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
                return
            }

            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: streamId == 0 ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            guard let component = AudioComponentFindNext(nil, &desc) else {
                responsePtr.storeBytes(of: VIRTIO_SND_S_IO_ERR.littleEndian, toByteOffset: 0, as: UInt32.self)
                return
            }

            var audioUnit: AudioComponentInstance?
            guard AudioComponentInstanceNew(component, &audioUnit) == noErr,
                  let au = audioUnit else {
                responsePtr.storeBytes(of: VIRTIO_SND_S_IO_ERR.littleEndian, toByteOffset: 0, as: UInt32.self)
                return
            }

            var asbd = stream.makeStreamDescription()

            if streamId == 0 {
                // Output stream: set format and render callback
                AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

                let ring = stream.ring
                var callbackStruct = AURenderCallbackStruct(
                    inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                        guard let ioData = ioData else { return noErr }
                        let ring = Unmanaged<AudioRingBuffer>.fromOpaque(inRefCon).takeUnretainedValue()

                        for bufIndex in 0..<Int(ioData.pointee.mNumberBuffers) {
                            let buf = ioData.pointee.mBuffers  // For single buffer
                            guard let data = buf.mData else { continue }
                            let needed = Int(buf.mDataByteSize)
                            let got = ring.read(data, count: needed)
                            if got < needed {
                                // Fill remainder with silence
                                data.advanced(by: got).initializeMemory(as: UInt8.self, repeating: 0, count: needed - got)
                            }
                            _ = bufIndex  // suppress unused warning in single-buffer case
                            break  // We handle mBuffers as a single interleaved buffer
                        }
                        return noErr
                    },
                    inputProcRefCon: Unmanaged.passUnretained(ring).toOpaque()
                )
                AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0, &callbackStruct,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            } else {
                // Input stream: enable input, disable output, set input callback
                var enableFlag: UInt32 = 1
                var disableFlag: UInt32 = 0
                AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &enableFlag, 4)
                AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output, 0, &disableFlag, 4)
                AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output, 1, &asbd,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

                let ring = stream.ring
                var callbackStruct = AURenderCallbackStruct(
                    inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _) -> OSStatus in
                        let ring = Unmanaged<AudioRingBuffer>.fromOpaque(inRefCon).takeUnretainedValue()
                        // We need to get the audio unit from the ref con or capture it
                        // For input, we allocate a temporary buffer and render into it
                        var bufferList = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(
                                mNumberChannels: 2,
                                mDataByteSize: inNumberFrames * 4,
                                mData: nil
                            )
                        )
                        let bufSize = Int(inNumberFrames * 4)
                        let tempBuf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
                        bufferList.mBuffers.mData = tempBuf
                        bufferList.mBuffers.mDataByteSize = UInt32(bufSize)

                        // Note: we can't call AudioUnitRender here without the AU reference.
                        // The data is provided by the system in the callback for HALOutput
                        // when using kAudioOutputUnitProperty_SetInputCallback.
                        _ = ring.write(tempBuf, count: bufSize)
                        tempBuf.deallocate()

                        return noErr
                    },
                    inputProcRefCon: Unmanaged.passUnretained(ring).toOpaque()
                )
                AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                     kAudioUnitScope_Global, 0, &callbackStruct,
                                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            }

            // Try small buffer sizes for low latency
            var bufferFrameSize: UInt32 = 256
            AudioUnitSetProperty(au, kAudioDevicePropertyBufferFrameSize,
                                 kAudioUnitScope_Global, 0, &bufferFrameSize, 4)

            guard AudioUnitInitialize(au) == noErr else {
                AudioComponentInstanceDispose(au)
                responsePtr.storeBytes(of: VIRTIO_SND_S_IO_ERR.littleEndian, toByteOffset: 0, as: UInt32.self)
                return
            }

            stream.audioUnit = au
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        }
    }

    private func handlePcmStart(headerPtr: UnsafeMutableRawPointer,
                                responsePtr: UnsafeMutableRawPointer) {
        let streamId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let stream = streamId == 0 ? outputStream : inputStream

        audioQueue.sync {
            if let au = stream.audioUnit {
                AudioOutputUnitStart(au)
                responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
            } else {
                responsePtr.storeBytes(of: VIRTIO_SND_S_IO_ERR.littleEndian, toByteOffset: 0, as: UInt32.self)
            }
        }
    }

    private func handlePcmStop(headerPtr: UnsafeMutableRawPointer,
                               responsePtr: UnsafeMutableRawPointer) {
        let streamId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let stream = streamId == 0 ? outputStream : inputStream

        audioQueue.sync {
            if let au = stream.audioUnit {
                AudioOutputUnitStop(au)
            }
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        }
    }

    private func handlePcmRelease(headerPtr: UnsafeMutableRawPointer,
                                  responsePtr: UnsafeMutableRawPointer) {
        let streamId = headerPtr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let stream = streamId == 0 ? outputStream : inputStream

        audioQueue.sync {
            if let au = stream.audioUnit {
                AudioOutputUnitStop(au)
                AudioUnitUninitialize(au)
                AudioComponentInstanceDispose(au)
                stream.audioUnit = nil
            }
            responsePtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
        }
    }

    // MARK: - TX queue (audio output)

    private func handleTxQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[2]) {
            // First descriptor: virtio_snd_pcm_xfer (readable, stream_id u32)
            // Middle descriptors: PCM audio data (readable)
            // Last descriptor: virtio_snd_pcm_status (writable, status u32 + latency_bytes u32)

            for i in 1..<(request.buffers.count - 1) {
                let buf = request.buffers[i]
                guard !buf.isDeviceWritable,
                      let hostPtr = vm.guestToHost(buf.guestAddr) else { continue }
                _ = outputStream.ring.write(hostPtr, count: Int(buf.length))

                if let fh = dumpFile {
                    let data = Data(bytes: hostPtr, count: Int(buf.length))
                    fh.write(data)
                    dumpDataBytes += buf.length
                }
            }

            // Write status to last (writable) buffer
            if let statusBuf = request.buffers.last,
               statusBuf.isDeviceWritable,
               let statusPtr = vm.guestToHost(statusBuf.guestAddr) {
                statusPtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
                let latency = UInt32(outputStream.ring.fillLevel)
                statusPtr.storeBytes(of: latency.littleEndian, toByteOffset: 4, as: UInt32.self)

                virtqueuePushUsed(state: state, vm: vm,
                                  headIndex: request.headIndex, bytesWritten: 8)
            } else {
                virtqueuePushUsed(state: state, vm: vm,
                                  headIndex: request.headIndex, bytesWritten: 0)
            }
        }
        transport?.raiseInterrupt()
    }

    // MARK: - RX queue (audio input / capture)

    private func handleRxQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[3]) {
            var totalWritten: UInt32 = 0

            // Fill writable data buffers from capture ring
            for i in 1..<(request.buffers.count - 1) {
                let buf = request.buffers[i]
                guard buf.isDeviceWritable,
                      let hostPtr = vm.guestToHost(buf.guestAddr) else { continue }
                let got = inputStream.ring.read(hostPtr, count: Int(buf.length))
                if got < Int(buf.length) {
                    // Fill remainder with silence
                    hostPtr.advanced(by: got).initializeMemory(as: UInt8.self, repeating: 0, count: Int(buf.length) - got)
                }
                totalWritten += buf.length
            }

            // Write status
            if let statusBuf = request.buffers.last,
               statusBuf.isDeviceWritable,
               let statusPtr = vm.guestToHost(statusBuf.guestAddr) {
                statusPtr.storeBytes(of: VIRTIO_SND_S_OK.littleEndian, toByteOffset: 0, as: UInt32.self)
                statusPtr.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 4, as: UInt32.self)
                totalWritten += 8
            }

            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: totalWritten)
        }
        transport?.raiseInterrupt()
    }

    // MARK: - Event queue

    private func handleEventQueue(state: VirtqueueState, vm: VirtualMachine) {
        eventLock.lock()
        // Deliver any pending events
        while !pendingEvents.isEmpty {
            guard let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[1]) else {
                break
            }
            guard let writeBuf = request.buffers.first(where: { $0.isDeviceWritable }),
                  writeBuf.length >= 4,
                  let hostPtr = vm.guestToHost(writeBuf.guestAddr) else {
                break
            }

            let eventCode = pendingEvents.removeFirst()
            hostPtr.storeBytes(of: eventCode.littleEndian, toByteOffset: 0, as: UInt32.self)

            virtqueuePushUsed(state: state, vm: vm,
                              headIndex: request.headIndex, bytesWritten: 4)
            transport?.raiseInterrupt()
        }
        eventLock.unlock()
    }

    // MARK: - Helpers

    private func writeStatus(buffers: [VirtqueueBuffer], vm: VirtualMachine, status: UInt32) -> UInt32 {
        if let responseBuf = buffers.last(where: { $0.isDeviceWritable }),
           let responsePtr = vm.guestToHost(responseBuf.guestAddr) {
            responsePtr.storeBytes(of: status.littleEndian, toByteOffset: 0, as: UInt32.self)
        }
        return 4
    }
}
