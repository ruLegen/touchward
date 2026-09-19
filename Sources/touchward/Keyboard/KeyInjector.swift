import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Types into whatever app currently has focus.
///
/// Two paths on purpose. Real virtual keycodes are what terminals, games and IME-aware
/// fields understand; a Unicode payload with keycode 0 is ignored by those. So we resolve
/// a character to a keycode against the *current* layout first and only fall back to the
/// Unicode payload for characters the layout cannot produce. That fallback is what makes
/// Vietnamese diacritics and emoji work when the layout has no key for them.
final class KeyInjector {
    private let source: CGEventSource?
    private var heldKeyCounts: [CGKeyCode: Int] = [:]
    private var repeatKey: CGKeyCode?
    private var repeatFlags: CGEventFlags = []
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?

    init() {
        source = CGEventSource(stateID: .hidSystemState)
    }

    /// True when macOS has secure input on. Synthetic keystrokes are dropped system-wide
    /// while it is, by design — surface it instead of silently swallowing keys.
    var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    func type(_ text: String) {
        for character in text {
            if let (keyCode, flags) = Self.keyCode(for: character) {
                sendKey(keyCode, flags: flags)
            } else {
                sendUnicode(String(character))
            }
        }
    }

    func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        postKeyDown(keyCode, flags: flags)
        postKeyUp(keyCode)
    }

    /// Holds a physical key down. Repeatable keys receive additional keyDown events
    /// after the normal macOS delay until releaseKey is called.
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], repeatable: Bool = false) {
        let count = heldKeyCounts[keyCode, default: 0]
        heldKeyCounts[keyCode] = count + 1
        guard count == 0 else { return }

        postKeyDown(keyCode, flags: flags)
        if repeatable {
            repeatKey = keyCode
            repeatFlags = flags
            scheduleRepeat()
        }
    }

    func releaseKey(_ keyCode: CGKeyCode) {
        guard let count = heldKeyCounts[keyCode] else { return }
        if count > 1 {
            heldKeyCounts[keyCode] = count - 1
            return
        }
        heldKeyCounts.removeValue(forKey: keyCode)
        postKeyUp(keyCode)
        if repeatKey == keyCode { stopRepeat() }
    }

    func releaseAllKeys() {
        let keys = Array(heldKeyCounts.keys)
        heldKeyCounts.removeAll()
        stopRepeat()
        for key in keys { postKeyUp(key) }
    }

    private func postKeyDown(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postKeyUp(_ keyCode: CGKeyCode) {
        // Clear modifiers on the way up or the target app can see a stuck modifier.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func scheduleRepeat() {
        repeatDelayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.beginRepeat()
        }
        repeatDelayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginRepeat() {
        repeatDelayTimer = nil
        guard repeatKey != nil else { return }
        let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
            guard let self, let repeatKey = self.repeatKey else { return }
            self.postKeyDown(repeatKey, flags: self.repeatFlags)
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRepeat() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatKey = nil
        repeatFlags = []
    }

    private func sendUnicode(_ string: String) {
        var utf16 = Array(string.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        guard !utf16.isEmpty else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)

        // Payload on keyDown only: AppKit inserts there, and a consumer that reads both
        // edges would otherwise insert the character twice.
        up.post(tap: .cghidEventTap)
    }

    // MARK: layout reverse-mapping

    /// Builds character → (keycode, modifiers) for the active layout, so we emit real key
    /// presses whenever the layout can produce the character.
    private static var layoutCache: (source: TISInputSource, table: [Character: (CGKeyCode, CGEventFlags)])?

    private static func keyCode(for character: Character) -> (CGKeyCode, CGEventFlags)? {
        guard let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }

        if let cache = layoutCache, cache.source == current {
            return cache.table[character]
        }

        let table = buildTable(for: current)
        layoutCache = (current, table)
        return table[character]
    }

    private static func buildTable(for input: TISInputSource) -> [Character: (CGKeyCode, CGEventFlags)] {
        guard let raw = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var table: [Character: (CGKeyCode, CGEventFlags)] = [:]
        let modifierStates: [(UInt32, CGEventFlags)] = [(0, []), (UInt32(shiftKey >> 8), .maskShift)]

        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }

            for keyCode in 0..<CGKeyCode(128) {
                for (modifierKey, flags) in modifierStates {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)

                    let status = UCKeyTranslate(
                        layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierKey,
                        UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState, chars.count, &length, &chars
                    )

                    guard status == noErr, length == 1,
                          let scalar = String(utf16CodeUnits: chars, count: length).first,
                          !scalar.unicodeScalars.allSatisfy({
                              $0.properties.generalCategory == .control
                          })
                    else { continue }

                    // First writer wins: lower key codes are the primary keys.
                    if table[scalar] == nil {
                        table[scalar] = (keyCode, flags)
                    }
                }
            }
        }
        return table
    }
}
