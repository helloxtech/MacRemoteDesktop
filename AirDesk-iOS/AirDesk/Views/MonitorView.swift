import SwiftUI
import UIKit

struct MonitorView: UIViewControllerRepresentable {

    let monitor: MonitorInfo
    let displayIndex: Int
    @EnvironmentObject var appState: AppState

    func makeUIViewController(context: Context) -> MonitorViewController {
        let vc = MonitorViewController(monitor: monitor, displayIndex: displayIndex)
        if let client = appState.webSocketClient {
            vc.configure(client: client)
        }
        // Use per-display handler — fixes multi-monitor overwrite bug
        appState.registerFrameHandler(displayIndex: displayIndex) { pixelBuffer in
            vc.updateFrame(pixelBuffer)
        }
        return vc
    }

    func updateUIViewController(_ vc: MonitorViewController, context: Context) {
        appState.registerFrameHandler(displayIndex: displayIndex) { pixelBuffer in
            vc.updateFrame(pixelBuffer)
        }
    }
}

class MonitorViewController: UIViewController {

    private let monitor: MonitorInfo
    private let displayIndex: Int
    private var mtkView: MTKView!
    private var renderer: MetalVideoRendererObjC?
    private var inputMapper: TouchInputMapper?
    private var cursorView: UIView!
    private var scale: CGFloat = 1.0
    private var lastScale: CGFloat = 1.0

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
        setupCursor()
        setupGestures()
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

    private func setupCursor() {
        cursorView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 12))
        cursorView.layer.cornerRadius = 6
        cursorView.backgroundColor = UIColor.white.withAlphaComponent(0.8)
        cursorView.layer.borderColor = UIColor.black.cgColor
        cursorView.layer.borderWidth = 1
        cursorView.isHidden = true
        cursorView.isUserInteractionEnabled = false
        view.addSubview(cursorView)
    }

    private func setupGestures() {
        // Single tap = click
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        view.addGestureRecognizer(tap)

        // Long press = right click
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        view.addGestureRecognizer(longPress)

        // Single-finger drag = mouse drag
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        view.addGestureRecognizer(drag)

        // Two-finger pan = scroll
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        view.addGestureRecognizer(scroll)

        // Pinch = local zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        tap.require(toFail: longPress)
        drag.require(toFail: scroll)
    }

    func configure(client: WebSocketClient) {
        let mapper = TouchInputMapper(client: client)
        mapper.configure(displayIndex: displayIndex, monitor: monitor)
        self.inputMapper = mapper
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        renderer?.updateFrame(pixelBuffer)
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let point = gr.location(in: view)
        inputMapper?.handleTap(at: point, in: view.bounds.size)
        flashCursor(at: point)
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let point = gr.location(in: view)
        inputMapper?.handleLongPress(at: point, in: view.bounds.size)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc private func handleDrag(_ gr: UIPanGestureRecognizer) {
        let point = gr.location(in: view)
        switch gr.state {
        case .began:
            inputMapper?.handleDragBegan(at: point, in: view.bounds.size)
            cursorView.isHidden = false
        case .changed:
            inputMapper?.handleDragChanged(to: point, in: view.bounds.size)
            cursorView.center = point
        case .ended, .cancelled:
            inputMapper?.handleDragEnded(at: point, in: view.bounds.size)
            cursorView.isHidden = true
        default: break
        }
    }

    @objc private func handleScroll(_ gr: UIPanGestureRecognizer) {
        guard gr.state == .changed else { return }
        // Use translation delta (not velocity) for smooth, proportional scrolling
        let delta = gr.translation(in: view)
        gr.setTranslation(.zero, in: view)
        let point = gr.location(in: view)
        inputMapper?.handleScroll(deltaX: delta.x, deltaY: delta.y, at: point, in: view.bounds.size)
    }

    @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
        switch gr.state {
        case .began: lastScale = scale
        case .changed:
            scale = max(1.0, min(4.0, lastScale * gr.scale))
            // Scale around the pinch center, not the view center
            let pinch = gr.location(in: view)
            let cx = view.bounds.midX, cy = view.bounds.midY
            let tx = (pinch.x - cx) * (1.0 - scale)
            let ty = (pinch.y - cy) * (1.0 - scale)
            mtkView.transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
        case .ended:
            if scale < 1.05 {
                UIView.animate(withDuration: 0.2) { self.mtkView.transform = .identity }
                scale = 1.0
            }
        default: break
        }
    }

    private func flashCursor(at point: CGPoint) {
        cursorView.center = point
        cursorView.isHidden = false
        cursorView.alpha = 1.0
        UIView.animate(withDuration: 0.3, delay: 0.1) {
            self.cursorView.alpha = 0
        } completion: { _ in
            self.cursorView.isHidden = true
            self.cursorView.alpha = 1
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
