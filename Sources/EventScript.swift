/// Event script parser and scheduler for automated testing.
///
/// Parses a simple line-based format using evdev key names (Linux
/// input-event-codes.h standard):
///
///     type hello world     — type each character with key press/release
///     key backspace        — press a single key
///     key shift+left       — press a modified key (modifier held)
///     click 100 200        — click at (x, y) in points
///     dblclick 100 200     — double-click at (x, y) in points
///     wait 10              — wait 10 extra frames
///     capture /tmp/out.png — capture screenshot
///
/// Lines starting with # are comments. Blank lines are ignored.

import Foundation

// evdev constants EV_SYN, EV_KEY, EV_ABS are defined in VirtioInput.swift.

private let SYN_REPORT: UInt16 = 0
private let ABS_X: UInt16 = 0
private let ABS_Y: UInt16 = 1
private let BTN_LEFT: UInt16 = 0x110

// ── Evdev keycode name table ──────────────────────────────────────────

/// Map human-friendly key names to Linux evdev keycodes.
/// Names are case-insensitive. Standard evdev names (KEY_A → "a") plus
/// common aliases ("backspace", "enter", "esc", etc.).
private let evdevKeyCodes: [String: UInt16] = [
    // Letters
    "a": 30, "b": 48, "c": 46, "d": 32, "e": 18, "f": 33,
    "g": 34, "h": 35, "i": 23, "j": 36, "k": 37, "l": 38,
    "m": 50, "n": 49, "o": 24, "p": 25, "q": 16, "r": 19,
    "s": 31, "t": 20, "u": 22, "v": 47, "w": 17, "x": 45,
    "y": 21, "z": 44,
    // Digits
    "0": 11, "1": 2, "2": 3, "3": 4, "4": 5,
    "5": 6, "6": 7, "7": 8, "8": 9, "9": 10,
    // Navigation
    "left": 105, "right": 106, "up": 103, "down": 108,
    "home": 102, "end": 107, "pageup": 104, "pagedown": 109,
    // Editing
    "backspace": 14, "delete": 111, "return": 28, "enter": 28,
    "tab": 15, "space": 57, "escape": 1, "esc": 1,
    // Modifiers
    "shift": 42, "leftshift": 42, "rightshift": 54,
    "ctrl": 29, "leftctrl": 29, "rightctrl": 97,
    "alt": 56, "leftalt": 56, "rightalt": 100,
    "cmd": 125, "meta": 125, "leftmeta": 125, "rightmeta": 126,
    // Punctuation
    "minus": 12, "equal": 13, "leftbrace": 26, "rightbrace": 27,
    "semicolon": 39, "apostrophe": 40, "grave": 41, "backslash": 43,
    "comma": 51, "dot": 52, "slash": 53,
    // Function keys
    "f1": 59, "f2": 60, "f3": 61, "f4": 62, "f5": 63, "f6": 64,
    "f7": 65, "f8": 66, "f9": 67, "f10": 68, "f11": 87, "f12": 88,
]

/// Map a printable character to (evdev keycode, needs shift).
private func charToKey(_ ch: Character) -> (code: UInt16, shift: Bool)? {
    // Lowercase letters
    if ch >= "a" && ch <= "z" {
        return (evdevKeyCodes[String(ch)]!, false)
    }
    // Uppercase letters
    if ch >= "A" && ch <= "Z" {
        return (evdevKeyCodes[String(ch).lowercased()]!, true)
    }
    // Digits
    if ch >= "0" && ch <= "9" {
        return (evdevKeyCodes[String(ch)]!, false)
    }
    // Space
    if ch == " " { return (57, false) }
    // Unshifted punctuation
    let unshifted: [Character: UInt16] = [
        "-": 12, "=": 13, "[": 26, "]": 27,
        ";": 39, "'": 40, "`": 41, "\\": 43,
        ",": 51, ".": 52, "/": 53,
    ]
    if let code = unshifted[ch] { return (code, false) }
    // Shifted punctuation
    let shifted: [Character: UInt16] = [
        "!": 2, "@": 3, "#": 4, "$": 5, "%": 6,
        "^": 7, "&": 8, "*": 9, "(": 10, ")": 11,
        "_": 12, "+": 13, "{": 26, "}": 27,
        ":": 39, "\"": 40, "~": 41, "|": 43,
        "<": 51, ">": 52, "?": 53,
    ]
    if let code = shifted[ch] { return (code, true) }
    return nil
}

// ── Frame actions ─────────────────────────────────────────────────────

/// A single evdev-level event to inject at a specific frame.
enum FrameAction {
    /// Keyboard event: type (EV_KEY/EV_SYN), code (keycode), value (1=press, 0=release).
    case keyboard(type: UInt16, code: UInt16, value: UInt32)
    /// Move pointer to (x, y) in points. Converted to absolute tablet coords at injection time.
    case pointer(x: Float, y: Float)
    /// Tablet button event (BTN_LEFT etc.). Separate from keyboard because it goes to the tablet device.
    case button(code: UInt16, value: UInt32)
    /// Tablet SYN_REPORT (goes to tablet device, not keyboard).
    case tabletSync
    /// Capture screenshot to path.
    case capture(path: String)
}

// ── Event schedule ────────────────────────────────────────────────────

/// A frame-indexed schedule of input events and captures.
///
/// Built from a parsed event script. Used by the hypervisor to inject
/// events at specific frames during execution.
class EventSchedule {
    /// Frame number → list of actions to execute at that frame.
    private var frameActions: [Int: [FrameAction]] = [:]
    /// Highest scheduled frame (for determining when to exit).
    private(set) var maxFrame: Int = 0

    /// Get actions scheduled for a specific frame.
    func actionsForFrame(_ frame: Int) -> [FrameAction] {
        frameActions[frame] ?? []
    }

    /// Whether any events or captures are scheduled.
    var isEmpty: Bool { frameActions.isEmpty }

    /// Build a schedule from parsed script actions.
    ///
    /// - Parameters:
    ///   - actions: Parsed script actions.
    ///   - startFrame: Frame number for the first action (default: 30, gives OS time to boot).
    ///   - delay: Frames between individual key events (default: 2).
    static func build(actions: [ScriptAction], startFrame: Int = 30, delay: Int = 1) -> EventSchedule {
        let schedule = EventSchedule()
        var frame = startFrame

        for action in actions {
            switch action {
            case .type(let text):
                for ch in text {
                    guard let (code, shift) = charToKey(ch) else { continue }
                    var events: [FrameAction] = []
                    if shift {
                        events.append(.keyboard(type: EV_KEY, code: 42, value: 1)) // LEFTSHIFT down
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                    events.append(.keyboard(type: EV_KEY, code: code, value: 1)) // key down
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    events.append(.keyboard(type: EV_KEY, code: code, value: 0)) // key up
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    if shift {
                        events.append(.keyboard(type: EV_KEY, code: 42, value: 0)) // LEFTSHIFT up
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                    schedule.addActions(events, at: frame)
                    frame += delay
                }

            case .key(let parts):
                // Parts: ["shift", "left"] or ["backspace"]
                // All parts except the last are modifiers.
                var events: [FrameAction] = []
                let modifiers = parts.dropLast()
                let mainKey = parts.last!

                // Press modifiers
                for mod in modifiers {
                    if let code = evdevKeyCodes[mod] {
                        events.append(.keyboard(type: EV_KEY, code: code, value: 1))
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                }
                // Press + release main key
                if let code = evdevKeyCodes[mainKey] {
                    events.append(.keyboard(type: EV_KEY, code: code, value: 1))
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    events.append(.keyboard(type: EV_KEY, code: code, value: 0))
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                }
                // Release modifiers (reverse order)
                for mod in modifiers.reversed() {
                    if let code = evdevKeyCodes[mod] {
                        events.append(.keyboard(type: EV_KEY, code: code, value: 0))
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                }
                schedule.addActions(events, at: frame)
                frame += delay

            case .click(let x, let y):
                let events: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1), // press
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0), // release
                    .tabletSync,
                ]
                schedule.addActions(events, at: frame)
                frame += delay

            case .dblclick(let x, let y):
                // First click
                let click1: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0),
                    .tabletSync,
                ]
                schedule.addActions(click1, at: frame)
                frame += 1 // Short delay for double-click
                // Second click
                let click2: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0),
                    .tabletSync,
                ]
                schedule.addActions(click2, at: frame)
                frame += delay

            case .wait(let frames):
                frame += frames

            case .capture(let path):
                schedule.addActions([.capture(path: path)], at: frame)
                frame += delay
            }
        }

        return schedule
    }

    private func addActions(_ actions: [FrameAction], at frame: Int) {
        if frameActions[frame] == nil {
            frameActions[frame] = actions
        } else {
            frameActions[frame]!.append(contentsOf: actions)
        }
        if frame > maxFrame {
            maxFrame = frame
        }
    }
}

// ── Script parsing ────────────────────────────────────────────────────

/// A high-level action parsed from the event script.
enum ScriptAction {
    case type(String)
    case key([String])         // ["shift", "left"] or ["backspace"]
    case click(Float, Float)
    case dblclick(Float, Float)
    case wait(Int)
    case capture(String)
}

/// Parse an event script from text.
///
/// Format: one action per line. Lines starting with # are comments.
/// Blank lines are ignored.
///
///     type hello world
///     key backspace
///     key shift+left
///     click 100 200
///     wait 5
///     capture /tmp/test.png
func parseEventScript(_ text: String) -> [ScriptAction] {
    var actions: [ScriptAction] = []

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        // Split into command + arguments
        let parts = line.split(separator: " ", maxSplits: 1)
        guard let command = parts.first else { continue }
        let argStr = parts.count > 1 ? String(parts[1]) : ""

        switch command.lowercased() {
        case "type":
            if !argStr.isEmpty {
                actions.append(.type(argStr))
            }
        case "key":
            // Parse key names, possibly with + for modifiers: "shift+left"
            let keyParts = argStr.lowercased().split(separator: "+").map(String.init)
            if !keyParts.isEmpty {
                actions.append(.key(keyParts))
            }
        case "click":
            let coords = argStr.split(separator: " ")
            if coords.count >= 2, let x = Float(coords[0]), let y = Float(coords[1]) {
                actions.append(.click(x, y))
            }
        case "dblclick":
            let coords = argStr.split(separator: " ")
            if coords.count >= 2, let x = Float(coords[0]), let y = Float(coords[1]) {
                actions.append(.dblclick(x, y))
            }
        case "wait":
            if let n = Int(argStr.trimmingCharacters(in: .whitespaces)) {
                actions.append(.wait(n))
            }
        case "capture":
            let path = argStr.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                actions.append(.capture(path))
            }
        default:
            print("EventScript: unknown command '\(command)', ignoring")
        }
    }

    return actions
}

/// Load and parse an event script from a file path.
func loadEventScript(path: String) -> [ScriptAction]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("Error: cannot read event script '\(path)'")
        return nil
    }
    return parseEventScript(text)
}
