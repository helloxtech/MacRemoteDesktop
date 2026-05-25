import UIKit
import AirDeskProtocol

class TouchInputMapper {

    private var client: WebSocketClient?
    private var activeDisplayIndex: Int = 0
    private var monitor: MonitorInfo?
    private var viewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var displayRect: CGRect = .zero
    private var isDragging = false
    private var scrollRemainder: CGPoint = .zero

    init(client: WebSocketClient) {
        self.client = client
    }

    func updateClient(_ client: WebSocketClient) {
        self.client = client
    }

    func configure(displayIndex: Int, monitor: MonitorInfo) {
        self.activeDisplayIndex = displayIndex
        self.monitor = monitor
    }

    func setViewport(_ viewport: CGRect) {
        self.viewport = viewport
    }

    func setDisplayRect(_ rect: CGRect) {
        self.displayRect = rect
    }

    func handleMove(at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "move", displayIndex: activeDisplayIndex))
    }

    func handleTap(at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "click", displayIndex: activeDisplayIndex))
    }

    func handleDoubleTap(at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "doubleClick", displayIndex: activeDisplayIndex))
    }

    func handleLongPress(at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "rightClick", displayIndex: activeDisplayIndex))
    }

    func handleDragBegan(at point: CGPoint, in viewSize: CGSize) {
        isDragging = true
        let n = normalizePoint(point, viewSize: viewSize)
        // mouseDown to begin the drag
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "drag", displayIndex: activeDisplayIndex))
    }

    func handleDragChanged(to point: CGPoint, in viewSize: CGSize) {
        guard isDragging else { return }
        let n = normalizePoint(point, viewSize: viewSize)
        // Use "mouseDrag" so InputInjector sends leftMouseDragged (not mouseMoved)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "mouseDrag", displayIndex: activeDisplayIndex))
    }

    func handleDragEnded(at point: CGPoint, in viewSize: CGSize) {
        guard isDragging else { return }
        isDragging = false
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "dragEnd", displayIndex: activeDisplayIndex))
    }

    func beginScroll() {
        scrollRemainder = .zero
    }

    func endScroll() {
        scrollRemainder = .zero
    }

    /// Returns true if the point is within the rendered screen content (not in letterbox/pillarbox bars).
    func isInContentArea(_ point: CGPoint, viewSize: CGSize) -> Bool {
        let rect = contentRect(viewSize: viewSize)
        return rect.contains(point)
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        let sensitivity: CGFloat = 1.8
        let accumulatedX = deltaX * sensitivity + scrollRemainder.x
        let accumulatedY = deltaY * sensitivity + scrollRemainder.y
        let wholeX = accumulatedX >= 0 ? floor(accumulatedX) : ceil(accumulatedX)
        let wholeY = accumulatedY >= 0 ? floor(accumulatedY) : ceil(accumulatedY)
        scrollRemainder = CGPoint(x: accumulatedX - wholeX, y: accumulatedY - wholeY)
        guard wholeX != 0 || wholeY != 0 else { return }
        // Natural scrolling: same direction as iOS — swipe up = content moves up
        send(MouseMessage(
            x: Float(n.x), y: Float(n.y),
            action: "scroll",
            displayIndex: activeDisplayIndex,
            scrollDeltaX: Float(wholeX),
            scrollDeltaY: Float(wholeY)
        ))
    }

    /// The rect within the view where the Mac screen is actually rendered.
    private func contentRect(viewSize: CGSize) -> CGRect {
        if displayRect.width > 0, displayRect.height > 0 {
            return displayRect
        }
        return CGRect(origin: .zero, size: viewSize)
    }

    /// Maps a touch in the view to normalized Mac coordinates (0–1),
    /// correctly accounting for letterbox/pillarbox based on monitor aspect ratio.
    private func normalizePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let rect = contentRect(viewSize: viewSize)
        let localX = max(0, min(1, (point.x - rect.origin.x) / rect.width))
        let localY = max(0, min(1, (point.y - rect.origin.y) / rect.height))
        return CGPoint(
            x: max(0, min(1, viewport.origin.x + localX * viewport.width)),
            y: max(0, min(1, viewport.origin.y + localY * viewport.height))
        )
    }

    private func send(_ msg: MouseMessage) {
        client?.sendMouseMessage(msg)
    }
}
