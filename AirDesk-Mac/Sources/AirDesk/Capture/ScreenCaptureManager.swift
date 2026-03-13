import ScreenCaptureKit
import CoreGraphics
import Foundation

protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureFrame(_ frame: CVPixelBuffer, displayIndex: Int)
}

class ScreenCaptureManager: NSObject {

    weak var delegate: ScreenCaptureDelegate?
    private var streams: [SCStream] = []
    private var streamIndexMap: [ObjectIdentifier: Int] = [:]
    private(set) var monitorInfos: [MonitorInfo] = []
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "airdesk.capture.manager")

    func startCapture() {
        captureQueue.async { [weak self] in
            guard let self, !self.isCapturing else { return }
            self.isCapturing = true
            Task { await self.beginCapture() }
        }
    }

    func stopCapture() {
        captureQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.isCapturing = false
            let streamsToStop = self.streams
            self.streams.removeAll()
            self.streamIndexMap.removeAll()
            self.monitorInfos.removeAll()
            Task {
                for stream in streamsToStop {
                    try? await stream.stopCapture()
                }
            }
        }
    }

    private func beginCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let screens = NSScreen.screens

            // Sort displays by displayID so index ordering is deterministic and matches
            // CGGetActiveDisplayList (which also returns displays sorted by ID).
            let sortedDisplays = content.displays.sorted { $0.displayID < $1.displayID }

            let infos: [MonitorInfo] = sortedDisplays.enumerated().map { index, display in
                let scale = screens.first(where: { Int($0.frame.width * $0.backingScaleFactor) == display.width })?.backingScaleFactor ?? 1.0
                return MonitorInfo(id: index, width: display.width, height: display.height, scaleFactor: Float(scale), name: "Display \(index + 1)")
            }

            captureQueue.async { self.monitorInfos = infos }

            for (index, display) in sortedDisplays.enumerated() {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.scalesToFit = false

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "airdesk.capture.\(index)"))

                // Register the stream→index mapping BEFORE startCapture() so that
                // didOutputSampleBuffer can always find the correct displayIndex.
                captureQueue.sync {
                    self.streams.append(stream)
                    self.streamIndexMap[ObjectIdentifier(stream)] = index
                }

                try await stream.startCapture()
            }
        } catch {
            captureQueue.async { self.isCapturing = false }
            print("ScreenCaptureManager error: \(error)")
        }
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let displayIndex = streamIndexMap[ObjectIdentifier(stream)] ?? 0
        delegate?.didCaptureFrame(pixelBuffer, displayIndex: displayIndex)
    }
}
