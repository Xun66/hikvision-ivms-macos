import Foundation

enum VideoCodec {
    case h264
    case h265
    case unknown
}

enum AudioCodec: Equatable {
    case pcmu
    case pcma
    case unknown(String)
    case none

    var isSupported: Bool {
        switch self {
        case .pcmu, .pcma: return true
        case .unknown, .none: return false
        }
    }
}

/// A single media stream parsed from an SDP body.
struct MediaDescription {
    var media: String = ""          // "video", "audio", ...
    var payloadType: Int = 96
    var codec: VideoCodec = .unknown
    var audioCodec: AudioCodec = .none
    var clockRate: Int = 0
    var channels: Int = 1
    var control: String = ""        // control attribute (relative or absolute)

    // Parameter sets extracted from the fmtp line (already base64-decoded).
    var vps: Data?                  // H.265 only
    var sps: Data?
    var pps: Data?

    var isVideo: Bool { media == "video" }
    var isAudio: Bool { media == "audio" }
}

/// Minimal SDP parser: enough to locate the video track, its codec, control
/// URL and out-of-band parameter sets.
struct SDPDescription {
    var sessionControl: String = ""
    var medias: [MediaDescription] = []

    var videoMedia: MediaDescription? { medias.first { $0.isVideo } }
    var audioMedia: MediaDescription? { medias.first { $0.isAudio && $0.audioCodec.isSupported } }

    static func parse(_ text: String) -> SDPDescription {
        var desc = SDPDescription()
        var current: MediaDescription?

        func flush() {
            if let c = current { desc.medias.append(c) }
            current = nil
        }

        // SDP lines are CRLF-separated but be lenient.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
        for raw in lines {
            let line = String(raw)
            guard line.count >= 2 else { continue }
            let type = line.first!
            let value = String(line.dropFirst(2)) // skip "x="

            switch type {
            case "m":
                flush()
                var m = MediaDescription()
                let parts = value.split(separator: " ").map(String.init)
                if let first = parts.first { m.media = first }
                if parts.count >= 4, let pt = Int(parts[3]) { m.payloadType = pt }
                current = m
            case "a":
                if current != nil {
                    parseMediaAttribute(value, into: &current!)
                } else if value.hasPrefix("control:") {
                    desc.sessionControl = String(value.dropFirst("control:".count))
                }
            default:
                break
            }
        }
        flush()
        return desc
    }

    private static func parseMediaAttribute(_ value: String, into m: inout MediaDescription) {
        if value.hasPrefix("control:") {
            m.control = String(value.dropFirst("control:".count))
        } else if value.hasPrefix("rtpmap:") {
            let up = value.uppercased()
            parseRTPMap(value, into: &m)
            if up.contains("H265") || up.contains("HEVC") {
                m.codec = .h265
            } else if up.contains("H264") {
                m.codec = .h264
            }
        } else if value.hasPrefix("fmtp:") {
            parseFmtp(String(value.dropFirst("fmtp:".count)), into: &m)
        }
    }

    private static func parseRTPMap(_ value: String, into m: inout MediaDescription) {
        let spec = value.dropFirst("rtpmap:".count)
        let afterPT = spec.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
        let parts = afterPT.split(separator: "/").map(String.init)
        guard let codec = parts.first?.uppercased() else { return }
        if parts.count >= 2, let rate = Int(parts[1]) {
            m.clockRate = rate
        }
        if parts.count >= 3, let channels = Int(parts[2]) {
            m.channels = max(1, channels)
        }

        guard m.isAudio else { return }
        switch codec {
        case "PCMU":
            m.audioCodec = .pcmu
            if m.clockRate == 0 { m.clockRate = 8_000 }
        case "PCMA":
            m.audioCodec = .pcma
            if m.clockRate == 0 { m.clockRate = 8_000 }
        default:
            m.audioCodec = .unknown(codec)
        }
    }

    private static func parseFmtp(_ value: String, into m: inout MediaDescription) {
        // Drop the leading payload type number.
        let afterPT = value.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
        let params = afterPT.split(separator: ";")
        for param in params {
            let kv = param.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let val = kv[1]
            switch key {
            case "sprop-parameter-sets":
                // H.264: comma-separated base64 NAL units, typically SPS,PPS.
                let sets = val.split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
                if sets.count >= 1 { m.sps = sets[0] }
                if sets.count >= 2 { m.pps = sets[1] }
            case "sprop-vps":
                m.vps = Data(base64Encoded: val)
            case "sprop-sps":
                m.sps = Data(base64Encoded: val)
            case "sprop-pps":
                m.pps = Data(base64Encoded: val)
            default:
                break
            }
        }
    }
}
