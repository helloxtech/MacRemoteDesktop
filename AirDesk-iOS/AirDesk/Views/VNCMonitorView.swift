import SwiftUI
import UIKit

struct VNCMonitorView: UIViewControllerRepresentable {
    let remoteImage: CGImage?
    let remoteSize: CGSize
    let desktopSize: CGSize
    let renderRevision: Int
    let selectedDisplay: VNCDisplayInfo?
    let imageCoversSelectedDisplay: Bool
    let controlMode: RemoteControlMode
    let inputEnabled: Bool
    let session: VNCSessionController?
    @EnvironmentObject var appState: AppState

    func makeUIViewController(context: Context) -> VNCMonitorViewController {
        let vc = VNCMonitorViewController()
        vc.setSession(session)
        vc.setRemoteSize(remoteSize)
        vc.setDesktopSize(desktopSize)
        vc.setSelectedDisplay(selectedDisplay)
        vc.setImageCoversSelectedDisplay(imageCoversSelectedDisplay)
        vc.setControlMode(controlMode)
        vc.setInputEnabled(inputEnabled)
        vc.updateImage(remoteImage)
        appState.activeVNCMonitorVC = vc
        return vc
    }

    func updateUIViewController(_ vc: VNCMonitorViewController, context: Context) {
        vc.setSession(session)
        vc.setRemoteSize(remoteSize)
        vc.setDesktopSize(desktopSize)
        vc.setSelectedDisplay(selectedDisplay)
        vc.setImageCoversSelectedDisplay(imageCoversSelectedDisplay)
        vc.setControlMode(controlMode)
        vc.setInputEnabled(inputEnabled)
        vc.updateImage(remoteImage)
        appState.activeVNCMonitorVC = vc
    }
}

final class VNCMonitorViewController: UIViewController, UIGestureRecognizerDelegate {
    private let canvasView = UIView()
    private var inputMapper = VNCTouchInputMapper(session: nil)
    private var session: VNCSessionController?
    private var remoteSize: CGSize = .zero
    private var desktopSize: CGSize = .zero
    private var selectedDisplay: VNCDisplayInfo?
    private var imageCoversSelectedDisplay = false
    private var scale: CGFloat = 1.0
    private var canvasOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1.0
    private var isPinching = false
    private var singleFingerScrollActive = false
    private var twoFingerScrollActive = false
    private var controlMode: RemoteControlMode = .touch
    private var inputEnabled = true
    private var hasInitializedViewport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        canvasView.backgroundColor = .black
        canvasView.layer.contentsGravity = .resize
        canvasView.layer.magnificationFilter = .linear
        canvasView.layer.minificationFilter = .trilinear
        view.addSubview(canvasView)
        setupGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if !hasInitializedViewport {
            canvasOffset = .zero
            scale = 1.0
            hasInitializedViewport = true
        }
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    func setSession(_ session: VNCSessionController?) {
        self.session = session
        inputMapper.updateSession(session)
    }

    func setRemoteSize(_ size: CGSize) {
        remoteSize = size
        updateContentsRect()
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    func setDesktopSize(_ size: CGSize) {
        desktopSize = size
        inputMapper.updateDesktopSize(size)
    }

    func setSelectedDisplay(_ display: VNCDisplayInfo?) {
        let selectionChanged = selectedDisplay != display
        selectedDisplay = display
        inputMapper.setActiveScreenFrame(display?.frame)
        updateContentsRect()

        if selectionChanged {
            canvasOffset = .zero
            scale = 1.0
        }

        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    func setImageCoversSelectedDisplay(_ coversSelectedDisplay: Bool) {
        guard imageCoversSelectedDisplay != coversSelectedDisplay else { return }
        imageCoversSelectedDisplay = coversSelectedDisplay
        updateContentsRect()
    }

    func setControlMode(_ mode: RemoteControlMode) {
        guard controlMode != mode else { return }
        controlMode = mode
        singleFingerScrollActive = false
        twoFingerScrollActive = false
        inputMapper.endScroll()
    }

    func setInputEnabled(_ enabled: Bool) {
        if !enabled {
            singleFingerScrollActive = false
            twoFingerScrollActive = false
            inputMapper.endScroll()
        }
        inputEnabled = enabled
    }

    func updateImage(_ image: CGImage?) {
        guard let image else { return }
        canvasView.layer.contents = image
        canvasView.layer.contentsScale = UIScreen.main.scale
        updateContentsRect()
    }

    func displayFrame(
        _ image: CGImage,
        remoteSize: CGSize,
        desktopSize: CGSize,
        imageCoversSelectedDisplay: Bool
    ) {
        self.remoteSize = remoteSize
        self.desktopSize = desktopSize
        inputMapper.updateDesktopSize(desktopSize)
        self.imageCoversSelectedDisplay = imageCoversSelectedDisplay
        canvasView.layer.contents = image
        canvasView.layer.contentsScale = UIScreen.main.scale
        updateContentsRect()

        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    func toggleZoom() {
        if scale > 1.1 {
            zoomCanvas(to: 1.0, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        } else {
            zoomCanvas(to: 2.0, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        }
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        view.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        view.addGestureRecognizer(drag)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        scroll.require(toFail: pinch)
        view.addGestureRecognizer(scroll)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer {
            return false
        }
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return true
        }
        return false
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled else { return }
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        inputMapper.handleTap(at: point, in: view.bounds.size)
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled else { return }
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        inputMapper.handleDoubleTap(at: point, in: view.bounds.size)
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled else { return }
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        inputMapper.handleLongPress(at: point, in: view.bounds.size)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        guard inputEnabled else { return }
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        inputMapper.handleLongPress(at: point, in: view.bounds.size)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleDrag(_ gr: UIPanGestureRecognizer) {
        switch controlMode {
        case .touch:
            handleViewportPan(gr)
        case .scroll:
            handleSingleFingerScroll(gr)
        }
    }

    private func handleSingleFingerScroll(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else {
            singleFingerScrollActive = false
            inputMapper.endScroll()
            return
        }

        switch gr.state {
        case .began:
            let point = gr.location(in: view)
            guard isInContent(point) else {
                singleFingerScrollActive = false
                return
            }
            singleFingerScrollActive = true
            inputMapper.beginScroll()
            inputMapper.handleMove(at: point, in: view.bounds.size)
            gr.setTranslation(.zero, in: view)
        case .changed:
            guard singleFingerScrollActive, !isPinching else { return }
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)
            let point = gr.location(in: view)
            inputMapper.handleScroll(deltaX: delta.x, deltaY: delta.y, at: point, in: view.bounds.size)
        case .ended, .cancelled, .failed:
            singleFingerScrollActive = false
            inputMapper.endScroll()
        default:
            break
        }
    }

    private func handleViewportPan(_ gr: UIPanGestureRecognizer) {
        guard !isPinching else { return }
        switch gr.state {
        case .began:
            gr.setTranslation(.zero, in: view)
        case .changed:
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)
            panCanvas(by: delta)
        default:
            break
        }
    }

    @objc private func handleScroll(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else {
            twoFingerScrollActive = false
            inputMapper.endScroll()
            return
        }

        switch gr.state {
        case .began:
            let point = gr.location(in: view)
            guard isInContent(point) else {
                twoFingerScrollActive = false
                return
            }
            twoFingerScrollActive = true
            inputMapper.beginScroll()
            inputMapper.handleMove(at: point, in: view.bounds.size)
            gr.setTranslation(.zero, in: view)
        case .changed:
            guard twoFingerScrollActive, !isPinching else { return }
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)
            let point = gr.location(in: view)
            inputMapper.handleScroll(deltaX: delta.x, deltaY: delta.y, at: point, in: view.bounds.size)
        case .ended, .cancelled, .failed:
            twoFingerScrollActive = false
            inputMapper.endScroll()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            isPinching = true
            pinchStartScale = scale
        case .changed:
            let target = max(0.7, min(5.0, pinchStartScale * gr.scale))
            zoomCanvas(to: target, around: gr.location(in: view))
        case .ended, .cancelled:
            isPinching = false
            if abs(scale - 1.0) < 0.015 {
                zoomCanvas(to: 1.0, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            }
        default:
            break
        }
    }

    private func isInContent(_ point: CGPoint) -> Bool {
        inputMapper.isInContentArea(point, viewSize: view.bounds.size)
    }

    private func applyPresentation(viewSize: CGSize) {
        let displayRect = canvasDisplayRect(for: viewSize)
        canvasView.frame = displayRect
        inputMapper.setDisplayRect(displayRect)
    }

    private func canvasDisplayRect(for viewSize: CGSize) -> CGRect {
        let base = aspectFitRect(for: viewSize)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let center = CGPoint(
            x: viewSize.width / 2 + canvasOffset.x,
            y: viewSize.height / 2 + canvasOffset.y
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func aspectFitRect(for viewSize: CGSize) -> CGRect {
        let contentAspect: CGFloat
        if let selectedDisplay, selectedDisplay.frame.width > 0, selectedDisplay.frame.height > 0 {
            contentAspect = selectedDisplay.aspectRatio
        } else if remoteSize.width > 0, remoteSize.height > 0 {
            contentAspect = remoteSize.width / remoteSize.height
        } else {
            contentAspect = 16.0 / 10.0
        }

        let clampedAspect = max(contentAspect, 0.0001)
        let viewAspect = max(viewSize.width, 1) / max(viewSize.height, 1)
        if viewAspect > clampedAspect {
            let width = viewSize.height * clampedAspect
            return CGRect(x: (viewSize.width - width) / 2, y: 0, width: width, height: viewSize.height)
        } else {
            let height = viewSize.width / clampedAspect
            return CGRect(x: 0, y: (viewSize.height - height) / 2, width: viewSize.width, height: height)
        }
    }

    private func zoomCanvas(to newScale: CGFloat, around pointInView: CGPoint) {
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let currentRect = canvasDisplayRect(for: viewSize)
        guard currentRect.width > 0, currentRect.height > 0 else { return }

        let anchor = CGPoint(
            x: max(0, min(1, (pointInView.x - currentRect.minX) / currentRect.width)),
            y: max(0, min(1, (pointInView.y - currentRect.minY) / currentRect.height))
        )
        let clampedScale = max(0.7, min(5.0, newScale))
        let baseRect = aspectFitRect(for: viewSize)
        let newSize = CGSize(width: baseRect.width * clampedScale, height: baseRect.height * clampedScale)
        let newOrigin = CGPoint(
            x: pointInView.x - anchor.x * newSize.width,
            y: pointInView.y - anchor.y * newSize.height
        )
        scale = clampedScale
        canvasOffset = CGPoint(
            x: newOrigin.x + newSize.width / 2 - viewSize.width / 2,
            y: newOrigin.y + newSize.height / 2 - viewSize.height / 2
        )
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    private func panCanvas(by delta: CGPoint) {
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        canvasOffset.x += delta.x
        canvasOffset.y += delta.y
        clampCanvasOffset(viewSize: viewSize)
        applyPresentation(viewSize: viewSize)
    }

    private func clampCanvasOffset(viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let base = aspectFitRect(for: viewSize)
        let width = base.width * scale
        let height = base.height * scale
        let minVisibleX = min(96, max(44, min(width, viewSize.width) * 0.35))
        let minVisibleY = min(96, max(44, min(height, viewSize.height) * 0.35))
        let maxX = max(0, (width + viewSize.width) / 2 - minVisibleX)
        let maxY = max(0, (height + viewSize.height) / 2 - minVisibleY)
        canvasOffset.x = max(-maxX, min(maxX, canvasOffset.x))
        canvasOffset.y = max(-maxY, min(maxY, canvasOffset.y))
    }

    private func updateContentsRect() {
        guard remoteSize.width > 0, remoteSize.height > 0 else {
            canvasView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        guard let selectedDisplay else {
            canvasView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        if imageCoversSelectedDisplay {
            canvasView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        let frame = selectedDisplay.frame.standardized
        guard frame.width > 0, frame.height > 0 else {
            canvasView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }

        let normalizedRect = CGRect(
            x: max(0, min(1, frame.minX / remoteSize.width)),
            y: max(0, min(1, frame.minY / remoteSize.height)),
            width: max(0, min(1, frame.width / remoteSize.width)),
            height: max(0, min(1, frame.height / remoteSize.height))
        )

        canvasView.layer.contentsRect = normalizedRect
    }
}
