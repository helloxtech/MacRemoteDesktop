import VideoToolbox
import CoreMedia
import CoreGraphics
import QuartzCore
import Foundation

protocol H264EncoderDelegate: AnyObject {
    func didEncodeFrame(_ data: Data, isKeyframe: Bool, displayIndex: Int, timestamp: Double)
}

class H264Encoder: NSObject, ScreenCaptureDelegate {

    weak var delegate: H264EncoderDelegate?
    private var sessions: [Int: VTCompressionSession] = [:]
    private var sessionSizes: [Int: CGSize] = [:]
    private let encoderQueue = DispatchQueue(label: "airdesk.encoder")
    private var frameCounters: [Int: Int] = [:]
    private var pendingKeyframe: Set<Int> = []

    /// Force a keyframe on all active display streams on the next encoded frame.
    func forceKeyframeOnNextFrame() {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            for key in self.sessions.keys { self.pendingKeyframe.insert(key) }
        }
    }

    func didCaptureFrame(_ frame: CVPixelBuffer, displayIndex: Int) {
        encoderQueue.async { [weak self] in
            self?.encodeFrame(frame, displayIndex: displayIndex)
        }
    }

    func resetAllSessions() {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            for session in self.sessions.values {
                VTCompressionSessionInvalidate(session)
            }
            self.sessions.removeAll()
            self.sessionSizes.removeAll()
            self.frameCounters.removeAll()
            self.pendingKeyframe.removeAll()
        }
    }

    /// Capture the screen directly via Core Graphics and encode immediately.
    /// Bypasses ScreenCaptureKit, so it works even when the screen is static.
    /// Encodes as a P-frame (not keyframe) to keep frame size small for fast delivery.
    func captureAndEncodeImmediate(displayIndex: Int) {
        encoderQueue.async { [weak self] in
            guard let self else { return }
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            let sorted = displays.sorted()
            guard displayIndex < sorted.count else { return }
            guard let cgImage = CGDisplayCreateImage(sorted[displayIndex]) else { return }
            guard let pixelBuffer = self.pixelBuffer(from: cgImage) else { return }
            self.encodeFrame(pixelBuffer, displayIndex: displayIndex)
        }
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    private func encodeFrame(_ pixelBuffer: CVPixelBuffer, displayIndex: Int) {
        ensureSessionMatches(pixelBuffer: pixelBuffer, displayIndex: displayIndex)
        if sessions[displayIndex] == nil {
            createSession(for: pixelBuffer, displayIndex: displayIndex)
        }
        guard let session = sessions[displayIndex] else { return }

        let presentationTime = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameCounters[displayIndex, default: 0] += 1
        let forced = pendingKeyframe.remove(displayIndex) != nil
        let forceKeyframe = forced || (frameCounters[displayIndex]! % 60) == 1

        var frameProperties: CFDictionary? = nil
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            // Read keyframe status from the per-sample attachment array.
            // CMGetAttachment reads buffer-level and returns nil for this key,
            // so we must use the per-sample array instead.
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
            let dependsOnOthers = attachments?.first?[kCMSampleAttachmentKey_DependsOnOthers] as? Bool ?? false
            let isActualKeyframe = !dependsOnOthers
            self?.handleEncodedFrame(sampleBuffer, displayIndex: displayIndex, isKeyframe: isActualKeyframe)
        }
    }

    private func createSession(for pixelBuffer: CVPixelBuffer, displayIndex: Int) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // 15 Mbps — keeps text crisp on local WiFi; hardware encoder handles this easily
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 15_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        // Disable frame reordering — eliminates B-frame decode delay for lower latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // CABAC gives better compression at same bitrate vs CAVLC (High profile supports it)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTCompressionSessionPrepareToEncodeFrames(session)

        sessions[displayIndex] = session
        sessionSizes[displayIndex] = CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private func ensureSessionMatches(pixelBuffer: CVPixelBuffer, displayIndex: Int) {
        let size = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        )
        if let currentSize = sessionSizes[displayIndex], currentSize != size {
            invalidateSession(for: displayIndex)
        }
    }

    private func invalidateSession(for displayIndex: Int) {
        if let session = sessions.removeValue(forKey: displayIndex) {
            VTCompressionSessionInvalidate(session)
        }
        sessionSizes.removeValue(forKey: displayIndex)
        frameCounters.removeValue(forKey: displayIndex)
        pendingKeyframe.remove(displayIndex)
    }

    private var encodeLogCounter = 0

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer, displayIndex: Int, isKeyframe: Bool) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        encodeLogCounter += 1
        if encodeLogCounter <= 3 || encodeLogCounter % 300 == 0 {
            print("[AirDesk] Encoded frame #\(encodeLogCounter) display=\(displayIndex) keyframe=\(isKeyframe)")
        }

        var annexBData = Data()

        // Extract SPS and PPS for keyframes
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)

            for i in 0..<parameterSetCount {
                var paramSet: UnsafePointer<UInt8>?
                var paramSetSize = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: i, parameterSetPointerOut: &paramSet, parameterSetSizeOut: &paramSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let paramSet = paramSet {
                    annexBData.append(contentsOf: [0, 0, 0, 1])
                    annexBData.append(UnsafeBufferPointer(start: paramSet, count: paramSetSize))
                }
            }
        }

        // Convert AVCC to Annex B — zero-copy via CMBlockBuffer pointer
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        annexBData.reserveCapacity(annexBData.count + totalLength + 16)

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0
        var totalLengthOut = 0
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLengthOut, dataPointerOut: &dataPointer) == noErr,
              let rawPtr = dataPointer else { return }

        var offset = 0
        while offset < totalLengthOut - 4 {
            let p = rawPtr.advanced(by: offset)
            let naluLength = Int(UInt8(bitPattern: p[0])) << 24 | Int(UInt8(bitPattern: p[1])) << 16 |
                             Int(UInt8(bitPattern: p[2])) << 8  | Int(UInt8(bitPattern: p[3]))
            annexBData.append(contentsOf: [0, 0, 0, 1])
            annexBData.append(UnsafeBufferPointer(start: UnsafeRawPointer(p.advanced(by: 4)).assumingMemoryBound(to: UInt8.self),
                                                  count: naluLength))
            offset += 4 + naluLength
        }

        let timestamp = CACurrentMediaTime()
        delegate?.didEncodeFrame(annexBData, isKeyframe: isKeyframe, displayIndex: displayIndex, timestamp: timestamp)
    }

    deinit {
        for session in sessions.values {
            VTCompressionSessionInvalidate(session)
        }
    }
}
