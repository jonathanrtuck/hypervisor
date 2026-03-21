# hypervisor

A native macOS hypervisor for ARM64 bare-metal development, with Metal GPU passthrough.

Built on Apple's [Hypervisor.framework](https://developer.apple.com/documentation/hypervisor), this tool boots an ARM64 ELF kernel on Apple Silicon with hardware-accelerated GPU rendering — no emulation layers, no translation.

## Why This Exists

If you're developing a bare-metal OS or kernel on a Mac, your options for GPU-accelerated display are limited:

| Approach            | GPU Path                                 | Layers                   |
| ------------------- | ---------------------------------------- | ------------------------ |
| QEMU + virtio-gpu   | Software rendering                       | 0 GPU layers (CPU only)  |
| QEMU + virgl        | virglrenderer → ANGLE → MoltenVK → Metal | 4 translation layers     |
| **This hypervisor** | **Native Metal**                         | **0 translation layers** |

Your guest kernel sends Metal commands over a virtio device. The hypervisor replays them directly via the Metal API. No OpenGL. No Vulkan. No translation. The same GPU API on both sides.

## Features

- **Metal GPU passthrough** — guest sends serialized Metal commands, host replays them natively
- **4x MSAA** — native Metal multisampling, no post-process AA
- **Multi-core SMP** — hardware-backed vCPUs via Hypervisor.framework with PSCI CPU_ON
- **Hardware GIC** — Apple Silicon's native GICv3, not software emulation
- **Virtio devices** — 9P filesystem, keyboard, tablet (absolute pointer), Metal GPU
- **Built-in screenshot** — `--capture N path.png` or `SIGUSR1` for ad-hoc capture
- **ELF loader** — loads standard ELF64 binaries, handles VA→PA entry point resolution
- **Device tree** — generates FDT with memory, UART, GIC, PSCI, CPU, and virtio nodes

## Requirements

- macOS 15+ (Sequoia) — for `hv_gic_create`
- Apple Silicon (M1 or later)
- Xcode Command Line Tools (for Swift compiler)

## Quick Start

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
.build/debug/hypervisor examples/hello-triangle/target/aarch64-unknown-none/release/hello-triangle
```

The example is ~550 lines with zero dependencies — boots, initializes virtio, compiles MSL shaders, and draws a triangle via the Metal protocol. Read the source for a walkthrough of how to build a guest driver.

## Usage

```text
hypervisor <kernel-elf> [options]

Options:
  --verbose            Enable verbose logging
  --no-gpu             Boot without GPU (serial only, no window)
  --ram SIZE           RAM size in MiB (default: 256)
  --cpus N             Number of vCPUs (default: 4)
  --share DIR          9P shared directory (auto-detected if omitted)
  --capture N PATH     Capture frame N as PNG to PATH, then exit

Signals:
  SIGUSR1              Capture next frame to /tmp/hypervisor-capture.png
```

### Examples

```sh
# Boot with 512 MiB RAM and 2 CPUs
.build/debug/hypervisor kernel.elf --ram 512 --cpus 2

# Boot with a shared directory for 9P filesystem
.build/debug/hypervisor kernel.elf --share ./rootfs

# Serial-only mode (no window, no GPU)
.build/debug/hypervisor kernel.elf --no-gpu

# Capture frame 5 as a screenshot, then exit
.build/debug/hypervisor kernel.elf --capture 5 /tmp/screenshot.png
```

## Architecture

```text
┌─────────────────────────────────────────────────────┐
│  macOS Host                                         │
│                                                     │
│  ┌─────────┐  ┌──────────┐  ┌───────────────────┐   │
│  │ AppKit  │  │ Hyperv.  │  │ Metal             │   │
│  │ Window  │  │ framework│  │ (GPU passthrough) │   │
│  └────┬────┘  └────┬─────┘  └────────┬──────────┘   │
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
| `PL011.swift`           | PL011 UART emulation (serial output)                     |
| `VirtioMMIO.swift`      | Virtio MMIO transport layer                              |
| `VirtqueueHelper.swift` | Virtqueue descriptor chain helpers                       |
| `Virtio9P.swift`        | 9P2000.L filesystem passthrough                          |
| `VirtioInput.swift`     | Keyboard and tablet input devices                        |
| `VirtioMetal.swift`     | Metal command passthrough (deserialize + replay)         |
| `MetalProtocol.swift`   | Metal command wire format definitions                    |
| `AppWindow.swift`       | NSWindow + CAMetalLayer + macOS input forwarding         |

### Threading Model

- **Main thread:** NSApplication run loop (AppKit window, Metal display link)
- **VM thread:** Boots the VM, runs vCPU 0
- **Secondary vCPU threads:** Spawned via PSCI CPU_ON
- **GPU thread:** Dedicated serial queue for Metal command processing

## Guest VM Environment

Your kernel boots into a standard ARM64 `virt`-like environment:

| Resource | Details                                                               |
| -------- | --------------------------------------------------------------------- |
| RAM      | Configurable, default 256 MiB at PA `0x40000000`                      |
| UART     | PL011 at `0x09000000` (serial I/O)                                    |
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

## Metal GPU Protocol

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

## Dependencies

Only Apple system frameworks — no external dependencies:

- **Hypervisor.framework** — hardware virtualization
- **Metal.framework** — GPU API
- **AppKit.framework** — windowing
- **QuartzCore.framework** — CAMetalLayer

## Origin

This was built for [a document-centric OS project](https://github.com/jonathanrtuck/os) exploring an alternative operating system where files are first-class citizens. We needed GPU-accelerated rendering for the guest OS but found QEMU's virgl path on macOS required four translation layers (virglrenderer → ANGLE → MoltenVK → Metal) — slow, fragile, and hard to debug. So we built a native hypervisor that passes Metal commands straight through, and extracted it here for anyone with the same problem.

## License

[Unlicense](UNLICENSE) — public domain.
