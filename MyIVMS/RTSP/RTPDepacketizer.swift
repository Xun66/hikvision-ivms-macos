import Foundation

/// Turns a stream of RTP packets into complete NAL units and access-unit
/// (frame) boundaries. Supports the packetization modes Hikvision actually
/// uses: single NAL, STAP-A / aggregation, and FU-A / FU fragmentation, for
/// both H.264 and H.265.
final class RTPDepacketizer {
    let codec: VideoCodec

    /// Emitted for each fully-reassembled NAL unit (raw, no start code / length prefix).
    var onNAL: ((Data) -> Void)?
    /// Emitted when a frame boundary is detected (RTP marker bit).
    var onFrameBoundary: ((UInt32) -> Void)?

    private var fuBuffer: Data?

    init(codec: VideoCodec) {
        self.codec = codec
    }

    func handle(_ packet: Data) {
        guard packet.count > 12 else { return }
        let bytes = [UInt8](packet)

        let cc = Int(bytes[0] & 0x0F)
        let hasExtension = (bytes[0] & 0x10) != 0
        let hasPadding = (bytes[0] & 0x20) != 0
        let marker = (bytes[1] & 0x80) != 0
        let timestamp = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16)
            | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])

        var offset = 12 + cc * 4
        if hasExtension {
            guard offset + 4 <= bytes.count else { return }
            let extLen = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + extLen * 4
        }
        guard offset < bytes.count else { return }

        let payloadEnd: Int
        if hasPadding, let padding = bytes.last, padding > 0 {
            payloadEnd = bytes.count - Int(padding)
            guard offset < payloadEnd else { return }
        } else {
            payloadEnd = bytes.count
        }

        let payload = Array(bytes[offset..<payloadEnd])

        switch codec {
        case .h264:
            handleH264(payload)
        case .h265:
            handleH265(payload)
        case .unknown:
            break
        }

        if marker {
            onFrameBoundary?(timestamp)
        }
    }

    // MARK: H.264

    private func handleH264(_ payload: [UInt8]) {
        guard let first = payload.first else { return }
        let nalType = first & 0x1F

        switch nalType {
        case 1...23:
            onNAL?(Data(payload))
        case 24: // STAP-A: aggregation of multiple NAL units
            var i = 1
            while i + 2 <= payload.count {
                let size = (Int(payload[i]) << 8) | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.count else { break }
                onNAL?(Data(payload[i..<(i + size)]))
                i += size
            }
        case 28: // FU-A: fragmentation unit
            guard payload.count > 2 else { return }
            let fuHeader = payload[1]
            let start = (fuHeader & 0x80) != 0
            let end = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x1F
            if start {
                let reconstructedHeader = (payload[0] & 0xE0) | originalType
                fuBuffer = Data([reconstructedHeader])
                fuBuffer?.append(contentsOf: payload[2...])
            } else if fuBuffer != nil {
                fuBuffer?.append(contentsOf: payload[2...])
            }
            if end, let complete = fuBuffer {
                onNAL?(complete)
                fuBuffer = nil
            }
        default:
            break
        }
    }

    // MARK: H.265 (HEVC)

    private func handleH265(_ payload: [UInt8]) {
        guard payload.count >= 2 else { return }
        let nalType = (payload[0] >> 1) & 0x3F

        switch nalType {
        case 0...47:
            onNAL?(Data(payload))
        case 48: // Aggregation packet
            var i = 2
            while i + 2 <= payload.count {
                let size = (Int(payload[i]) << 8) | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.count else { break }
                onNAL?(Data(payload[i..<(i + size)]))
                i += size
            }
        case 49: // Fragmentation unit
            guard payload.count > 3 else { return }
            let fuHeader = payload[2]
            let start = (fuHeader & 0x80) != 0
            let end = (fuHeader & 0x40) != 0
            let originalType = fuHeader & 0x3F
            if start {
                // Rebuild the 2-byte HEVC NAL header with the original type.
                let header0 = (payload[0] & 0x81) | (originalType << 1)
                let header1 = payload[1]
                fuBuffer = Data([header0, header1])
                fuBuffer?.append(contentsOf: payload[3...])
            } else if fuBuffer != nil {
                fuBuffer?.append(contentsOf: payload[3...])
            }
            if end, let complete = fuBuffer {
                onNAL?(complete)
                fuBuffer = nil
            }
        default:
            break
        }
    }
}
