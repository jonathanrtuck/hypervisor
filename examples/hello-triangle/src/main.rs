//! Hello Triangle — minimal bare-metal ARM64 program that renders a colored
//! triangle via the hypervisor's Metal GPU passthrough.
//!
//! This is a complete, self-contained example with no dependencies beyond
//! `core`. It demonstrates:
//!   1. Booting on the hypervisor (stack setup, PL011 UART output)
//!   2. Virtio MMIO device initialization
//!   3. Metal command encoding (shader compilation, pipeline creation, draw)
//!   4. Submitting commands via virtqueue
//!
//! The hypervisor processes virtio commands synchronously during the MMIO
//! trap — by the time the QueueNotify write returns, the triangle is on
//! screen. No interrupts or polling needed.

#![no_std]
#![no_main]

use core::panic::PanicInfo;
use core::ptr::addr_of;
use core::ptr::addr_of_mut;
use core::sync::atomic::{compiler_fence, Ordering};

// ── Boot stub ──────────────────────────────────────────────────────────────

core::arch::global_asm!(
    r#"
.section .text.boot
.global _start
_start:
    // Set up stack pointer
    ldr x1, =_stack_top
    mov sp, x1

    // Zero BSS
    ldr x1, =__bss_start
    ldr x2, =__bss_end
1:  cmp x1, x2
    b.ge 2f
    str xzr, [x1], #8
    b 1b
2:

    // Jump to Rust entry point
    bl main

    // Halt if main returns
3:  wfi
    b 3b
"#
);

// ── PL011 UART (serial output) ────────────────────────────────────────────

const UART_BASE: usize = 0x0900_0000;

fn uart_putc(c: u8) {
    let dr = UART_BASE as *mut u32;
    // SAFETY: PL011 data register at UART_BASE.
    unsafe { core::ptr::write_volatile(dr, c as u32) };
}

fn uart_print(s: &[u8]) {
    for &c in s {
        if c == b'\n' {
            uart_putc(b'\r');
        }
        uart_putc(c);
    }
}

fn uart_print_hex(val: u32) {
    let hex = b"0123456789abcdef";
    uart_print(b"0x");
    for i in (0..8).rev() {
        uart_putc(hex[((val >> (i * 4)) & 0xF) as usize]);
    }
}

// ── MMIO helpers ──────────────────────────────────────────────────────────

fn mmio_read32(addr: usize) -> u32 {
    // SAFETY: MMIO register access.
    unsafe { core::ptr::read_volatile(addr as *const u32) }
}

fn mmio_write32(addr: usize, val: u32) {
    // SAFETY: MMIO register access.
    unsafe { core::ptr::write_volatile(addr as *mut u32, val) };
}

// ── Virtio MMIO registers (offsets from device base) ──────────────────────

const VIRTIO_MAGIC: usize = 0x000;
const VIRTIO_VERSION: usize = 0x004;
const VIRTIO_DEVICE_ID: usize = 0x008;
const VIRTIO_DEVICE_FEATURES: usize = 0x010;
const VIRTIO_DEVICE_FEATURES_SEL: usize = 0x014;
const VIRTIO_DRIVER_FEATURES: usize = 0x020;
const VIRTIO_DRIVER_FEATURES_SEL: usize = 0x024;
const VIRTIO_QUEUE_SEL: usize = 0x030;
const VIRTIO_QUEUE_NUM_MAX: usize = 0x034;
const VIRTIO_QUEUE_NUM: usize = 0x038;
const VIRTIO_QUEUE_READY: usize = 0x044;
const VIRTIO_QUEUE_NOTIFY: usize = 0x050;
const VIRTIO_INTERRUPT_STATUS: usize = 0x060;
const VIRTIO_INTERRUPT_ACK: usize = 0x064;
const VIRTIO_STATUS: usize = 0x070;
const VIRTIO_QUEUE_DESC_LOW: usize = 0x080;
const VIRTIO_QUEUE_DESC_HIGH: usize = 0x084;
const VIRTIO_QUEUE_DRIVER_LOW: usize = 0x090;
const VIRTIO_QUEUE_DRIVER_HIGH: usize = 0x094;
const VIRTIO_QUEUE_USED_LOW: usize = 0x0A0;
const VIRTIO_QUEUE_USED_HIGH: usize = 0x0A4;

// Virtio status bits
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_DRIVER_OK: u32 = 4;

// Virtio metal device
const METAL_DEVICE_ID: u32 = 22;
const VIRTIO_SLOT_3_BASE: usize = 0x0A00_0000 + 3 * 0x200;

// ── Virtqueue structures (queue size = 16) ────────────────────────────────

const QUEUE_SIZE: u16 = 16;

/// Virtqueue descriptor (16 bytes each).
#[repr(C)]
struct VirtqDesc {
    addr: u64,  // guest-physical address of the buffer
    len: u32,   // length in bytes
    flags: u16, // 0 = device-readable, 2 = device-writable
    next: u16,
}

/// Virtqueue available ring.
#[repr(C)]
struct VirtqAvail {
    flags: u16,
    idx: u16,
    ring: [u16; QUEUE_SIZE as usize],
}

/// Virtqueue used ring element.
#[repr(C)]
struct VirtqUsedElem {
    id: u32,
    len: u32,
}

/// Virtqueue used ring.
#[repr(C)]
struct VirtqUsed {
    flags: u16,
    idx: u16,
    ring: [VirtqUsedElem; QUEUE_SIZE as usize],
}

/// Complete virtqueue state for one queue.
#[repr(C, align(4096))]
struct Virtqueue {
    desc: [VirtqDesc; QUEUE_SIZE as usize],
    avail: VirtqAvail,
    _pad: [u8; 4096 - 256 - 38], // pad to 4096 for used ring alignment
    used: VirtqUsed,
}

// Static virtqueues (in BSS — zeroed by boot stub).
static mut SETUP_VQ: Virtqueue = unsafe { core::mem::zeroed() };
static mut RENDER_VQ: Virtqueue = unsafe { core::mem::zeroed() };

// Static command buffers for DMA.
const CMD_BUF_SIZE: usize = 8192;
static mut SETUP_BUF: [u8; CMD_BUF_SIZE] = [0u8; CMD_BUF_SIZE];
static mut RENDER_BUF: [u8; CMD_BUF_SIZE] = [0u8; CMD_BUF_SIZE];

/// Track how many descriptors we've submitted on each queue.
static mut SETUP_AVAIL_IDX: u16 = 0;
static mut RENDER_AVAIL_IDX: u16 = 0;

// ── Virtio initialization ─────────────────────────────────────────────────

fn virtio_init(base: usize) -> bool {
    let magic = mmio_read32(base + VIRTIO_MAGIC);
    if magic != 0x7472_6976 {
        uart_print(b"virtio: bad magic ");
        uart_print_hex(magic);
        uart_print(b"\n");
        return false;
    }

    let version = mmio_read32(base + VIRTIO_VERSION);
    if version != 2 {
        uart_print(b"virtio: unsupported version\n");
        return false;
    }

    let device_id = mmio_read32(base + VIRTIO_DEVICE_ID);
    if device_id != METAL_DEVICE_ID {
        uart_print(b"virtio: unexpected device ID ");
        uart_print_hex(device_id);
        uart_print(b"\n");
        return false;
    }

    // Reset device
    mmio_write32(base + VIRTIO_STATUS, 0);

    // Acknowledge + Driver
    mmio_write32(base + VIRTIO_STATUS, STATUS_ACKNOWLEDGE);
    mmio_write32(base + VIRTIO_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // Feature negotiation: accept VIRTIO_F_VERSION_1 (bit 32) only
    mmio_write32(base + VIRTIO_DEVICE_FEATURES_SEL, 1);
    let _high_features = mmio_read32(base + VIRTIO_DEVICE_FEATURES);
    mmio_write32(base + VIRTIO_DRIVER_FEATURES_SEL, 1);
    mmio_write32(base + VIRTIO_DRIVER_FEATURES, 1); // bit 0 of high word = bit 32

    mmio_write32(base + VIRTIO_DRIVER_FEATURES_SEL, 0);
    mmio_write32(base + VIRTIO_DRIVER_FEATURES, 0); // no low features

    mmio_write32(
        base + VIRTIO_STATUS,
        STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK,
    );

    if mmio_read32(base + VIRTIO_STATUS) & STATUS_FEATURES_OK == 0 {
        uart_print(b"virtio: FEATURES_OK not set\n");
        return false;
    }

    // Setup queue 0 (setup)
    setup_queue(base, 0, addr_of!(SETUP_VQ) as usize);

    // Setup queue 1 (render)
    setup_queue(base, 1, addr_of!(RENDER_VQ) as usize);

    // Driver OK
    mmio_write32(
        base + VIRTIO_STATUS,
        STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK,
    );

    true
}

fn setup_queue(base: usize, queue_idx: u32, vq_addr: usize) {
    mmio_write32(base + VIRTIO_QUEUE_SEL, queue_idx);

    let max_size = mmio_read32(base + VIRTIO_QUEUE_NUM_MAX);
    let size = if (QUEUE_SIZE as u32) < max_size {
        QUEUE_SIZE as u32
    } else {
        max_size
    };
    mmio_write32(base + VIRTIO_QUEUE_NUM, size);

    // Descriptor table is at the start of the Virtqueue struct
    let desc_addr = vq_addr as u64;
    mmio_write32(base + VIRTIO_QUEUE_DESC_LOW, desc_addr as u32);
    mmio_write32(base + VIRTIO_QUEUE_DESC_HIGH, (desc_addr >> 32) as u32);

    // Available ring offset: after descriptors (16 * 16 = 256 bytes)
    let avail_addr = vq_addr as u64 + 256;
    mmio_write32(base + VIRTIO_QUEUE_DRIVER_LOW, avail_addr as u32);
    mmio_write32(base + VIRTIO_QUEUE_DRIVER_HIGH, (avail_addr >> 32) as u32);

    // Used ring offset: at the 4096-byte boundary within the struct
    let used_addr = vq_addr as u64 + 4096;
    mmio_write32(base + VIRTIO_QUEUE_USED_LOW, used_addr as u32);
    mmio_write32(base + VIRTIO_QUEUE_USED_HIGH, (used_addr >> 32) as u32);

    mmio_write32(base + VIRTIO_QUEUE_READY, 1);
}

// ── Command submission ────────────────────────────────────────────────────

/// Submit a command buffer on the setup queue and wait for completion.
///
/// Since the hypervisor processes commands synchronously during the MMIO
/// trap, the write to QueueNotify blocks until all commands are done.
fn submit_setup(buf: &[u8], len: usize) {
    // SAFETY: single-threaded, single-core access to static virtqueue + buffer.
    unsafe {
        let buf_ptr = addr_of_mut!(SETUP_BUF) as *mut u8;
        let buf_pa = buf_ptr as u64;
        core::ptr::copy_nonoverlapping(buf.as_ptr(), buf_ptr, len);

        let vq = addr_of_mut!(SETUP_VQ);
        let idx = (SETUP_AVAIL_IDX % QUEUE_SIZE) as usize;

        // Write descriptor
        (*vq).desc[idx].addr = buf_pa;
        (*vq).desc[idx].len = len as u32;
        (*vq).desc[idx].flags = 0; // device-readable
        (*vq).desc[idx].next = 0;

        // Update available ring
        compiler_fence(Ordering::Release);
        (*vq).avail.ring[idx] = idx as u16;
        compiler_fence(Ordering::Release);
        SETUP_AVAIL_IDX += 1;
        (*vq).avail.idx = SETUP_AVAIL_IDX;
        compiler_fence(Ordering::Release);

        // Notify — this blocks until the host finishes processing
        mmio_write32(VIRTIO_SLOT_3_BASE + VIRTIO_QUEUE_NOTIFY, 0);

        // Ack interrupt
        let status = mmio_read32(VIRTIO_SLOT_3_BASE + VIRTIO_INTERRUPT_STATUS);
        if status != 0 {
            mmio_write32(VIRTIO_SLOT_3_BASE + VIRTIO_INTERRUPT_ACK, status);
        }
    }
}

/// Submit a command buffer on the render queue and wait for completion.
fn submit_render(buf: &[u8], len: usize) {
    // SAFETY: single-threaded, single-core access to static virtqueue + buffer.
    unsafe {
        let buf_ptr = addr_of_mut!(RENDER_BUF) as *mut u8;
        let buf_pa = buf_ptr as u64;
        core::ptr::copy_nonoverlapping(buf.as_ptr(), buf_ptr, len);

        let vq = addr_of_mut!(RENDER_VQ);
        let idx = (RENDER_AVAIL_IDX % QUEUE_SIZE) as usize;

        (*vq).desc[idx].addr = buf_pa;
        (*vq).desc[idx].len = len as u32;
        (*vq).desc[idx].flags = 0;
        (*vq).desc[idx].next = 0;

        compiler_fence(Ordering::Release);
        (*vq).avail.ring[idx] = idx as u16;
        compiler_fence(Ordering::Release);
        RENDER_AVAIL_IDX += 1;
        (*vq).avail.idx = RENDER_AVAIL_IDX;
        compiler_fence(Ordering::Release);

        mmio_write32(VIRTIO_SLOT_3_BASE + VIRTIO_QUEUE_NOTIFY, 1);

        let status = mmio_read32(VIRTIO_SLOT_3_BASE + VIRTIO_INTERRUPT_STATUS);
        if status != 0 {
            mmio_write32(VIRTIO_SLOT_3_BASE + VIRTIO_INTERRUPT_ACK, status);
        }
    }
}

// ── Metal command encoding ────────────────────────────────────────────────
//
// Each command: [u16 method_id] [u16 flags=0] [u32 payload_size] [payload...]

struct CmdEncoder<'a> {
    buf: &'a mut [u8],
    pos: usize,
}

impl<'a> CmdEncoder<'a> {
    fn new(buf: &'a mut [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn len(&self) -> usize {
        self.pos
    }

    fn push_u8(&mut self, v: u8) {
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    fn push_u16(&mut self, v: u16) {
        let b = v.to_le_bytes();
        self.buf[self.pos..self.pos + 2].copy_from_slice(&b);
        self.pos += 2;
    }

    fn push_u32(&mut self, v: u32) {
        let b = v.to_le_bytes();
        self.buf[self.pos..self.pos + 4].copy_from_slice(&b);
        self.pos += 4;
    }

    fn push_f32(&mut self, v: f32) {
        let b = v.to_le_bytes();
        self.buf[self.pos..self.pos + 4].copy_from_slice(&b);
        self.pos += 4;
    }

    fn push_bytes(&mut self, data: &[u8]) {
        self.buf[self.pos..self.pos + data.len()].copy_from_slice(data);
        self.pos += data.len();
    }

    fn header(&mut self, method_id: u16, payload_size: u32) {
        self.push_u16(method_id);
        self.push_u16(0); // flags
        self.push_u32(payload_size);
    }

    // ── Setup commands ──────────────────────────────────────────────────

    fn compile_library(&mut self, handle: u32, source: &[u8]) {
        self.header(0x0001, 8 + source.len() as u32);
        self.push_u32(handle);
        self.push_u32(source.len() as u32);
        self.push_bytes(source);
    }

    fn get_function(&mut self, handle: u32, library: u32, name: &[u8]) {
        self.header(0x0002, 12 + name.len() as u32);
        self.push_u32(handle);
        self.push_u32(library);
        self.push_u32(name.len() as u32);
        self.push_bytes(name);
    }

    fn create_render_pipeline(
        &mut self,
        handle: u32,
        vertex_fn: u32,
        fragment_fn: u32,
        sample_count: u8,
        pixel_format: u8,
    ) {
        self.header(0x0010, 17);
        self.push_u32(handle);
        self.push_u32(vertex_fn);
        self.push_u32(fragment_fn);
        self.push_u8(0); // blend_enabled = false
        self.push_u8(0xF); // color_write_mask = all
        self.push_u8(0); // stencil_format = none
        self.push_u8(sample_count);
        self.push_u8(pixel_format);
    }

    fn create_texture(
        &mut self,
        handle: u32,
        width: u16,
        height: u16,
        format: u8,
        sample_count: u8,
        usage: u8,
    ) {
        self.header(0x0020, 12);
        self.push_u32(handle);
        self.push_u16(width);
        self.push_u16(height);
        self.push_u8(format);
        self.push_u8(if sample_count > 1 { 1 } else { 0 }); // texture_type: 0=2D, 1=2DMultisample
        self.push_u8(sample_count);
        self.push_u8(usage);
    }

    // ── Render commands ─────────────────────────────────────────────────

    fn begin_render_pass(
        &mut self,
        color_tex: u32,
        resolve_tex: u32,
        store_action: u8,
        clear_r: f32,
        clear_g: f32,
        clear_b: f32,
    ) {
        self.header(0x0100, 32);
        self.push_u32(color_tex);
        self.push_u32(resolve_tex);
        self.push_u32(0); // stencil_texture = none
        self.push_u8(2); // load_action = clear
        self.push_u8(store_action);
        self.push_u8(0); // stencil_load = don't care
        self.push_u8(0); // stencil_store = don't care
        self.push_f32(clear_r);
        self.push_f32(clear_g);
        self.push_f32(clear_b);
        self.push_f32(1.0); // clear_a
    }

    fn end_render_pass(&mut self) {
        self.header(0x0101, 0);
    }

    fn set_render_pipeline(&mut self, handle: u32) {
        self.header(0x0110, 4);
        self.push_u32(handle);
    }

    fn set_vertex_bytes(&mut self, index: u8, data: &[u8]) {
        self.header(0x0120, 8 + data.len() as u32);
        self.push_u8(index);
        self.push_u8(0);
        self.push_u16(0);
        self.push_u32(data.len() as u32);
        self.push_bytes(data);
    }

    fn draw_primitives(&mut self, vertex_start: u32, vertex_count: u32) {
        self.header(0x0130, 12);
        self.push_u8(0); // primitive_type = triangle
        self.push_u8(0);
        self.push_u16(0);
        self.push_u32(vertex_start);
        self.push_u32(vertex_count);
    }

    fn present_and_commit(&mut self) {
        self.header(0x0F00, 0);
    }
}

// ── MSL shader source ─────────────────────────────────────────────────────

const MSL_SOURCE: &[u8] = b"
#include <metal_stdlib>
using namespace metal;

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
";

// ── Triangle vertex data ──────────────────────────────────────────────────
//
// Each vertex: position (f32x2) + texCoord (f32x2) + color (f32x4) = 32 bytes
// Three vertices = 96 bytes total
//
// Positions are in clip space (-1 to +1).

fn triangle_vertices() -> [u8; 96] {
    let mut buf = [0u8; 96];
    let vertices: [(f32, f32, f32, f32, f32, f32, f32, f32); 3] = [
        // position        texCoord    color (RGBA)
        (0.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0), // top — red
        (-0.5, -0.5, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0), // bottom-left — green
        (0.5, -0.5, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0), // bottom-right — blue
    ];

    for (i, v) in vertices.iter().enumerate() {
        let off = i * 32;
        buf[off..off + 4].copy_from_slice(&v.0.to_le_bytes());
        buf[off + 4..off + 8].copy_from_slice(&v.1.to_le_bytes());
        buf[off + 8..off + 12].copy_from_slice(&v.2.to_le_bytes());
        buf[off + 12..off + 16].copy_from_slice(&v.3.to_le_bytes());
        buf[off + 16..off + 20].copy_from_slice(&v.4.to_le_bytes());
        buf[off + 20..off + 24].copy_from_slice(&v.5.to_le_bytes());
        buf[off + 24..off + 28].copy_from_slice(&v.6.to_le_bytes());
        buf[off + 28..off + 32].copy_from_slice(&v.7.to_le_bytes());
    }
    buf
}

// ── Metal object handles (guest-assigned) ─────────────────────────────────

const LIB_SHADERS: u32 = 1;
const FN_VERTEX: u32 = 10;
const FN_FRAGMENT: u32 = 11;
const PIPE_SOLID: u32 = 20;
const TEX_MSAA: u32 = 50;

const DISPLAY_W: u16 = 1024;
const DISPLAY_H: u16 = 768;
const SAMPLE_COUNT: u8 = 4;

// ── Entry point ───────────────────────────────────────────────────────────

#[unsafe(no_mangle)]
pub extern "C" fn main() {
    uart_print(b"\nhello-triangle: starting\n");

    // ── Initialize virtio-metal device ──────────────────────────────────

    uart_print(b"  Initializing virtio-metal...\n");
    if !virtio_init(VIRTIO_SLOT_3_BASE) {
        uart_print(b"  FAILED: virtio init\n");
        return;
    }
    uart_print(b"  Virtio device ready\n");

    // ── Setup phase: compile shaders and create pipeline ────────────────

    uart_print(b"  Compiling shaders...\n");

    let mut cmdbuf = [0u8; CMD_BUF_SIZE];
    let len = {
        let mut enc = CmdEncoder::new(&mut cmdbuf);

        // 1. Compile MSL shader library
        enc.compile_library(LIB_SHADERS, MSL_SOURCE);

        // 2. Get vertex and fragment functions
        enc.get_function(FN_VERTEX, LIB_SHADERS, b"vertex_main");
        enc.get_function(FN_FRAGMENT, LIB_SHADERS, b"fragment_main");

        // 3. Create 4x MSAA texture (render target)
        //    format=1 (BGRA8), usage=4 (renderTarget)
        enc.create_texture(TEX_MSAA, DISPLAY_W, DISPLAY_H, 1, SAMPLE_COUNT, 4);

        // 4. Create render pipeline with 4x MSAA
        //    pixel_format=1 (BGRA8Unorm) — must match the resolve texture format
        enc.create_render_pipeline(PIPE_SOLID, FN_VERTEX, FN_FRAGMENT, SAMPLE_COUNT, 1);

        enc.len()
    };
    submit_setup(&cmdbuf, len);
    uart_print(b"  Pipeline created\n");

    // ── Wait for the host window to be ready ──────────────────────────
    //
    // The hypervisor opens the Metal window on the main thread in parallel
    // with the VM boot. We boot so fast that the first frame can arrive
    // before CAMetalLayer has a drawable. A brief delay ensures the window
    // is ready. (A real OS would have seconds of boot time before its first
    // frame, so this isn't an issue in practice.)
    uart_print(b"  Waiting for display...\n");
    for _ in 0..50_000_000u64 {
        core::hint::spin_loop();
    }

    // ── Render phase: draw the triangle ─────────────────────────────────

    uart_print(b"  Rendering triangle...\n");

    let vertices = triangle_vertices();

    let len = {
        let mut enc = CmdEncoder::new(&mut cmdbuf);

        // 1. Begin render pass — render to MSAA texture, resolve to drawable
        //    store_action=2 (multisampleResolve)
        enc.begin_render_pass(TEX_MSAA, 0xFFFF_FFFF, 2, 0.1, 0.1, 0.15);

        // 2. Bind the pipeline
        enc.set_render_pipeline(PIPE_SOLID);

        // 3. Set vertex data (3 vertices = 96 bytes)
        enc.set_vertex_bytes(0, &vertices);

        // 4. Draw!
        enc.draw_primitives(0, 3);

        // 5. End render pass
        enc.end_render_pass();

        // 6. Present to screen
        enc.present_and_commit();

        enc.len()
    };
    submit_render(&cmdbuf, len);

    uart_print(b"\nhello-triangle: done! Triangle is on screen.\n");

    // Halt — the triangle stays visible because CAMetalLayer retains the
    // last presented drawable.
    loop {
        unsafe { core::arch::asm!("wfi") };
    }
}

// ── Panic handler ─────────────────────────────────────────────────────────

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    uart_print(b"\n!!! PANIC !!!\n");
    if let Some(location) = info.location() {
        uart_print(location.file().as_bytes());
        uart_print(b":");
        // Print line number (simple decimal)
        let line = location.line();
        let mut buf = [0u8; 10];
        let mut n = line;
        let mut i = buf.len();
        loop {
            i -= 1;
            buf[i] = b'0' + (n % 10) as u8;
            n /= 10;
            if n == 0 {
                break;
            }
        }
        uart_print(&buf[i..]);
        uart_print(b"\n");
    }
    loop {
        unsafe { core::arch::asm!("wfi") };
    }
}
