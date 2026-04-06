/// Event script parser and scheduler for automated testing.
///
/// Each line specifies a frame_id and a command. The frame_id corresponds
/// to the guest's `presentAndCommit` frame_id — actions fire when the
/// guest presents a frame with that ID.
///
///     0 type hello world       — type each character starting at frame 0
///     10 key backspace         — press a single key at frame 10
///     15 key shift+left        — press a modified key at frame 15
///     20 move 100 200          — move pointer to (x, y) at frame 20
///     25 click 100 200         — click at (x, y) at frame 25
///     30 dblclick 100 200      — double-click at (x, y) (spans 2 frames)
///     40 drag 100 200 300 200     — drag from→to (steps+2 frames, default 12)
///     40 drag 100 200 300 200 20  — drag with 20 interpolation steps (22 frames)
///     55 capture /tmp/out.png  — capture screenshot at frame 55
///     60 exit                  — exit the hypervisor cleanly
///
/// Lines starting with # are comments. Blank lines are ignored.
///
/// Multi-frame commands expand across consecutive frame_ids:
///   - type:     1 frame per mapped ASCII character (a-z, A-Z, 0-9, space,
///               common punctuation). Unmapped characters are skipped with a warning.
///   - dblclick: 2 frames (click at N, click at N+1)
///   - drag:     steps+2 frames (press + steps interpolation + release, default steps=10)
///
/// If two commands target the same frame_id, both fire (actions are
/// appended, not replaced). Avoid overlapping multi-frame ranges.

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
    /// Move pointer to (x, y) in framebuffer pixels. Converted to absolute tablet coords at injection time.
    case pointer(x: Float, y: Float)
    /// Tablet button event (BTN_LEFT etc.). Separate from keyboard because it goes to the tablet device.
    case button(code: UInt16, value: UInt32)
    /// Tablet SYN_REPORT (goes to tablet device, not keyboard).
    case tabletSync
    /// Capture screenshot to path.
    case capture(path: String)
    /// Exit the hypervisor cleanly.
    case exit
}

// ── Event schedule ────────────────────────────────────────────────────

/// A frame_id-indexed schedule of input events and captures.
///
/// Built from a parsed event script. Used by the hypervisor to inject
/// events at specific frames during execution. Frame numbers correspond
/// to the guest's presentAndCommit frame_id values.
class EventSchedule {
    /// Frame_id → list of actions to execute at that frame.
    private var frameActions: [Int: [FrameAction]] = [:]
    /// Highest scheduled frame_id.
    private(set) var maxFrame: Int = 0

    /// Get actions scheduled for a specific frame_id.
    func actionsForFrame(_ frame: Int) -> [FrameAction] {
        frameActions[frame] ?? []
    }

    /// Whether any events or captures are scheduled.
    var isEmpty: Bool { frameActions.isEmpty }

    /// Build a schedule from parsed script actions with explicit frame_ids.
    ///
    /// Multi-frame commands (type, drag, dblclick) expand across consecutive
    /// frame_ids starting from the action's specified frame_id.
    static func build(actions: [(frameId: Int, action: ScriptAction)]) -> EventSchedule {
        let schedule = EventSchedule()

        for (startFrame, action) in actions {
            var frame = startFrame

            switch action {
            case .type(let text):
                for ch in text {
                    guard let (code, shift) = charToKey(ch) else {
                        print("EventScript: type: skipping unmapped character '\(ch)' (U+\(String(ch.unicodeScalars.first!.value, radix: 16, uppercase: true)))")
                        continue
                    }
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
                    frame += 1
                }

            case .key(let parts):
                var events: [FrameAction] = []
                let modifiers = parts.dropLast()
                let mainKey = parts.last!
                for mod in modifiers {
                    if let code = evdevKeyCodes[mod] {
                        events.append(.keyboard(type: EV_KEY, code: code, value: 1))
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                }
                if let code = evdevKeyCodes[mainKey] {
                    events.append(.keyboard(type: EV_KEY, code: code, value: 1))
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    events.append(.keyboard(type: EV_KEY, code: code, value: 0))
                    events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                }
                for mod in modifiers.reversed() {
                    if let code = evdevKeyCodes[mod] {
                        events.append(.keyboard(type: EV_KEY, code: code, value: 0))
                        events.append(.keyboard(type: EV_SYN, code: SYN_REPORT, value: 0))
                    }
                }
                schedule.addActions(events, at: frame)

            case .move(let x, let y):
                schedule.addActions([.pointer(x: x, y: y), .tabletSync], at: frame)

            case .click(let x, let y):
                let events: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0),
                    .tabletSync,
                ]
                schedule.addActions(events, at: frame)

            case .dblclick(let x, let y):
                let click1: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0),
                    .tabletSync,
                ]
                schedule.addActions(click1, at: frame)
                let click2: [FrameAction] = [
                    .pointer(x: x, y: y),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 0),
                    .tabletSync,
                ]
                schedule.addActions(click2, at: frame + 1)

            case .drag(let x1, let y1, let x2, let y2, let steps):
                let pressEvents: [FrameAction] = [
                    .pointer(x: x1, y: y1),
                    .tabletSync,
                    .button(code: BTN_LEFT, value: 1),
                    .tabletSync,
                ]
                schedule.addActions(pressEvents, at: frame)
                frame += 1
                for i in 1...steps {
                    let t = Float(i) / Float(steps)
                    let x = x1 + (x2 - x1) * t
                    let y = y1 + (y2 - y1) * t
                    schedule.addActions([.pointer(x: x, y: y), .tabletSync], at: frame)
                    frame += 1
                }
                schedule.addActions([.button(code: BTN_LEFT, value: 0), .tabletSync], at: frame)

            case .capture(let path):
                schedule.addActions([.capture(path: path)], at: frame)

            case .exit:
                schedule.addActions([.exit], at: frame)
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
    case move(Float, Float)
    case click(Float, Float)
    case dblclick(Float, Float)
    case drag(Float, Float, Float, Float, Int) // x1, y1, x2, y2, steps
    case capture(String)
    case exit
}

/// Parse an event script from text.
///
/// Format: `<frame_id> <command> [args]`, one per line.
/// Lines starting with # are comments. Blank lines are ignored.
///
///     0 type hello world
///     10 key backspace
///     15 click 100 200
///     20 capture /tmp/test.png
///     25 exit
func parseEventScript(_ text: String) -> [(frameId: Int, action: ScriptAction)] {
    var actions: [(frameId: Int, action: ScriptAction)] = []

    for (lineNum, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        // Split: <frame_id> <command> [args]
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let frameId = Int(parts[0]) else {
            print("EventScript: line \(lineNum + 1): expected '<frame_id> <command> [args]': \(line)")
            continue
        }
        let command = String(parts[1]).lowercased()
        let argStr = parts.count > 2 ? String(parts[2]) : ""

        switch command {
        case "type":
            if !argStr.isEmpty {
                actions.append((frameId, .type(argStr)))
            }
        case "key":
            let keyParts = argStr.lowercased().split(separator: "+").map(String.init)
            if !keyParts.isEmpty {
                actions.append((frameId, .key(keyParts)))
            }
        case "move":
            let coords = argStr.split(separator: " ")
            if coords.count >= 2, let x = Float(coords[0]), let y = Float(coords[1]) {
                actions.append((frameId, .move(x, y)))
            }
        case "click":
            let coords = argStr.split(separator: " ")
            if coords.count >= 2, let x = Float(coords[0]), let y = Float(coords[1]) {
                actions.append((frameId, .click(x, y)))
            }
        case "dblclick":
            let coords = argStr.split(separator: " ")
            if coords.count >= 2, let x = Float(coords[0]), let y = Float(coords[1]) {
                actions.append((frameId, .dblclick(x, y)))
            }
        case "drag":
            let coords = argStr.split(separator: " ")
            if coords.count >= 4,
               let x1 = Float(coords[0]), let y1 = Float(coords[1]),
               let x2 = Float(coords[2]), let y2 = Float(coords[3]) {
                let steps = coords.count >= 5 ? (Int(coords[4]) ?? 10) : 10
                actions.append((frameId, .drag(x1, y1, x2, y2, steps)))
            }
        case "capture":
            let path = argStr.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                actions.append((frameId, .capture(path)))
            }
        case "exit":
            actions.append((frameId, .exit))
        default:
            print("EventScript: line \(lineNum + 1): unknown command '\(command)'")
        }
    }

    return actions
}

/// Load and parse an event script from a file path.
func loadEventScript(path: String) -> [(frameId: Int, action: ScriptAction)]? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("Error: cannot read event script '\(path)'")
        return nil
    }
    return parseEventScript(text)
}
