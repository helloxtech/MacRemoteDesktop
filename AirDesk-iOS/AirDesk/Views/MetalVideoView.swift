import SwiftUI
import MetalKit
import CoreImage

class MetalVideoRenderer: NSObject, MTKViewDelegate {

    private var device: MTLDevice
    private var commandQueue: MTLCommandQueue
    private var ciContext: CIContext
    private var currentPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        super.init()
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        currentPixelBuffer = pixelBuffer
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = currentPixelBuffer
        lock.unlock()

        guard let pixelBuffer = pixelBuffer,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let drawableSize = view.drawableSize

        // Scale to fit with aspect ratio preserved
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let scaleX = drawableSize.width / imageSize.width
        let scaleY = drawableSize.height / imageSize.height
        let scale = min(scaleX, scaleY)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let originX = (drawableSize.width - scaledWidth) / 2
        let originY = (drawableSize.height - scaledHeight) / 2

        let transform = CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: originX / scale, y: originY / scale)
        let scaledImage = ciImage.transformed(by: transform)

        let destination = CIRenderDestination(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer
        ) { () -> MTLTexture in drawable.texture }

        try? ciContext.startTask(toRender: scaledImage, to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalVideoView: UIViewRepresentable {

    let displayIndex: Int
    @Binding var pixelBuffer: CVPixelBuffer?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black

        if let device = view.device, let renderer = MetalVideoRenderer(device: device) {
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if let buffer = pixelBuffer {
            context.coordinator.renderer?.updateFrame(buffer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var renderer: MetalVideoRenderer?
    }
}
