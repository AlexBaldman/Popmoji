import AppKit
import ApplicationServices
import Carbon

let popmojiEventTag: Int64 = 0x504F504D4F4A49

enum Accessibility {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func openSettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String
    }
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
    /// If the host exposes its text, require an exact suffix and an empty selection.
    static func suffixMatches(_ suffix: String, element: AXUIElement) -> Bool {
        guard let range = selectedRange(element) else { return true }
        guard range.length == 0 else { return false }
        guard let value = string(element, kAXValueAttribute) else { return true }
        let text = value as NSString
        let length = (suffix as NSString).length
        guard range.location >= length, range.location <= text.length else { return false }
        return text.substring(with: NSRange(location: range.location - length, length: length)) == suffix
    }
    static func caretRect() -> NSRect? {
        guard let element = focusedElement(), var range = selectedRange(element),
              let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
              rangeValue, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

final class GlobalHotKey {
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    @discardableResult func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().action?()
            return noErr
        }, 1, &spec, context, &handler)
        guard status == noErr else { return false }
        let id = EventHotKeyID(signature: OSType(0x504F504D), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class KeyboardMonitor {
    var onQuery: ((String?) -> Void)?
    var onNavigate: ((Int) -> Void)?
    var onCommit: ((String) -> Bool)?
    var inlineContains: ((CGPoint) -> Bool)?
    var enabled: () -> Bool = { true }
    var isPickerVisible: () -> Bool = { false }
    var excluded: (String) -> Bool = { _ in false }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedKeys = Set<Int64>()
    private(set) var tracker = ShortcodeTracker()
    private(set) var targetPID: pid_t?
    private(set) var targetElement: AXUIElement?
    private var lastInput = Date.distantPast
    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil, Accessibility.trusted else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(pointer).takeUnretainedValue()
            return monitor.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; swallowedKeys.removeAll(); reset()
    }
    func reset() {
        tracker.reset(); targetPID = nil; targetElement = nil
        onQuery?(nil)
    }
    private func publish() {
        let query = tracker.query
        // Let the host receive its character before accessibility and UI work.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tracker.query == query else { return }
            self.onQuery?(query)
        }
    }
    private func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == popmojiEventTag { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedKeys.remove(key) != nil }
        guard enabled(), !isPickerVisible(), !IsSecureEventInputEnabled() else {
            if tracker.query != nil { reset() }
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .scrollWheel {
            if inlineContains?(event.location) != true { reset() }
            return false
        }
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) || event.flags.contains(.maskAlternate) {
            if tracker.query != nil { reset() }
            return false
        }
        guard type == .keyDown else { return false }
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !excluded(app?.bundleIdentifier ?? "") else { reset(); return false }
        if targetPID != nil && targetPID != app?.processIdentifier { reset() }
        if Date().timeIntervalSince(lastInput) > 30 { reset() }
        lastInput = Date()
        if let query = tracker.query {
            if key == 53 { reset(); swallowedKeys.insert(key); return true }
            if (key == 125 || key == 126) && !query.isEmpty {
                onNavigate?(key == 125 ? 1 : -1); swallowedKeys.insert(key); return true
            }
            if (key == 36 || key == 48 || key == 76) && !query.isEmpty {
                if onCommit?(query) == true { swallowedKeys.insert(key); return true }
                reset(); return false
            }
        }
        if key == 51 { tracker.backspace(); publish(); return false }
        if [123, 124, 125, 126, 115, 119, 116, 121, 117, 53, 36, 48, 76].contains(key) { reset(); return false }
        var buffer = [UniChar](repeating: 0, count: 16)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
        guard count > 0 else { reset(); return false }
        let string = String(utf16CodeUnits: buffer, count: count)
        if string == ":", let query = tracker.query, !query.isEmpty {
            if onCommit?(query) == true { swallowedKeys.insert(key); return true }
            reset(); return false
        }
        let oldQuery = tracker.query
        tracker.type(string)
        if oldQuery == nil && tracker.query != nil {
            let element = Accessibility.focusedElement()
            if Accessibility.isSecure(element) { reset(); return false }
            targetPID = app?.processIdentifier
            targetElement = element
        }
        if tracker.query != nil || oldQuery != nil { publish() }
        return false
    }
}

enum Inserter {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    static func insert(_ string: String, into app: NSRunningApplication, replacing suffix: String = "",
                       originalElement: AXUIElement? = nil, completion: @escaping (Bool) -> Void) {
        guard Accessibility.trusted, !app.isTerminated, !IsSecureEventInputEnabled() else { completion(false); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            guard suffix.isEmpty else { completion(false); return }
            app.activate(options: [.activateIgnoringOtherApps])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (suffix.isEmpty ? 0.09 : 0.01)) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                  !IsSecureEventInputEnabled() else { completion(false); return }
            let focused = Accessibility.focusedElement()
            guard !Accessibility.isSecure(focused) else { completion(false); return }
            if !suffix.isEmpty {
                if let originalElement, let focused, !CFEqual(originalElement, focused) { completion(false); return }
                if let focused, !Accessibility.suffixMatches(suffix, element: focused) { completion(false); return }
            }
            // Unicode keyboard events leave all clipboard types and clipboard history untouched.
            for _ in suffix { postKey(51, down: true); postKey(51, down: false) }
            let source = CGEventSource(stateID: .privateState)
            let utf16 = Array(string.utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: popmojiEventTag)
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cgSessionEventTap)
            }
            completion(true)
        }
    }
    private static func postKey(_ code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: down) else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: popmojiEventTag)
        event.post(tap: .cgSessionEventTap)
    }
}
