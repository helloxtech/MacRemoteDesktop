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
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(x: Float(normalized.x), y: Float(normalized.y), action: "click", displayIndex: activeDisplayIndex)
        client?.sendMouseMessage(msg)
    }

    func handleLongPress(at point: CGPoint, in viewSize: CGSize) {
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(x: Float(normalized.x), y: Float(normalized.y), action: "rightClick", displayIndex: activeDisplayIndex)
        client?.sendMouseMessage(msg)
    }

    func handleDragBegan(at point: CGPoint, in viewSize: CGSize) {
        isDragging = true
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(x: Float(normalized.x), y: Float(normalized.y), action: "drag", displayIndex: activeDisplayIndex)
        client?.sendMouseMessage(msg)
    }

    func handleDragChanged(to point: CGPoint, in viewSize: CGSize) {
        guard isDragging else { return }
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(x: Float(normalized.x), y: Float(normalized.y), action: "move", displayIndex: activeDisplayIndex)
        client?.sendMouseMessage(msg)
    }

    func handleDragEnded(at point: CGPoint, in viewSize: CGSize) {
        isDragging = false
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(x: Float(normalized.x), y: Float(normalized.y), action: "dragEnd", displayIndex: activeDisplayIndex)
        client?.sendMouseMessage(msg)
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint, in viewSize: CGSize) {
        let normalized = normalizePoint(point, viewSize: viewSize)
        let msg = MouseMessage(
            x: Float(normalized.x), y: Float(normalized.y),
            action: "scroll",
            displayIndex: activeDisplayIndex,
            scrollDeltaX: Float(deltaX * 3),
            scrollDeltaY: Float(deltaY * 3)
        )
        client?.sendMouseMessage(msg)
    }

    /// Converts a touch point in the view to normalized Mac coordinates (0.0-1.0),
    /// accounting for letterboxing based on the monitor's aspect ratio.
    private func normalizePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        guard let monitor = monitor else {
            return CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        }

        let monitorAspect = CGFloat(monitor.width) / CGFloat(monitor.height)
        let viewAspect = viewSize.width / viewSize.height

        let (contentWidth, contentHeight, offsetX, offsetY): (CGFloat, CGFloat, CGFloat, CGFloat)
        if viewAspect > monitorAspect {
            // Pillarbox — black bars on sides
            contentHeight = viewSize.height
            contentWidth = contentHeight * monitorAspect
            offsetX = (viewSize.width - contentWidth) / 2
            offsetY = 0
        } else {
            // Letterbox — black bars on top/bottom
            contentWidth = viewSize.width
            contentHeight = contentWidth / monitorAspect
            offsetX = 0
            offsetY = (viewSize.height - contentHeight) / 2
        }

        let relX = (point.x - offsetX) / contentWidth
        let relY = (point.y - offsetY) / contentHeight
        return CGPoint(
            x: max(0, min(1, relX)),
            y: max(0, min(1, relY))
        )
    }
}
