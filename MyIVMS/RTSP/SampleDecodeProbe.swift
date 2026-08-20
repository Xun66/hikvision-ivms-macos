import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class SampleDecodeProbe {
    private let codec: VideoCodec
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var attempts = 0
    private var failures = 0
    private var loggedSuccess = false

    init(codec: VideoCodec) {
        self.codec = codec
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    func inspect(_ sample: CMSampleBuffer) {
        guard !loggedSuccess, attempts < 12 else { return }
        attempts += 1

        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            logFailure("missing format description")
            return
        }

        guard ensureSession(format: format) else { return }
        guard let session else { return }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sample,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: &infoFlags)
        if status != noErr {
            logFailure("decode submit failed status=\(status)")
            return
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    private func ensureSession(format: CMFormatDescription) -> Bool {
        if let sessionFormat, CMFormatDescriptionEqual(sessionFormat, otherFormatDescription: format), session != nil {
            return true
        }

        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        sessionFormat = nil

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: sampleDecodeProbeOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: &callback,
                                                  decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            logFailure("session create failed status=\(status)")
            return false
        }

        session = newSession
        sessionFormat = format
        return true
    }

    fileprivate func handleDecode(status: OSStatus, imageBuffer: CVImageBuffer?) {
        if status == noErr, let imageBuffer {
            loggedSuccess = true
            let width = CVPixelBufferGetWidth(imageBuffer)
            let height = CVPixelBufferGetHeight(imageBuffer)
            Log.info("VideoToolbox probe decoded first \(codec) frame: \(width)x\(height)")
        } else {
            logFailure("callback status=\(status), imageBuffer=\(imageBuffer != nil)")
        }
    }

    private func logFailure(_ message: String) {
        failures += 1
        if failures <= 5 {
            Log.info("VideoToolbox probe failed: \(message)")
        }
    }
}

private func sampleDecodeProbeOutputCallback(decompressionOutputRefCon: UnsafeMutableRawPointer?,
                                             sourceFrameRefCon: UnsafeMutableRawPointer?,
                                             status: OSStatus,
                                             infoFlags: VTDecodeInfoFlags,
                                             imageBuffer: CVImageBuffer?,
                                             presentationTimeStamp: CMTime,
                                             presentationDuration: CMTime) {
    guard let decompressionOutputRefCon else { return }
    let probe = Unmanaged<SampleDecodeProbe>.fromOpaque(decompressionOutputRefCon).takeUnretainedValue()
    probe.handleDecode(status: status, imageBuffer: imageBuffer)
}
