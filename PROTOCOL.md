# Metal-over-Virtio Protocol Specification

This document specifies the wire format for Metal GPU command passthrough
between an ARM64 guest and the macOS host hypervisor. It is the source of truth
for guest driver implementors.

## Overview

The protocol enables a guest kernel to issue Metal rendering commands without
any translation layers. The guest serializes Metal API calls into a flat command
buffer, sends it over a virtio device, and the host deserializes and replays
each command via the native Metal API.

### Design Principles

- **Thin proxy.** Commands map 1:1 to Metal API calls. No abstraction, no
  batching, no reinterpretation.
- **Guest-assigned handles.** The guest pre-assigns `u32` IDs for all Metal
  objects. The host maintains a mapping to real Metal objects. Invalid handles
  are silently ignored.
- **Two queues.** Setup commands (object creation) and render commands
  (per-frame) use separate virtqueues to allow independent flow control.
- **Flat encoding.** No nested structures, no variable-length arrays within
  fixed fields. Every command can be parsed with sequential reads.

## Transport

The Metal GPU device uses virtio MMIO with **device ID 22** (custom).

| Queue  | Index | Purpose                     | Typical Usage                            |
| ------ | ----- | --------------------------- | ---------------------------------------- |
| Setup  | 0     | Object creation/destruction | Once at init, occasional texture uploads |
| Render | 1     | Per-frame command buffers   | Every frame                              |

The guest writes one or more commands into a virtio descriptor chain. The host
processes all commands in the chain sequentially, then marks the descriptor as
used.

## Config Space

The Metal device config space exposes display parameters. All fields are
read-only, little-endian u32.

| Offset | Field        | Description                                         |
| ------ | ------------ | --------------------------------------------------- |
| 0x00   | width        | Display width in pixels                             |
| 0x04   | height       | Display height in pixels                            |
| 0x08   | refresh_hz   | Host display refresh rate (e.g., 60, 120)           |
| 0x0C   | scale_factor | Display backing scale factor (1 = 1x, 2 = Retina)   |
| 0x10   | has_display  | 1 if visible window, 0 if headless (`--background`) |

The guest reads width/height to size its framebuffer and viewport.

### Vsync Notification

The host raises a config change interrupt (`InterruptStatus` bit 1) at the
display's native refresh rate via `CADisplayLink`. The guest can use this as a
vsync signal to pace frame submission. In headless mode (`--background`), no
vsync interrupts are delivered.

## Command Format

Every command starts with an 8-byte header:

```text
Offset  Size  Field
0       u16   method_id      Command identifier
2       u16   flags          Reserved (must be 0)
4       u32   payload_size   Size of payload in bytes (following this header)
```

Commands are packed sequentially in the virtio buffer with no padding between
them.

## Special Handles

| Handle            | Value        | Meaning                                                         |
| ----------------- | ------------ | --------------------------------------------------------------- |
| `DRAWABLE_HANDLE` | `0xFFFFFFFF` | When used as a texture, acquires the next CAMetalLayer drawable |

## Setup Commands (Queue 0)

### `COMPILE_LIBRARY` (0x0001)

Compile Metal Shading Language source into a library.

```text
Payload:
  u32   library_handle     Guest-assigned handle for the compiled library
  u32   source_length      Length of MSL source in bytes
  u8[]  source             UTF-8 MSL source code
```

The host calls `MTLDevice.makeLibrary(source:)`. Compilation errors are logged
but do not halt the guest — subsequent use of the handle is a no-op.

### `GET_FUNCTION` (0x0002)

Get a named function from a compiled library.

```text
Payload:
  u32   function_handle    Guest-assigned handle for the function
  u32   library_handle     Handle of the compiled library
  u32   name_length        Length of function name in bytes
  u8[]  name               UTF-8 function name
```

### `CREATE_RENDER_PIPELINE` (0x0010)

Create a render pipeline state object.

```text
Payload (17 bytes):
  u32   pipeline_handle       Guest-assigned handle
  u32   vertex_fn_handle      Handle of vertex function
  u32   fragment_fn_handle    Handle of fragment function
  u8    blend_enabled         1 = source-over alpha blending
  u8    color_write_mask      Bitmask: R=8, G=4, B=2, A=1 (0xF = all)
  u8    stencil_format        0 = no stencil, 1 = stencil8
  u8    sample_count          MSAA sample count (1 or 4)
  u8    pixel_format          Color attachment format (see CREATE_TEXTURE)
```

**Vertex layout convention:** The default vertex descriptor is:

| Attribute | Index | Format | Offset | Description         |
| --------- | ----- | ------ | ------ | ------------------- |
| position  | 0     | float2 | 0      | Clip-space position |
| texCoord  | 1     | float2 | 8      | Texture coordinates |
| color     | 2     | float4 | 16     | RGBA color          |

Stride: **32 bytes**, buffer index 0.

This layout is used for all render pipelines. Guest shaders must match this
vertex input layout.

### `CREATE_COMPUTE_PIPELINE` (0x0011)

Create a compute pipeline state object.

```text
Payload:
  u32   pipeline_handle    Guest-assigned handle
  u32   function_handle    Handle of compute function
```

### `CREATE_DEPTH_STENCIL_STATE` (0x0012)

Create a depth/stencil state object.

```text
Payload:
  u32   state_handle       Guest-assigned handle
  u8    stencil_enabled    1 = enable stencil test
  u8    compare_fn         Comparison function (see enum below)
  u8    stencil_pass_op    Operation on stencil pass
  u8    stencil_fail_op    Operation on stencil fail
```

### `CREATE_SAMPLER` (0x0013)

Create a sampler state object.

```text
Payload:
  u32   sampler_handle     Guest-assigned handle
  u8    min_filter         0 = nearest, 1 = linear
  u8    mag_filter         0 = nearest, 1 = linear
  u8    s_address_mode     Address mode for S coordinate
  u8    t_address_mode     Address mode for T coordinate
```

Address modes: 0 = clampToEdge, 1 = repeat, 2 = mirrorRepeat, 3 = clampToZero.

### `CREATE_TEXTURE` (0x0020)

Create a texture object.

```text
Payload:
  u32   texture_handle     Guest-assigned handle
  u16   width              Width in pixels
  u16   height             Height in pixels
  u8    pixel_format       Pixel format (see enum below)
  u8    texture_type       0 = 2D, 1 = 2DMultisample
  u8    sample_count       MSAA sample count (1 for regular, 4 for MSAA)
  u8    usage_flags        Bitmask: shaderRead=1, renderTarget=2, shaderWrite=4
```

### `UPLOAD_TEXTURE` (0x0021)

Upload pixel data to a region of a texture.

```text
Payload:
  u32   texture_handle     Target texture handle
  u16   x                  Destination X offset
  u16   y                  Destination Y offset
  u16   width              Region width
  u16   height             Region height
  u32   bytes_per_row      Source row stride in bytes
  u8[]  pixel_data         Raw pixel data (width * height * bpp)
```

### `BIND_HOST_TEXTURE` (0x0022)

Bind a host-assigned texture handle to a guest-assigned texture ID. This allows
the guest to reference host-created textures (e.g., from video decode sessions)
in Metal render commands using a guest-chosen handle.

```text
Payload:
  u32   guest_tex_id     Guest-assigned handle to create/overwrite
  u32   host_handle      Host-assigned handle (from video decode CREATE_SESSION)
```

The host looks up the real `MTLTexture` for `host_handle` in the shared
`TextureRegistry` and registers it under `guest_tex_id`. After binding, the
guest can use `guest_tex_id` in `SET_FRAGMENT_TEXTURE`, `SET_COMPUTE_TEXTURE`,
and other texture-referencing commands.

### `DESTROY_OBJECT` (0x00FF)

Destroy any previously created object.

```text
Payload:
  u32   handle             Handle of the object to destroy
```

The host removes the handle from all object tables (libraries, functions,
pipelines, textures, etc.).

## Render Commands (Queue 1)

### Render Pass

#### `BEGIN_RENDER_PASS` (0x0100)

Begin a new render pass.

```text
Payload:
  u32   color_texture      Color attachment handle (DRAWABLE_HANDLE for screen)
  u32   resolve_texture    MSAA resolve target (DRAWABLE_HANDLE or 0 for none)
  u32   stencil_texture    Stencil attachment handle (0 for none)
  u8    load_action        Color load action
  u8    store_action       Color store action
  u8    stencil_load       Stencil load action
  u8    stencil_store      Stencil store action
  f32   clear_r            Clear color red (0.0 - 1.0)
  f32   clear_g            Clear color green
  f32   clear_b            Clear color blue
  f32   clear_a            Clear color alpha
```

#### `END_RENDER_PASS` (0x0101)

End the current render pass encoder.

```text
Payload: (none)
```

### Render State

#### `SET_RENDER_PIPELINE` (0x0110)

```text
Payload:
  u32   pipeline_handle
```

#### `SET_DEPTH_STENCIL_STATE` (0x0111)

```text
Payload:
  u32   state_handle
```

#### `SET_STENCIL_REF` (0x0112)

```text
Payload:
  u32   value              Stencil reference value
```

#### `SET_SCISSOR` (0x0113)

```text
Payload:
  u16   x
  u16   y
  u16   width
  u16   height
```

### Vertex and Fragment Data

#### `SET_VERTEX_BYTES` (0x0120)

Set inline vertex data (up to 4 KB per Metal call).

```text
Payload:
  u8    buffer_index       Metal buffer index (typically 0 for vertices, 1 for uniforms)
  u8    pad
  u16   pad
  u32   data_length        Length of vertex data in bytes
  u8[]  data               Raw vertex data
```

#### `SET_FRAGMENT_TEXTURE` (0x0121)

Bind a texture to a fragment shader slot.

```text
Payload:
  u32   texture_handle
  u8    index              Fragment texture index
  u8    pad
  u16   pad
```

#### `SET_FRAGMENT_SAMPLER` (0x0122)

Bind a sampler to a fragment shader slot.

```text
Payload:
  u32   sampler_handle
  u8    index              Fragment sampler index
  u8    pad
  u16   pad
```

#### `SET_FRAGMENT_BYTES` (0x0123)

Set inline fragment shader uniform data.

```text
Payload:
  u8    index              Metal buffer index
  u8    pad
  u16   pad
  u32   data_length        Length of uniform data
  u8[]  data               Raw uniform data
```

### Drawing

#### `DRAW_PRIMITIVES` (0x0130)

```text
Payload:
  u8    primitive_type     Primitive type (see enum below)
  u8    pad
  u16   pad
  u32   vertex_start       First vertex index
  u32   vertex_count       Number of vertices to draw
```

### Compute Pass

#### `BEGIN_COMPUTE_PASS` (0x0200)

```text
Payload: (none)
```

#### `END_COMPUTE_PASS` (0x0201)

```text
Payload: (none)
```

#### `SET_COMPUTE_PIPELINE` (0x0210)

```text
Payload:
  u32   pipeline_handle
```

#### `SET_COMPUTE_TEXTURE` (0x0211)

```text
Payload:
  u32   texture_handle
  u8    index
  u8    pad
  u16   pad
```

#### `SET_COMPUTE_BYTES` (0x0212)

```text
Payload:
  u8    buffer_index
  u8    pad
  u16   pad
  u32   data_length
  u8[]  data
```

#### `DISPATCH_THREADS` (0x0220)

```text
Payload:
  u16   grid_x             Grid size X
  u16   grid_y             Grid size Y
  u16   grid_z             Grid size Z
  u16   threadgroup_x      Threadgroup size X
  u16   threadgroup_y      Threadgroup size Y
  u16   threadgroup_z      Threadgroup size Z
```

### Blit Pass

#### `BEGIN_BLIT_PASS` (0x0300)

```text
Payload: (none)
```

#### `END_BLIT_PASS` (0x0301)

```text
Payload: (none)
```

#### `COPY_TEXTURE_REGION` (0x0310)

Copy a rectangular region between textures.

```text
Payload:
  u32   src_texture
  u32   dst_texture
  u16   src_x
  u16   src_y
  u16   src_w
  u16   src_h
  u16   dst_x
  u16   dst_y
  u16   pad
  u16   pad
```

### Frame Control

#### `PRESENT_AND_COMMIT` (0x0F00)

Present the drawable and commit the command buffer. This ends the frame.

```text
Payload:
  u32   frame_id       Guest-assigned frame identifier
```

The `frame_id` is an opaque value assigned by the guest. The host uses it for
`--capture` matching and event script timing — `--capture N` captures the first
present whose `frame_id` equals N. Guests that don't need deterministic frame
identification can send 0 for every present. Guests that need deterministic
captures (e.g., for visual regression testing) should assign sequential IDs
starting from 0.

The host presents the CAMetalLayer drawable (if one was acquired via
`DRAWABLE_HANDLE`) and commits the Metal command buffer. The guest should wait
for the virtio completion before submitting the next frame.

If the cursor plane is active (visible, with a cursor image set), the host
composites the cursor onto the drawable in a separate render pass immediately
before presenting. This cursor plane is independent of the guest's scene graph —
the guest does not need to render the cursor itself.

### Cursor Plane

The cursor plane provides hardware-cursor-like compositing. The host maintains a
small BGRA texture (the cursor image) and composites it onto the drawable at the
current position before each `PRESENT_AND_COMMIT`. This decouples cursor
rendering from the guest's scene graph and render pipeline, eliminating cursor
lag.

The guest sends the cursor image once (or on shape change), updates the position
each frame, and controls visibility. The host handles compositing — the guest
never draws the cursor into its framebuffer.

#### `SET_CURSOR_IMAGE` (0x0F10)

Upload a cursor image with hotspot offset.

```text
Payload:
  u16   width          Cursor width in pixels (max 256)
  u16   height         Cursor height in pixels (max 256)
  i16   hotspot_x      Hotspot X offset in image pixels
  i16   hotspot_y      Hotspot Y offset in image pixels
  u8[]  bgra_pixels    BGRA pixel data (premultiplied alpha), width * height * 4 bytes
```

The cursor image is composited with premultiplied alpha blending (src=one,
dst=oneMinusSourceAlpha). The hotspot defines the click point within the image —
the host offsets the draw position so the hotspot aligns with the cursor
position.

Pixel format is BGRA with sRGB encoding (the host creates the texture as
`bgra8Unorm_srgb` for gamma-correct compositing).

#### `SET_CURSOR_POSITION` (0x0F11)

Update the cursor position in framebuffer pixels.

```text
Payload:
  f32   x              Cursor X in framebuffer pixels (the click point)
  f32   y              Cursor Y in framebuffer pixels (the click point)
```

The position is the logical cursor location (where a click would land). The host
subtracts the hotspot offset to compute the image draw position. Uses `f32` for
subpixel precision.

#### `SET_CURSOR_VISIBLE` (0x0F12)

Show or hide the cursor plane.

```text
Payload:
  u8    visible        1 = show, 0 = hide
```

When hidden, the cursor plane is not composited. The guest should hide the
cursor on keyboard input and show it on mouse movement.

#### `SET_CURSOR_FROM_TEXTURE` (0x0F13)

Set the cursor image from a GPU texture handle (zero-copy path).

```text
Payload:
  u32   texture_handle    Handle of a texture containing the cursor image (BGRA)
  u16   width             Cursor width in pixels
  u16   height            Cursor height in pixels
  i16   hotspot_x         Hotspot X offset in image pixels
  i16   hotspot_y         Hotspot Y offset in image pixels
```

Like `SET_CURSOR_IMAGE`, but the host reads cursor pixels directly from the
named GPU texture instead of receiving pixel data inline. The host encodes a
blit on the current command buffer; the actual pixel readback is deferred to
after the next `PRESENT_AND_COMMIT` completes (when GPU work is guaranteed
finished).

This is the preferred path when the guest renders the cursor to a GPU texture
(e.g., via stencil-then-cover path rendering). It avoids a GPU→CPU→GPU round
trip — the guest never reads the pixels back.

### Cursor Plane and Captures

When `--capture` or `SIGUSR1` triggers a screenshot, the host always composites
the cursor onto the captured image, regardless of whether the live display uses
GPU compositing or an `NSCursor` overlay. This ensures captures accurately
reflect the cursor state for automated visual testing. The compositing is done
on a staging copy — the live display is unaffected.

## Enumerations

### Pixel Format

| Wire Value | Metal Equivalent   |
| ---------- | ------------------ |
| 1          | `.bgra8Unorm`      |
| 2          | `.rgba8Unorm`      |
| 3          | `.r8Unorm`         |
| 4          | `.stencil8`        |
| 5          | `.rgba16Float`     |
| 6          | `.bgra8Unorm_srgb` |

### Primitive Type

| Wire Value | Metal Equivalent |
| ---------- | ---------------- |
| 0          | `.triangle`      |
| 1          | `.triangleStrip` |
| 2          | `.line`          |
| 3          | `.point`         |

### Load Action

| Wire Value | Metal Equivalent |
| ---------- | ---------------- |
| 0          | `.dontCare`      |
| 1          | `.load`          |
| 2          | `.clear`         |

### Store Action

| Wire Value | Metal Equivalent      |
| ---------- | --------------------- |
| 0          | `.dontCare`           |
| 1          | `.store`              |
| 2          | `.multisampleResolve` |

### Compare Function (Stencil)

| Wire Value | Metal Equivalent |
| ---------- | ---------------- |
| 0          | `.never`         |
| 1          | `.always`        |
| 2          | `.equal`         |
| 3          | `.notEqual`      |
| 4          | `.less`          |
| 5          | `.lessEqual`     |
| 6          | `.greater`       |
| 7          | `.greaterEqual`  |

### Stencil Operation

| Wire Value | Metal Equivalent  |
| ---------- | ----------------- |
| 0          | `.keep`           |
| 1          | `.zero`           |
| 2          | `.replace`        |
| 3          | `.incrementClamp` |
| 4          | `.decrementClamp` |
| 5          | `.invert`         |
| 6          | `.incrementWrap`  |
| 7          | `.decrementWrap`  |

## Minimal Example: Rendering a Triangle

A guest driver that draws a single colored triangle needs:

**Setup (once):**

1. `COMPILE_LIBRARY` — compile an MSL shader with vertex/fragment functions
2. `GET_FUNCTION` — get `"vertex_main"` and `"fragment_main"`
3. `CREATE_RENDER_PIPELINE` — vertex + fragment, blend off, sample_count=1

**Per frame:**

1. `BEGIN_RENDER_PASS` — color=`DRAWABLE_HANDLE`, load=clear, store=store
2. `SET_RENDER_PIPELINE` — bind the pipeline
3. `SET_VERTEX_BYTES` — 3 vertices × 32 bytes = 96 bytes of vertex data
4. `DRAW_PRIMITIVES` — triangle, start=0, count=3
5. `END_RENDER_PASS`
6. `PRESENT_AND_COMMIT`

**Minimal MSL shader:**

```metal
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
```

**Vertex data (clip space, 32 bytes each):**

```text
// position (f32×2), texCoord (f32×2), color (f32×4)
{  0.0,  0.5,   0.0, 0.0,   1.0, 0.0, 0.0, 1.0 }  // top, red
{ -0.5, -0.5,   0.0, 0.0,   0.0, 1.0, 0.0, 1.0 }  // bottom-left, green
{  0.5, -0.5,   0.0, 0.0,   0.0, 0.0, 1.0, 1.0 }  // bottom-right, blue
```

---

# Video Decode Protocol Specification

The video decode device (device ID 30, custom) provides hardware-accelerated
video decoding via macOS VideoToolbox. The guest submits compressed video
frames; the host decodes them and makes decoded BGRA pixels available as Metal
textures and/or writes them to guest memory.

## Transport

| Queue   | Index | Purpose                                   |
| ------- | ----- | ----------------------------------------- |
| Control | 0     | Session management (create/destroy/flush) |
| Decode  | 1     | Frame submission and decode               |

Features: `VIRTIO_F_VERSION_1` (bit 32).

## Config Space

Read-only, little-endian u32:

| Offset | Field            | Description                          |
| ------ | ---------------- | ------------------------------------ |
| 0x00   | supported_codecs | Bitmask of hardware-supported codecs |
| 0x04   | max_width        | Maximum decode width (8192)          |
| 0x08   | max_height       | Maximum decode height (8192)         |

### Codec Bitmask

| Bit | Codec |
| --- | ----- |
| 0   | MJPEG |
| 1   | H.264 |
| 2   | HEVC  |
| 3   | VP9   |
| 4   | AV1   |

Bits reflect hardware capability — checked at init via
`VTIsHardwareDecodeSupported`. MJPEG and H.264 are always available on Apple
Silicon.

## Control Commands (Queue 0)

The first readable descriptor contains the request. The last writable descriptor
receives the response. The first `u32` of every request is the command code.

### `CREATE_SESSION` (0x01)

Create a decode session backed by a `VTDecompressionSession`.

```text
Request (24 bytes):
  u32   command          = 0x01
  u32   session_id       Guest-assigned session identifier
  u8    codec            Codec index (see bitmask table)
  u8[3] reserved
  u32   width            Frame width in pixels
  u32   height           Frame height in pixels
  u32   codec_data_size  Size of codec-specific data (0 if none)
```

If `codec_data_size > 0`, a second readable descriptor contains codec-specific
initialization data:

- **H.264**: NAL length size (u8), parameter set count (u8), 2 bytes reserved,
  then for each parameter set: u32 size + raw NAL bytes. Minimum 2 sets (SPS +
  PPS).
- **HEVC**: Same layout, minimum 3 sets (VPS + SPS + PPS).
- **Other codecs**: No codec data needed.

```text
Response (12 bytes):
  u32   status           Status code
  u32   texture_handle   Host-assigned Metal texture handle (0x80000000+)
  u32   reserved
```

The returned `texture_handle` is registered in the shared `TextureRegistry` and
can be used in Metal render commands (`SET_FRAGMENT_TEXTURE`, etc.) for
zero-copy compositing. The texture is updated with each decoded frame via
IOSurface backing.

### `DESTROY_SESSION` (0x02)

Destroy a session and release its texture handle.

```text
Request (8 bytes):
  u32   command          = 0x02
  u32   session_id

Response (4 bytes):
  u32   status
```

### `FLUSH_SESSION` (0x03)

Flush the decoder (invalidate and recreate the internal VT session). Use after
seeking or when the compressed stream is discontinuous.

```text
Request (8 bytes):
  u32   command          = 0x03
  u32   session_id

Response (4 bytes):
  u32   status
```

## Decode Commands (Queue 1)

Each descriptor chain decodes one compressed frame. Four descriptors:

```text
Descriptor 0 — Frame header (readable, 24 bytes):
  u32   session_id
  u32   flags            Reserved (must be 0)
  u32   compressed_size  Size of compressed data in bytes
  u32   reserved
  u64   timestamp_ns     Presentation timestamp in nanoseconds

Descriptor 1 — Compressed data (readable):
  u8[]  data             Raw compressed frame (compressed_size bytes)

Descriptor 2 — Pixel output (writable, optional):
  u8[]  pixels           Decoded BGRA pixels (width * height * 4 bytes)
                         Omit this descriptor for texture-only decode

Descriptor 3 — Status (writable, 24 bytes):
  u32   status           Status code
  u32   bytes_written    Bytes written to pixel output (0 if no pixel descriptor)
  u64   timestamp_ns     Echo of input timestamp
  u64   duration_ns      Reserved (currently 0)
```

If the pixel output descriptor is present, the host copies decoded BGRA pixels
into guest memory. If omitted, decoded frames are only available via the
session's Metal texture handle (zero-copy path via IOSurface).

## Texture Integration

Decoded frames use IOSurface-backed `CVPixelBuffer` output from VideoToolbox.
The host creates an `MTLTexture` from the IOSurface and updates the session's
texture handle in the shared `TextureRegistry`. This allows the guest to
reference decoded video frames in Metal render commands without any CPU-side
pixel copy.

Handle ranges:

- `0x00000001 – 0x7FFFFFFF`: guest-assigned (Metal `CREATE_TEXTURE`)
- `0x80000000 – 0xFFFFFFFE`: host-assigned (video decode sessions)
- `0x00000000`: invalid
- `0xFFFFFFFF`: `DRAWABLE_HANDLE` (reserved)

## Status Codes

| Code   | Name                | Description                  |
| ------ | ------------------- | ---------------------------- |
| 0x0000 | OK                  | Success                      |
| 0x0001 | ERR_INVALID_SESSION | Session ID not found         |
| 0x0002 | ERR_UNSUPPORTED     | Codec not supported          |
| 0x0003 | ERR_DECODE_FAILED   | VideoToolbox decode error    |
| 0x0004 | ERR_BAD_DATA        | Malformed compressed data    |
| 0x0005 | ERR_NO_MEMORY       | Failed to allocate resources |
| 0x0006 | ERR_BAD_REQUEST     | Invalid request format       |
