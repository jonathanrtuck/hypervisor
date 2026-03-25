# Metal-over-Virtio Protocol Specification

This document specifies the wire format for Metal GPU command passthrough between an ARM64 guest and the macOS host hypervisor. It is the source of truth for guest driver implementors.

## Overview

The protocol enables a guest kernel to issue Metal rendering commands without any translation layers. The guest serializes Metal API calls into a flat command buffer, sends it over a virtio device, and the host deserializes and replays each command via the native Metal API.

### Design Principles

- **Thin proxy.** Commands map 1:1 to Metal API calls. No abstraction, no batching, no reinterpretation.
- **Guest-assigned handles.** The guest pre-assigns `u32` IDs for all Metal objects. The host maintains a mapping to real Metal objects. Invalid handles are silently ignored.
- **Two queues.** Setup commands (object creation) and render commands (per-frame) use separate virtqueues to allow independent flow control.
- **Flat encoding.** No nested structures, no variable-length arrays within fixed fields. Every command can be parsed with sequential reads.

## Transport

The Metal GPU device uses virtio MMIO with **device ID 22** (custom).

| Queue  | Index | Purpose                     | Typical Usage                            |
| ------ | ----- | --------------------------- | ---------------------------------------- |
| Setup  | 0     | Object creation/destruction | Once at init, occasional texture uploads |
| Render | 1     | Per-frame command buffers   | Every frame                              |

The guest writes one or more commands into a virtio descriptor chain. The host processes all commands in the chain sequentially, then marks the descriptor as used.

## Command Format

Every command starts with an 8-byte header:

```text
Offset  Size  Field
0       u16   method_id      Command identifier
2       u16   flags          Reserved (must be 0)
4       u32   payload_size   Size of payload in bytes (following this header)
```

Commands are packed sequentially in the virtio buffer with no padding between them.

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

The host calls `MTLDevice.makeLibrary(source:)`. Compilation errors are logged but do not halt the guest — subsequent use of the handle is a no-op.

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
  u8    sample_count           MSAA sample count (1 or 4)
  u8    pixel_format           Color attachment format (see CREATE_TEXTURE)
```

**Vertex layout convention:** The default vertex descriptor is:

| Attribute | Index | Format | Offset | Description         |
| --------- | ----- | ------ | ------ | ------------------- |
| position  | 0     | float2 | 0      | Clip-space position |
| texCoord  | 1     | float2 | 8      | Texture coordinates |
| color     | 2     | float4 | 16     | RGBA color          |

Stride: **32 bytes**, buffer index 0.

This layout is used for all render pipelines. Guest shaders must match this vertex input layout.

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

### `DESTROY_OBJECT` (0x00FF)

Destroy any previously created object.

```text
Payload:
  u32   handle             Handle of the object to destroy
```

The host removes the handle from all object tables (libraries, functions, pipelines, textures, etc.).

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
Payload: (none)
```

The host presents the CAMetalLayer drawable (if one was acquired via `DRAWABLE_HANDLE`) and commits the Metal command buffer. The guest should wait for the virtio completion before submitting the next frame.

If the cursor plane is active (visible, with a cursor image set), the host composites the cursor onto the drawable in a separate render pass immediately before presenting. This cursor plane is independent of the guest's scene graph — the guest does not need to render the cursor itself.

### Cursor Plane

The cursor plane provides hardware-cursor-like compositing. The host maintains a small BGRA texture (the cursor image) and composites it onto the drawable at the current position before each `PRESENT_AND_COMMIT`. This decouples cursor rendering from the guest's scene graph and render pipeline, eliminating cursor lag.

The guest sends the cursor image once (or on shape change), updates the position each frame, and controls visibility. The host handles compositing — the guest never draws the cursor into its framebuffer.

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

The cursor image is composited with premultiplied alpha blending (src=one, dst=oneMinusSourceAlpha). The hotspot defines the click point within the image — the host offsets the draw position so the hotspot aligns with the cursor position.

Pixel format is BGRA with sRGB encoding (the host creates the texture as `bgra8Unorm_srgb` for gamma-correct compositing).

#### `SET_CURSOR_POSITION` (0x0F11)

Update the cursor position in framebuffer pixels.

```text
Payload:
  f32   x              Cursor X in framebuffer pixels (the click point)
  f32   y              Cursor Y in framebuffer pixels (the click point)
```

The position is the logical cursor location (where a click would land). The host subtracts the hotspot offset to compute the image draw position. Uses `f32` for subpixel precision.

#### `SET_CURSOR_VISIBLE` (0x0F12)

Show or hide the cursor plane.

```text
Payload:
  u8    visible        1 = show, 0 = hide
```

When hidden, the cursor plane is not composited. The guest should hide the cursor on keyboard input and show it on mouse movement.

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
