import ScreenCaptureKit
import CoreGraphics
import Foundation

protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureFrame(_ frame: CVPixelBuffer, displayIndex: Int)
}

class ScreenCaptureManager: NSObject {

    weak var delegate: ScreenCaptureDelegate?
    private var streams: [SCStream] = []
    private var displays: [SCDisplay] = []
    private(set) var monitorInfos: [MonitorInfo] = []

    func startCapture() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                self.displays = content.displays
                self.monitorInfos = content.displays.enumerated().map { index, display in
                    MonitorInfo(
                        id: index,
                        width: display.width,
                        height: display.height,
                        scaleFactor: Float(NSScreen.screens.first(where: { Int($0.frame.width) == display.width })?.backingScaleFactor ?? 1.0),
                        name: "Display \(index + 1)"
                    )
                }

                for (index, display) in content.displays.enumerated() {
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = display.width
                    config.height = display.height
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.scalesToFit = false

                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "airdesk.capture.\(index)"))
                    try await stream.startCapture()
                    self.streams.append(stream)
                }
            } catch {
                print("ScreenCaptureManager error: \(error)")
            }
        }
    }

    func stopCapture() {
        for stream in streams {
            Task { try? await stream.stopCapture() }
        }
        streams.removeAll()
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let displayIndex = streams.firstIndex(of: stream) ?? 0
        delegate?.didCaptureFrame(pixelBuffer, displayIndex: displayIndex)
    }
}
