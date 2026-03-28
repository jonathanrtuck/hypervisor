# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```sh
make build          # swift build
make sign           # build + codesign with hypervisor entitlement
make run KERNEL=path/to/kernel.elf          # sign + run
make run KERNEL=path/to/kernel.elf ARGS="--windowed --verbose"
make run KERNEL=path/to/kernel.elf ARGS="--background --capture 5 /tmp/out.png"  # headless capture
make run-verbose KERNEL=path/to/kernel.elf  # with --verbose
make run-serial KERNEL=path/to/kernel.elf   # --no-gpu (no window)
make clean          # swift package clean
```

The `com.apple.security.hypervisor` entitlement (in `hypervisor.entitlements`) is required. Always `make sign` after building — unsigned binaries will crash on `hv_vm_create`.

There are no tests. There is no linter configuration.

## Architecture

This is a native macOS ARM64 hypervisor built on Apple's Hypervisor.framework with Metal GPU passthrough. ~4400 lines of Swift, no external dependencies — only Apple system frameworks (Hypervisor, Metal, AppKit, QuartzCore).

### Threading Model

- **Main thread**: NSApplication run loop — AppKit window, Metal display, input events
- **VM thread** ("VM-Boot"): boots the VM, runs vCPU 0
- **Secondary vCPU threads**: spawned via PSCI CPU_ON
- **GPU queue**: dedicated serial queue in VirtioMetal for Metal command processing

In `--no-gpu` mode, the VM runs directly on the main thread (no NSApplication).

### Core Layers

**VM lifecycle** (`main.swift` → `VirtualMachine.swift` → `VCPU.swift`):

- `main.swift`: CLI parsing (`Config` struct), device registration, threading setup
- `VirtualMachine`: mmap'd guest RAM, ELF loader, GIC setup, vCPU orchestration, PSCI state
- `VCPU`: per-CPU execution loop handling MMIO exits, HVC traps (PSCI), and timer management

**Virtio transport** (`VirtioMMIO.swift` + `VirtqueueHelper.swift`):

- `VirtioMMIOTransport` handles the MMIO register interface (virtio spec §4.2)
- `VirtioDeviceBackend` protocol — all device backends implement this
- `VirtqueueHelper` reads descriptor chains from guest memory

**Device backends** — each maps a virtio device to a native Apple framework:

| Backend              | File                | Virtio Device ID | Apple Framework  |
| -------------------- | ------------------- | ---------------- | ---------------- |
| `Virtio9PBackend`    | `Virtio9P.swift`    | 9                | Foundation (FS)  |
| `VirtioInputBackend` | `VirtioInput.swift` | 18               | AppKit (NSEvent) |
| `VirtioMetalBackend` | `VirtioMetal.swift` | 22 (custom)      | Metal            |
| `VirtioBlockBackend` | `VirtioBlock.swift` | 2                | Foundation (FS)  |

**Display** (`AppWindow.swift`): NSWindow + CAMetalLayer + macOS input forwarding. Converts NSEvent keyboard/mouse events into Linux evdev codes for the guest.

**Support**: `DTB.swift` (flattened device tree generator), `PL011.swift` (UART + log buffer), `PVPanic.swift` (pvpanic-mmio device), `CrashReport.swift` (crash report writer), `MetalProtocol.swift` (GPU command wire format enums), `EventScript.swift` (automated input injection for testing).

**Crash reporting**: On kernel panic, the guest writes `0x01` to the pvpanic MMIO register at `0x0902_0000` (QEMU pvpanic-mmio spec). The hypervisor captures all vCPU registers via `hv_vcpu_get_reg`/`hv_vcpu_get_sys_reg`, combines them with the PL011 serial log buffer, and writes a timestamped crash report to `/tmp/hypervisor-crash-<ts>.log`. Detection flows: pvpanic MMIO write → `VCPU.handleDataAbort` → `captureSnapshot` → `writeCrashReport` → `exit(1)`. The kernel's panic handler calls `pvpanic_signal()` then `system_off()` (PSCI) as a fallback.

**Background mode**: `--background` uses `.accessory` activation policy (no Dock icon), orders the window behind others via `orderBack`, and skips `app.activate`. Metal rendering still works because the window remains in the compositing tree. Designed for CI pipelines and automated captures. Note: `--events` does **not** imply background mode — pass `--background` explicitly.

**Watchdog timeout**: `--timeout SECS` schedules a GCD timer that fires `exit(2)` if the VM hasn't exited in time. Prevents infinite hangs when the kernel deadlocks (no pvpanic) or panics before virtio devices are initialized. Exit codes: 0 = success, 1 = panic, 2 = timeout.

### Guest Memory Map

| Address                      | Resource                                       |
| ---------------------------- | ---------------------------------------------- |
| `0x0800_0000`                | GIC distributor                                |
| `0x080A_0000`                | GIC redistributor                              |
| `0x0900_0000`                | PL011 UART                                     |
| `0x0901_0000`                | PL031 RTC (wall-clock time)                    |
| `0x0902_0000`                | pvpanic (paravirtual panic notification)       |
| `0x0A00_0000 + slot * 0x200` | Virtio MMIO devices                            |
| `0x4000_0000`                | RAM base (DTB loaded here, ELF segments above) |

### Adding a New Virtio Backend

1. Create a class conforming to `VirtioDeviceBackend` (see protocol in `VirtioMMIO.swift`)
2. Implement `deviceId`, `deviceFeatures`, `numQueues`, `maxQueueSize`, `handleNotify`, `configRead`, `configWrite`
3. Register in `main.swift` at the next slot: `vm.addVirtioDevice(slot: N, backend: myBackend)`
4. Add a DTB node (happens automatically — DTB generation iterates `vm.virtioDevices`)

### Metal GPU Protocol

Two virtqueues: queue 0 (setup — object creation) and queue 1 (render — per-frame commands). Commands are 8-byte header (`u16 method_id`, `u16 flags`, `u32 payload_size`) + payload. Guest-assigned `u32` handles map to real Metal objects on the host. Full spec in `PROTOCOL.md`.

**Cursor plane:** The host provides a hardware-cursor-like overlay via three commands (`SET_CURSOR_IMAGE`, `SET_CURSOR_POSITION`, `SET_CURSOR_VISIBLE`). The cursor is composited onto the drawable in a separate render pass before `PRESENT_AND_COMMIT`, independent of the guest's scene graph. This eliminates cursor lag by bypassing the guest's render pipeline. The cursor pipeline uses premultiplied alpha blending with sRGB-correct compositing.

## Swift Conventions

- Swift 6 package (`swift-tools-version: 6.0`) but uses Swift 5 language mode (`swiftLanguageMode(.v5)`) to avoid strict concurrency requirements
- Flat source layout — all `.swift` files in `Sources/`, no subdirectories
- `Info.plist` is embedded via linker flags (`-sectcreate __TEXT __info_plist`)
- Signal-safe globals use `nonisolated(unsafe)` with `Int32` (matches `sig_atomic_t`)
- Error handling: `hvCheck()` wraps all Hypervisor.framework calls, throws `HypervisorError`
- Guest memory access: `VirtualMachine.readGuest(at:count:)` and `writeGuest(at:data:)` for PA-based access
