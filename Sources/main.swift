/// Native macOS hypervisor — boots an ARM64 ELF kernel with Metal GPU-accelerated rendering.
///
/// Architecture:
///   Main thread:       NSApplication run loop (AppKit window + Metal display)
///   Background thread: VM boot + vCPU execution
///
/// Virtio device slots:
///   0: virtio-9p   (host filesystem access, optional)
///   1: virtio-input (keyboard)
///   2: virtio-input (tablet / absolute pointer)
///   3: virtio-metal (Metal command passthrough — device ID 22)
///   4: virtio-blk  (file-backed block device, optional)

import Foundation
import AppKit
import Hypervisor
import Metal

/// Global flag set by SIGUSR1 signal handler. Checked by VirtioMetal on each frame.
/// Uses Int32 (matches sig_atomic_t) for signal-handler safety.
nonisolated(unsafe) var _signalCaptureFlag: Int32 = 0

// MARK: - Argument parsing

struct Config {
    let kernelPath: String
    let verbose: Bool
    let noGpu: Bool
    let windowed: Bool
    let background: Bool
    let ramMiB: Int
    let cpuCount: Int
    let shareDir: String?
    let drivePath: String?
    let captureFrames: Set<Int>
    let capturePath: String
    let eventsFile: String?
    let resolution: (Int, Int)?
    let timeout: Int?

    var ramSize: Int { ramMiB * 1024 * 1024 }
    let ramBase: UInt64 = 0x4000_0000
}

func printUsage() {
    print("Usage: hypervisor <kernel-elf> [options]")
    print("")
    print("Boot an ARM64 ELF kernel with Apple Hypervisor.framework and optional")
    print("Metal GPU passthrough.")
    print("")
    print("Options:")
    print("  --verbose            Enable verbose logging")
    print("  --no-gpu             Boot without GPU (serial only, no window)")
    print("  --windowed           Run in a window instead of fullscreen")
    print("  --background         No visible window, no focus steal (for automated captures)")
    print("  --ram SIZE           RAM size in MiB (default: 256)")
    print("  --cpus N             Number of vCPUs (default: 4)")
    print("  --share DIR          9P shared directory (auto-detected if omitted)")
    print("  --drive PATH         Disk image for virtio-blk (raw format)")
    print("  --capture N PATH     Capture frame_id N as PNG to PATH, then exit")
    print("  --capture N,M,.. PFX Capture multiple frame_ids as PFX-NNN.png")
    print("  --events FILE        Run event script (evdev input injection + captures)")
    print("  --resolution WxH     Fixed pixel resolution (e.g., 800x600)")
    print("  --timeout SECS       Exit with code 2 if not done within SECS seconds")
    print("")
    print("Signals:")
    print("  SIGUSR1              Capture next frame to /tmp/hypervisor-capture.png")
}

func parseArgs() -> Config {
    let args = CommandLine.arguments

    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }

    var kernelPath: String?
    var verbose = false
    var noGpu = false
    var windowed = false
    var background = false
    var ramMiB = 256
    var cpuCount = 4
    var shareDir: String?
    var drivePath: String?
    var captureFrames: Set<Int> = []
    var capturePath = "/tmp/hypervisor-capture.png"
    var eventsFile: String?
    var resolution: (Int, Int)?
    var timeout: Int?

    var i = 1
    while i < args.count {
        let a = args[i]

        switch a {
        case "--verbose":
            verbose = true
        case "--no-gpu":
            noGpu = true
        case "--windowed":
            windowed = true
        case "--background":
            background = true
        case "--ram":
            guard i + 1 < args.count, let val = Int(args[i + 1]), val > 0 else {
                print("Error: --ram requires a positive integer (MiB)")
                exit(1)
            }
            ramMiB = val
            i += 1
        case "--cpus":
            guard i + 1 < args.count, let val = Int(args[i + 1]), val > 0, val <= 64 else {
                print("Error: --cpus requires a positive integer (1-64)")
                exit(1)
            }
            cpuCount = val
            i += 1
        case "--share":
            guard i + 1 < args.count else {
                print("Error: --share requires a directory path")
                exit(1)
            }
            shareDir = args[i + 1]
            i += 1
        case "--drive":
            guard i + 1 < args.count else {
                print("Error: --drive requires a file path")
                exit(1)
            }
            drivePath = args[i + 1]
            i += 1
        case "--capture":
            guard i + 2 < args.count else {
                print("Error: --capture requires FRAMES PATH")
                exit(1)
            }
            let spec = args[i + 1]
            let parts = spec.split(separator: ",")
            var frames: Set<Int> = []
            for part in parts {
                guard let n = Int(part) else {
                    print("Error: --capture frame numbers must be integers, got '\(part)'")
                    exit(1)
                }
                frames.insert(n)
            }
            guard !frames.isEmpty else {
                print("Error: --capture requires at least one frame number")
                exit(1)
            }
            captureFrames = frames
            capturePath = args[i + 2]
            i += 2
        case "--events":
            guard i + 1 < args.count else {
                print("Error: --events requires a file path")
                exit(1)
            }
            eventsFile = args[i + 1]
            i += 1
        case "--timeout":
            guard i + 1 < args.count, let val = Int(args[i + 1]), val > 0 else {
                print("Error: --timeout requires a positive integer (seconds)")
                exit(1)
            }
            timeout = val
            i += 1
        case "--resolution":
            guard i + 1 < args.count else {
                print("Error: --resolution requires WxH (e.g., 800x600)")
                exit(1)
            }
            let parts = args[i + 1].lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  w > 0, h > 0 else {
                print("Error: --resolution format is WxH (e.g., 800x600)")
                exit(1)
            }
            resolution = (w, h)
            i += 1
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            if a.hasPrefix("-") {
                print("Error: unknown option '\(a)'")
                printUsage()
                exit(1)
            }
            // Positional argument: kernel path
            if kernelPath == nil {
                kernelPath = a
            } else {
                print("Error: unexpected argument '\(a)'")
                exit(1)
            }
        }
        i += 1
    }

    guard let kernel = kernelPath else {
        print("Error: no kernel path specified")
        print("")
        printUsage()
        exit(1)
    }

    return Config(
        kernelPath: kernel,
        verbose: verbose,
        noGpu: noGpu,
        windowed: windowed,
        background: background,
        ramMiB: ramMiB,
        cpuCount: cpuCount,
        shareDir: shareDir,
        drivePath: drivePath,
        captureFrames: captureFrames,
        capturePath: capturePath,
        eventsFile: eventsFile,
        resolution: resolution,
        timeout: timeout
    )
}

// MARK: - 9P share directory auto-detection

/// Try to find a share directory relative to the kernel path.
/// Looks for a `share/` sibling directory, or `system/share` in the project tree.
func autoDetectShareDir(kernelPath: String) -> String? {
    let absPath: String = {
        if kernelPath.hasPrefix("/") { return kernelPath }
        return FileManager.default.currentDirectoryPath + "/" + kernelPath
    }()

    let fm = FileManager.default

    // Strategy 1: look for /system/target/ in the path → use /system/share
    if let range = absPath.range(of: "/system/target/") {
        let candidate = String(absPath[..<range.lowerBound]) + "/system/share"
        if fm.fileExists(atPath: candidate) {
            return candidate
        }
    }

    // Strategy 2: look for a `share/` directory alongside the kernel binary
    let dir = (absPath as NSString).deletingLastPathComponent
    let candidate = dir + "/share"
    if fm.fileExists(atPath: candidate) {
        return candidate
    }

    return nil
}

// MARK: - Main

func main() throws {
    let config = parseArgs()

    print("Hypervisor — Native macOS ARM64 VM")
    print("")

    // Load kernel ELF
    let kernelData = try Data(contentsOf: URL(fileURLWithPath: config.kernelPath))
    print("  Loaded kernel: \(config.kernelPath) (\(kernelData.count) bytes)")

    // Create and configure the VM
    let vm = try VirtualMachine(
        ramSize: config.ramSize,
        ramBase: config.ramBase,
        verbose: config.verbose
    )

    vm.config = config

    // Load kernel ELF into guest memory
    let entry = try vm.loadKernelELF(kernelData)
    print("  Kernel entry point: 0x\(String(entry, radix: 16))")
    print("  RAM: \(config.ramMiB) MiB at 0x\(String(config.ramBase, radix: 16))")
    print("  CPUs: \(config.cpuCount)")

    // ── Virtio devices ──────────────────────────────────────────────────

    // Slot 0: virtio-9p (optional — only if share dir is available)
    let shareDir = config.shareDir ?? autoDetectShareDir(kernelPath: config.kernelPath)
    if let dir = shareDir {
        let virtio9p = Virtio9PBackend(rootPath: dir)
        vm.addVirtioDevice(slot: 0, backend: virtio9p)
        print("  9P share dir: \(dir)")
    } else {
        print("  9P: disabled (no --share dir, auto-detection failed)")
    }

    // Slot 1: virtio-input keyboard
    let keyboard = VirtioInputBackend(name: "virtio-keyboard", keyboard: true)
    vm.addVirtioDevice(slot: 1, backend: keyboard)

    // Slot 2: virtio-input tablet
    let tablet = VirtioInputBackend(name: "virtio-tablet", keyboard: false)
    vm.addVirtioDevice(slot: 2, backend: tablet)

    // Slot 4: virtio-blk (optional — only if drive image is provided)
    if let path = config.drivePath {
        let block = try VirtioBlockBackend(imagePath: path)
        vm.addVirtioDevice(slot: 4, backend: block)
        print("  Block device: \(path) (\(block.deviceId == 2 ? "virtio-blk" : "?"))")
    }

    // Slot 3: Metal GPU (if GPU mode)
    var appWindow: AppWindow?

    if !config.noGpu {
        let bg = config.background
        let backend: VirtioMetalBackend

        if bg {
            // Headless mode: render to an offscreen texture. No window, no
            // CAMetalLayer, no interaction with the macOS window server.
            guard let device = MTLCreateSystemDefaultDevice() else {
                fatalError("Metal is not supported on this system")
            }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let sf = screen.backingScaleFactor
            let (w, h): (Int, Int)
            if let res = config.resolution {
                (w, h) = res
            } else {
                (w, h) = (Int(screen.frame.width * sf), Int(screen.frame.height * sf))
            }
            backend = VirtioMetalBackend(device: device, width: w, height: h)
        } else {
            // Windowed mode: create AppWindow with CAMetalLayer.
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = AppWindow(windowed: config.windowed, resolution: config.resolution, background: false)
            appWindow = window
            backend = VirtioMetalBackend(device: window.metalDevice, layer: window.metalLayer)
        }

        backend.verbose = config.verbose
        backend.captureFrames = config.captureFrames
        backend.capturePath = config.capturePath
        backend.multiCapture = config.captureFrames.count > 1
        vm.addVirtioDevice(slot: 3, backend: backend)
        print("  GPU: Metal passthrough (slot 3)")

        // ── Event schedule ───────────────────────────────────────────
        // Built from --events file, --capture flags, or both.
        // Frame numbers in the schedule are guest frame_ids.
        let schedule: EventSchedule
        if let eventsPath = config.eventsFile {
            guard let actions = loadEventScript(path: eventsPath) else { exit(1) }
            schedule = EventSchedule.build(actions: actions)
            print("  Events: \(eventsPath) (\(actions.count) actions, through frame \(schedule.maxFrame))")

            // Merge script captures into VirtioMetal capture state.
            for frame in 0...schedule.maxFrame + 10 {
                for action in schedule.actionsForFrame(frame) {
                    if case .capture(let path) = action {
                        backend.captureFrames.insert(frame)
                        backend.capturePath = path
                    }
                }
            }
            backend.multiCapture = backend.captureFrames.count > 1
        } else if !config.captureFrames.isEmpty {
            // --capture without an event script: exit after all requested
            // frame_ids have been captured. No schedule needed — VirtioMetal
            // checks captureFrames.isEmpty after each capture.
            backend.exitWhenCapturesDone = true
            schedule = EventSchedule.build(actions: [])
        } else {
            schedule = EventSchedule.build(actions: [])
        }

        // Wire onFrame callback: inject input events and handle exit
        // at scheduled frames.
        if !schedule.isEmpty {
            let fbSize = CGSize(width: CGFloat(backend.displayWidth),
                                height: CGFloat(backend.displayHeight))
            backend.onFrame = { [weak vm] frame in
                guard let vm = vm else { return }
                let events = schedule.actionsForFrame(frame)
                if events.isEmpty { return }

                guard let kbTransport = vm.virtioDevices[1],
                      let tabTransport = vm.virtioDevices[2] else { return }
                let kb = kbTransport.backend as! VirtioInputBackend
                let tab = tabTransport.backend as! VirtioInputBackend

                for action in events {
                    switch action {
                    case .keyboard(let type, let code, let value):
                        kb.injectEvent(type: type, code: code, value: value,
                                       state: kbTransport.currentQueueState(queue: 0), vm: vm)
                    case .text(let str):
                        let kbState = kbTransport.currentQueueState(queue: 0)
                        for scalar in str.unicodeScalars {
                            kb.injectEvent(type: EV_TEXT, code: 0, value: scalar.value,
                                           state: kbState, vm: vm)
                        }
                        kb.injectEvent(type: EV_SYN, code: 0, value: 0,
                                       state: kbState, vm: vm)
                    case .pointer(let x, let y):
                        let absX = UInt32(max(0, min(32767, x / Float(fbSize.width) * 32767)))
                        let absY = UInt32(max(0, min(32767, y / Float(fbSize.height) * 32767)))
                        tab.injectEvent(type: 3, code: 0, value: absX,
                                        state: tabTransport.currentQueueState(queue: 0), vm: vm)
                        tab.injectEvent(type: 3, code: 1, value: absY,
                                        state: tabTransport.currentQueueState(queue: 0), vm: vm)
                    case .button(let code, let value):
                        tab.injectEvent(type: 1, code: code, value: value,
                                        state: tabTransport.currentQueueState(queue: 0), vm: vm)
                    case .tabletSync:
                        tab.injectEvent(type: 0, code: 0, value: 0,
                                        state: tabTransport.currentQueueState(queue: 0), vm: vm)
                    case .capture:
                        break // Handled via captureFrames
                    case .exit:
                        exit(0)
                    }
                }
            }
        }

        // SIGUSR1 triggers ad-hoc screenshot capture.
        signal(SIGUSR1) { _ in
            _signalCaptureFlag = 1
        }

        // Display timer starts on first presentAndCommit (for SIGUSR1 only).
        // Scheduled captures and event scripts are driven by presents.
    }

    // ── DTB ─────────────────────────────────────────────────────────────

    var dtbDevices: [DTB.DeviceInfo] = []
    for (slot, transport) in vm.virtioDevices.sorted(by: { $0.key < $1.key }) {
        dtbDevices.append(DTB.DeviceInfo(slot: slot, deviceId: transport.backend.deviceId))
    }

    let dtb = DTB.minimal(ramBase: config.ramBase, ramSize: config.ramSize,
                          cpuCount: config.cpuCount, virtioDevices: dtbDevices)
    let dtbAddr = config.ramBase
    vm.writeGuest(at: dtbAddr, data: dtb)
    print("  DTB loaded at 0x\(String(dtbAddr, radix: 16)) (\(dtb.count) bytes)")
    print("")

    // ── Boot ────────────────────────────────────────────────────────────

    if let window = appWindow {
        // GPU mode: main thread = NSApplication, VM on background thread
        print("── Booting kernel (Metal GPU mode) ──")
        print("")

        // Boot VM on background thread
        let vmThread = Thread {
            do {
                try vm.run(entryPoint: entry, dtbAddress: dtbAddr, cpuCount: config.cpuCount)
            } catch {
                print("VM error: \(error)")
                exit(1)
            }
        }
        vmThread.name = "VM-Boot"
        vmThread.qualityOfService = .userInteractive
        vmThread.start()

        let app = NSApplication.shared
        app.delegate = window

        // Wire input event forwarding
        window.onKeyboardEvent = { type, code, value in
            guard let kbTransport = vm.virtioDevices[1] else { return }
            let kbBackend = kbTransport.backend as! VirtioInputBackend
            kbBackend.injectEvent(
                type: type, code: code, value: value,
                state: kbTransport.currentQueueState(queue: 0),
                vm: vm
            )
        }

        window.onTabletEvent = { type, code, value in
            guard let tabTransport = vm.virtioDevices[2] else { return }
            let tabBackend = tabTransport.backend as! VirtioInputBackend
            tabBackend.injectEvent(
                type: type, code: code, value: value,
                state: tabTransport.currentQueueState(queue: 0),
                vm: vm
            )
        }

        // Host-side cursor: use NSCursor for zero-latency hardware cursor plane.
        // Guest uploads cursor image via setCursorImage → we build NSCursor from
        // the pixels and set it on the view. WindowServer composites it at display
        // refresh rate, completely independent of the guest's frame rate.
        if let gpuTransport = vm.virtioDevices[3] {
            let gpuBackend = gpuTransport.backend as! VirtioMetalBackend
            gpuBackend.onCursorImageChanged = { [weak window] cursor in
                guard let window = window else { return }
                window.contentView.guestCursor = cursor
                window.contentView.updateCursor()
                window.contentView.window?.invalidateCursorRects(for: window.contentView)
            }
            gpuBackend.onCursorVisibilityChanged = { [weak window] visible in
                guard let window = window else { return }
                window.contentView.guestCursorVisible = visible
                window.contentView.updateCursor()
                window.contentView.window?.invalidateCursorRects(for: window.contentView)
            }
        }

        // Watchdog timer: exit with code 2 if the VM doesn't finish in time.
        // Safety net for kernel panics or deadlocks before virtio init.
        if let seconds = config.timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds)) {
                FileHandle.standardError.write(
                    Data("error: timeout after \(seconds)s — VM did not exit in time\n".utf8)
                )
                exit(2)
            }
            print("  Timeout: \(seconds)s")
        }

        // Activate and run the application.
        // In background mode, skip activation — the window exists for Metal
        // but doesn't need to be visible or steal focus.
        if !config.background {
            app.activate(ignoringOtherApps: true)
        }
        app.run()
    } else {
        // No GPU: run VM directly on main thread (serial-only mode)
        print("── Booting kernel (serial mode) ──")
        print("")

        // Watchdog timer for serial mode.
        if let seconds = config.timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(seconds)) {
                FileHandle.standardError.write(
                    Data("error: timeout after \(seconds)s — VM did not exit in time\n".utf8)
                )
                exit(2)
            }
            print("  Timeout: \(seconds)s")
        }

        try vm.run(entryPoint: entry, dtbAddress: dtbAddr, cpuCount: config.cpuCount)
    }
}

try main()
