import VideoToolbox
import CoreMedia
import QuartzCore
import Foundation

class VideoDecoder {

    let displayIndex: Int
    var frameHandler: ((CVPixelBuffer, Int) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    init(displayIndex: Int) {
        self.displayIndex = displayIndex
    }

    func decode(_ annexBData: Data, isKeyframe: Bool) {
        if isKeyframe {
            extractParameterSets(from: annexBData)
        }
        guard formatDescription != nil || createFormatDescription() else { return }
        guard session != nil || createSession() else { return }

        guard let sampleBuffer = createSampleBuffer(from: annexBData) else { return }

        var flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sampleBuffer, flags: flags, frameRefcon: nil, infoFlagsOut: &infoFlags)
    }

    private func extractParameterSets(from data: Data) {
        var sps: Data?
        var pps: Data?
        var offset = 0

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

            let naluData = data[offset..<end]
            if naluType == 7 { sps = Data(naluData) }
            if naluType == 8 { pps = Data(naluData) }
            offset = end
        }

        if let sps = sps, let pps = pps {
            self.spsData = sps
            self.ppsData = pps
            formatDescription = nil
            session = nil
            createFormatDescription()
        }
    }

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

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let imageBuffer = imageBuffer else {
                    if status != noErr {
                        NSLog("[AirDesk] VT decode error: %d", Int(status))
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
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        return status == noErr
    }

    private func createSampleBuffer(from annexBData: Data) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription else { return nil }

        // Convert Annex B to AVCC
        var avccData = Data()
        var offset = 0
        while offset < annexBData.count - 4 {
            guard annexBData[offset] == 0, annexBData[offset+1] == 0,
                  annexBData[offset+2] == 0, annexBData[offset+3] == 1 else {
                offset += 1
                continue
            }
            offset += 4
            var end = offset
            while end < annexBData.count - 3 {
                if annexBData[end] == 0 && annexBData[end+1] == 0 && annexBData[end+2] == 0 && annexBData[end+3] == 1 { break }
                end += 1
            }
            if end >= annexBData.count - 3 { end = annexBData.count }
            let naluLen = end - offset
            var lengthBE = UInt32(naluLen).bigEndian
            avccData.append(Data(bytes: &lengthBE, count: 4))
            avccData.append(annexBData[offset..<end])
            offset = end
        }

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avccData.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avccData.count, flags: 0, blockBufferOut: &blockBuffer)
        guard let blockBuffer = blockBuffer else { return nil }
        avccData.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avccData.count)
        }

        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000), decodeTimeStamp: .invalid)
        var timingCopy = timing
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingCopy, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    deinit {
        if let session = session { VTDecompressionSessionInvalidate(session) }
    }
}

