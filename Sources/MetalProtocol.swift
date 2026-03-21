/// Metal Protocol — command IDs and payload formats for Metal-over-virtio.
///
/// The guest driver writes a flat command buffer (sequence of commands) into the
/// virtio backing store. Each command is:
///
///     [u16 method_id] [u16 flags] [u32 payload_size] [payload bytes...]
///
/// The host reads commands sequentially, dispatches each to the corresponding
/// Metal API call, and processes the entire buffer as one frame.
///
/// Handle model: the guest pre-assigns u32 IDs for all Metal objects (textures,
/// pipelines, etc.). The host maintains a mapping from guest IDs to real Metal
/// objects. If creation fails, subsequent use of that handle is a no-op.
///
/// Two virtqueues:
///   - Queue 0 (setup): object creation commands (shaders, pipelines, textures)
///   - Queue 1 (render): per-frame command buffers (draw calls, present)

import Foundation

// MARK: - Special handles

/// When used as a texture handle, the host acquires the next drawable
/// from CAMetalLayer and uses its texture.
let DRAWABLE_HANDLE: UInt32 = 0xFFFF_FFFF

// MARK: - Command header

/// Every command starts with this 8-byte header.
struct MetalCommandHeader {
    let methodId: UInt16
    let flags: UInt16
    let payloadSize: UInt32

    static let size = 8

    static func read(from ptr: UnsafeRawPointer) -> MetalCommandHeader {
        MetalCommandHeader(
            methodId:    ptr.loadUnaligned(fromByteOffset: 0, as: UInt16.self),
            flags:       ptr.loadUnaligned(fromByteOffset: 2, as: UInt16.self),
            payloadSize: ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        )
    }
}

// MARK: - Command IDs

/// Object creation commands (setup queue).
enum MetalSetupCommand: UInt16 {
    /// Compile MSL source into a library.
    /// Payload: [u32 library_handle] [u32 source_length] [utf8 source...]
    case compileLibrary       = 0x0001

    /// Get a function from a compiled library.
    /// Payload: [u32 function_handle] [u32 library_handle] [u32 name_length] [utf8 name...]
    case getFunction          = 0x0002

    /// Create a render pipeline state.
    /// Payload: [u32 pipeline_handle] [u32 vertex_fn_handle] [u32 fragment_fn_handle]
    ///          [u8 blend_enabled] [u8 color_write_mask] [u8 stencil_format] [u8 sample_count]
    case createRenderPipeline = 0x0010

    /// Create a compute pipeline state.
    /// Payload: [u32 pipeline_handle] [u32 function_handle]
    case createComputePipeline = 0x0011

    /// Create a depth/stencil state.
    /// Payload: [u32 state_handle] [u8 stencil_enabled] [u8 compare_fn]
    ///          [u8 stencil_pass_op] [u8 stencil_fail_op]
    case createDepthStencilState = 0x0012

    /// Create a sampler state.
    /// Payload: [u32 sampler_handle] [u8 min_filter] [u8 mag_filter]
    ///          [u8 s_address_mode] [u8 t_address_mode]
    case createSampler        = 0x0013

    /// Create a texture.
    /// Payload: [u32 texture_handle] [u16 width] [u16 height] [u8 pixel_format]
    ///          [u8 texture_type] [u8 sample_count] [u8 usage_flags]
    case createTexture        = 0x0020

    /// Upload pixel data to a texture.
    /// Payload: [u32 texture_handle] [u16 x] [u16 y] [u16 width] [u16 height]
    ///          [u32 bytes_per_row] [u8... pixel_data]
    case uploadTexture        = 0x0021

    /// Destroy an object (any type).
    /// Payload: [u32 handle]
    case destroyObject        = 0x00FF
}

/// Render commands (render queue, batched per frame).
enum MetalRenderCommand: UInt16 {
    // ── Render pass ──────────────────────────────────────────────────

    /// Begin a render pass.
    /// Payload: [u32 color_texture] [u32 resolve_texture] [u32 stencil_texture]
    ///          [u8 load_action] [u8 store_action] [u8 stencil_load] [u8 stencil_store]
    ///          [f32 clear_r] [f32 clear_g] [f32 clear_b] [f32 clear_a]
    case beginRenderPass      = 0x0100

    /// End the current render pass.
    /// Payload: (none)
    case endRenderPass        = 0x0101

    /// Set the active render pipeline state.
    /// Payload: [u32 pipeline_handle]
    case setRenderPipeline    = 0x0110

    /// Set the active depth/stencil state.
    /// Payload: [u32 state_handle]
    case setDepthStencilState = 0x0111

    /// Set the stencil reference value.
    /// Payload: [u32 value]
    case setStencilRef        = 0x0112

    /// Set scissor rectangle.
    /// Payload: [u16 x] [u16 y] [u16 width] [u16 height]
    case setScissor           = 0x0113

    /// Set inline vertex data.
    /// Payload: [u8 buffer_index] [u8 pad] [u16 pad] [u32 data_length] [u8... data]
    case setVertexBytes       = 0x0120

    /// Bind a texture to a fragment shader slot.
    /// Payload: [u32 texture_handle] [u8 index] [u8 pad] [u16 pad]
    case setFragmentTexture   = 0x0121

    /// Bind a sampler to a fragment shader slot.
    /// Payload: [u32 sampler_handle] [u8 index] [u8 pad] [u16 pad]
    case setFragmentSampler   = 0x0122

    /// Set inline fragment shader data (uniform buffer).
    /// Payload: [u8 index] [u8 pad] [u16 pad] [u32 data_len] [data...]
    case setFragmentBytes     = 0x0123

    /// Draw primitives.
    /// Payload: [u8 primitive_type] [u8 pad] [u16 pad]
    ///          [u32 vertex_start] [u32 vertex_count]
    case drawPrimitives       = 0x0130

    // ── Compute pass ─────────────────────────────────────────────────

    /// Begin a compute pass.
    /// Payload: (none)
    case beginComputePass     = 0x0200

    /// End the current compute pass.
    /// Payload: (none)
    case endComputePass       = 0x0201

    /// Set the active compute pipeline state.
    /// Payload: [u32 pipeline_handle]
    case setComputePipeline   = 0x0210

    /// Bind a texture to a compute shader slot.
    /// Payload: [u32 texture_handle] [u8 index] [u8 pad] [u16 pad]
    case setComputeTexture    = 0x0211

    /// Set inline compute buffer data.
    /// Payload: [u8 buffer_index] [u8 pad] [u16 pad] [u32 data_length] [u8... data]
    case setComputeBytes      = 0x0212

    /// Dispatch compute threads.
    /// Payload: [u16 grid_x] [u16 grid_y] [u16 grid_z]
    ///          [u16 threadgroup_x] [u16 threadgroup_y] [u16 threadgroup_z]
    case dispatchThreads      = 0x0220

    // ── Blit pass ────────────────────────────────────────────────────

    /// Begin a blit pass.
    /// Payload: (none)
    case beginBlitPass        = 0x0300

    /// End the current blit pass.
    /// Payload: (none)
    case endBlitPass          = 0x0301

    /// Copy a region from one texture to another.
    /// Payload: [u32 src_texture] [u32 dst_texture]
    ///          [u16 src_x] [u16 src_y] [u16 src_w] [u16 src_h]
    ///          [u16 dst_x] [u16 dst_y] [u16 pad] [u16 pad]
    case copyTextureRegion    = 0x0310

    // ── Frame control ────────────────────────────────────────────────

    /// Present the drawable and commit the command buffer.
    /// Payload: (none)
    case presentAndCommit     = 0x0F00
}

// MARK: - Pixel format mapping

/// Maps a u8 wire format value to MTLPixelFormat.
/// Only the formats our driver actually uses.
enum MetalPixelFormatWire: UInt8 {
    case bgra8Unorm = 1
    case rgba8Unorm = 2
    case r8Unorm    = 3
    case stencil8   = 4
    case rgba16Float = 5
}

// MARK: - Primitive type mapping

enum MetalPrimitiveTypeWire: UInt8 {
    case triangle      = 0
    case triangleStrip = 1
    case line          = 2
    case point         = 3
}

// MARK: - Load/store action mapping

enum MetalLoadActionWire: UInt8 {
    case dontCare = 0
    case load     = 1
    case clear    = 2
}

enum MetalStoreActionWire: UInt8 {
    case dontCare          = 0
    case store             = 1
    case multisampleResolve = 2
}

// MARK: - Stencil compare function mapping

enum MetalCompareFunctionWire: UInt8 {
    case never        = 0
    case always       = 1
    case equal        = 2
    case notEqual     = 3
    case less         = 4
    case lessEqual    = 5
    case greater      = 6
    case greaterEqual = 7
}

// MARK: - Stencil operation mapping

enum MetalStencilOperationWire: UInt8 {
    case keep            = 0
    case zero            = 1
    case replace         = 2
    case incrementClamp  = 3
    case decrementClamp  = 4
    case invert          = 5
    case incrementWrap   = 6
    case decrementWrap   = 7
}
