import VideoToolbox
import CoreMedia
import QuartzCore
import Foundation

class VideoDecoder {

    let displayIndex: Int
    var frameHandler: ((CVPixelBuffer, Int) -> Void)?
    var recoveryHandler: ((Int) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var waitingForKeyframe = true
    private var lastRecoveryRequestTime: CFAbsoluteTime = 0

    init(displayIndex: Int) {
        self.displayIndex = displayIndex
    }

    // MARK: - Single-pass NALU structure

    private struct NALUnit {
        let type: UInt8
        let offset: Int   // byte offset of NALU data (after start code)
        let length: Int   // byte length of NALU data
    }

    private func parseNALUnits(from data: Data, payloadOffset: Int) -> [NALUnit] {
        var nalus: [NALUnit] = []
        var offset = payloadOffset

        while offset < data.count - 4 {
            guard data[offset] == 0, data[offset+1] == 0,
                  data[offset+2] == 0, data[offset+3] == 1 else {
                offset += 1
                continue
            }
            offset += 4
            guard offset < data.count else { break }

            let naluType = data[offset] & 0x1F
            var end = offset + 1
            while end < data.count - 3 {
                if data[end] == 0 && data[end+1] == 0 && data[end+2] == 0 && data[end+3] == 1 { break }
                end += 1
            }
            if end >= data.count - 3 { end = data.count }

            nalus.append(NALUnit(type: naluType, offset: offset, length: end - offset))
            offset = end
        }
        return nalus
    }

    // MARK: - Decode (single pass)

    func decode(_ packetData: Data, payloadOffset: Int, isKeyframe: Bool) {
        if waitingForKeyframe && !isKeyframe { return }

        // Single pass: parse all NALUs, extract SPS/PPS, and build AVCC
        let nalus = parseNALUnits(from: packetData, payloadOffset: payloadOffset)

        if isKeyframe {
            var newSPS: Data?
            var newPPS: Data?
            for nalu in nalus {
                if nalu.type == 7 { newSPS = Data(packetData[nalu.offset..<(nalu.offset + nalu.length)]) }
                if nalu.type == 8 { newPPS = Data(packetData[nalu.offset..<(nalu.offset + nalu.length)]) }
            }
            if let sps = newSPS, let pps = newPPS {
                let parametersChanged = spsData != sps || ppsData != pps
                spsData = sps
                ppsData = pps
                if parametersChanged {
                    formatDescription = nil
                    if let session {
                        VTDecompressionSessionWaitForAsynchronousFrames(session)
                        VTDecompressionSessionInvalidate(session)
                    }
                    session = nil
                    createFormatDescription()
                }
            }
        } else if waitingForKeyframe {
            return
        }

        guard formatDescription != nil || createFormatDescription() else { return }
        guard session != nil || createSession() else { return }

        // Build AVCC from video NALUs only (skip SPS=7, PPS=8)
        var avccData = Data(capacity: max(0, packetData.count - payloadOffset))
        for nalu in nalus where nalu.type != 7 && nalu.type != 8 {
            var lengthBE = UInt32(nalu.length).bigEndian
            avccData.append(Data(bytes: &lengthBE, count: 4))
            avccData.append(packetData[nalu.offset..<(nalu.offset + nalu.length)])
        }
        guard !avccData.isEmpty else { return }

        guard let sampleBuffer = createSampleBuffer(avccData: avccData) else { return }

        let flags = VTDecodeFrameFlags()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sampleBuffer, flags: flags, frameRefcon: nil, infoFlagsOut: &infoFlags)
        if status == noErr {
            waitingForKeyframe = false
        } else {
            handleDecodeError(status)
        }
    }

    // MARK: - Session setup

    @discardableResult
    private func createFormatDescription() -> Bool {
        guard let sps = spsData, let pps = ppsData else { return false }

        var status: OSStatus = noErr
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress,
                      let ppsBase = ppsPtr.baseAddress else { return }
                var paramPtrs: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var paramSizes: [Int] = [sps.count, pps.count]
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &paramPtrs,
                    parameterSetSizes: &paramSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        return status == noErr
    }

    private func createSession() -> Bool {
        guard let formatDescription = formatDescription else { return false }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        // Prefer hardware decoder for lower latency and power usage
        var decoderSpec: [CFString: Any] = [:]
        if #available(iOS 17.0, *) {
            decoderSpec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
        }

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer = imageBuffer else {
                    if let refCon {
                        let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                        decoder.handleDecodeError(status)
                    }
                    return
                }
                let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon!).takeUnretainedValue()
                decoder.frameHandler?(imageBuffer, decoder.displayIndex)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        return status == noErr
    }

    private func createSampleBuffer(avccData: Data) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avccData.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avccData.count, flags: 0, blockBufferOut: &blockBuffer)
        guard let blockBuffer = blockBuffer else { return nil }
        _ = avccData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avccData.count)
        }

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000), decodeTimeStamp: .invalid)
        var timingCopy = timing
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingCopy, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    private func handleDecodeError(_ status: OSStatus) {
        NSLog("[AirDesk] VT decode error display=%d status=%d", displayIndex, Int(status))
        resetDecodeSession(waitForFrames: false)
        waitingForKeyframe = true
        requestRecoveryKeyframeIfNeeded()
    }

    private func requestRecoveryKeyframeIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRecoveryRequestTime >= 0.75 else { return }
        lastRecoveryRequestTime = now
        recoveryHandler?(displayIndex)
    }

    private func resetDecodeSession(waitForFrames: Bool) {
        if let session {
            if waitForFrames {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    func close() {
        frameHandler = nil
        recoveryHandler = nil
        resetDecodeSession(waitForFrames: true)
        waitingForKeyframe = true
    }

    deinit {
        close()
    }
}
