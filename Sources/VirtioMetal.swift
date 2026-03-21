/// VirtioMetal — virtio device that receives serialized Metal commands from the guest
/// and replays them via the Metal API.
///
/// Replaces VirtioGPU + gpu_bridge.c + virglrenderer + ANGLE.
/// The guest's metal-render driver emits a command buffer per frame, sends it over
/// virtio, and this device processes it sequentially using Metal.
///
/// Two virtqueues:
///   - Queue 0 (setup): object creation (shaders, pipelines, textures)
///   - Queue 1 (render): per-frame command buffers (draw calls, present)

import Foundation
import Hypervisor
import Metal
import QuartzCore

/// Dedicated serial queue for Metal GPU operations.
/// Ensures all Metal API calls happen on the same thread.
final class GPUThread: @unchecked Sendable {
    private var thread: Thread?
    private let queue = DispatchQueue(label: "metal-gpu", qos: .userInteractive)
    private var started = false

    func start() {
        // No-op — using GCD queue instead of manual thread.
    }

    func runSync(_ block: @escaping () -> Void) {
        queue.sync(execute: block)
    }
}

final class VirtioMetalBackend: VirtioDeviceBackend {
    let deviceId: UInt32 = 22        // custom device ID for metal passthrough
    let deviceFeatures: UInt64 = (1 << 32)  // VIRTIO_F_VERSION_1
    let numQueues: Int = 2           // setup + render
    let maxQueueSize: UInt32 = 256

    var verbose = false

    /// Tracks unknown command IDs already logged (log each ID only once).
    private var loggedUnknownCommands: Set<UInt16> = []

    // Display dimensions
    var displayWidth: UInt32 = 1024
    var displayHeight: UInt32 = 768

    // Frame capture state
    private(set) var frameCount: Int = 0
    var captureAtFrame: Int = -1       // -1 = disabled
    var capturePath: String = "/tmp/hypervisor-capture.png"
    var captureNextFrame: Bool = false  // triggered by SIGUSR1
    var exitAfterCapture: Bool = false

    // Metal state
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let layer: CAMetalLayer

    // Handle table: guest u32 IDs → host Metal objects
    private var libraries: [UInt32: MTLLibrary] = [:]
    private var functions: [UInt32: MTLFunction] = [:]
    private var renderPipelines: [UInt32: MTLRenderPipelineState] = [:]
    private var computePipelines: [UInt32: MTLComputePipelineState] = [:]
    private var depthStencilStates: [UInt32: MTLDepthStencilState] = [:]
    private var samplers: [UInt32: MTLSamplerState] = [:]
    private var textures: [UInt32: MTLTexture] = [:]

    // Vertex descriptor (must match guest's vertex layout)
    private let vertexDescriptor: MTLVertexDescriptor

    // Per-frame state (reset each frame)
    private var currentCommandBuffer: MTLCommandBuffer?
    private var currentRenderEncoder: MTLRenderCommandEncoder?
    private var currentComputeEncoder: MTLComputeCommandEncoder?
    private var currentBlitEncoder: MTLBlitCommandEncoder?
    private var currentDrawable: CAMetalDrawable?

    /// Available ring index tracker per queue.
    private var lastAvailIdx: [UInt16] = [0, 0]

    // Dedicated GPU thread
    private let gpuThread = GPUThread()

    init(device: MTLDevice, layer: CAMetalLayer) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.layer = layer

        // Vertex descriptor matching the guest's Vertex struct:
        // position (float2) + texCoord (float2) + color (float4) = 32 bytes
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float2; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 8;  vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float4; vd.attributes[2].offset = 16; vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 32
        self.vertexDescriptor = vd

        print("VirtioMetal: initialized (\(displayWidth)×\(displayHeight))")
    }

    // MARK: - Config space

    func configRead(offset: UInt64) -> UInt32 {
        switch offset {
        case 0x00: return displayWidth
        case 0x04: return displayHeight
        default: return 0
        }
    }

    func configWrite(offset: UInt64, value: UInt32) {
        // No writable config for now
    }

    // MARK: - Queue notify

    func handleNotify(queue: Int, state: VirtqueueState, vm: VirtualMachine) {
        gpuThread.start()
        gpuThread.runSync {
            if queue == 0 {
                self.processSetupQueue(state: state, vm: vm)
            } else if queue == 1 {
                self.processRenderQueue(state: state, vm: vm)
            }
        }
    }

    // MARK: - Setup queue (object creation)

    private func processSetupQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[0]) {
            // Gather input data
            var inputData = Data()
            for buf in request.buffers where !buf.isDeviceWritable {
                if let host = vm.guestToHost(buf.guestAddr) {
                    inputData.append(contentsOf: UnsafeRawBufferPointer(start: host, count: Int(buf.length)))
                }
            }

            // Process all commands in the buffer
            inputData.withUnsafeBytes { rawBuf in
                processCommandBuffer(rawBuf.baseAddress!, length: inputData.count, isSetup: true)
            }

            // Write minimal response and complete
            virtqueuePushUsed(state: state, vm: vm, headIndex: request.headIndex, bytesWritten: 0)
            raiseInterrupt(vm: vm)
        }
    }

    // MARK: - Render queue (per-frame commands)

    private func processRenderQueue(state: VirtqueueState, vm: VirtualMachine) {
        while let request = virtqueuePopAvail(state: state, vm: vm, lastSeenIdx: &lastAvailIdx[1]) {
            var inputData = Data()
            for buf in request.buffers where !buf.isDeviceWritable {
                if let host = vm.guestToHost(buf.guestAddr) {
                    inputData.append(contentsOf: UnsafeRawBufferPointer(start: host, count: Int(buf.length)))
                }
            }

            inputData.withUnsafeBytes { rawBuf in
                processCommandBuffer(rawBuf.baseAddress!, length: inputData.count, isSetup: false)
            }

            virtqueuePushUsed(state: state, vm: vm, headIndex: request.headIndex, bytesWritten: 0)
            raiseInterrupt(vm: vm)
        }
    }

    // MARK: - Command buffer processing

    /// Process a command buffer. Commands are dispatched by ID regardless of
    /// which queue they arrived on — the queue distinction is transport-level
    /// (setup = synchronous, render = batched), not command-level.
    private func processCommandBuffer(_ base: UnsafeRawPointer, length: Int, isSetup: Bool) {
        var offset = 0
        while offset + MetalCommandHeader.size <= length {
            let hdr = MetalCommandHeader.read(from: base + offset)
            offset += MetalCommandHeader.size

            let payloadSize = Int(hdr.payloadSize)
            guard offset + payloadSize <= length else {
                print("VirtioMetal: truncated command 0x\(String(hdr.methodId, radix: 16))")
                break
            }

            let payload = base + offset
            dispatchCommand(methodId: hdr.methodId, payload: payload, size: payloadSize)
            offset += payloadSize
        }
    }

    /// Unified command dispatch — tries render commands first, falls back to setup.
    private func dispatchCommand(methodId: UInt16, payload: UnsafeRawPointer, size: Int) {
        if MetalRenderCommand(rawValue: methodId) != nil {
            dispatchRenderCommand(methodId: methodId, payload: payload, size: size)
        } else if MetalSetupCommand(rawValue: methodId) != nil {
            dispatchSetupCommand(methodId: methodId, payload: payload, size: size)
        } else if loggedUnknownCommands.insert(methodId).inserted {
            // Log each unknown command ID exactly once (regardless of verbose mode).
            print("VirtioMetal: unknown command 0x\(String(methodId, radix: 16))")
        }
    }

    // MARK: - Setup command dispatch

    private func dispatchSetupCommand(methodId: UInt16, payload: UnsafeRawPointer, size: Int) {
        guard let cmd = MetalSetupCommand(rawValue: methodId) else {
            if verbose { print("VirtioMetal: unknown setup command 0x\(String(methodId, radix: 16))") }
            return
        }

        switch cmd {
        case .compileLibrary:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let srcLen = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard size >= 8 + Int(srcLen) else { return }
            let source = String(bytes: UnsafeRawBufferPointer(start: payload + 8, count: Int(srcLen)),
                                encoding: .utf8) ?? ""
            do {
                let lib = try device.makeLibrary(source: source, options: nil)
                libraries[handle] = lib
                if verbose { print("VirtioMetal: compiled library \(handle)") }
            } catch {
                fatalError("VirtioMetal: shader compilation failed for handle \(handle): \(error)")
            }

        case .getFunction:
            guard size >= 12 else { return }
            let fnHandle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let libHandle = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let nameLen = payload.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            guard size >= 12 + Int(nameLen) else { return }
            let name = String(bytes: UnsafeRawBufferPointer(start: payload + 12, count: Int(nameLen)),
                              encoding: .utf8) ?? ""
            guard let lib = libraries[libHandle] else {
                print("VirtioMetal: getFunction — library \(libHandle) not found")
                return
            }
            guard let fn = lib.makeFunction(name: name) else {
                print("VirtioMetal: getFunction — '\(name)' not found in library \(libHandle)")
                return
            }
            functions[fnHandle] = fn
            if verbose { print("VirtioMetal: function '\(name)' → \(fnHandle)") }

        case .createRenderPipeline:
            guard size >= 16 else { return }
            let handle    = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let vertFn    = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let fragFn    = payload.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let blendOn   = payload.loadUnaligned(fromByteOffset: 12, as: UInt8.self)
            let writeMask = payload.loadUnaligned(fromByteOffset: 13, as: UInt8.self)
            let stencilFmt = payload.loadUnaligned(fromByteOffset: 14, as: UInt8.self)
            let sampleCnt = payload.loadUnaligned(fromByteOffset: 15, as: UInt8.self)

            guard let vfn = functions[vertFn] else {
                print("VirtioMetal: createRenderPipeline \(handle) — vertex function \(vertFn) not found")
                return
            }
            guard let ffn = functions[fragFn] else {
                print("VirtioMetal: createRenderPipeline \(handle) — fragment function \(fragFn) not found")
                return
            }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.vertexDescriptor = vertexDescriptor
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.rasterSampleCount = max(1, Int(sampleCnt))

            if stencilFmt != 0 {
                desc.stencilAttachmentPixelFormat = .stencil8
            }

            if blendOn != 0 {
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }

            desc.colorAttachments[0].writeMask = MTLColorWriteMask(rawValue: UInt(writeMask))

            do {
                renderPipelines[handle] = try device.makeRenderPipelineState(descriptor: desc)
                if verbose { print("VirtioMetal: render pipeline \(handle)") }
            } catch {
                print("VirtioMetal: render pipeline \(handle) failed: \(error)")
            }

        case .createComputePipeline:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let fnHandle = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard let fn = functions[fnHandle] else {
                print("VirtioMetal: createComputePipeline \(handle) — function \(fnHandle) not found")
                return
            }
            do {
                computePipelines[handle] = try device.makeComputePipelineState(function: fn)
                if verbose { print("VirtioMetal: compute pipeline \(handle)") }
            } catch {
                print("VirtioMetal: compute pipeline \(handle) failed: \(error)")
            }

        case .createDepthStencilState:
            guard size >= 8 else { return }
            let handle   = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let enabled  = payload.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let compareFn = payload.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            let passOp   = payload.loadUnaligned(fromByteOffset: 6, as: UInt8.self)
            let failOp   = payload.loadUnaligned(fromByteOffset: 7, as: UInt8.self)

            let desc = MTLDepthStencilDescriptor()
            if enabled != 0 {
                let stencilDesc = MTLStencilDescriptor()
                stencilDesc.stencilCompareFunction = mapCompareFunction(compareFn)
                stencilDesc.depthStencilPassOperation = mapStencilOperation(passOp)
                stencilDesc.stencilFailureOperation = mapStencilOperation(failOp)
                desc.frontFaceStencil = stencilDesc
                desc.backFaceStencil = stencilDesc
            }
            depthStencilStates[handle] = device.makeDepthStencilState(descriptor: desc)
            if verbose { print("VirtioMetal: depth/stencil state \(handle)") }

        case .createSampler:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let minFilt = payload.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let magFilt = payload.loadUnaligned(fromByteOffset: 5, as: UInt8.self)

            let desc = MTLSamplerDescriptor()
            desc.minFilter = minFilt == 0 ? .nearest : .linear
            desc.magFilter = magFilt == 0 ? .nearest : .linear
            desc.sAddressMode = .clampToEdge
            desc.tAddressMode = .clampToEdge
            samplers[handle] = device.makeSamplerState(descriptor: desc)
            if verbose { print("VirtioMetal: sampler \(handle)") }

        case .createTexture:
            guard size >= 12 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let width  = payload.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let height = payload.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            let format = payload.loadUnaligned(fromByteOffset: 8, as: UInt8.self)
            let _ = payload.loadUnaligned(fromByteOffset: 9, as: UInt8.self) // texture type (reserved)
            let samples = payload.loadUnaligned(fromByteOffset: 10, as: UInt8.self)
            let usage   = payload.loadUnaligned(fromByteOffset: 11, as: UInt8.self)

            // SECURITY: Reject unreasonably large textures to prevent VRAM exhaustion.
            // 8192×8192 is the limit for most Metal GPUs and far beyond our display size.
            let maxDim: UInt16 = 8192
            guard width > 0 && height > 0 && width <= maxDim && height <= maxDim else {
                print("VirtioMetal: REJECTED texture \(handle) — dimensions \(width)×\(height) exceed \(maxDim)×\(maxDim) limit")
                return
            }

            let desc = MTLTextureDescriptor()
            desc.width = Int(width)
            desc.height = Int(height)
            desc.pixelFormat = mapPixelFormat(format)
            desc.textureType = samples > 1 ? .type2DMultisample : .type2D
            desc.sampleCount = max(1, Int(samples))
            desc.usage = mapTextureUsage(usage)
            desc.storageMode = (usage & 0x04) != 0 ? .private : .managed

            if let tex = device.makeTexture(descriptor: desc) {
                textures[handle] = tex
                if verbose { print("VirtioMetal: texture \(handle) (\(width)×\(height))") }
            }

        case .uploadTexture:
            guard size >= 16 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let x      = payload.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let y      = payload.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            let w      = payload.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
            let h      = payload.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
            let bpr    = payload.loadUnaligned(fromByteOffset: 12, as: UInt32.self)

            guard let tex = textures[handle] else { return }
            let dataOffset = 16
            guard size >= dataOffset + Int(bpr) * Int(h) else { return }

            let region = MTLRegion(origin: MTLOrigin(x: Int(x), y: Int(y), z: 0),
                                   size: MTLSize(width: Int(w), height: Int(h), depth: 1))
            tex.replace(region: region, mipmapLevel: 0,
                        withBytes: payload + dataOffset, bytesPerRow: Int(bpr))
            if verbose { print("VirtioMetal: upload texture \(handle) (\(w)×\(h))") }

        case .destroyObject:
            guard size >= 4 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            libraries.removeValue(forKey: handle)
            functions.removeValue(forKey: handle)
            renderPipelines.removeValue(forKey: handle)
            computePipelines.removeValue(forKey: handle)
            depthStencilStates.removeValue(forKey: handle)
            samplers.removeValue(forKey: handle)
            textures.removeValue(forKey: handle)
        }
    }

    // MARK: - Render command dispatch

    private func dispatchRenderCommand(methodId: UInt16, payload: UnsafeRawPointer, size: Int) {
        guard let cmd = MetalRenderCommand(rawValue: methodId) else {
            if verbose { print("VirtioMetal: unknown render command 0x\(String(methodId, radix: 16))") }
            return
        }

        switch cmd {
        case .beginRenderPass:
            guard size >= 28 else { return }
            let colorTex   = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let resolveTex = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let stencilTex = payload.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let loadAct    = payload.loadUnaligned(fromByteOffset: 12, as: UInt8.self)
            let storeAct   = payload.loadUnaligned(fromByteOffset: 13, as: UInt8.self)
            let clearR = payload.loadUnaligned(fromByteOffset: 16, as: Float.self)
            let clearG = payload.loadUnaligned(fromByteOffset: 20, as: Float.self)
            let clearB = payload.loadUnaligned(fromByteOffset: 24, as: Float.self)
            let clearA = size >= 32 ? payload.loadUnaligned(fromByteOffset: 28, as: Float.self) : 1.0

            // Resolve texture handles — DRAWABLE_HANDLE means "use the CAMetalLayer drawable"
            let colorTexture: MTLTexture
            if colorTex == DRAWABLE_HANDLE {
                if currentDrawable == nil { currentDrawable = layer.nextDrawable() }
                guard let drawable = currentDrawable else { return }
                colorTexture = drawable.texture
            } else {
                guard let tex = textures[colorTex] else { return }
                colorTexture = tex
            }

            let resolveTexture: MTLTexture?
            if resolveTex == DRAWABLE_HANDLE {
                if currentDrawable == nil { currentDrawable = layer.nextDrawable() }
                resolveTexture = currentDrawable?.texture
            } else if resolveTex == 0 {
                resolveTexture = nil
            } else {
                resolveTexture = textures[resolveTex]
            }

            // Lazily create the per-frame command buffer
            if currentCommandBuffer == nil {
                currentCommandBuffer = commandQueue.makeCommandBuffer()
            }

            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = colorTexture
            passDesc.colorAttachments[0].resolveTexture = resolveTexture
            passDesc.colorAttachments[0].loadAction = mapLoadAction(loadAct)
            passDesc.colorAttachments[0].storeAction = mapStoreAction(storeAct)
            passDesc.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(clearR), green: Double(clearG),
                blue: Double(clearB), alpha: Double(clearA))

            if stencilTex != 0, let sTex = textures[stencilTex] {
                passDesc.stencilAttachment.texture = sTex
                passDesc.stencilAttachment.loadAction = .clear
                passDesc.stencilAttachment.storeAction = .dontCare
            }

            currentRenderEncoder = currentCommandBuffer?.makeRenderCommandEncoder(descriptor: passDesc)

        case .endRenderPass:
            currentRenderEncoder?.endEncoding()
            currentRenderEncoder = nil

        case .setRenderPipeline:
            guard size >= 4 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            if let pipeline = renderPipelines[handle] {
                currentRenderEncoder?.setRenderPipelineState(pipeline)
            }

        case .setDepthStencilState:
            guard size >= 4 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            if let state = depthStencilStates[handle] {
                currentRenderEncoder?.setDepthStencilState(state)
            }

        case .setStencilRef:
            guard size >= 4 else { return }
            let val = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            currentRenderEncoder?.setStencilReferenceValue(val)

        case .setScissor:
            guard size >= 8 else { return }
            let x = payload.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
            let y = payload.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
            let w = payload.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let h = payload.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            currentRenderEncoder?.setScissorRect(MTLScissorRect(
                x: Int(x), y: Int(y), width: Int(w), height: Int(h)))

        case .setVertexBytes:
            guard size >= 8 else { return }
            let bufIdx = payload.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let dataLen = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard size >= 8 + Int(dataLen) else { return }
            currentRenderEncoder?.setVertexBytes(payload + 8, length: Int(dataLen), index: Int(bufIdx))

        case .setFragmentTexture:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let idx = payload.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            if let tex = textures[handle] {
                currentRenderEncoder?.setFragmentTexture(tex, index: Int(idx))
            }

        case .setFragmentSampler:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let idx = payload.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            if let s = samplers[handle] {
                currentRenderEncoder?.setFragmentSamplerState(s, index: Int(idx))
            }

        case .setFragmentBytes:
            guard size >= 8 else { return }
            let bufIdx = payload.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let dataLen = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard size >= 8 + Int(dataLen) else { return }
            currentRenderEncoder?.setFragmentBytes(payload + 8, length: Int(dataLen), index: Int(bufIdx))

        case .drawPrimitives:
            guard size >= 12 else { return }
            let primType = payload.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let vertStart = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let vertCount = payload.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            currentRenderEncoder?.drawPrimitives(
                type: mapPrimitiveType(primType),
                vertexStart: Int(vertStart),
                vertexCount: Int(vertCount))

        case .beginComputePass:
            if currentCommandBuffer == nil {
                currentCommandBuffer = commandQueue.makeCommandBuffer()
            }
            if currentComputeEncoder == nil {
                currentComputeEncoder = currentCommandBuffer?.makeComputeCommandEncoder()
            }

        case .endComputePass:
            currentComputeEncoder?.endEncoding()
            currentComputeEncoder = nil

        case .setComputePipeline:
            guard size >= 4 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            if let pipeline = computePipelines[handle] {
                currentComputeEncoder?.setComputePipelineState(pipeline)
            }

        case .setComputeTexture:
            guard size >= 8 else { return }
            let handle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let idx = payload.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            let tex: MTLTexture?
            if handle == DRAWABLE_HANDLE {
                if currentDrawable == nil { currentDrawable = layer.nextDrawable() }
                tex = currentDrawable?.texture
            } else {
                tex = textures[handle]
            }
            if let tex {
                currentComputeEncoder?.setTexture(tex, index: Int(idx))
            }

        case .setComputeBytes:
            guard size >= 8 else { return }
            let bufIdx = payload.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
            let dataLen = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard size >= 8 + Int(dataLen) else { return }
            currentComputeEncoder?.setBytes(payload + 8, length: Int(dataLen), index: Int(bufIdx))

        case .dispatchThreads:
            guard size >= 12 else { return }
            let gx = payload.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
            let gy = payload.loadUnaligned(fromByteOffset: 2, as: UInt16.self)
            let gz = payload.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            let tx = payload.loadUnaligned(fromByteOffset: 6, as: UInt16.self)
            let ty = payload.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
            let tz = payload.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
            currentComputeEncoder?.dispatchThreads(
                MTLSize(width: Int(gx), height: Int(gy), depth: Int(gz)),
                threadsPerThreadgroup: MTLSize(width: Int(tx), height: Int(ty), depth: Int(tz)))

        case .beginBlitPass:
            if currentCommandBuffer == nil {
                currentCommandBuffer = commandQueue.makeCommandBuffer()
            }
            if currentBlitEncoder == nil {
                currentBlitEncoder = currentCommandBuffer?.makeBlitCommandEncoder()
            }

        case .endBlitPass:
            currentBlitEncoder?.endEncoding()
            currentBlitEncoder = nil

        case .copyTextureRegion:
            guard size >= 20 else { return }
            let srcHandle = payload.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let dstHandle = payload.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            let sx = payload.loadUnaligned(fromByteOffset: 8, as: UInt16.self)
            let sy = payload.loadUnaligned(fromByteOffset: 10, as: UInt16.self)
            let sw = payload.loadUnaligned(fromByteOffset: 12, as: UInt16.self)
            let sh = payload.loadUnaligned(fromByteOffset: 14, as: UInt16.self)
            let dx = payload.loadUnaligned(fromByteOffset: 16, as: UInt16.self)
            let dy = payload.loadUnaligned(fromByteOffset: 18, as: UInt16.self)

            // DRAWABLE_HANDLE → use the current drawable's texture.
            let srcTex: MTLTexture? = srcHandle == DRAWABLE_HANDLE ? currentDrawable?.texture : textures[srcHandle]
            let dstTex: MTLTexture? = dstHandle == DRAWABLE_HANDLE ? currentDrawable?.texture : textures[dstHandle]
            guard let srcTex, let dstTex else { return }
            currentBlitEncoder?.copy(
                from: srcTex, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: Int(sx), y: Int(sy), z: 0),
                sourceSize: MTLSize(width: Int(sw), height: Int(sh), depth: 1),
                to: dstTex, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: Int(dx), y: Int(dy), z: 0))

        case .presentAndCommit:
            // Check SIGUSR1 signal flag (set from signal handler).
            if _signalCaptureFlag {
                _signalCaptureFlag = false
                captureNextFrame = true
            }
            let shouldCapture = captureNextFrame
                || (captureAtFrame >= 0 && frameCount == captureAtFrame)

            if shouldCapture, let drawable = currentDrawable {
                // Blit drawable to a CPU-readable staging texture before present.
                let tex = drawable.texture
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: tex.pixelFormat,
                    width: tex.width, height: tex.height,
                    mipmapped: false)
                desc.storageMode = .shared
                desc.usage = []
                if let staging = device.makeTexture(descriptor: desc) {
                    let cb = commandQueue.makeCommandBuffer()!
                    let blit = cb.makeBlitCommandEncoder()!
                    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: tex.width, height: tex.height, depth: 1),
                              to: staging, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                    cb.commit()
                    cb.waitUntilCompleted()
                    saveTextureAsPNG(staging, path: capturePath)
                    print("VirtioMetal: captured frame \(frameCount) → \(capturePath)")
                }
                captureNextFrame = false
            }

            if let drawable = currentDrawable {
                currentCommandBuffer?.present(drawable)
            }
            currentCommandBuffer?.commit()
            currentCommandBuffer?.waitUntilCompleted()
            frameCount += 1
            currentCommandBuffer = nil
            currentDrawable = nil

            if shouldCapture && exitAfterCapture {
                exit(0)
            }
        }
    }

    // MARK: - Interrupt delivery

    private func raiseInterrupt(vm: VirtualMachine) {
        if let transport = vm.virtioDevices.values.first(where: { $0.backend === self }) {
            transport.raiseInterrupt()
            hv_gic_set_spi(transport.irq, true)
        }
    }

    // MARK: - Wire format → Metal type mappings

    private func mapPixelFormat(_ wire: UInt8) -> MTLPixelFormat {
        switch MetalPixelFormatWire(rawValue: wire) {
        case .bgra8Unorm:  return .bgra8Unorm
        case .rgba8Unorm:  return .rgba8Unorm
        case .r8Unorm:     return .r8Unorm
        case .stencil8:    return .stencil8
        case .rgba16Float: return .rgba16Float
        case .none:        return .bgra8Unorm
        }
    }

    private func mapTextureUsage(_ wire: UInt8) -> MTLTextureUsage {
        var usage: MTLTextureUsage = []
        if (wire & 0x01) != 0 { usage.insert(.shaderRead) }
        if (wire & 0x02) != 0 { usage.insert(.shaderWrite) }
        if (wire & 0x04) != 0 { usage.insert(.renderTarget) }
        return usage.isEmpty ? [.shaderRead] : usage
    }

    private func mapLoadAction(_ wire: UInt8) -> MTLLoadAction {
        switch MetalLoadActionWire(rawValue: wire) {
        case .dontCare: return .dontCare
        case .load:     return .load
        case .clear:    return .clear
        case .none:     return .dontCare
        }
    }

    private func mapStoreAction(_ wire: UInt8) -> MTLStoreAction {
        switch MetalStoreActionWire(rawValue: wire) {
        case .dontCare:          return .dontCare
        case .store:             return .store
        case .multisampleResolve: return .multisampleResolve
        case .none:              return .dontCare
        }
    }

    private func mapPrimitiveType(_ wire: UInt8) -> MTLPrimitiveType {
        switch MetalPrimitiveTypeWire(rawValue: wire) {
        case .triangle:      return .triangle
        case .triangleStrip: return .triangleStrip
        case .line:          return .line
        case .point:         return .point
        case .none:          return .triangle
        }
    }

    private func mapCompareFunction(_ wire: UInt8) -> MTLCompareFunction {
        switch MetalCompareFunctionWire(rawValue: wire) {
        case .never:        return .never
        case .always:       return .always
        case .equal:        return .equal
        case .notEqual:     return .notEqual
        case .less:         return .less
        case .lessEqual:    return .lessEqual
        case .greater:      return .greater
        case .greaterEqual: return .greaterEqual
        case .none:         return .always
        }
    }

    private func mapStencilOperation(_ wire: UInt8) -> MTLStencilOperation {
        switch MetalStencilOperationWire(rawValue: wire) {
        case .keep:           return .keep
        case .zero:           return .zero
        case .replace:        return .replace
        case .incrementClamp: return .incrementClamp
        case .decrementClamp: return .decrementClamp
        case .invert:         return .invert
        case .incrementWrap:  return .incrementWrap
        case .decrementWrap:  return .decrementWrap
        case .none:           return .keep
        }
    }
}

// MARK: - PNG capture

import ImageIO
import CoreGraphics

/// Save a Metal texture (shared storage) as a PNG file.
private func saveTextureAsPNG(_ texture: MTLTexture, path: String) {
    let w = texture.width
    let h = texture.height
    let bpr = w * 4
    var pixels = [UInt8](repeating: 0, count: bpr * h)
    texture.getBytes(&pixels, bytesPerRow: bpr,
                     from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                     size: MTLSize(width: w, height: h, depth: 1)),
                     mipmapLevel: 0)

    // BGRA → RGBA swap (Metal uses BGRA, CGImage expects RGBA).
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let b = pixels[i]
        pixels[i] = pixels[i + 2]
        pixels[i + 2] = b
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: &pixels, width: w, height: h,
                             bitsPerComponent: 8, bytesPerRow: bpr,
                             space: colorSpace,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = ctx.makeImage()
    else {
        print("VirtioMetal: failed to create CGImage for capture")
        return
    }

    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
        print("VirtioMetal: failed to create PNG destination at \(path)")
        return
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
