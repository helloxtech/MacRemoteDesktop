import UIKit

final class VNCTouchInputMapper {
    private weak var session: VNCSessionController?
    private var desktopSize: CGSize = .zero
    private var displayRect: CGRect = .zero
    private var activeScreenFrame: CGRect?
    private var isDragging = false
    private var scrollRemainder: CGPoint = .zero

    init(session: VNCSessionController?) {
        self.session = session
    }

    func updateSession(_ session: VNCSessionController?) {
        self.session = session
    }

    func updateDesktopSize(_ size: CGSize) {
        desktopSize = size
    }

    func setDisplayRect(_ rect: CGRect) {
        displayRect = rect
    }

    func setActiveScreenFrame(_ frame: CGRect?) {
        activeScreenFrame = frame
    }

    func handleMove(at point: CGPoint, in viewSize: CGSize) {
        session?.movePointer(to: normalizePoint(point, viewSize: viewSize))
    }

    func handleTap(at point: CGPoint, in viewSize: CGSize) {
        session?.leftClick(at: normalizePoint(point, viewSize: viewSize))
    }

    func handleDoubleTap(at point: CGPoint, in viewSize: CGSize) {
        session?.doubleClick(at: normalizePoint(point, viewSize: viewSize))
    }

    func handleLongPress(at point: CGPoint, in viewSize: CGSize) {
        session?.rightClick(at: normalizePoint(point, viewSize: viewSize))
    }

    func handleDragBegan(at point: CGPoint, in viewSize: CGSize) {
        isDragging = true
        session?.dragBegan(at: normalizePoint(point, viewSize: viewSize))
    }

    func handleDragChanged(to point: CGPoint, in viewSize: CGSize) {
        guard isDragging else { return }
        session?.dragChanged(to: normalizePoint(point, viewSize: viewSize))
    }

    func handleDragEnded(at point: CGPoint, in viewSize: CGSize) {
        guard isDragging else { return }
        isDragging = false
        session?.dragEnded(at: normalizePoint(point, viewSize: viewSize))
    }

    func beginScroll() {
        scrollRemainder = .zero
    }

    func endScroll() {
        scrollRemainder = .zero
    }

    func isInContentArea(_ point: CGPoint, viewSize: CGSize) -> Bool {
        contentRect(viewSize: viewSize).contains(point)
    }

    func handleScroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint, in viewSize: CGSize) {
        let normalizedPoint = normalizePoint(point, viewSize: viewSize)
        let stepSize: CGFloat = 26

        let accumulatedX = scrollRemainder.x + deltaX
        let accumulatedY = scrollRemainder.y + deltaY
        let wholeX = truncatingStepCount(from: accumulatedX, stepSize: stepSize)
        let wholeY = truncatingStepCount(from: accumulatedY, stepSize: stepSize)

        scrollRemainder = CGPoint(
            x: accumulatedX - CGFloat(wholeX) * stepSize,
            y: accumulatedY - CGFloat(wholeY) * stepSize
        )

        guard wholeX != 0 || wholeY != 0 else { return }
        session?.scroll(horizontalSteps: wholeX, verticalSteps: wholeY, at: normalizedPoint)
    }

    private func truncatingStepCount(from delta: CGFloat, stepSize: CGFloat) -> Int {
        guard stepSize > 0 else { return 0 }
        if delta > 0 {
            return Int(floor(delta / stepSize))
        }
        if delta < 0 {
            return Int(ceil(delta / stepSize))
        }
        return 0
    }

    private func contentRect(viewSize: CGSize) -> CGRect {
        if displayRect.width > 0, displayRect.height > 0 {
            return displayRect
        }
        return CGRect(origin: .zero, size: viewSize)
    }

    private func normalizePoint(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let rect = contentRect(viewSize: viewSize)
        guard rect.width > 0, rect.height > 0 else { return .zero }

        let localX = max(0, min(1, (point.x - rect.origin.x) / rect.width))
        let localY = max(0, min(1, (point.y - rect.origin.y) / rect.height))

        guard let activeScreenFrame,
              desktopSize.width > 0,
              desktopSize.height > 0 else {
            return CGPoint(x: localX, y: localY)
        }

        let globalX = (activeScreenFrame.minX + activeScreenFrame.width * localX) / desktopSize.width
        let globalY = (activeScreenFrame.minY + activeScreenFrame.height * localY) / desktopSize.height

        return CGPoint(
            x: max(0, min(1, globalX)),
            y: max(0, min(1, globalY))
        )
    }
}
