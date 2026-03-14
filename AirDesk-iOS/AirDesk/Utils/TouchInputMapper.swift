import UIKit

class TouchInputMapper {

    private weak var client: WebSocketClient?
    private var activeDisplayIndex: Int = 0
    private var monitor: MonitorInfo?
    private var isDragging = false

    init(client: WebSocketClient) {
        self.client = client
    }

    func configure(displayIndex: Int, monitor: MonitorInfo) {
        self.activeDisplayIndex = displayIndex
        self.monitor = monitor
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
        isDragging = false
        let n = normalizePoint(point, viewSize: viewSize)
        send(MouseMessage(x: Float(n.x), y: Float(n.y), action: "dragEnd", displayIndex: activeDisplayIndex))
    }

    /// Returns true if the point is within the rendered screen content (not in letterbox/pillarbox bars).
    func isInContentArea(_ point: CGPoint, viewSize: CGSize) -> Bool {
        let rect = contentRect(viewSize: viewSize)
        return rect.contains(point)
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint, in viewSize: CGSize) {
        let n = normalizePoint(point, viewSize: viewSize)
        // Negate deltaY: iOS Y increases downward, macOS scroll positive = up
        // Multiply for comfortable scroll speed
        send(MouseMessage(
            x: Float(n.x), y: Float(n.y),
            action: "scroll",
            displayIndex: activeDisplayIndex,
            scrollDeltaX: Float(deltaX * 0.4),
            scrollDeltaY: Float(-deltaY * 0.4)   // negated: iOS Y↓ vs Mac scroll +up
        ))
    }

    /// The rect within the view where the Mac screen is actually rendered.
    private func contentRect(viewSize: CGSize) -> CGRect {
        guard let monitor else { return CGRect(origin: .zero, size: viewSize) }
        let monitorAspect = CGFloat(monitor.width) / CGFloat(monitor.height)
        let viewAspect = viewSize.width / viewSize.height

        if viewAspect > monitorAspect {
            let contentHeight = viewSize.height
            let contentWidth = contentHeight * monitorAspect
            let offsetX = (viewSize.width - contentWidth) / 2
            return CGRect(x: offsetX, y: 0, width: contentWidth, height: contentHeight)
        } else {
            let contentWidth = viewSize.width
            let contentHeight = contentWidth / monitorAspect
            let offsetY = (viewSize.height - contentHeight) / 2
            return CGRect(x: 0, y: offsetY, width: contentWidth, height: contentHeight)
        }
    }

    /// Maps a touch in the view to normalized Mac coordinates (0–1),
    /// correctly accounting for letterbox/pillarbox based on monitor aspect ratio.
    private func normalizePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let rect = contentRect(viewSize: viewSize)
        return CGPoint(
            x: max(0, min(1, (point.x - rect.origin.x) / rect.width)),
            y: max(0, min(1, (point.y - rect.origin.y) / rect.height))
        )
    }

    private func send(_ msg: MouseMessage) {
        client?.sendMouseMessage(msg)
    }
}
