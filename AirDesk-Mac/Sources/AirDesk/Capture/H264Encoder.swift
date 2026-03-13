import VideoToolbox
import CoreMedia
import QuartzCore
import Foundation

protocol H264EncoderDelegate: AnyObject {
    func didEncodeFrame(_ data: Data, isKeyframe: Bool, displayIndex: Int, timestamp: Double)
}

class H264Encoder: NSObject, ScreenCaptureDelegate {

    weak var delegate: H264EncoderDelegate?
    private var sessions: [Int: VTCompressionSession] = [:]
    private let encoderQueue = DispatchQueue(label: "airdesk.encoder")
    private var frameCounters: [Int: Int] = [:]

    func didCaptureFrame(_ frame: CVPixelBuffer, displayIndex: Int) {
        encoderQueue.async { [weak self] in
            self?.encodeFrame(frame, displayIndex: displayIndex)
        }
    }

    private func encodeFrame(_ pixelBuffer: CVPixelBuffer, displayIndex: Int) {
        if sessions[displayIndex] == nil {
            createSession(for: pixelBuffer, displayIndex: displayIndex)
        }
        guard let session = sessions[displayIndex] else { return }

        let presentationTime = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameCounters[displayIndex, default: 0] += 1
        let forceKeyframe = (frameCounters[displayIndex]! % 60) == 1

        var frameProperties: CFDictionary? = nil
        if forceKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            // Read actual keyframe status from the sample buffer attachment instead of relying
            // on forceKeyframe — VT may produce a keyframe on its own (first frame, resolution change)
            let notSync = CMGetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_NotSync, attachmentModeOut: nil) as? Bool
            let isActualKeyframe = !(notSync ?? false)
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
        // 8 Mbps — appropriate for local WiFi; 2 Mbps caused visible blocking artefacts
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 8_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 60))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        // Disable frame reordering — eliminates B-frame decode delay for lower latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // CABAC gives better compression at same bitrate vs CAVLC (High profile supports it)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTCompressionSessionPrepareToEncodeFrames(session)

        sessions[displayIndex] = session
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer, displayIndex: Int, isKeyframe: Bool) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

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

        // Convert AVCC to Annex B
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        var rawData = Data(count: totalLength)
        rawData.withUnsafeMutableBytes { ptr in
            _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength, destination: ptr.baseAddress!)
        }

        var offset = 0
        while offset < rawData.count - 4 {
            let naluLength = rawData.withUnsafeBytes { bytes -> Int in
                let ptr = bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return Int(ptr[0]) << 24 | Int(ptr[1]) << 16 | Int(ptr[2]) << 8 | Int(ptr[3])
            }
            annexBData.append(contentsOf: [0, 0, 0, 1])
            annexBData.append(rawData[(offset + 4)..<(offset + 4 + naluLength)])
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
