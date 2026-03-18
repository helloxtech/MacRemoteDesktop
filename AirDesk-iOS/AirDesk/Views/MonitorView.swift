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
        webSocketClient?.requestStream(displayIndex: displayIndex)
        startRefreshTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Stop Metal rendering immediately to prevent GPU faults from in-flight
        // command buffers referencing a drawable that's being torn down.
        mtkView.delegate = nil
        renderer = nil
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
        mtkView.setNeedsDisplay()
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
    private let lock = NSLock()

    // Cached aspect-fit vertices — recomputed only when dimensions change
    private var cachedVerts: [SIMD4<Float>]?
    private var lastImgW = 0, lastImgH = 0
    private var lastDrawW: Float = 0, lastDrawH: Float = 0

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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastDrawW = 0; lastDrawH = 0
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        lock.lock(); let pb = currentPixelBuffer; lock.unlock()
        guard let pb,
              let textureCache = textureCache,
              let pipelineState = pipelineState,
              let drawable = view.currentDrawable,
              let cb = commandQueue.makeCommandBuffer() else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex,
              let texture = CVMetalTextureGetTexture(cvTex) else { return }

        // Recompute aspect-fit vertices only when dimensions change
        let dw = Float(view.drawableSize.width), dh = Float(view.drawableSize.height)
        if w != lastImgW || h != lastImgH || dw != lastDrawW || dh != lastDrawH {
            lastImgW = w; lastImgH = h; lastDrawW = dw; lastDrawH = dh
            let imgAspect = Float(w) / Float(max(h, 1))
            let viewAspect = dw / max(dh, 1)
            var sx: Float = 1, sy: Float = 1
            if imgAspect > viewAspect { sy = viewAspect / imgAspect }
            else { sx = imgAspect / viewAspect }
            cachedVerts = [
                SIMD4(-sx, -sy, 0, 1), SIMD4(sx, -sy, 1, 1), SIMD4(-sx, sy, 0, 0),
                SIMD4(sx, -sy, 1, 1), SIMD4(sx, sy, 1, 0), SIMD4(-sx, sy, 0, 0),
            ]
        }
        guard let verts = cachedVerts else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBytes(verts, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        // Retain CVMetalTexture until the GPU finishes — the MTLTexture is just
        // a view into the IOSurface and becomes invalid once cvTex is released.
        cb.addCompletedHandler { _ in _ = cvTex }
        cb.present(drawable)
        cb.commit()
    }
}
