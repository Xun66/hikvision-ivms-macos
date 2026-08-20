import Foundation
import CoreMedia
import VideoToolbox

/// Assembles NAL units into access units and wraps them in `CMSampleBuffer`s
/// ready to be enqueued into an `AVSampleBufferDisplayLayer`, which performs
/// hardware decoding via VideoToolbox. No third-party code involved.
final class VideoDecoder {
    private let codec: VideoCodec

    /// Called on the decode queue with each decodable frame.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMFormatDescription?
    private lazy var decodeProbe = SampleDecodeProbe(codec: codec)

    private var accessUnit: [Data] = []      // pending VCL NAL units for the current frame
    private var firstRTPTimestamp: UInt32?
    private var hasSeenKeyframe = false

    init(codec: VideoCodec) {
        self.codec = codec
    }

    /// Seed parameter sets from SDP (out-of-band). Optional — many devices also
    /// send them in-band, which we pick up in `append`.
    func setParameterSets(vps: Data?, sps: Data?, pps: Data?) {
        if let vps { self.vps = vps }
        if let sps { self.sps = sps }
        if let pps { self.pps = pps }
        rebuildFormatDescription()
    }

    /// Feed a reassembled NAL unit.
    func append(nal: Data) {
        guard let first = nal.first else { return }

        switch codec {
        case .h264:
            let type = first & 0x1F
            switch type {
            case 7: updateH264ParameterSet(sps: nal, pps: nil)
            case 8: updateH264ParameterSet(sps: nil, pps: nal)
            case 9: break // access unit delimiter — ignore
            case 6: break // SEI — ignore
            default: accessUnit.append(nal) // VCL (1, 5, ...)
            }
        case .h265:
            let type = (first >> 1) & 0x3F
            switch type {
            case 32: updateH265ParameterSet(vps: nal, sps: nil, pps: nil)
            case 33: updateH265ParameterSet(vps: nil, sps: nal, pps: nil)
            case 34: updateH265ParameterSet(vps: nil, sps: nil, pps: nal)
            case 0...31: accessUnit.append(nal) // VCL
            case 35...40: break // AUD / EOS / EOB / filler / SEI
            default: break
            }
        case .unknown:
            break
        }
    }

    /// Called at a frame boundary — flush the accumulated access unit.
    func frameBoundary(rtpTimestamp: UInt32) {
        defer { accessUnit.removeAll(keepingCapacity: true) }
        guard !accessUnit.isEmpty else { return }
        let isKeyframe = containsKeyframe(nalUnits: accessUnit)
        guard hasSeenKeyframe || isKeyframe else {
            if !warnedWaitingForKeyframe {
                warnedWaitingForKeyframe = true
                Log.info("dropping frames: waiting for first keyframe")
            }
            return
        }
        guard let format = formatDescription else {
            if !warnedNoFormat { warnedNoFormat = true; Log.info("dropping frames: no format description yet") }
            return
        }
        guard let sampleBuffer = makeSampleBuffer(nalUnits: accessUnit,
                                                  format: format,
                                                  rtpTimestamp: rtpTimestamp,
                                                  isKeyframe: isKeyframe) else {
            Log.info("makeSampleBuffer FAILED"); return
        }
        if isKeyframe { hasSeenKeyframe = true }
        producedSamples += 1
        if producedSamples == 1 { Log.info("first decodable sample produced") }
        decodeProbe.inspect(sampleBuffer)
        onSampleBuffer?(sampleBuffer)
    }

    private var warnedNoFormat = false
    private var warnedWaitingForKeyframe = false
    private var producedSamples = 0

    // MARK: Format description

    private func rebuildFormatDescription() {
        let had = formatDescription != nil
        switch codec {
        case .h264:
            guard let sps, let pps else { return }
            formatDescription = Self.h264FormatDescription(sps: sps, pps: pps)
        case .h265:
            guard let vps, let sps, let pps else { return }
            formatDescription = Self.h265FormatDescription(vps: vps, sps: sps, pps: pps)
        case .unknown:
            break
        }
        if !had, let format = formatDescription {
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            Log.info("format description ready: \(dim.width)x\(dim.height)")
        } else if formatDescription == nil {
            Log.info("format description build FAILED (sps/pps/vps invalid)")
        }
    }

    private func updateH264ParameterSet(sps newSPS: Data?, pps newPPS: Data?) {
        let candidateSPS = newSPS ?? sps
        let candidatePPS = newPPS ?? pps
        guard let candidateSPS, let candidatePPS else {
            if let newSPS { sps = newSPS }
            if let newPPS { pps = newPPS }
            return
        }

        guard let candidateFormat = Self.h264FormatDescription(sps: candidateSPS, pps: candidatePPS) else {
            Log.info("ignoring invalid in-band H.264 parameter set")
            return
        }
        sps = candidateSPS
        pps = candidatePPS
        setFormatDescription(candidateFormat)
    }

    private func updateH265ParameterSet(vps newVPS: Data?, sps newSPS: Data?, pps newPPS: Data?) {
        let candidateVPS = newVPS ?? vps
        let candidateSPS = newSPS ?? sps
        let candidatePPS = newPPS ?? pps
        guard let candidateVPS, let candidateSPS, let candidatePPS else {
            if let newVPS { vps = newVPS }
            if let newSPS { sps = newSPS }
            if let newPPS { pps = newPPS }
            return
        }

        guard let candidateFormat = Self.h265FormatDescription(vps: candidateVPS, sps: candidateSPS, pps: candidatePPS) else {
            Log.info("ignoring invalid in-band H.265 parameter set")
            return
        }
        vps = candidateVPS
        sps = candidateSPS
        pps = candidatePPS
        setFormatDescription(candidateFormat)
    }

    private func setFormatDescription(_ format: CMFormatDescription) {
        let had = formatDescription != nil
        formatDescription = format
        if !had {
            let dim = CMVideoFormatDescriptionGetDimensions(format)
            Log.info("format description ready: \(dim.width)x\(dim.height)")
        }
    }

    private static func h264FormatDescription(sps: Data, pps: Data) -> CMFormatDescription? {
        var format: CMFormatDescription?
        let spsArr = [UInt8](sps)
        let ppsArr = [UInt8](pps)
        return spsArr.withUnsafeBufferPointer { spsPtr in
            ppsArr.withUnsafeBufferPointer { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes: [Int] = [spsArr.count, ppsArr.count]
                let status = pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sp in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!,
                            parameterSetSizes: sp.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
                return status == noErr ? format : nil
            }
        }
    }

    private static func h265FormatDescription(vps: Data, sps: Data, pps: Data) -> CMFormatDescription? {
        var format: CMFormatDescription?
        let vpsArr = [UInt8](vps)
        let spsArr = [UInt8](sps)
        let ppsArr = [UInt8](pps)
        return vpsArr.withUnsafeBufferPointer { v in
            spsArr.withUnsafeBufferPointer { s in
                ppsArr.withUnsafeBufferPointer { p in
                    let pointers: [UnsafePointer<UInt8>] = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                    let sizes: [Int] = [vpsArr.count, spsArr.count, ppsArr.count]
                    let status = pointers.withUnsafeBufferPointer { pp in
                        sizes.withUnsafeBufferPointer { sp in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pp.baseAddress!,
                                parameterSetSizes: sp.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &format)
                        }
                    }
                    return status == noErr ? format : nil
                }
            }
        }
    }

    // MARK: Sample buffer

    /// Build an AVCC/HVCC elementary stream (4-byte length prefixed) and wrap
    /// it in a `CMSampleBuffer`, tagged to display immediately.
    private func makeSampleBuffer(nalUnits: [Data],
                                  format: CMFormatDescription,
                                  rtpTimestamp: UInt32,
                                  isKeyframe: Bool) -> CMSampleBuffer? {
        var elementaryStream = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { elementaryStream.append(contentsOf: $0) }
            elementaryStream.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let dataLength = elementaryStream.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = elementaryStream.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        let presentationTime = presentationTime(for: rtpTimestamp)
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sample = sampleBuffer else { return nil }

        // Tag to be displayed as soon as it is decoded (we rely on the server's
        // pacing / RTSP Scale for playback speed).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyframe {
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        return sample
    }

    private func presentationTime(for rtpTimestamp: UInt32) -> CMTime {
        if firstRTPTimestamp == nil { firstRTPTimestamp = rtpTimestamp }
        let delta = rtpTimestamp &- (firstRTPTimestamp ?? rtpTimestamp)
        return CMTime(value: CMTimeValue(delta), timescale: 90_000)
    }

    private func containsKeyframe(nalUnits: [Data]) -> Bool {
        switch codec {
        case .h264:
            return nalUnits.contains { nal in
                guard let first = nal.first else { return false }
                return (first & 0x1F) == 5
            }
        case .h265:
            return nalUnits.contains { nal in
                guard let first = nal.first else { return false }
                let type = (first >> 1) & 0x3F
                return (16...21).contains(type)
            }
        case .unknown:
            return false
        }
    }
}
