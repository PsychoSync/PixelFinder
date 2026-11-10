import AppKit

/// A wide, always-visible vertical scroller with a large knob that is easy to grab,
/// even in folders with thousands of items. Clicking the track jumps there and keeps tracking.
final class BigScroller: NSScroller {
    static let thickness: CGFloat = 22
    static let minKnobLength: CGFloat = 64
    private static let inset: CGFloat = 3

    private var isTracking = false { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { thickness }

    private var scrollView: NSScrollView? { superview as? NSScrollView }

    private var track: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }

    private var knobLength: CGFloat {
        let t = track.height
        return min(t, max(Self.minKnobLength, t * CGFloat(knobProportion)))
    }

    private var knobFrame: NSRect {
        let t = track, len = knobLength
        let y = t.minY + (t.height - len) * CGFloat(doubleValue)
        return NSRect(x: t.minX, y: y, width: t.width, height: len)
    }

    override func rect(for partCode: NSScroller.Part) -> NSRect {
        switch partCode {
        case .knob: return knobFrame
        case .knobSlot: return bounds
        default: return super.rect(for: partCode)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        guard isEnabled, knobProportion < 1 else { return }
        let alpha: CGFloat = isTracking ? 0.75 : (isHovering ? 0.6 : 0.45)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        let r = knobFrame.insetBy(dx: 1, dy: 0)
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, knobProportion < 1, let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let knob = knobFrame
        // Grab the knob where it was clicked; a click on the track centres the knob there.
        let grab = knob.contains(start) ? start.y - knob.minY : knob.height / 2
        isTracking = true
        scroll(knobTop: start.y - grab)
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            scroll(knobTop: convert(e.locationInWindow, from: nil).y - grab)
        }
        isTracking = false
    }

    private func scroll(knobTop: CGFloat) {
        guard let scrollView, let doc = scrollView.documentView else { return }
        let t = track
        let travel = t.height - knobLength
        let fraction = travel > 0 ? min(1, max(0, (knobTop - t.minY) / travel)) : 0
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let minY = -insets.top
        let maxY = max(minY, doc.frame.height - clip.bounds.height + insets.bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: (minY + (maxY - minY) * fraction).rounded()))
        scrollView.reflectScrolledClipView(clip)
    }
}
