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
        appState.registerFrameHandler(displayIndex: displayIndex) { pixelBuffer in
            vc.updateFrame(pixelBuffer)
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

    private let monitor: MonitorInfo
    private let displayIndex: Int
    private var mtkView: MTKView!
    private var renderer: MetalVideoRendererObjC?
    private var inputMapper: TouchInputMapper?
    private var webSocketClient: WebSocketClient?
    private var scale: CGFloat = 1.0
    private var lastScale: CGFloat = 1.0
    private var isPinching = false
    private var panOffset: CGPoint = .zero
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

    init(monitor: MonitorInfo, displayIndex: Int) {
        self.monitor = monitor
        self.displayIndex = displayIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupMetalView()
        setupGestures()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        webSocketClient?.requestStream(displayIndex: displayIndex)
        startRefreshTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Periodically requests a fresh stream if no frames arrived recently.
    /// This recovers from ScreenCaptureKit going idle on a static screen
    /// and from decoder desync (lost keyframe / corrupted P-frame chain).
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastFrameTime
            // If no frame for >2s, request a fresh keyframe.
            // Use a generous threshold so normal playback is never interrupted.
            if elapsed > 2.0 {
                self.webSocketClient?.requestStream(displayIndex: self.displayIndex)
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
        mtkView = MTKView(frame: view.bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 30
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.backgroundColor = .black
        view.addSubview(mtkView)

        renderer = MetalVideoRendererObjC(device: device, mtkView: mtkView)
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
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        renderer?.updateFrame(pixelBuffer)
    }

    /// Toggle between 1x (fit) and 2x (readable text) zoom.
    func toggleZoom() {
        if scale > 1.1 {
            // Zoomed in — restore to 1x
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0, options: .curveEaseOut) {
                self.scale = 1.0
                self.panOffset = .zero
                self.mtkView.transform = .identity
            }
        } else {
            // At 1x — zoom to 2x centered
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85,
                           initialSpringVelocity: 0, options: .curveEaseOut) {
                self.scale = 2.0
                self.panOffset = .zero
                self.updateViewTransform()
            }
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

    /// Apply the current scale + panOffset to the mtkView transform.
    private func updateViewTransform() {
        mtkView.transform = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: panOffset.x, y: panOffset.y))
    }

    private func isInContent(_ point: CGPoint) -> Bool {
        guard let inputMapper else { return true }
        let p = touchPointInMTKView(point)
        return inputMapper.isInContentArea(p, viewSize: mtkViewSize)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        ensureMapper()
        let point = gr.location(in: view)
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

    private var isZoomed: Bool { scale < 0.95 || scale > 1.05 }

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

            switch dragAxis {
            case .vertical:
                if isZoomed {
                    // Smart detect: try Mac scroll, fall back to pan
                    handleZoomedVerticalDrag(deltaY: delta.y, gr: gr)
                    updateViewTransform()
                } else {
                    let point = gr.location(in: view)
                    let p = touchPointInMTKView(point)
                    inputMapper?.handleScroll(deltaX: 0, deltaY: delta.y / scale, at: p, in: mtkViewSize)
                }
            case .horizontal:
                panOffset.x += delta.x
                updateViewTransform()
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
            if elapsed > 0.15 {
                // Probe period over — did the screen change?
                if lastFrameTime > probeStartFrameTime {
                    // New frame arrived → page IS scrollable
                    zoomDragMode = .scrolling
                } else {
                    // No new frame → page can't scroll, switch to pan
                    zoomDragMode = .panning
                    // Apply the accumulated Y movement as pan
                    panOffset.y += probePendingPan
                }
            }
        case .scrolling:
            // Page is scrollable — keep sending scroll to Mac
            let point = gr.location(in: view)
            let p = touchPointInMTKView(point)
            inputMapper?.handleScroll(deltaX: 0, deltaY: deltaY / scale, at: p, in: mtkViewSize)
        case .panning:
            // Page can't scroll — pan the view
            panOffset.y += deltaY
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
            lastScale = scale
        case .changed:
            scale = max(0.3, min(4.0, lastScale * gr.scale))
            // Adjust pan offset so the pinch center stays fixed
            let pinch = gr.location(in: view)
            let cx = view.bounds.midX, cy = view.bounds.midY
            panOffset.x = (pinch.x - cx) * (1.0 - scale)
            panOffset.y = (pinch.y - cy) * (1.0 - scale)
            updateViewTransform()
        case .ended, .cancelled:
            isPinching = false
            // Only snap back if barely zoomed out (accidental) — between 0.9 and 1.0.
            // Intentional zoom out (< 0.9) is kept so user can see full screen in landscape.
            if scale > 0.9 && scale < 1.02 {
                resetViewTransform()
            } else if scale < 0.3 {
                resetViewTransform()
            }
        default: break
        }
    }

    /// Animate back to center when at 1x and panned off.
    private func snapBackIfNeeded() {
        if !isZoomed && (panOffset.x != 0 || panOffset.y != 0) {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0, options: .curveEaseOut) {
                self.panOffset = .zero
                self.updateViewTransform()
            }
        }
    }

    private func resetViewTransform() {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0, options: .curveEaseOut) {
            self.scale = 1.0
            self.panOffset = .zero
            self.mtkView.transform = .identity
        }
    }
}

// Thin ObjC-compatible wrapper so MTKViewDelegate can be retained properly
class MetalVideoRendererObjC: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private var currentPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    init?(device: MTLDevice, mtkView: MTKView) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        super.init()
        mtkView.delegate = self
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock(); currentPixelBuffer = pixelBuffer; lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock(); let pb = currentPixelBuffer; lock.unlock()
        guard let pb, let drawable = view.currentDrawable, let cb = commandQueue.makeCommandBuffer() else { return }

        let image = CIImage(cvPixelBuffer: pb)
        let drawableSize = view.drawableSize
        let imgSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let scale = min(drawableSize.width / imgSize.width, drawableSize.height / imgSize.height)
        let sx = (drawableSize.width - imgSize.width * scale) / 2
        let sy = (drawableSize.height - imgSize.height * scale) / 2
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: sx / scale, y: sy / scale))

        let dest = CIRenderDestination(width: Int(drawableSize.width), height: Int(drawableSize.height), pixelFormat: view.colorPixelFormat, commandBuffer: cb) { drawable.texture }
        try? ciContext.startTask(toRender: scaled, to: dest)
        cb.present(drawable); cb.commit()
    }
}
