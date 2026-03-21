/// AppWindow: NSApplication + NSWindow with CAMetalLayer for display output.
///
/// Runs on the main thread. Provides:
/// - Metal-backed display surface for presenting guest framebuffer pixels
/// - NSEvent forwarding to virtio-input devices (keyboard + tablet)
///
/// Threading: updateDisplay() is called from vCPU threads (via virtio-gpu
/// RESOURCE_FLUSH). It dispatches to the main thread for Metal presentation.

import AppKit
import Metal
import QuartzCore

/// Callback for keyboard events: (type: UInt16, code: UInt16, value: UInt32)
typealias KeyboardEventCallback = (UInt16, UInt16, UInt32) -> Void

/// Callback for tablet (absolute pointer) events: (type: UInt16, code: UInt16, value: UInt32)
typealias TabletEventCallback = (UInt16, UInt16, UInt32) -> Void

// Linux evdev constants (EV_SYN, EV_KEY, EV_ABS defined in VirtioInput.swift)
private let ABS_X: UInt16 = 0
private let ABS_Y: UInt16 = 1
private let SYN_REPORT: UInt16 = 0
private let BTN_LEFT: UInt16 = 0x110

final class AppWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let metalDevice: MTLDevice
    let commandQueue: MTLCommandQueue
    let metalLayer: CAMetalLayer
    let window: NSWindow
    let contentView: MetalView

    /// Current display dimensions (set by guest via GET_DISPLAY_INFO response).
    private(set) var displayWidth: Int = 1024
    private(set) var displayHeight: Int = 768

    /// Input event callbacks (set by main.swift after VM starts).
    var onKeyboardEvent: KeyboardEventCallback?
    var onTabletEvent: TabletEventCallback?

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this system")
        }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()!

        // Create Metal layer
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: displayWidth, height: displayHeight)
        self.metalLayer = layer

        // Create content view
        let frame = NSRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        self.contentView = MetalView(frame: frame)
        self.contentView.wantsLayer = true

        // Create window
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        self.window = NSWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        super.init()

        self.contentView.layer = layer
        self.window.contentView = self.contentView
        self.window.title = "Hypervisor"
        self.window.delegate = self
        self.window.center()
        self.window.makeKeyAndOrderFront(nil)

        // Accept mouse events
        self.contentView.appWindow = self
    }

    // MARK: - Display update

    /// Present a pixel buffer on the Metal display.
    /// Called from vCPU threads — dispatches to main thread for presentation.
    /// Pixels are BGRA8 format, row-major, `width * 4` stride.
    func updateDisplay(pixels: UnsafeRawPointer, width: Int, height: Int) {
        // Resize if dimensions changed
        if width != displayWidth || height != displayHeight {
            displayWidth = width
            displayHeight = height
            DispatchQueue.main.async { [self] in
                metalLayer.drawableSize = CGSize(width: width, height: height)
                window.setContentSize(NSSize(width: width, height: height))
            }
        }

        // Copy pixels (they're in guest memory, which could be reused)
        let byteCount = width * height * 4
        let pixelCopy = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        memcpy(pixelCopy, pixels, byteCount)

        DispatchQueue.main.async { [self] in
            defer { pixelCopy.deallocate() }

            guard let drawable = metalLayer.nextDrawable() else {
                print("AppWindow: nextDrawable() returned nil")
                return
            }

            // Create an intermediate texture for CPU upload, then blit to drawable.
            // CAMetalLayer drawable textures may not support direct CPU replace().
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width, height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            guard let staging = metalDevice.makeTexture(descriptor: desc) else {
                print("AppWindow: failed to create staging texture")
                return
            }

            let region = MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            )
            staging.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: pixelCopy,
                bytesPerRow: width * 4
            )

            // Blit staging → drawable
            guard let cmdBuffer = commandQueue.makeCommandBuffer(),
                  let blit = cmdBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()

            cmdBuffer.present(drawable)
            cmdBuffer.commit()
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window is already created in init
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        exit(0)
    }

    // MARK: - Input event forwarding

    func handleKeyEvent(_ event: NSEvent) {
        guard let callback = onKeyboardEvent else { return }

        // Map NSEvent keyCode to Linux evdev keycode
        let linuxCode = macToLinuxKeycode(event.keyCode)
        let isDown: UInt32 = (event.type == .keyDown) ? 1 : 0

        callback(EV_KEY, linuxCode, isDown)
        callback(EV_SYN, SYN_REPORT, 0)
    }

    func handleMouseEvent(_ event: NSEvent) {
        guard let callback = onTabletEvent else { return }

        // Convert window coordinates to absolute tablet coordinates (0..32767)
        let loc = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds

        let absX = UInt32(max(0, min(32767, (loc.x / bounds.width) * 32767)))
        // Flip Y: NSView has origin at bottom-left, guest expects top-left
        let absY = UInt32(max(0, min(32767, ((bounds.height - loc.y) / bounds.height) * 32767)))

        callback(EV_ABS, ABS_X, absX)
        callback(EV_ABS, ABS_Y, absY)
        callback(EV_SYN, SYN_REPORT, 0)
    }

    func handleMouseButton(_ event: NSEvent) {
        guard let callback = onTabletEvent else { return }

        let isDown: UInt32 = (event.type == .leftMouseDown) ? 1 : 0
        callback(EV_KEY, BTN_LEFT, isDown)
        callback(EV_SYN, SYN_REPORT, 0)
    }
}

// MARK: - MetalView (NSView subclass for event handling)

final class MetalView: NSView {
    weak var appWindow: AppWindow?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        appWindow?.handleKeyEvent(event)
    }

    override func keyUp(with event: NSEvent) {
        appWindow?.handleKeyEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        appWindow?.handleMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        appWindow?.handleMouseEvent(event)
    }

    override func mouseDown(with event: NSEvent) {
        appWindow?.handleMouseButton(event)
        appWindow?.handleMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        appWindow?.handleMouseButton(event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove old tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Add new tracking area for mouse movement
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}

// MARK: - Keycode mapping (macOS → Linux evdev)

/// Map macOS virtual keycode to Linux evdev keycode.
/// macOS keycodes are hardware-specific (kVK_* from Carbon Events.h).
/// Linux keycodes are from linux/input-event-codes.h.
private func macToLinuxKeycode(_ macKeyCode: UInt16) -> UInt16 {
    switch macKeyCode {
    // Letters (QWERTY layout)
    case 0x00: return 30   // A
    case 0x01: return 31   // S
    case 0x02: return 32   // D
    case 0x03: return 33   // F
    case 0x04: return 35   // H
    case 0x05: return 34   // G
    case 0x06: return 44   // Z
    case 0x07: return 45   // X
    case 0x08: return 46   // C
    case 0x09: return 47   // V
    case 0x0B: return 48   // B
    case 0x0C: return 16   // Q
    case 0x0D: return 17   // W
    case 0x0E: return 18   // E
    case 0x0F: return 19   // R
    case 0x10: return 21   // Y
    case 0x11: return 20   // T
    case 0x12: return 2    // 1
    case 0x13: return 3    // 2
    case 0x14: return 4    // 3
    case 0x15: return 5    // 4
    case 0x16: return 7    // 6
    case 0x17: return 6    // 5
    case 0x18: return 13   // =
    case 0x19: return 10   // 9
    case 0x1A: return 8    // 7
    case 0x1B: return 12   // -
    case 0x1C: return 9    // 8
    case 0x1D: return 11   // 0
    case 0x1E: return 27   // ]
    case 0x1F: return 24   // O
    case 0x20: return 22   // U
    case 0x21: return 26   // [
    case 0x22: return 23   // I
    case 0x23: return 25   // P
    case 0x25: return 38   // L
    case 0x26: return 36   // J
    case 0x27: return 40   // '
    case 0x28: return 37   // K
    case 0x29: return 39   // ;
    case 0x2A: return 43   // backslash
    case 0x2B: return 51   // ,
    case 0x2C: return 53   // /
    case 0x2D: return 49   // N
    case 0x2E: return 50   // M
    case 0x2F: return 52   // .
    case 0x32: return 41   // `

    // Special keys
    case 0x24: return 28   // Return
    case 0x30: return 15   // Tab
    case 0x31: return 57   // Space
    case 0x33: return 14   // Backspace
    case 0x35: return 1    // Escape
    case 0x37: return 125  // Left Command (as KEY_LEFTMETA)
    case 0x38: return 42   // Left Shift
    case 0x39: return 58   // Caps Lock
    case 0x3A: return 56   // Left Alt/Option
    case 0x3B: return 29   // Left Control
    case 0x3C: return 54   // Right Shift
    case 0x3D: return 100  // Right Alt/Option
    case 0x3E: return 97   // Right Control

    // Arrow keys
    case 0x7B: return 105  // Left
    case 0x7C: return 106  // Right
    case 0x7D: return 108  // Down
    case 0x7E: return 103  // Up

    // Function keys
    case 0x7A: return 59   // F1
    case 0x78: return 60   // F2
    case 0x63: return 61   // F3
    case 0x76: return 62   // F4
    case 0x60: return 63   // F5
    case 0x61: return 64   // F6
    case 0x62: return 65   // F7
    case 0x64: return 66   // F8
    case 0x65: return 67   // F9
    case 0x6D: return 68   // F10
    case 0x67: return 87   // F11
    case 0x6F: return 88   // F12

    // Navigation
    case 0x73: return 102  // Home
    case 0x77: return 107  // End
    case 0x74: return 104  // Page Up
    case 0x79: return 109  // Page Down
    case 0x75: return 111  // Delete (forward)

    default: return 0      // Unknown — KEY_RESERVED
    }
}
