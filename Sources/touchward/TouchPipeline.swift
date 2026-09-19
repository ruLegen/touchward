import CoreGraphics
import Foundation
import TouchwardCore

/// Wires the pure core to the system layer: bytes in, pointer events out.
final class TouchPipeline {
    private var mapper: CoordinateMapper
    private var recognizer = GestureRecognizer()
    private var palmFilter: PalmFilter
    private let synthesizer: EventSynthesizer
    private let cursorReturn: CursorReturn
    private var mainCentre: CGPoint
    private var shouldReturnCursor: Bool
    private var heartbeat: Timer?
    private var lastFrameAt: TimeInterval = 0
    /// HID is change-driven, so a resting finger sends no reports. This is only a
    /// last-resort release for a dead stream; ordinary lifts still use the zero-contact frame.
    private let keyboardStaleTimeout: TimeInterval = 5.0

    /// Global-coordinate rect of the on-screen keyboard while it is visible.
    /// Touches inside it bypass gesture classification entirely.
    var directTouchRegion: (() -> CGRect?)?
    /// Presses the key under a global point; returns true when a key was actually hit.
    /// Injected rather than synthesized as a click so typing never moves the pointer.
    var pressKey: ((UInt8, CGPoint) -> Bool)?
    /// Moves a contact to a new key for slide typing.
    var moveKey: ((UInt8, CGPoint) -> Bool)?
    /// Releases the key owned by one contact ID.
    var releaseKey: ((UInt8) -> Void)?
    /// The keyboard can have one independently held key per HID contact.
    private var directPresses: [UInt8: CGPoint] = [:]
    private var keyboardTouchActive = false
    /// Lets a same-frame Shift contact be processed before character contacts.
    var isModifierKey: ((CGPoint) -> Bool)?

    private let profile: DeviceProfile

    init?(profile: DeviceProfile,
          touchDisplay: CGDirectDisplayID,
          mainDisplay: CGDirectDisplayID,
          cursorReturn: CursorReturn) {
        guard let synthesizer = EventSynthesizer() else { return nil }
        self.synthesizer = synthesizer
        self.cursorReturn = cursorReturn
        self.profile = profile
        // Ranges come from the device's descriptor, so a panel with a different resolution
        // maps correctly without anyone editing a constant.
        self.mapper = CoordinateMapper(logicalMaxX: profile.logicalMaxX,
                                       logicalMaxY: profile.logicalMaxY,
                                       displayBounds: CGDisplayBounds(touchDisplay))
        self.palmFilter = PalmFilter(logicalMax: profile.logicalMax)
        self.mainCentre = DisplayRegistry.centre(of: mainDisplay)
        self.shouldReturnCursor = touchDisplay != mainDisplay
    }

    /// Drives the clock-dependent half of the recognizer: long press on a still finger, and
    /// the backstop that releases a drag whose report stream died.
    func start() {
        heartbeat?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Clock.now()
            if self.keyboardTouchActive,
               now - self.lastFrameAt > self.keyboardStaleTimeout {
                log("⚠️ Keyboard touch stream timed out — releasing held keys.")
                self.finishKeyboardTouch()
            }
            guard self.recognizer.hasActiveGesture else { return }
            self.emit(self.recognizer.tick(at: now))
        }
        // Common mode: in default mode the heartbeat stalls while a control in our own
        // keyboard panel is tracking — exactly when a held button most needs the backstop.
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Re-reads geometry after a resolution change or a display being moved.
    func refreshGeometry(touchDisplay: CGDirectDisplayID, mainDisplay: CGDirectDisplayID) {
        mapper = CoordinateMapper(logicalMaxX: profile.logicalMaxX,
                                  logicalMaxY: profile.logicalMaxY,
                                  displayBounds: CGDisplayBounds(touchDisplay),
                                  calibration: mapper.calibration)
        mainCentre = DisplayRegistry.centre(of: mainDisplay)
        shouldReturnCursor = touchDisplay != mainDisplay
        if !shouldReturnCursor { cursorReturn.cancelPendingReturn() }
    }

    var calibration: Calibration {
        get { mapper.calibration }
        set { mapper.calibration = newValue }
    }

    private var framesHandled = 0
    private var pointerMoves = 0
    private var hasSeenMultitouch = false
    private var scrollsEmitted = 0

    /// True while the touchscreen is unusable — unplugged, asleep, or its monitor switched
    /// off. Reports keep arriving in that last case, because plenty of panels keep their
    /// USB side powered with the screen dark, and acting on them would drive the pointer to
    /// coordinates on a display nobody can see.
    private(set) var isSuspended = false

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        // Whatever was under a finger when the screen went away has to be let go, or the
        // button stays logically held for the rest of the session.
        if suspended { releaseEverything() }
    }

    func handle(_ raw: TouchFrame) {
        guard !isSuspended else { return }
        lastFrameAt = Clock.now()

        let frame = palmFilter.reject(raw)

        framesHandled += 1
        if framesHandled <= 12, let first = frame.contacts.first {
            let mapped = mapper.globalPoint(x: first.x, y: first.y)
            log("   → map (\(first.x),\(first.y)) ⇒ (\(Int(mapped.x)),\(Int(mapped.y)))")
        }

        // Whether the panel reports a second finger at all decides whether scrolling can
        // work; say so once rather than leaving the user to guess why nothing scrolls.
        if frame.contacts.count >= 2, !hasSeenMultitouch {
            hasSeenMultitouch = true
            log("✅ The panel reports \(frame.contacts.count) contacts — two-finger gestures are available.")
        }

        // A live touch means the user is not on the mouse — drop any queued cursor return.
        if !frame.contacts.isEmpty {
            cursorReturn.cancelPendingReturn()
            synthesizer.cancelMomentum()
        }

        let mapped = mapper.map(frame)

        // Keys must respond to the finger landing and leaving, full stop. Routing them
        // through the pointer recognizer meant a 0.4s press typed nothing (past the tap
        // window, short of the long press) and a 0.7s press fired a right click onto the
        // key — the single worst defect in the keyboard.
        if handleDirectTouch(mapped) { return }

        emit(recognizer.handle(mapped))
    }

    /// Returns true when the frame was consumed as a key press.
    private func handleDirectTouch(_ frame: MappedFrame) -> Bool {
        guard let region = directTouchRegion?() else {
            finishKeyboardTouch()
            return false
        }

        if !keyboardTouchActive {
            // Do not steal a pointer gesture that is already in flight. A keyboard
            // capture starts only when the complete first frame is on the panel.
            guard !recognizer.hasActiveGesture,
                  !frame.contacts.isEmpty,
                  frame.contacts.allSatisfy({ region.contains($0.point) }) else { return false }
            keyboardTouchActive = true
            log("⌨︎ Keyboard capture began for (frame.contacts.count) contact(s).")
        }

        if frame.contacts.isEmpty {
            finishKeyboardTouch()
            return true
        }

        let currentIDs = Set(frame.contacts.map(\.id))
        let removedIDs = directPresses.keys.filter { !currentIDs.contains($0) }
        for id in removedIDs {
            log("⌨︎ Keyboard contact up id=\(id)")
            releaseKey?(id)
            directPresses.removeValue(forKey: id)
        }

        // Leaving the panel releases that key, but the keyboard capture remains active
        // until all contacts are gone so a finger cannot fall through to the desktop.
        for contact in frame.contacts where !region.contains(contact.point) {
            if directPresses.removeValue(forKey: contact.id) != nil {
                log("⌨︎ Keyboard contact left panel id=\(contact.id)")
                releaseKey?(contact.id)
            }
        }

        let newContacts = frame.contacts
            .filter { region.contains($0.point) && directPresses[$0.id] == nil }
            .sorted { lhs, rhs in
                let leftModifier = isModifierKey?(lhs.point) ?? false
                let rightModifier = isModifierKey?(rhs.point) ?? false
                return leftModifier && !rightModifier
            }

        for contact in newContacts {
            log("⌨︎ Keyboard contact down id=\(contact.id)")
            _ = pressKey?(contact.id, contact.point)
            // Keep contacts that landed between keys so slide typing can enter a key
            // when the finger moves onto it later.
            directPresses[contact.id] = contact.point
        }

        for contact in frame.contacts where region.contains(contact.point) {
            guard let previous = directPresses[contact.id] else { continue }
            guard previous != contact.point else { continue }
            _ = moveKey?(contact.id, contact.point)
            directPresses[contact.id] = contact.point
        }

        return true
    }

    private func finishKeyboardTouch() {
        let wasActive = keyboardTouchActive || !directPresses.isEmpty
        if wasActive { log("⌨︎ Keyboard capture ended; releasing (directPresses.count) contact(s).") }
        let ids = Array(directPresses.keys)
        for id in ids { releaseKey?(id) }
        directPresses.removeAll()
        keyboardTouchActive = false
        if wasActive && shouldReturnCursor {
            cursorReturn.scheduleReturn(to: mainCentre)
        }
    }

    /// Closes out anything in flight. Called on quit, on unplug, and on sleep, so a pointer
    /// button is never left logically pressed for the rest of the login session.
    func releaseEverything() {
        // Keys may still be under several fingers; let them all go on quit and unplug.
        finishKeyboardTouch()
        emit(recognizer.forceRelease())
        synthesizer.cancelMomentum()
    }

    func cancelMomentum() {
        synthesizer.cancelMomentum()
    }

    func releaseKeyboardTouches() {
        finishKeyboardTouch()
    }

    func noteRealMouseActivity() {
        synthesizer.noteRealMouseActivity()
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        releaseEverything()
        synthesizer.stop()
    }

    private func emit(_ events: [GestureEvent]) {
        for event in events {
            if case .scroll(let dx, let dy, let at) = event {
                scrollsEmitted += 1
                if scrollsEmitted <= 6 {
                    log("   ↕︎ scroll \(Int(dx)),\(Int(dy)) at (\(Int(at.x)),\(Int(at.y)))")
                }
            }

            synthesizer.apply(event)
            if case .sessionEnded = event, shouldReturnCursor {
                cursorReturn.scheduleReturn(to: mainCentre)
            }
        }
    }
}
