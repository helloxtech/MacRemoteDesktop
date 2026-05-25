import SwiftUI
import UIKit
import MetalKit
import AirDeskProtocol

struct MonitorView: UIViewControllerRepresentable {

    let monitor: MonitorInfo
    let displayIndex: Int
    let controlMode: RemoteControlMode
    let inputEnabled: Bool
    @EnvironmentObject var appState: AppState

    func makeUIViewController(context: Context) -> MonitorViewController {
        let vc = MonitorViewController(monitor: monitor, displayIndex: displayIndex)
        vc.setControlMode(controlMode)
        vc.setInputEnabled(inputEnabled)
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
        vc.setControlMode(controlMode)
        vc.setInputEnabled(inputEnabled)
    }
}

class MonitorViewController: UIViewController, UIGestureRecognizerDelegate {
    private let monitor: MonitorInfo
    private let displayIndex: Int
    private var mtkView: MTKView!
    private var renderer: MetalVideoRendererObjC?
    private let rendererLock = NSLock()
    private var inputMapper: TouchInputMapper?
    private var webSocketClient: WebSocketClient?
    private var scale: CGFloat = 1.0
    private var viewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var canvasOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1.0
    private var isPinching = false
    private var singleFingerScrollActive = false
    private var twoFingerScrollActive = false
    private var controlMode: RemoteControlMode = .touch
    private var inputEnabled = true
    private var refreshTimer: Timer?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var isFrameDrawScheduled = false
    private var hasInitializedViewport = false

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
        startInitialFrameTimer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let viewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if !hasInitializedViewport {
            viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
            canvasOffset = .zero
            scale = 1.0
            hasInitializedViewport = true
        }
        clampCanvasOffset(viewSize: viewSize)
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
        isFrameDrawScheduled = false
    }

    /// Requests one extra stream only if the view appears and no frame arrives.
    /// A static Mac screen is valid; repeated forced captures on static content
    /// create visible flashes because immediate captures differ from SCK frames.
    private func startInitialFrameTimer() {
        refreshTimer?.invalidate()
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - self.lastFrameTime
            if elapsed > 2.8 {
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
        tap.require(toFail: doubleTap)

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

        // Control mode: one-finger drag moves the local desktop canvas.
        // Scroll mode: one-finger drag sends a wheel scroll to the Mac.
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
            return false
        }
        // Allow pinch alongside pan so pinch isn't cancelled
        if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
            return true
        }
        // Tap + Pan must NOT fire simultaneously — otherwise taps fire during
        // canvas movement or scrolling and send unwanted clicks.
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

    func setControlMode(_ mode: RemoteControlMode) {
        guard controlMode != mode else { return }
        controlMode = mode
        singleFingerScrollActive = false
        twoFingerScrollActive = false
        inputMapper?.endScroll()
    }

    func setInputEnabled(_ enabled: Bool) {
        if !enabled {
            singleFingerScrollActive = false
            twoFingerScrollActive = false
            inputMapper?.endScroll()
        }
        inputEnabled = enabled
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
            scheduleFrameDrawOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleFrameDrawOnMain()
            }
        }
    }

    private func scheduleFrameDrawOnMain() {
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        guard !isFrameDrawScheduled else { return }
        isFrameDrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFrameDrawScheduled = false
            self.mtkView?.setNeedsDisplay()
        }
    }

    /// Toggle between 1x (fit) and 2x (readable text) zoom.
    func toggleZoom() {
        if scale > 1.1 {
            zoomCanvas(to: 1.0, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        } else {
            zoomCanvas(to: 2.0, around: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
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

    private func applyViewport() {
        let currentViewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
        viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        scale = max(0.7, min(5.0, scale))
        clampCanvasOffset(viewSize: currentViewSize)
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
        guard viewSize.width > 0, viewSize.height > 0 else {
            return (viewport, CGRect(origin: .zero, size: viewSize))
        }
        return (
            CGRect(x: 0, y: 0, width: 1, height: 1),
            canvasDisplayRect(for: viewSize)
        )
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

    private func zoomCanvas(to newScale: CGFloat, around pointInView: CGPoint) {
        let viewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
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
        let viewSize = mtkViewSize == .zero ? view.bounds.size : mtkViewSize
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

    private func isInContent(_ point: CGPoint) -> Bool {
        guard let inputMapper else { return true }
        let p = touchPointInMTKView(point)
        return inputMapper.isInContentArea(p, viewSize: mtkViewSize)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled else { return }
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
        guard inputEnabled else { return }
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleDoubleTap(at: p, in: mtkViewSize)
    }

    @objc private func handleTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard inputEnabled else { return }
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleLongPress(at: p, in: mtkViewSize)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        guard inputEnabled else { return }
        ensureMapper()
        let point = gr.location(in: view)
        guard isInContent(point) else { return }
        let p = touchPointInMTKView(point)
        inputMapper?.handleLongPress(at: p, in: mtkViewSize)
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

    private func handleDirectMouseDrag(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else { return }
        guard !isPinching else { return }
        ensureMapper()
        let point = gr.location(in: view)
        let p = touchPointInMTKView(point)

        switch gr.state {
        case .began:
            guard isInContent(point) else { return }
            inputMapper?.handleDragBegan(at: p, in: mtkViewSize)
        case .changed:
            inputMapper?.handleDragChanged(to: p, in: mtkViewSize)
        case .ended, .cancelled:
            inputMapper?.handleDragEnded(at: p, in: mtkViewSize)
        default:
            break
        }
    }

    private func handleSingleFingerScroll(_ gr: UIPanGestureRecognizer) {
        guard inputEnabled else {
            singleFingerScrollActive = false
            inputMapper?.endScroll()
            return
        }

        switch gr.state {
        case .began:
            ensureMapper()
            let point = gr.location(in: view)
            guard isInContent(point) else {
                singleFingerScrollActive = false
                return
            }
            singleFingerScrollActive = true
            inputMapper?.beginScroll()
            let p = touchPointInMTKView(point)
            inputMapper?.handleMove(at: p, in: mtkViewSize)
            gr.setTranslation(.zero, in: view)
        case .changed:
            guard singleFingerScrollActive, !isPinching else { return }
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)
            let point = gr.location(in: view)
            let p = touchPointInMTKView(point)
            inputMapper?.handleScroll(deltaX: delta.x, deltaY: delta.y, at: p, in: mtkViewSize)
        case .ended, .cancelled, .failed:
            singleFingerScrollActive = false
            inputMapper?.endScroll()
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
            inputMapper?.endScroll()
            return
        }

        switch gr.state {
        case .began:
            ensureMapper()
            let point = gr.location(in: view)
            guard isInContent(point) else {
                twoFingerScrollActive = false
                return
            }
            twoFingerScrollActive = true
            inputMapper?.beginScroll()
            let p = touchPointInMTKView(point)
            inputMapper?.handleMove(at: p, in: mtkViewSize)
            gr.setTranslation(.zero, in: view)
        case .changed:
            guard twoFingerScrollActive, !isPinching else { return }
            let delta = gr.translation(in: view)
            gr.setTranslation(.zero, in: view)
            let point = gr.location(in: view)
            let p = touchPointInMTKView(point)
            inputMapper?.handleScroll(deltaX: delta.x, deltaY: delta.y, at: p, in: mtkViewSize)
        case .ended, .cancelled, .failed:
            twoFingerScrollActive = false
            inputMapper?.endScroll()
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
        default: break
        }
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
    private let maxInflight = 1
    private var needsDeferredDraw = false

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
        guard inflightCount < maxInflight else {
            needsDeferredDraw = true
            return
        }

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
            finishInflightDraw(on: view)
            return
        }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else {
            finishInflightDraw(on: view)
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
            finishInflightDraw(on: view)
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
            DispatchQueue.main.async { [weak view] in
                guard let self else { return }
                self.finishInflightDraw(on: view)
            }
        }
        cb.present(drawable)
        cb.commit()
    }

    private func finishInflightDraw(on view: MTKView?) {
        inflightCount = max(0, inflightCount - 1)
        guard needsDeferredDraw else { return }
        needsDeferredDraw = false
        view?.setNeedsDisplay()
    }
}
