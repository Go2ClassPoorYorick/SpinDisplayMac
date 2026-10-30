import AppKit

enum NSScreenLookup {
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// Converts a display-local, top-left-origin rectangle to global AppKit coordinates (bottom-left origin).
    static func globalFrame(_ rect: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a global AppKit frame back to display-local, top-left-origin coordinates.
    static func localRect(_ frame: NSRect, on screen: NSScreen) -> CGRect {
        CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// A click-through-free, borderless frame that shows the projected square and circle on screen.
/// Drag it to move the capture area; scroll over it to resize. It is excluded from the capture.
final class CaptureOverlay {
    /// Reports the new display-local rectangle after a move or resize.
    var onChange: ((CGRect) -> Void)?

    private let window: OverlayWindow
    private var screen: NSScreen

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        window = OverlayWindow(contentRect: NSScreenLookup.globalFrame(rect, on: screen))
        window.sharingType = .none
        window.onMoveOrResize = { [weak self] frame in
            guard let self else { return }
            self.onChange?(NSScreenLookup.localRect(frame, on: self.screen))
        }
        window.constrainingScreen = screen
        window.orderFrontRegardless()
    }

    func update(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        window.constrainingScreen = screen
        let frame = NSScreenLookup.globalFrame(rect, on: screen)
        if window.frame != frame { window.setFrame(frame, display: true) }
    }

    func close() {
        window.orderOut(nil)
    }
}

private final class OverlayWindow: NSWindow {
    var onMoveOrResize: ((NSRect) -> Void)?
    var constrainingScreen: NSScreen?
    private var dragOffset: NSPoint?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = OverlayView()
    }

    override func mouseDown(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        dragOffset = NSPoint(x: location.x - frame.minX, y: location.y - frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOffset else { return }
        let location = NSEvent.mouseLocation
        var newFrame = frame
        newFrame.origin = NSPoint(x: location.x - dragOffset.x, y: location.y - dragOffset.y)
        apply(newFrame)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    /// Scrolling resizes around the center.
    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let side = max(120, frame.width - delta * 2)
        apply(NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side))
    }

    private func apply(_ proposed: NSRect) {
        var newFrame = proposed
        if let bounds = constrainingScreen?.frame {
            let side = min(newFrame.width, bounds.width, bounds.height)
            newFrame.size = NSSize(width: side, height: side)
            newFrame.origin.x = min(max(newFrame.minX, bounds.minX), bounds.maxX - side)
            newFrame.origin.y = min(max(newFrame.minY, bounds.minY), bounds.maxY - side)
        }
        setFrame(newFrame, display: true)
        onMoveOrResize?(newFrame)
    }
}

private final class OverlayView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        NSColor.systemOrange.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: inset).fill()

        let square = NSBezierPath(rect: inset)
        square.lineWidth = 3
        square.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.systemOrange.setStroke()
        square.stroke()

        let circle = NSBezierPath(ovalIn: inset)
        circle.lineWidth = 2
        NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
        circle.stroke()

        let label = "SpinDisplay — drag to move, scroll to resize" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.85)
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 8), withAttributes: attributes)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
