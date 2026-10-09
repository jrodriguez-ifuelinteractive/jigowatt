import AppKit
import GhosttyKit

/// An NSView hosting one libghostty surface. libghostty attaches its own Metal layer to
/// the view and runs the child process (here: /usr/bin/ssh) on a PTY.
///
/// Adapted from Ghostty's SurfaceView_AppKit.swift (MIT license), keeping keyboard/IME,
/// mouse, resize and focus handling and dropping splits, search, inspector, etc.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?

    var onTitleChange: ((String) -> Void)?
    var onChildExited: ((Int32) -> Void)?
    /// Called when libghostty wants the surface closed (child exited or close requested).
    var onClose: ((_ processAlive: Bool) -> Void)?

    private var focused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var trackingArea: NSTrackingArea?
    private var cursor: NSCursor = .iBeam

    struct LaunchConfig {
        var command: String
        var environment: [String: String]
        var fontSize: Float = 0
    }

    init(app: ghostty_app_t, launch: LaunchConfig) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = launch.fontSize
        cfg.wait_after_command = false
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB

        let keys = Array(launch.environment.keys)
        let values = keys.map { launch.environment[$0]! }
        let cKeys = keys.map { strdup($0) }
        let cValues = values.map { strdup($0) }
        defer { (cKeys + cValues).forEach { free($0) } }
        var envVars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }

        surface = launch.command.withCString { cCommand in
            NSHomeDirectory().withCString { cHome in
                envVars.withUnsafeMutableBufferPointer { buf in
                    cfg.command = cCommand
                    cfg.working_directory = cHome
                    cfg.env_vars = buf.baseAddress
                    cfg.env_var_count = buf.count
                    return ghostty_surface_new(app, &cfg)
                }
            }
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Frees the libghostty surface (kills the child if still running). Call before discarding the view.
    func destroy() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    func setVisible(_ visible: Bool) {
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    // MARK: Layout

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let scaled = convertToBacking(NSRect(origin: .zero, size: frame.size)).size
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        ghostty_surface_set_color_scheme(surface, effectiveAppearance.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { setFocused(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setFocused(false) }
        return ok
    }

    private func setFocused(_ value: Bool) {
        guard focused != value else { return }
        focused = value
        if let surface { ghostty_surface_set_focus(surface, value) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        default: cursor = .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if !focused { window?.makeFirstResponder(self) }
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) { super.rightMouseUp(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_PRESS, GhosttyInput.mouseButton(event.buttonNumber))
    }
    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, GHOSTTY_MOUSE_RELEASE, GhosttyInput.mouseButton(event.buttonNumber))
    }

    @discardableResult
    private func sendMouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, GhosttyInput.mods(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        // Negative values tell Ghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Packed scroll mods: bit 0 = precision, bits 1-3 = momentum phase.
        var mods: Int32 = precise ? 1 : 0
        mods |= Int32(GhosttyInput.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
    }

    override func pressureChange(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure)) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Honor settings like macos-option-as-alt when translating text.
        let translatedGhostty = GhosttyInput.flags(
            ghostty_surface_key_translation_mods(surface, GhosttyInput.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reuse the original event when possible; IMEs (e.g. Korean) rely on identity.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                if markedBefore {
                    _ = committedText(action, text: text)
                } else {
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = GhosttyInput.mods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    /// Gives Ghostty first shot at ⌘/⌃ combos bound in its config (copy, paste, font size…);
    /// everything else falls through to the app menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { ptr -> Bool in
            ghosttyEvent.text = ptr
            var flags = ghostty_binding_flags_e(0)
            return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Treat C-/ as C-_ (avoids the macOS beep).
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            // Second time round (re-sent from doCommand) we encode it ourselves.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        if let text = text?.keyEventText {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    private func committedText(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Edit menu

    @IBAction func copy(_ sender: Any?) {
        if let surface { _ = "copy_to_clipboard".withCString { ghostty_surface_binding_action(surface, $0, 17) } }
    }

    @IBAction func paste(_ sender: Any?) {
        if let surface { _ = "paste_from_clipboard".withCString { ghostty_surface_binding_action(surface, $0, 20) } }
    }

    @IBAction override func selectAll(_ sender: Any?) {
        if let surface { _ = "select_all".withCString { ghostty_surface_binding_action(surface, $0, 10) } }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange { NSRange() }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // Ghostty reports top-left origin; convert to window, then screen coordinates.
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, 1))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }
        unmarkText()
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    /// Prevents beeps for unhandled selectors and re-sends ⌘ combos we deferred in performKeyEquivalent.
    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
