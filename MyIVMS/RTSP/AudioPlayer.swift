import AVFoundation
import Foundation

final class AudioPlayer {
    private let codec: AudioCodec
    private let sampleRate: Double
    private let channels: AVAudioChannelCount
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "my-ivms.audio-player")
    private var format: AVAudioFormat?
    private var isStarted = false
    private var isAttached = false
    private var isEnabled = true

    init(codec: AudioCodec, sampleRate: Int, channels: Int) {
        self.codec = codec
        self.sampleRate = Double(sampleRate > 0 ? sampleRate : 8_000)
        self.channels = AVAudioChannelCount(max(1, min(channels, 1)))
    }

    func appendRTPPacket(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, self.isEnabled else { return }
            guard let payload = Self.rtpPayload(packet), !payload.isEmpty else { return }
            self.startIfNeeded()
            guard let format = self.format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(payload.count)) else {
                return
            }

            buffer.frameLength = AVAudioFrameCount(payload.count)
            guard let channel = buffer.floatChannelData?[0] else { return }
            for (index, byte) in payload.enumerated() {
                channel[index] = self.decode(byte)
            }

            self.player.scheduleBuffer(buffer)
            if !self.player.isPlaying {
                self.player.play()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.isEnabled = enabled
            if enabled {
                self?.startIfNeeded()
                self?.player.play()
            } else {
                self?.player.stop()
            }
        }
    }

    func pause() {
        queue.async { [weak self] in
            self?.player.pause()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.engine.stop()
            self.isStarted = false
            self.format = nil
        }
    }

    private func startIfNeeded() {
        guard !isStarted else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: channels,
                                         interleaved: false) else {
            return
        }
        self.format = format
        if !isAttached {
            engine.attach(player)
            isAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            isStarted = true
            Log.info("audio engine started codec=\(codec), sampleRate=\(sampleRate), channels=\(channels)")
        } catch {
            Log.info("audio engine start failed: \(error.localizedDescription)")
        }
    }

    private func decode(_ byte: UInt8) -> Float {
        switch codec {
        case .pcmu:
            return Float(Self.decodeMuLaw(byte)) / 32768.0
        case .pcma:
            return Float(Self.decodeALaw(byte)) / 32768.0
        case .unknown, .none:
            return 0
        }
    }

    private static func rtpPayload(_ packet: Data) -> Data? {
        guard packet.count > 12 else { return nil }
        let bytes = [UInt8](packet)
        let cc = Int(bytes[0] & 0x0F)
        let hasExtension = (bytes[0] & 0x10) != 0
        let hasPadding = (bytes[0] & 0x20) != 0
        var offset = 12 + cc * 4
        if hasExtension {
            guard offset + 4 <= bytes.count else { return nil }
            let extLen = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + extLen * 4
        }
        guard offset < bytes.count else { return nil }

        let payloadEnd: Int
        if hasPadding, let padding = bytes.last, padding > 0 {
            payloadEnd = bytes.count - Int(padding)
            guard offset < payloadEnd else { return nil }
        } else {
            payloadEnd = bytes.count
        }
        return packet.subdata(in: offset..<payloadEnd)
    }

    private static func decodeMuLaw(_ value: UInt8) -> Int16 {
        let mu = ~value
        let sign = mu & 0x80
        let exponent = (mu >> 4) & 0x07
        let mantissa = mu & 0x0F
        var sample = (Int(mantissa) << 3) + 0x84
        sample <<= Int(exponent)
        sample -= 0x84
        return Int16(sign != 0 ? -sample : sample)
    }

    private static func decodeALaw(_ value: UInt8) -> Int16 {
        let a = value ^ 0x55
        let sign = a & 0x80
        let exponent = (a & 0x70) >> 4
        let mantissa = a & 0x0F
        var sample = Int(mantissa) << 4
        if exponent == 0 {
            sample += 8
        } else {
            sample += 0x108
            sample <<= Int(exponent - 1)
        }
        return Int16(sign == 0 ? -sample : sample)
    }
}
