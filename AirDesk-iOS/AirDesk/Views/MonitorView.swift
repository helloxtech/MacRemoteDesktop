import SwiftUI
import UIKit
import MetalKit

struct MonitorView: UIViewControllerRepresentable {

    let monitor: MonitorInfo
    let displayIndex: Int
    @EnvironmentObject var appState: AppState

    func makeUIViewController(context: Context) -> MonitorViewController {
        let vc = MonitorViewController(monitor: monitor, displayIndex: displayIndex)
        if let client = appState.webSocketClient {
            vc.configure(client: client)
        }
        appState.registerFrameHandler(displayIndex: displayIndex) { [weak vc] pixelBuffer in
            vc?.updateFrame(pixelBuffer)
        }
        appState.activeMonitorVC = vc
        return vc
    }

    func updateUIViewController(_ vc: MonitorViewController, context: Context) {
        // Only update the WebSocket client reference — do NOT re-register the
        // frame handler here. SwiftUI calls updateUIViewController on every
        // @Published change (latencyMs, decodedFPS, etc.), and registerFrameHandler
        // triggers requestStream which forces a keyframe on the Mac. That causes
        // visible flashing during video playback.
        if let client = appState.webSocketClient {
            vc.configure(client: client)
        }
    }
}

class MonitorViewController: UIViewController, UIGestureRecognizerDelegate {
    private static let minimumDisplayScale: CGFloat = 0.5

    private let monitor: MonitorInfo
    private let displayIndex: Int
    private var mtkView: MTKView!
    private var renderer: MetalVideoRendererObjC?
    private let rendererLock = NSLock()
    private var inputMapper: TouchInputMapper?
    private var webSocketClient: WebSocketClient?
    private var scale: CGFloat = 1.0
    private var displayScale: CGFloat = 1.0
    private var viewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var pinchStartScale: CGFloat = 1.0
    private var pinchStartDisplayScale: CGFloat = 1.0
    private var pinchStartViewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var isPinching = false
    private enum DragAxis { case undecided, vertical, horizontal }
    private var dragAxis: DragAxis = .undecided
    private var dragAccumulator: CGPoint = .zero
    // Zoom-scroll probe: detect if Mac page is scrollable
    private enum ZoomDragMode { case probing, scrolling, panning }
    private var zoomDragMode: ZoomDragMode = .probing
    private var probeStartTime: CFAbsoluteTime = 0
    private var probeStartFrameTime: CFAbsoluteTime = 0
    private var probePendingPan: CGFloat = 0  // accumulated Y delta during probe
    private var refreshTimer: Timer?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var hasInitializedViewport = false
    private var hasUserZoomedViewport = false

    init(monitor: MonitorInfo, displayIndex: Int) {
        self.monitor = monitor
        self.displayIndex = displayIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var mtkBottomConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMetalView()
        setupGestures()

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // (Re-)register with FrameRelay for direct frame delivery from decoder thread.
        // This also recovers if viewWillDisappear cleared the handler.
        FrameRelay.shared.set(displayIndex: displayIndex) { [weak self] pixelBuffer in
            self?.updateFrame(pixelBuffer)
        }
        // Restore MTKView delegate if it was cleared
        rendererLock.lock()
        let r = renderer
        rendererLock.unlock()
        if mtkView.delegate == nil, let r {
            mtkView.delegate = r
        }
        applyViewport()
        updateDisplayTransform()
        webSocketClient?.requestStream(displayIndex: displayIndex)
        startRefreshTimer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if !hasInitializedViewport || (!hasUserZoomedViewport && displayScale >= 0.999) {
            viewport = baseViewportRect(for: viewSize)
            hasInitializedViewport = true
        } else {
            let center = CGPoint(x: viewport.midX, y: viewport.midY)
            let targetScale = hasUserZoomedViewport ? max(scale, 1.001) : 1.0
            let size = viewportSize(for: targetScale, viewSize: viewSize)
            viewport = clampedViewport(center: center, size: size)
        }
        applyViewport()
        updateDisplayTransform()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Remove frame handler so decoder stops delivering to this VC
        FrameRelay.shared.set(displayIndex: displayIndex, handler: nil)
        // Stop Metal draws but keep renderer alive for potential viewDidAppear re-use.
        // ARC will clean up the renderer when the VC is deallocated.
        mtkView.delegate = nil
    }

    /// Periodically requests a fresh stream if no frames arrived recently.
    /// This recovers from ScreenCaptureKit going idle on a static screen
    /// and from decoder desync (lost keyframe / corrupted P-frame chain).
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastFrameTime
            // If no frame for >2s, request a fresh keyframe and force a redraw
            // so the screen recovers from any stale/black state.
            if elapsed > 2.0 {
                self.webSocketClient?.requestStream(displayIndex: self.displayIndex)
                self.mtkView.setNeedsDisplay()
            }
        }
    }

    private func ensureMapper() {
        if inputMapper == nil, let client = webSocketClient {
            configure(client: client)
        }
    }

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        mtkView = MTKView(frame: .zero, device: device)
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        mtkView.framebufferOnly = true
        mtkView.colorPixelFormat = .bgra8Unorm
        // On-demand rendering: only draw when a new frame arrives.
        // Avoids ~29 redundant GPU draws/sec on slower devices (A8).
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.backgroundColor = .black
        view.addSubview(mtkView)

        mtkBottomConstraint = mtkView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            mtkView.topAnchor.constraint(equalTo: view.topAnchor),
            mtkView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mtkBottomConstraint,
        ])

        rendererLock.lock()
        renderer = MetalVideoRendererObjC(device: device, mtkView: mtkView)
        rendererLock.unlock()
        updateDisplayTransform()
    }

    private func setupGestures() {
        // Single tap = click
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        // Double tap = double click
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)

        // Two-finger tap = right click
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        view.addGestureRecognizer(twoFingerTap)

        // Long press = right click
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        // Single-finger drag = scroll / pan
        // No require(toFail: tap) — pan starts immediately when finger moves.
        // Tap vs drag is distinguished by the gesture system's built-in movement
        // threshold: small movement → tap fires, larger movement → pan fires.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        view.addGestureRecognizer(drag)

        // Pinch = local zoom (must be added BEFORE scroll so require(toFail:) works)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        // Two-finger pan = scroll — requires pinch to fail first so they don't fight
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = self
        scroll.require(toFail: pinch)
        view.addGestureRecognizer(scroll)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow multiple taps simultaneously (single tap + double tap)
        if gestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer is UITapGestureRecognizer {
            return true
        }
        // Allow pinch alongside pan so pinch isn't cancelled
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return true
        }
        // Tap + Pan must NOT fire simultaneously — otherwise taps fire during
        // scrolling which sends unwanted clicks and causes view instability.
        return false
    }

    func configure(client: WebSocketClient) {
        self.webSocketClient = client
        if let mapper = inputMapper {
            mapper.updateClient(client)
        } else {
            let mapper = TouchInputMapper(client: client)
            mapper.configure(displayIndex: displayIndex, monitor: monitor)
            self.inputMapper = mapper
        }
        inputMapper?.setViewport(viewport)
    }

    /// Thread-safe: can be called from any thread (decoder callback, main thread).
    /// Takes a lock-protected local ref to renderer to avoid racing with
    /// viewWillDisappear, then schedules a lightweight setNeedsDisplay on main.
    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        rendererLock.lock()
        let r = renderer
        rendererLock.unlock()
        r?.updateFrame(pixelBuffer)
        if Thread.isMainThread {
            lastFrameTime = CFAbsoluteTimeGetCurrent()
            mtkView?.setNeedsDisplay()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lastFrameTime = CFAbsoluteTimeGetCurrent()
                self?.mtkView?.setNeedsDisplay()
            }
        }
    }

    /// Toggle between 1x (fit) and 2x (readable text) zoom.
    func toggleZoom() {
        if scale > 1.1 {
            zoom(to: 1.0)
        } else {
            zoom(to: 2.0)
        }
    }

    /// Convert a touch point from the parent view's coordinate space into
    /// the mtkView's own coordinate space. When the mtkView has a non-identity
    /// transform (pinch zoom), this correctly accounts for the scale/translation
    /// so the normalized Mac coordinate matches where the user actually tapped
    /// on the visible content.
    private func touchPointInMTKView(_ pointInView: CGPoint) -> CGPoint {
        return view.convert(pointInView, to: mtkView)
    }

    private var mtkViewSize: CGSize {
        return mtkView.bounds.size
    }

    private func contentRect(in viewSize: CGSize) -> CGRect {
        effectivePresentation(for: viewSize).displayRect
    }

    private func baseViewportSize(for viewSize: CGSize) -> CGSize {
        let monitorAspect = CGFloat(max(monitor.width, 1)) / CGFloat(max(monitor.height, 1))
        let viewAspect = max(viewSize.width, 1) / max(viewSize.height, 1)
        let ratio = viewAspect / monitorAspect
        if ratio >= 1 {
            return CGSize(width: 1, height: 1 / ratio)
        } else {
            return CGSize(width: ratio, height: 1)
        }
    }

    private func baseViewportRect(for viewSize: CGSize) -> CGRect {
        let size = baseViewportSize(for: viewSize)
        return CGRect(
            x: (1 - size.width) / 2,
            y: (1 - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func viewportSize(for targetScale: CGFloat, viewSize overrideViewSize: CGSize? = nil) -> CGSize {
        let clampedScale = max(1.0, min(4.0, targetScale))
        let currentViewSize = overrideViewSize ?? (mtkViewSize == .zero ? view.bounds.size : mtkViewSize)
        let baseSize = baseViewportSize(for: currentViewSize)
        return CGSize(width: baseSize.width / clampedScale, height: baseSize.height / clampedScale)
    }

    private func displayScaleViewportSize(for displayScale: CGFloat, viewSize: CGSize) -> CGSize {
        let fillViewport = baseViewportRect(for: viewSize)
        let t = max(0, min(1, (displayScale - Self.minimumDisplayScale) / (1 - Self.minimumDisplayScale)))
        return CGSize(
            width: 1 + (fillViewport.width - 1) * t,
            height: 1 + (fillViewport.height - 1) * t
        )
    }

    private func activeViewport(for viewSize: CGSize) -> CGRect {
        if displayScale < 0.999 {
            let size = displayScaleViewportSize(for: displayScale, viewSize: viewSize)
            return clampedViewport(center: CGPoint(x: viewport.midX, y: viewport.midY), size: size)
        }
        return clampedViewport(center: CGPoint(x: viewport.midX, y: viewport.midY), size: viewport.size)
    }

    private func clampedViewport(center: CGPoint, size: CGSize) -> CGRect {
        let width = max(0.08, min(1.0, size.width))
        let height = max(0.08, min(1.0, size.height))
        let originX = min(max(0, center.x - width / 2), 1 - width)
        let originY = min(max(0, center.y - height / 2), 1 - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func applyViewport() {
        let currentViewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
        let baseSize = baseViewportSize(for: currentViewSize)
        viewport = activeViewport(for: currentViewSize)
        scale = max(1.0, min(4.0, max(baseSize.width / max(viewport.width, 0.0001), baseSize.height / max(viewport.height, 0.0001))))
        applyPresentation(viewSize: currentViewSize)
    }

    private func updateDisplayTransform() {
        let currentViewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
        guard currentViewSize.width > 0, currentViewSize.height > 0 else { return }
        applyPresentation(viewSize: currentViewSize)
    }

    private func applyPresentation(viewSize: CGSize) {
        let presentation = effectivePresentation(for: viewSize)
        rendererLock.lock()
        renderer?.setViewport(presentation.viewport)
        renderer?.setDisplayRectNormalized(normalizedRect(presentation.displayRect, in: viewSize))
        rendererLock.unlock()
        inputMapper?.setViewport(presentation.viewport)
        inputMapper?.setDisplayRect(presentation.displayRect)
        mtkView?.setNeedsDisplay()
    }

    private func effectivePresentation(for viewSize: CGSize) -> (viewport: CGRect, displayRect: CGRect) {
        let fullRect = CGRect(origin: .zero, size: viewSize)
        guard viewSize.width > 0, viewSize.height > 0 else {
            return (viewport, fullRect)
        }
        guard displayScale < 0.999 else {
            return (viewport, fullRect)
        }

        let scaledViewport = activeViewport(for: viewSize)
        let monitorAspect = CGFloat(max(monitor.width, 1)) / CGFloat(max(monitor.height, 1))
        let contentAspect = monitorAspect * scaledViewport.width / scaledViewport.height
        return (
            scaledViewport,
            aspectFitRect(for: viewSize, contentAspect: contentAspect)
        )
    }

    private func aspectFitRect(for viewSize: CGSize) -> CGRect {
        let monitorAspect = CGFloat(max(monitor.width, 1)) / CGFloat(max(monitor.height, 1))
        return aspectFitRect(for: viewSize, contentAspect: monitorAspect)
    }

    private func aspectFitRect(for viewSize: CGSize, contentAspect: CGFloat) -> CGRect {
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

    private func interpolate(from start: CGRect, to end: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: start.origin.x + (end.origin.x - start.origin.x) * t,
            y: start.origin.y + (end.origin.y - start.origin.y) * t,
            width: start.size.width + (end.size.width - start.size.width) * t,
            height: start.size.height + (end.size.height - start.size.height) * t
        )
    }

    private func normalizedRect(_ rect: CGRect, in viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: rect.minX / viewSize.width,
            y: rect.minY / viewSize.height,
            width: rect.width / viewSize.width,
            height: rect.height / viewSize.height
        )
    }

    private func normalizedContentPoint(from pointInView: CGPoint) -> CGPoint? {
        let point = touchPointInMTKView(pointInView)
        let rect = contentRect(in: mtkViewSize)
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(
            x: max(0, min(1, (point.x - rect.minX) / rect.width)),
            y: max(0, min(1, (point.y - rect.minY) / rect.height))
        )
    }

    private func zoom(to newScale: CGFloat, around pointInView: CGPoint? = nil, from baseViewport: CGRect? = nil) {
        let clampedScale = max(1.0, min(4.0, newScale))
        let sourceViewport = baseViewport ?? viewport

        guard clampedScale > 1.001 else {
            hasUserZoomedViewport = false
            viewport = baseViewportRect(for: mtkViewSize == .zero ? view.bounds.size : mtkViewSize)
            applyViewport()
            return
        }

        hasUserZoomedViewport = true
        let targetSize = viewportSize(for: clampedScale)
        let anchor = pointInView.flatMap(normalizedContentPoint(from:)) ?? CGPoint(x: 0.5, y: 0.5)
        let sourcePoint = CGPoint(
            x: sourceViewport.origin.x + anchor.x * sourceViewport.width,
            y: sourceViewport.origin.y + anchor.y * sourceViewport.height
        )

        viewport = clampedViewport(
            center: CGPoint(
                x: sourcePoint.x + (0.5 - anchor.x) * targetSize.width,
                y: sourcePoint.y + (0.5 - anchor.y) * targetSize.height
            ),
            size: targetSize
        )
        applyViewport()
    }

    private func panViewport(by delta: CGPoint) {
        guard hasUserZoomedViewport || displayScale < 0.999 else { return }
        let rect = contentRect(in: mtkViewSize)
        guard rect.width > 0, rect.height > 0 else { return }
        let sourceViewport = activeViewport(for: mtkViewSize)

        let center = CGPoint(
            x: sourceViewport.midX - (delta.x / rect.width) * sourceViewport.width,
            y: sourceViewport.midY - (delta.y / rect.height) * sourceViewport.height
        )
        viewport = clampedViewport(center: center, size: sourceViewport.size)
        applyViewport()
    }

    private func isInContent(_ point: CGPoint) -> Bool {
        guard let inputMapper else { return true }
        let p = touchPointInMTKView(point)
        return inputMapper.isInContentArea(p, viewSize: mtkViewSize)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        ensureMapper()
        let point = gr.location(in: view)
        NSLog("[AirDesk] tap at (%.0f, %.0f) inContent=%d mapper=%d client=%d",
              point.x, point.y, isInContent(point) ? 1 : 0,
              inputMapper != nil ? 1 : 0, webSocketClient != nil ? 1 : 0)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleTap(at: p, in: mtkViewSize)
    }

    @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleDoubleTap(at: p, in: mtkViewSize)
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleLongPress(at: p, in: mtkViewSize)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleLongPress(at: p, in: mtkViewSize)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private var isZoomed: Bool { hasUserZoomedViewport || abs(displayScale - 1.0) > 0.01 }

    @objc private func handleDrag(_ gr: UIPanGestureRecognizer) {
        switch gr.state {
        case .began:
            dragAxis = .undecided
            dragAccumulator = .zero
            zoomDragMode = .probing
            probeStartTime = CFAbsoluteTimeGetCurrent()
            probeStartFrameTime = lastFrameTime
            probePendingPan = 0
            ensureMapper()
            // Always move cursor to finger position at drag start — both zoomed
            // and unzoomed — so scroll events target the correct Mac window/area
            // without requiring a separate tap first.
            let point = gr.location(in: view)
            if isInContent(point) {
                let p = touchPointInMTKView(point)
                inputMapper?.handleMove(at: p, in: mtkViewSize)
            }
        case .changed:
            guard !isPinching else { return }
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)

            // Axis-lock first — same logic whether zoomed or not
            if dragAxis == .undecided {
                dragAccumulator.x += delta.x
                dragAccumulator.y += delta.y
                let threshold: CGFloat = 8
                if abs(dragAccumulator.y) > threshold {
                    dragAxis = .vertical
                } else if abs(dragAccumulator.x) > threshold {
                    dragAxis = .horizontal
                } else {
                    return
                }
            }

            if hasUserZoomedViewport || displayScale < 0.999 {
                switch dragAxis {
                case .vertical:
                    handleZoomedVerticalDrag(deltaY: delta.y, gr: gr)
                case .horizontal:
                    panViewport(by: CGPoint(x: delta.x, y: 0))
                case .undecided:
                    break
                }
                return
            }

            switch dragAxis {
            case .vertical:
                let point = gr.location(in: view)
                let p = touchPointInMTKView(point)
                inputMapper?.handleScroll(deltaX: 0, deltaY: delta.y / scale, at: p, in: mtkViewSize)
            case .horizontal:
                panViewport(by: CGPoint(x: delta.x, y: 0))
            case .undecided:
                break
            }
        case .ended, .cancelled:
            dragAxis = .undecided
            zoomDragMode = .probing
            snapBackIfNeeded()
        default:
            break
        }
    }

    /// When zoomed, handle vertical drag with auto-detection:
    /// First send scroll to Mac. If a new frame arrives (page scrolled), keep scrolling.
    /// If no new frame after ~150ms, switch to panning the view.
    private func handleZoomedVerticalDrag(deltaY: CGFloat, gr: UIPanGestureRecognizer) {
        switch zoomDragMode {
        case .probing:
            // Send scroll to Mac while probing
            let point = gr.location(in: view)
            let p = touchPointInMTKView(point)
            inputMapper?.handleScroll(deltaX: 0, deltaY: deltaY / scale, at: p, in: mtkViewSize)
            probePendingPan += deltaY

            let elapsed = CFAbsoluteTimeGetCurrent() - probeStartTime
                if elapsed > 0.10 {
                    // Probe period over — did the screen change?
                    if lastFrameTime > probeStartFrameTime {
                        // New frame arrived → page IS scrollable
                        zoomDragMode = .scrolling
                    } else {
                        // No new frame → page can't scroll, switch to pan
                        zoomDragMode = .panning
                        // Apply the accumulated Y movement as pan
                        panViewport(by: CGPoint(x: 0, y: probePendingPan))
                    }
                }
            case .scrolling:
                // Page is scrollable — keep sending scroll to Mac
                let point = gr.location(in: view)
                let p = touchPointInMTKView(point)
                inputMapper?.handleScroll(deltaX: 0, deltaY: deltaY / scale, at: p, in: mtkViewSize)
            case .panning:
                // Page can't scroll — pan the view
                panViewport(by: CGPoint(x: 0, y: deltaY))
        }
    }

    @objc private func handleScroll(_ gr: UIPanGestureRecognizer) {
        if gr.state == .began {
            ensureMapper()
            let point = gr.location(in: view)
            let p = touchPointInMTKView(point)
            inputMapper?.handleMove(at: p, in: mtkViewSize)
        }
        guard gr.state == .changed else { return }
        guard !isPinching else { return }
        let delta = gr.translation(in: view)
        gr.setTranslation(.zero, in: view)
        let point = gr.location(in: view)
        let p = touchPointInMTKView(point)
        inputMapper?.handleScroll(deltaX: delta.x / scale, deltaY: delta.y / scale, at: p, in: mtkViewSize)
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began:
            isPinching = true
            pinchStartScale = scale
            pinchStartDisplayScale = displayScale
            pinchStartViewport = viewport
        case .changed:
            let start = pinchStartDisplayScale < 0.999 ? pinchStartDisplayScale : pinchStartScale
            let target = max(Self.minimumDisplayScale, min(4.0, start * gr.scale))
            if target < 1.0 {
                if scale > 1.001 {
                    zoom(to: 1.0)
                }
                displayScale = target
                updateDisplayTransform()
            } else {
                if displayScale < 0.999 {
                    displayScale = 1.0
                    updateDisplayTransform()
                }
                zoom(to: target, around: gr.location(in: view), from: pinchStartViewport)
            }
        case .ended, .cancelled:
            isPinching = false
            if displayScale < 1.0 {
                if displayScale > 0.995 {
                    displayScale = 1.0
                    updateDisplayTransform()
                }
            } else if scale < 1.0005 {
                zoom(to: 1.0)
            }
        default: break
        }
    }

    /// Animate back to center when at 1x and panned off.
    private func snapBackIfNeeded() {
        if !isZoomed {
            let currentViewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
            hasUserZoomedViewport = false
            viewport = baseViewportRect(for: currentViewSize)
            applyViewport()
        }
    }

    private func resetViewTransform() {
        zoom(to: 1.0)
    }

    // MARK: - Keyboard Avoidance

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let localFrame = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - localFrame.minY)
        mtkBottomConstraint.constant = -overlap
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        mtkBottomConstraint.constant = 0
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }
}

// Direct Metal renderer using CVMetalTextureCache — avoids CIContext for maximum
// compatibility with older devices (A8 / iOS 15).
class MetalVideoRendererObjC: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?
    private var currentPixelBuffer: CVPixelBuffer?
    private var viewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var displayRectNormalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let lock = NSLock()

    // Limit in-flight GPU frames to prevent drawable exhaustion (which blocks main thread).
    // MTKView has 3 drawables; capping at 2 in-flight guarantees one is always free.
    private var inflightCount = 0
    private let maxInflight = 2

    init?(device: MTLDevice, mtkView: MTKView) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache = cache else { return nil }
        self.textureCache = cache

        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 uv; };
        vertex V vs(uint vid [[vertex_id]], constant float4 *d [[buffer(0)]]) {
            V o; o.position = float4(d[vid].xy, 0, 1); o.uv = d[vid].zw; return o;
        }
        fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return t.sample(s, in.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: shaderSrc, options: nil) else {
            NSLog("[AirDesk] Failed to compile Metal shaders")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vs")
        desc.fragmentFunction = lib.makeFunction(name: "fs")
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        guard let ps = try? device.makeRenderPipelineState(descriptor: desc) else {
            NSLog("[AirDesk] Failed to create pipeline state")
            return nil
        }
        self.pipelineState = ps
        mtkView.delegate = self
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); currentPixelBuffer = pixelBuffer; lock.unlock()
    }

    func setViewport(_ viewport: CGRect) {
        lock.lock()
        self.viewport = viewport
        lock.unlock()
    }

    func setDisplayRectNormalized(_ rect: CGRect) {
        lock.lock()
        self.displayRectNormalized = rect
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        // Skip if GPU already has maxInflight frames queued — prevents
        // view.currentDrawable from blocking the main thread (which causes freeze).
        guard inflightCount < maxInflight else { return }

        lock.lock()
        let pb = currentPixelBuffer
        let viewport = self.viewport
        let displayRectNormalized = self.displayRectNormalized
        lock.unlock()
        guard let pb,
              let textureCache = textureCache,
              let pipelineState = pipelineState else { return }

        // Increment BEFORE requesting drawable (drawable can block if pool is full)
        inflightCount += 1

        guard let drawable = view.currentDrawable,
              let cb = commandQueue.makeCommandBuffer() else {
            inflightCount -= 1
            return
        }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            inflightCount -= 1
            return
        }

        let u0 = Float(viewport.minX)
        let v0 = Float(viewport.minY)
        let u1 = Float(viewport.maxX)
        let v1 = Float(viewport.maxY)
        let left = Float(displayRectNormalized.minX * 2 - 1)
        let right = Float(displayRectNormalized.maxX * 2 - 1)
        let top = Float(1 - displayRectNormalized.minY * 2)
        let bottom = Float(1 - displayRectNormalized.maxY * 2)
        let verts: [SIMD4<Float>] = [
            SIMD4(left, bottom, u0, v1), SIMD4(right, bottom, u1, v1), SIMD4(left, top, u0, v0),
            SIMD4(right, bottom, u1, v1), SIMD4(right, top, u1, v0), SIMD4(left, top, u0, v0),
        ]

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            inflightCount -= 1
            return
        }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBytes(verts, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        // Retain CVMetalTexture until the GPU finishes — the MTLTexture is just
        // a view into the IOSurface and becomes invalid once cvTex is released.
        // Also decrement inflightCount on main thread so draw() can accept new work.
        cb.addCompletedHandler { [weak self] _ in
            _ = cvTex
            DispatchQueue.main.async { self?.inflightCount -= 1 }
        }
        cb.present(drawable)
        cb.commit()
    }
}
