import ScreenCaptureKit
import CoreGraphics
import Foundation
import AppKit

protocol ScreenCaptureDelegate: AnyObject {
    func didCaptureFrame(_ frame: CVPixelBuffer, displayIndex: Int)
}

class ScreenCaptureManager: NSObject {

    weak var delegate: ScreenCaptureDelegate?
    var monitorConfigurationDidChange: (([MonitorInfo]) -> Void)?
    private var streams: [SCStream] = []
    private var streamIndexMap: [ObjectIdentifier: Int] = [:]
    private(set) var monitorInfos: [MonitorInfo] = []
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "airdesk.capture.manager")
    private var frameLogCounter = 0
    private var screenParametersObserver: Any?
    private var lockStatusObserver: Any?
    private var pendingRestartWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleCaptureRestart(reason: "display configuration changed")
        }
        lockStatusObserver = NotificationCenter.default.addObserver(
            forName: .screenLockStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isLocked = notification.object as? Bool, !isLocked else { return }
            self?.scheduleCaptureRestart(reason: "screen unlocked")
        }
    }

    deinit {
        pendingRestartWorkItem?.cancel()
        if let observer = screenParametersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = lockStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
            self.pendingRestartWorkItem?.cancel()
            self.pendingRestartWorkItem = nil
            let streamsToStop = self.streams
            self.streams.removeAll()
            self.streamIndexMap.removeAll()
            self.monitorInfos.removeAll()
            self.frameLogCounter = 0
            Task {
                for stream in streamsToStop {
                    try? await stream.stopCapture()
                }
            }
        }
    }

    func currentMonitorInfos() -> [MonitorInfo] {
        captureQueue.sync { monitorInfos }
    }

    private func beginCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let activeDisplayIDs = Self.activeDisplayIDs()
            let scaleByDisplayID = Self.scaleFactorsByDisplayID()
            let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            // Use the active CG display list as the source of truth so capture,
            // input injection, and immediate refresh captures all agree on index order.
            let sortedDisplays = activeDisplayIDs.isEmpty
                ? content.displays.sorted { $0.displayID < $1.displayID }
                : activeDisplayIDs.compactMap { displaysByID[$0] }
            print("[AirDesk] Found \(sortedDisplays.count) active displays, \(NSScreen.screens.count) NSScreens")

            let infos: [MonitorInfo] = sortedDisplays.enumerated().map { index, display in
                let scale = scaleByDisplayID[display.displayID] ?? 1.0
                print("[AirDesk] Display \(index): \(display.width)x\(display.height) scale=\(scale) id=\(display.displayID)")
                return MonitorInfo(id: index, width: display.width, height: display.height, scaleFactor: Float(scale), name: "Display \(index + 1)")
            }

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
                print("[AirDesk] Started capture for display \(index)")
            }

            captureQueue.async {
                self.monitorInfos = infos
                self.monitorConfigurationDidChange?(infos)
            }
        } catch {
            captureQueue.async { self.isCapturing = false }
            print("[AirDesk] ScreenCaptureManager error: \(error)")
        }
    }

    private func scheduleCaptureRestart(reason: String) {
        captureQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            self.pendingRestartWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isCapturing else { return }
                Task { await self.restartCapture(reason: reason) }
            }
            self.pendingRestartWorkItem = workItem
            self.captureQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
    }

    private func restartCapture(reason: String) async {
        print("[AirDesk] Restarting capture: \(reason)")
        let streamsToStop = captureQueue.sync { () -> [SCStream] in
            let currentStreams = streams
            streams.removeAll()
            streamIndexMap.removeAll()
            monitorInfos.removeAll()
            frameLogCounter = 0
            return currentStreams
        }
        for stream in streamsToStop {
            try? await stream.stopCapture()
        }
        await beginCapture()
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return Array(displays.prefix(Int(count))).sorted()
    }

    private static func scaleFactorsByDisplayID() -> [CGDirectDisplayID: CGFloat] {
        var result: [CGDirectDisplayID: CGFloat] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            result[CGDirectDisplayID(number.uint32Value)] = screen.backingScaleFactor
        }
        return result
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let displayIndex = streamIndexMap[ObjectIdentifier(stream)] ?? 0
        frameLogCounter += 1
        if frameLogCounter <= 3 || frameLogCounter % 300 == 0 {
            print("[AirDesk] SCK frame #\(frameLogCounter) display=\(displayIndex) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        delegate?.didCaptureFrame(pixelBuffer, displayIndex: displayIndex)
    }
}
