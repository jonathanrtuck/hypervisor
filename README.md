# hypervisor

A native macOS hypervisor for ARM64 bare-metal development, with Metal GPU passthrough.

Built on Apple’s [Hypervisor.framework](https://developer.apple.com/documentation/hypervisor), this tool boots an ARM64 ELF kernel on Apple Silicon with hardware-accelerated GPU rendering — no emulation layers, no translation.

## why this exists

If you’re developing a bare-metal OS or kernel on a Mac, your options for GPU-accelerated display are limited:

| Approach            | GPU Path                                 | Layers                   |
| ------------------- | ---------------------------------------- | ------------------------ |
| QEMU + virtio-gpu   | Software rendering                       | 0 GPU layers (CPU only)  |
| QEMU + virgl        | virglrenderer → ANGLE → MoltenVK → Metal | 4 translation layers     |
| **This hypervisor** | **Native Metal**                         | **0 translation layers** |

Your guest kernel sends Metal commands over a virtio device. The hypervisor replays them directly via the Metal API. No OpenGL. No Vulkan. No translation. The same GPU API on both sides.

## features

- **Metal GPU passthrough** — guest sends serialized Metal commands, host replays them natively
- **4x MSAA** — native Metal multisampling, no post-process AA
- **Multi-core SMP** — hardware-backed vCPUs via Hypervisor.framework with PSCI CPU_ON
- **Hardware GIC** — Apple Silicons native GICv3, not software emulation
- **Virtio devices** — 9P filesystem, keyboard (with modifier/Caps Lock forwarding), tablet (absolute pointer), Metal GPU
- **Crash reporting** — automatic crash report on kernel panic via [pvpanic](https://www.qemu.org/docs/master/specs/pvpanic.html) device. Captures vCPU registers, system registers, and full serial log to `/tmp/hypervisor-crash-<timestamp>.log`
- **Built-in screenshot** — `--capture N path.png` for single frame, `--capture N,M,.. prefix.png` for multi-frame, `SIGUSR1` for ad-hoc. Captures always include the cursor plane composite for accurate visual testing
- **Background mode** — `--background` renders to an offscreen Metal texture with no window, no CAMetalLayer, and no interaction with the macOS window server. Zero focus disruption. Designed for CI pipelines and automated captures
- **Event scripts** — `--events file.events` for automated input injection (keyboard, mouse, captures) using evdev key names. Combine with `--background` for headless operation
- **Fixed resolution** — `--resolution WxH` for deterministic display dimensions in testing
- **Watchdog timeout** — `--timeout SECS` exits with code 2 if the VM doesn't finish in time. Prevents infinite hangs when a kernel deadlocks before producing frames
- **Block device** — `--drive path.img` attaches a raw disk image as a virtio-blk device
- **ELF loader** — loads standard ELF64 binaries, handles VA→PA entry point resolution
- **Device tree** — generates FDT with memory, UART, GIC, PSCI, CPU, and virtio nodes

## requirements

- macOS 15+ (Sequoia) — for `hv_gic_create`
- Apple Silicon (M1 or later)
- Xcode Command Line Tools (for Swift compiler)

## quick start

```sh
# Clone and build
git clone https://github.com/user/hypervisor.git
cd hypervisor
make build && make sign

# Boot your kernel
.build/debug/hypervisor path/to/kernel.elf

# Or use the Makefile
make run KERNEL=path/to/kernel.elf
```

The `com.apple.security.hypervisor` entitlement is applied automatically by `make sign`.

### Hello Triangle Demo

A self-contained bare-metal Rust example that renders a colored triangle with 4x MSAA:

```sh
cd examples/hello-triangle
cargo build --release
cd ../..
make sign
.build/debug/hypervisor examples/hello-triangle/target/aarch64-unknown-none/release/hello-triangle --windowed
```

The example renders at a fixed 1024x768 viewport, so `--windowed` keeps it properly framed. In fullscreen the triangle appears in the top-left corner of the display.

The example is ~550 lines with zero dependencies — boots, initializes virtio, compiles MSL shaders, and draws a triangle via the Metal protocol. Read the source for a walkthrough of how to build a guest driver.

## usage

```text
hypervisor <kernel-elf> [options]

Options:
  --verbose            Enable verbose logging
  --no-gpu             Boot without GPU (serial only, no window)
  --windowed           Run in a window instead of fullscreen
  --background         Headless rendering (offscreen texture, no window, no focus steal)
  --ram SIZE           RAM size in MiB (default: 256)
  --cpus N             Number of vCPUs (default: 4)
  --share DIR          9P shared directory (auto-detected if omitted)
  --drive PATH         Disk image for virtio-blk (raw format)
  --capture N PATH     Capture frame N as PNG to PATH, then exit
  --capture N,M,.. PFX Capture multiple frames as PFX-NNN.png, exit after last
  --events FILE        Run event script (evdev input injection + captures)
  --resolution WxH     Fixed pixel resolution (e.g., 800x600)
  --timeout SECS       Exit with code 2 if not done within SECS seconds

Signals:
  SIGUSR1              Capture next frame to /tmp/hypervisor-capture.png

Exit codes:
  0                    Success (normal exit or capture completed)
  1                    Kernel panic (pvpanic signal received)
  2                    Timeout (--timeout deadline exceeded)
```

### Examples

```sh
# Boot with 512 MiB RAM and 2 CPUs
.build/debug/hypervisor kernel.elf --ram 512 --cpus 2

# Boot with a shared directory for 9P filesystem
.build/debug/hypervisor kernel.elf --share ./rootfs

# Windowed mode (skip fullscreen)
.build/debug/hypervisor kernel.elf --windowed

# Serial-only mode (no window, no GPU)
.build/debug/hypervisor kernel.elf --no-gpu

# Capture frame 5 as a screenshot, then exit
.build/debug/hypervisor kernel.elf --capture 5 /tmp/screenshot.png

# Capture frames 10, 30, 60 in a single boot (for animation verification)
.build/debug/hypervisor kernel.elf --capture 10,30,60 /tmp/anim.png
# Produces /tmp/anim-010.png, /tmp/anim-030.png, /tmp/anim-060.png

# Background mode — headless rendering, no window created
.build/debug/hypervisor kernel.elf --background --capture 5 /tmp/screenshot.png

# Run an event script in background mode (headless CI)
cat > /tmp/test.events << 'SCRIPT'
type hello world
key backspace
wait 5
capture /tmp/result.png
SCRIPT
.build/debug/hypervisor kernel.elf --background --events /tmp/test.events

# Fixed resolution for deterministic display dimensions
.build/debug/hypervisor kernel.elf --background --resolution 800x600 --events /tmp/test.events

# Boot with a disk image (virtio-blk)
.build/debug/hypervisor kernel.elf --drive rootfs.img

# Capture with a 30-second timeout (exit 2 if kernel hangs)
.build/debug/hypervisor kernel.elf --capture 30 /tmp/out.png --timeout 30
```

### Event Script Format

Event scripts use standard Linux evdev key names (`linux/input-event-codes.h`). One action per line, `#` comments, blank lines ignored.

```text
type hello world          # Type each character (handles shift for uppercase)
key backspace             # Single key press
key shift+left            # Modified key (modifiers: shift, ctrl, alt, cmd)
move 100 200              # Move pointer to (x, y) without clicking
click 100 200             # Left click at (x, y) in points
dblclick 100 200          # Double click
wait 10                   # Wait 10 extra frames
capture /tmp/result.png   # Screenshot at this point
```

## architecture

```text
┌─────────────────────────────────────────────────────┐
│  macOS Host                                         │
│                                                     │
│  ┌─────────┐  ┌───────────┐  ┌───────────────────┐  │
│  │ AppKit  │  │ Hyperv.   │  │ Metal             │  │
│  │ Window  │  │ framework │  │ (GPU passthrough) │  │
│  └────┬────┘  └────┬──────┘  └────────┬──────────┘  │
│       │            │                  │             │
│  ┌────┴────────────┴──────────────────┴──────────┐  │
│  │              Hypervisor App                   │  │
│  │                                               │  │
│  │  VirtioInput  Virtio9P  VirtioMetal  PL011    │  │
│  │  (keyboard)   (files)   (GPU cmds)   (UART)   │  │
│  └──────────────────┬────────────────────────────┘  │
│                     │ virtio MMIO                   │
│  ┌──────────────────┴────────────────────────────┐  │
│  │              Guest ARM64 VM                   │  │
│  │                                               │  │
│  │  Your kernel (ELF64)                          │  │
│  │  Your GPU driver (speaks Metal protocol)      │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Source Files

| File                    | Purpose                                                  |
| ----------------------- | -------------------------------------------------------- |
| `main.swift`            | Entry point, CLI parsing, device registration, threading |
| `VirtualMachine.swift`  | VM creation, guest memory, ELF loader, GIC setup         |
| `VCPU.swift`            | vCPU execution loop, MMIO dispatch, PSCI, timer handling |
| `DTB.swift`             | Flattened Device Tree generator                          |
| `PL011.swift`           | PL011 UART emulation (serial output + log buffer)        |
| `PVPanic.swift`         | pvpanic device (QEMU pvpanic-mmio spec)                  |
| `CrashReport.swift`     | Crash report generator (register dump + serial log)      |
| `VirtioMMIO.swift`      | Virtio MMIO transport layer                              |
| `VirtqueueHelper.swift` | Virtqueue descriptor chain helpers                       |
| `Virtio9P.swift`        | 9P2000.L filesystem passthrough                          |
| `VirtioInput.swift`     | Keyboard and tablet input devices                        |
| `VirtioMetal.swift`     | Metal command passthrough (deserialize + replay)         |
| `VirtioBlock.swift`     | File-backed block device (virtio-blk)                    |
| `MetalProtocol.swift`   | Metal command wire format definitions                    |
| `EventScript.swift`     | Event script parser + scheduler (evdev key names)        |
| `AppWindow.swift`       | NSWindow + CAMetalLayer + macOS input forwarding         |

### Threading Model

- **Main thread:** NSApplication run loop (AppKit window, Metal display link)
- **VM thread:** Boots the VM, runs vCPU 0
- **Secondary vCPU threads:** Spawned via PSCI CPU_ON
- **GPU thread:** Dedicated serial queue for Metal command processing

## guest VM environment

Your kernel boots into a standard ARM64 `virt`-like environment:

| Resource | Details                                                               |
| -------- | --------------------------------------------------------------------- |
| RAM      | Configurable, default 256 MiB at PA `0x40000000`                      |
| UART     | PL011 at `0x09000000` (serial I/O)                                    |
| RTC      | PL031 at `0x09010000` (wall-clock time from host)                     |
| pvpanic  | At `0x09020000` — write `0x01` to signal kernel panic to hypervisor   |
| GIC      | Hardware GICv3 (distributor `0x08000000`, redistributor `0x080A0000`) |
| Timer    | Virtual timer (host counter frequency, typically 24 MHz)              |
| Boot     | ELF loaded at physical addresses, DTB at RAM base, PSCI for SMP       |
| Virtio   | MMIO devices at `0x0A000000 + slot * 0x200`, IRQ = SPI `48 + slot`    |

### Virtio Device Slots

| Slot | Device       | IRQ (SPI) | Device ID | Description                             |
| ---- | ------------ | --------- | --------- | --------------------------------------- |
| 0    | virtio-9p    | 48        | 9         | Host filesystem (if `--share` provided) |
| 1    | virtio-input | 49        | 18        | Keyboard (evdev)                        |
| 2    | virtio-input | 50        | 18        | Tablet / absolute pointer               |
| 3    | virtio-metal | 51        | 22        | Metal GPU command passthrough           |
| 4    | virtio-blk   | 52        | 2         | Block device (if `--drive` provided)    |

## virtio device architecture

Each virtio backend maps one virtio device to one Apple framework. The guest always sees standard virtio; the host always sees native macOS APIs. No translation layers in between.

| Backend       | Virtio Device    | Apple Framework | Guest Sees           | Host Uses                 |
| ------------- | ---------------- | --------------- | -------------------- | ------------------------- |
| `Virtio9P`    | 9P filesystem    | Foundation (FS) | 9P2000.L protocol    | macOS file I/O            |
| `VirtioInput` | Input (keyboard) | AppKit          | evdev key events     | NSEvent key events        |
| `VirtioInput` | Input (tablet)   | AppKit          | evdev abs events     | NSEvent mouse tracking    |
| `VirtioMetal` | GPU (device 22)  | Metal           | Metal command stream | MTLDevice/MTLCommandQueue |
| `VirtioBlock` | Block (device 2) | Foundation (FS) | virtio-blk protocol  | File-backed read/write    |

This pattern is the organizing principle for all backends, current and future. Adding a new backend means: pick a virtio device type (standard or custom), write a Swift class that translates between virtio virtqueues and the corresponding Apple framework, register it at a slot in `main.swift`.

### Planned Backends

These are not yet implemented. Slot assignments and details may change.

**virtio-sound** (device ID 25) — Audio playback and capture via CoreAudio. Two virtqueues: TX for playback, RX for capture. The guest negotiates PCM stream parameters (sample rate, channels, format) via virtio-sound’s standard config space. The host backend creates a CoreAudio audio unit and bridges PCM buffers. Needed for audio/video content types.

**Networking** — Options include:

- _virtio-net_ (device ID 1): Standard NIC. The guest needs a TCP/IP stack. The host bridges via `Network.framework` (userspace packet injection) or a `utun` device.
- _HTTP bridge_ (custom device): A higher-level alternative that exposes HTTP request/response and WebSocket semantics directly over virtio. The guest sends structured HTTP requests; the host executes them via `URLSession`. Avoids the guest needing a full TCP/IP stack at the cost of not supporting arbitrary protocols.

**Clipboard bridge** — Copy/paste between host and guest. Either a custom virtio device or an extension of virtio-input. The host side reads and writes `NSPasteboard`. The guest side exposes a simple get/put interface for the OS clipboard abstraction.

**File drag-drop** — Drag files between host Finder and guest window. Could extend virtio-9p (the file is already accessible via the shared directory) or use a custom device that sends file metadata + path on drop events. The host side hooks `NSDraggingDestination` / `NSDraggingSource` on the AppKit window.

## metal GPU protocol

The Metal passthrough protocol is a simple command stream over two virtqueues. See [`PROTOCOL.md`](PROTOCOL.md) for the full specification.

### Quick Overview

Your guest driver writes a sequence of commands into a virtio buffer:

```text
[u16 method_id] [u16 flags] [u32 payload_size] [payload bytes...]
```

- **Queue 0 (setup):** Object creation — compile shaders, create pipelines, create textures
- **Queue 1 (render):** Per-frame rendering — begin pass, set state, draw, present

The host deserializes each command and calls the corresponding Metal API. Guest-assigned `u32` handle IDs map to real Metal objects on the host.

### Building a Guest Driver

To use Metal GPU passthrough, your guest kernel needs:

1. **A virtio MMIO driver** — initialize the transport at slot 3 (PA `0x0A000200 * 3`)
2. **Metal protocol encoder** — serialize commands into the wire format
3. **MSL shaders** — write Metal Shading Language source (compiled at runtime by the host)
4. **Vertex data** — the default vertex layout is `float2 position + float2 texCoord + float4 color` (32 bytes)

A minimal rendering loop:

```text
1. Setup (once):
   - Compile MSL shader library
   - Get vertex/fragment functions
   - Create render pipeline
   - Create textures, samplers as needed

2. Per frame:
   - Begin render pass (target = DRAWABLE_HANDLE 0xFFFFFFFF)
   - Set pipeline, set vertex data, draw
   - Present and commit
```

See the protocol spec for command details and payload formats.

## dependencies

Only Apple system frameworks — no external dependencies:

- **Hypervisor.framework** — hardware virtualization
- **Metal.framework** — GPU API
- **AppKit.framework** — windowing
- **QuartzCore.framework** — CAMetalLayer

## origin

This was built for [a document-centric OS project](https://github.com/jonathanrtuck/os) exploring an operating system design where mimetypes are first-class. We needed GPU-accelerated rendering for the guest OS but found QEMUs virgl path on macOS required four translation layers (virglrenderer → ANGLE → MoltenVK → Metal) — slow, fragile, and hard to debug. So we built a native hypervisor that passes Metal commands straight through, and extracted it here for anyone with the same problem.

## license

[Unlicense](UNLICENSE) — public domain.
