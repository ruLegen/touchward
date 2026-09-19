import AppKit
import CoreGraphics
import Foundation
import TouchwardCore

/// Posts synthetic pointer events on behalf of the touchscreen.
///
/// Every event carries a marker in the source's user data so the rest of the app can
/// tell its own events apart from the physical mouse without touching the real input
/// path. We only ever inject; we never modify or swallow the user's own events.
final class EventSynthesizer {
    /// Arbitrary constant. Any observer can read it back from `.eventSourceUserData`.
    static let marker: Int64 = 0x5A_17C4

    private let source: CGEventSource

    // macOS recognizes a double-click from the clickState field on the second
    // down/up pair. Keep this separate from GestureRecognizer: each touch tap
    // is already classified as one left click before it reaches this layer.
    private var lastLeftClickTime: TimeInterval?
    private var lastLeftClickPoint: CGPoint?
    private var leftClickCount = 0
    /// There is no public CGEvent setting for the spatial double-click tolerance.
    /// Match the existing tap movement tolerance while using macOS for the timing.
    private let doubleClickDistance: CGFloat = 10

    /// True when the finger's motion should carry the content with it, matching how a
    /// phone behaves. Flip this if scrolling feels inverted on your setup — it is the
    /// only place polarity is decided.
    var contentFollowsFinger = true

    init?() {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        source.userData = EventSynthesizer.marker

        // Without this, every warp freezes the physical mouse for 0.25s. That would make
        // the real mouse feel broken each time the cursor returns to the main display.
        source.localEventsSuppressionInterval = 0

        self.source = source
    }

    func apply(_ event: GestureEvent) {
        switch event {
        case .leftClick(let p):
            let clickState = nextLeftClickState(at: p)
            post(.leftMouseDown, at: p, button: .left, clickState: clickState)
            post(.leftMouseUp, at: p, button: .left, clickState: clickState)

        case .rightClick(let p):
            resetClickSequence()
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)

        case .dragBegan(let p):
            resetClickSequence()
            pressLeft(at: p)

        case .dragMoved(let p):
            post(.leftMouseDragged, at: p, button: .left)

        case .dragEnded(let p):
            releaseLeft(at: p)

        case .scroll(let dx, let dy, let centre):
            resetClickSequence()
            endMagnify()
            cancelMomentum()
            // A wheel event has no target location; route it to the touched window.
            moveCursor(to: centre)
            recordScroll(dx: dx, dy: dy)
            postScroll(dx: dx, dy: dy, scrollPhase: scrollActive ? 2 : 1)
            scrollActive = true

        case .pinch(let scale, let centre):
            resetClickSequence()
            finishTouchScroll(withMomentum: false)
            cancelMomentum()
            moveCursor(to: centre)
            postMagnify(scale: scale, at: centre)

        case .sessionEnded:
            endMagnify()
            finishTouchScroll(withMomentum: true)
            lastCursorPoint = nil
        }
    }

    /// Quartz gesture events are not exposed as a public constructor. These fields follow
    /// Touch Up's event format. Keep this isolated: the host macOS version must be tested
    /// before treating it as a supported magnification path.
    private var magnifyActive = false
    private var lastMagnifyPoint: CGPoint = .zero

    private func postMagnify(scale: CGFloat, at point: CGPoint) {
        guard scale > 0, scale.isFinite else { return }
        if !magnifyActive {
            magnifyActive = true
            lastMagnifyPoint = point
            postMagnifyEvent(delta: 0, at: point, phase: 1) // began
            log("🔎 Synthetic magnify began")
        }
        lastMagnifyPoint = point
        postMagnifyEvent(delta: Double(scale - 1), at: point, phase: 2) // changed
    }

    private func endMagnify() {
        guard magnifyActive else { return }
        postMagnifyEvent(delta: 0, at: lastMagnifyPoint, phase: 4) // ended
        magnifyActive = false
        log("🔎 Synthetic magnify ended")
    }

    private func postMagnifyEvent(delta: Double, at point: CGPoint, phase: Int64) {
        guard let event = CGEvent(source: nil),
              let gestureType = CGEventType(rawValue: 29),
              let subtype = CGEventField(rawValue: 110),
              let phaseField = CGEventField(rawValue: 132),
              let magnification = CGEventField(rawValue: 113)
        else { return }

        event.type = gestureType
        event.location = point
        event.setIntegerValueField(subtype, value: 8)
        event.setIntegerValueField(phaseField, value: phase)
        event.setDoubleValueField(magnification, value: delta)
        event.post(tap: .cghidEventTap)
    }

    /// Direct press/release, bypassing gesture classification. The on-screen keyboard uses
    /// these: a key must go down the instant a finger lands and up when it leaves, with no
    /// tap-duration or movement test in between.
    func pressLeft(at point: CGPoint) {
        resetClickSequence()
        post(.leftMouseDown, at: point, button: .left)
    }

    func releaseLeft(at point: CGPoint) {
        post(.leftMouseUp, at: point, button: .left)
    }

    /// Real mouse activity takes over pointer ownership and must not be combined
    /// with a pending touchscreen double-click sequence.
    func noteRealMouseActivity() {
        resetClickSequence()
        cancelMomentum()
    }

    /// Parks the pointer without pressing anything, so a location-less event (the scroll
    /// wheel) is routed to the window the fingers are actually on.
    private var lastCursorPoint: CGPoint?

    private func moveCursor(to point: CGPoint) {
        guard lastCursorPoint != point else { return }
        lastCursorPoint = point
        post(.mouseMoved, at: point, button: .left)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton,
                      clickState: Int64? = nil) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        // Apps that gate on clickCount >= 1 (custom text views, web content) ignore a
        // click that arrives with 0. For a touchscreen double-click, both events in the
        // second down/up pair must carry clickState=2.
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            event.setIntegerValueField(.mouseEventClickState, value: clickState ?? 1)
        default:
            break
        }
        event.post(tap: .cghidEventTap)
    }

    private func nextLeftClickState(at point: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        let canContinue = lastLeftClickTime.map { now - $0 <= NSEvent.doubleClickInterval } == true
            && lastLeftClickPoint.map { distance($0, point) <= doubleClickDistance } == true

        if canContinue {
            // Preserve normal macOS triple-click semantics, but avoid unbounded growth
            // when a panel reports repeated taps without a pause.
            leftClickCount = min(leftClickCount + 1, 3)
        } else {
            leftClickCount = 1
        }

        lastLeftClickTime = now
        lastLeftClickPoint = point
        let state = Int64(leftClickCount)
        log("🖱️ synthetic left clickState=\(state) at (\(Int(point.x)),\(Int(point.y)))")
        return state
    }

    private func resetClickSequence() {
        lastLeftClickTime = nil
        lastLeftClickPoint = nil
        leftClickCount = 0
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Scroll wheel deltas are integers. Keep the fractional remainder across frames.
    private var residualX: CGFloat = 0
    private var residualY: CGFloat = 0
    private var scrollActive = false
    private var scrollHistory: [(time: TimeInterval, point: CGPoint)] = []
    private var scrollPosition = CGPoint.zero
    private var lastScrollTime: TimeInterval = 0
    private var momentumTimer: Timer?
    private var momentumVelocity = CGPoint.zero
    private var momentumStart: TimeInterval = 0
    private var momentumLastTick: TimeInterval = 0
    private var momentumHasBegun = false

    private func recordScroll(dx: CGFloat, dy: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        if !scrollActive {
            scrollPosition = .zero
            scrollHistory = [(now, .zero)]
        }
        scrollPosition.x += dx
        scrollPosition.y += dy
        scrollHistory.append((now, scrollPosition))
        scrollHistory.removeAll { $0.time < now - 0.12 }
        lastScrollTime = now
    }

    private func finishTouchScroll(withMomentum: Bool) {
        guard scrollActive else { return }
        postScroll(dx: 0, dy: 0, scrollPhase: 4, force: true)
        scrollActive = false
        defer {
            scrollHistory.removeAll()
            scrollPosition = .zero
        }

        guard withMomentum,
              let first = scrollHistory.first,
              let last = scrollHistory.last,
              scrollHistory.count >= 3,
              last.time - first.time >= 0.02,
              ProcessInfo.processInfo.systemUptime - lastScrollTime < 0.08
        else {
            residualX = 0
            residualY = 0
            return
        }

        let interval = last.time - first.time
        let vx = (last.point.x - first.point.x) / interval
        let vy = (last.point.y - first.point.y) / interval
        let speed = hypot(vx, vy)
        guard speed.isFinite, speed > 100 else {
            residualX = 0
            residualY = 0
            return
        }
        let limit: CGFloat = 3000
        let ratio = min(1, limit / speed)
        momentumVelocity = CGPoint(x: vx * ratio, y: vy * ratio)
        momentumStart = ProcessInfo.processInfo.systemUptime
        momentumLastTick = momentumStart
        momentumHasBegun = false

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceMomentum()
        }
        RunLoop.main.add(timer, forMode: .common)
        momentumTimer = timer
    }

    private func advanceMomentum() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - momentumLastTick, 0), 0.05)
        momentumLastTick = now
        let decay = pow(0.92, dt * 60)
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        if now - momentumStart >= 1.2 || hypot(momentumVelocity.x, momentumVelocity.y) < 40 {
            cancelMomentum()
            return
        }
        postScroll(dx: momentumVelocity.x * dt, dy: momentumVelocity.y * dt,
                   momentumPhase: momentumHasBegun ? 2 : 1)
        momentumHasBegun = true
    }

    /// A new touch, real mouse activity, disconnect, or shutdown ends momentum.
    func cancelMomentum() {
        guard let timer = momentumTimer else { return }
        timer.invalidate()
        momentumTimer = nil
        if momentumHasBegun {
            postScroll(dx: 0, dy: 0, momentumPhase: 3, force: true)
        }
        momentumHasBegun = false
        momentumVelocity = .zero
        residualX = 0
        residualY = 0
    }

    func stop() {
        finishTouchScroll(withMomentum: false)
        cancelMomentum()
        endMagnify()
    }

    private func postScroll(dx: CGFloat, dy: CGFloat, scrollPhase: Int64 = 0,
                            momentumPhase: Int64 = 0, force: Bool = false) {
        residualX += dx
        residualY += dy
        guard residualX.isFinite, residualY.isFinite else {
            residualX = 0
            residualY = 0
            return
        }

        let stepX = residualX.rounded(.towardZero)
        let stepY = residualY.rounded(.towardZero)
        guard force || stepX != 0 || stepY != 0 else { return }
        residualX -= stepX
        residualY -= stepY

        let sign: Int32 = contentFollowsFinger ? 1 : -1
        let maxDelta = CGFloat(Int32.max)
        let x = Int32(min(max(stepX, -maxDelta), maxDelta))
        let y = Int32(min(max(stepY, -maxDelta), maxDelta))
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel, wheelCount: 2,
                                  wheel1: sign * y, wheel2: sign * x, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.post(tap: .cghidEventTap)
    }
}
