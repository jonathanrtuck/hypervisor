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
    let ramMiB: Int
    let cpuCount: Int
    let shareDir: String?
    let captureFrame: Int
    let capturePath: String

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
    print("  --ram SIZE           RAM size in MiB (default: 256)")
    print("  --cpus N             Number of vCPUs (default: 4)")
    print("  --share DIR          9P shared directory (auto-detected if omitted)")
    print("  --capture N PATH     Capture frame N as PNG to PATH, then exit")
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
    var ramMiB = 256
    var cpuCount = 4
    var shareDir: String?
    var captureFrame = -1
    var capturePath = "/tmp/hypervisor-capture.png"

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
        case "--capture":
            guard i + 2 < args.count, let n = Int(args[i + 1]) else {
                print("Error: --capture requires N PATH")
                exit(1)
            }
            captureFrame = n
            capturePath = args[i + 2]
            i += 2
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
        ramMiB: ramMiB,
        cpuCount: cpuCount,
        shareDir: shareDir,
        captureFrame: captureFrame,
        capturePath: capturePath
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

    // Slot 3: Metal GPU (if GPU mode)
    var appWindow: AppWindow?

    if !config.noGpu {
        // Create AppWindow on main thread — provides MTLDevice + CAMetalLayer
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = AppWindow(windowed: config.windowed)
        appWindow = window

        let backend = VirtioMetalBackend(device: window.metalDevice, layer: window.metalLayer)
        backend.verbose = config.verbose
        backend.captureAtFrame = config.captureFrame
        backend.capturePath = config.capturePath
        backend.exitAfterCapture = config.captureFrame >= 0
        vm.addVirtioDevice(slot: 3, backend: backend)
        print("  GPU: Metal passthrough (slot 3)")

        // SIGUSR1 triggers ad-hoc screenshot capture.
        signal(SIGUSR1) { _ in
            _signalCaptureFlag = 1
        }
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

        // Activate and run the application
        app.activate(ignoringOtherApps: true)
        app.run()
    } else {
        // No GPU: run VM directly on main thread (serial-only mode)
        print("── Booting kernel (serial mode) ──")
        print("")
        try vm.run(entryPoint: entry, dtbAddress: dtbAddr, cpuCount: config.cpuCount)
    }
}

try main()
