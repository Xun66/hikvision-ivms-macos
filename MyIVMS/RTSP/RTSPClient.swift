import Foundation
import Network
import CoreMedia

/// A minimal RTSP 1.0 client speaking to Hikvision devices over TCP with
/// RTP interleaved on the same connection (`Transport: RTP/AVP/TCP`). This is
/// the most firewall-friendly transport and avoids separate UDP sockets.
///
/// Flow: OPTIONS → DESCRIBE (handling Digest 401) → SETUP → PLAY, then read
/// interleaved `$`-framed RTP packets and feed them through the depacketizer
/// and decoder.
final class RTSPClient {
    enum State: Equatable {
        case connecting
        case describing
        case playing
        case paused
        case stopped
        case failed(String)
    }

    // Callbacks are delivered on the client's internal queue.
    var onState: ((State) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let url: URL
    private let username: String
    private let password: String
    private let queue = DispatchQueue(label: "rtsp.client")

    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var authenticator: HTTPAuthenticator?
    private var sessionID: String?
    private var contentBase: String?

    private var depacketizer: RTPDepacketizer?
    private var decoder: VideoDecoder?
    private var videoRTPChannel: UInt8 = 0   // interleaved channel carrying RTP video
    private var audioRTPChannel: UInt8?
    private var audioPlayer: AudioPlayer?
    private var pendingAudioMedia: MediaDescription?
    private var rtpPacketCount = 0
    private var audioPacketCount = 0
    private var frameCount = 0

    private var pendingResponse: ((RTSPResponse) -> Void)?
    private var keepAliveTimer: DispatchSourceTimer?
    private var stopFallback: DispatchWorkItem?
    private var isStopping = false
    private var isFinished = false

    /// Optional playback parameters. `range` e.g. "npt=now-" ; `scale` e.g. 2.0
    private var initialRange: String?
    private var scale: Double?

    init(url: URL, username: String, password: String,
         range: String? = nil, scale: Double? = nil) {
        self.url = url
        self.username = username
        self.password = password
        self.initialRange = range
        self.scale = scale
    }

    // MARK: Lifecycle

    func start() {
        let targetHost = url.host ?? ""
        let targetPort = UInt16(url.port ?? 554)
        isFinished = false
        isStopping = false

        let conn = NWConnection(host: NWEndpoint.Host(targetHost),
                                port: NWEndpoint.Port(rawValue: targetPort) ?? 554,
                                using: .tcp)
        connection = conn
        emit(.connecting)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("TCP ready to \(targetHost):\(targetPort)")
                self.receiveLoop()
                self.sendDescribe()
            case .failed(let error):
                self.fail("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.keepAliveTimer?.cancel()
            self.keepAliveTimer = nil
            self.stopFallback?.cancel()
            self.stopFallback = nil

            var didFinishStop = false
            let finishStop: () -> Void = { [weak self] in
                guard let self else { return }
                guard !didFinishStop else { return }
                didFinishStop = true
                self.stopFallback?.cancel()
                self.stopFallback = nil
                self.connection?.cancel()
                self.connection = nil
                self.sessionID = nil
                self.pendingResponse = nil
                self.isFinished = true
                self.audioPlayer?.stop()
                self.audioPlayer = nil
                self.emit(.stopped)
                completion?()
            }

            if self.sessionID != nil, self.connection?.state == .ready {
                self.sendRequest(method: "TEARDOWN", uri: self.aggregateURI) { _ in
                    finishStop()
                }
                let fallback = DispatchWorkItem(block: finishStop)
                self.stopFallback = fallback
                self.queue.asyncAfter(deadline: .now() + 1.0, execute: fallback)
            } else {
                finishStop()
            }
        }
    }

    /// Change playback speed on the fly (playback streams only). Re-issues PLAY
    /// with a new `Scale` header, resuming from the current position.
    func setScale(_ newScale: Double) {
        queue.async { [weak self] in
            guard let self, self.sessionID != nil else { return }
            self.scale = newScale
            self.audioPlayer?.setEnabled(newScale == 1)
            self.sendPlay(range: "npt=now-")
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, self.sessionID != nil else { return }
            self.sendRequest(method: "PAUSE", uri: self.aggregateURI) { [weak self] response in
                guard let self else { return }
                guard response.statusCode == 200 else {
                    self.fail("PAUSE failed (\(response.statusCode))")
                    return
                }
                Log.info("PAUSE 200")
                self.audioPlayer?.pause()
                self.emit(.paused)
            }
        }
    }

    func resume() {
        queue.async { [weak self] in
            self?.sendPlay(range: "npt=now-")
        }
    }

    func seek(nptSeconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.sessionID != nil else {
                completion(false)
                return
            }
            self.sendPlay(range: String(format: "npt=%.3f-", nptSeconds),
                          failOnError: false,
                          completion: completion)
        }
    }

    // MARK: Request/response

    private var aggregateURI: String { contentBase ?? url.absoluteString }

    private func sendDescribe() {
        emit(.describing)
        sendRequest(method: "DESCRIBE", uri: url.absoluteString,
                    headers: ["Accept": "application/sdp"]) { [weak self] response in
            self?.handleDescribe(response)
        }
    }

    private func handleDescribe(_ response: RTSPResponse) {
        if response.statusCode == 401 {
            guard setupAuthenticator(from: response) else {
                fail("Authentication failed"); return
            }
            sendDescribe() // retry with credentials
            return
        }
        guard response.statusCode == 200 else {
            fail("DESCRIBE failed (\(response.statusCode))"); return
        }

        contentBase = response.headers["content-base"] ?? response.headers["content-location"]
        let sdp = SDPDescription.parse(response.body)
        guard let video = sdp.videoMedia, video.codec != .unknown else {
            fail("No supported video track in SDP"); return
        }
        Log.info("DESCRIBE 200: codec=\(video.codec), control=\(video.control), SPS=\(video.sps?.count ?? 0)B PPS=\(video.pps?.count ?? 0)B VPS=\(video.vps?.count ?? 0)B")

        // Wire up the decode pipeline for the negotiated codec.
        let depacketizer = RTPDepacketizer(codec: video.codec)
        let decoder = VideoDecoder(codec: video.codec)
        decoder.setParameterSets(vps: video.vps, sps: video.sps, pps: video.pps)
        decoder.onSampleBuffer = { [weak self] sample in self?.onSampleBuffer?(sample) }
        depacketizer.onNAL = { [weak decoder] nal in decoder?.append(nal: nal) }
        depacketizer.onFrameBoundary = { [weak self, weak decoder] timestamp in
            self?.frameCount += 1
            decoder?.frameBoundary(rtpTimestamp: timestamp)
        }
        self.depacketizer = depacketizer
        self.decoder = decoder
        if let audio = sdp.audioMedia {
            pendingAudioMedia = audio
            audioPlayer = AudioPlayer(codec: audio.audioCodec,
                                      sampleRate: audio.clockRate,
                                      channels: audio.channels)
            Log.info("audio track found: codec=\(audio.audioCodec), rate=\(audio.clockRate), channels=\(audio.channels), control=\(audio.control)")
        } else if let audio = sdp.medias.first(where: { $0.isAudio }) {
            Log.info("audio track unsupported: codec=\(audio.audioCodec), control=\(audio.control)")
        } else {
            Log.info("no audio track in SDP")
        }

        let controlURI = resolveControl(video.control)
        sendSetup(controlURI: controlURI, requestedInterleaved: 0...1) { [weak self] response, rtpChannel in
            self?.handleVideoSetup(response, rtpChannel: rtpChannel)
        }
    }

    private func handleVideoSetup(_ response: RTSPResponse, rtpChannel: UInt8) {
        guard response.statusCode == 200 else {
            fail("SETUP failed (\(response.statusCode))"); return
        }
        updateSession(from: response)
        videoRTPChannel = rtpChannel
        Log.info("video SETUP 200: session=\(sessionID ?? "?"), rtpChannel=\(videoRTPChannel), transport=\(response.headers["transport"] ?? "-")")

        guard let audio = pendingAudioMedia, audio.audioCodec.isSupported else {
            sendPlay()
            return
        }
        let controlURI = resolveControl(audio.control)
        sendSetup(controlURI: controlURI, requestedInterleaved: 2...3) { [weak self] response, rtpChannel in
            self?.handleAudioSetup(response, rtpChannel: rtpChannel)
        }
    }

    private func handleAudioSetup(_ response: RTSPResponse, rtpChannel: UInt8) {
        if response.statusCode == 200 {
            updateSession(from: response)
            audioRTPChannel = rtpChannel
            Log.info("audio SETUP 200: rtpChannel=\(rtpChannel), transport=\(response.headers["transport"] ?? "-")")
        } else {
            Log.info("audio SETUP skipped: status=\(response.statusCode)")
            audioRTPChannel = nil
            audioPlayer?.stop()
            audioPlayer = nil
        }
        sendPlay()
    }

    private func sendSetup(controlURI: String,
                           requestedInterleaved: ClosedRange<UInt8>,
                           completion: @escaping (RTSPResponse, UInt8) -> Void) {
        let transport = "RTP/AVP/TCP;unicast;interleaved=\(requestedInterleaved.lowerBound)-\(requestedInterleaved.upperBound)"
        sendRequest(method: "SETUP", uri: controlURI,
                    headers: ["Transport": transport]) { [weak self] response in
            guard let self else { return }
            completion(response, self.rtpChannel(from: response, defaultChannel: requestedInterleaved.lowerBound))
        }
    }

    private func updateSession(from response: RTSPResponse) {
        if let session = response.headers["session"] {
            sessionID = session.split(separator: ";").first.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func rtpChannel(from response: RTSPResponse, defaultChannel: UInt8) -> UInt8 {
        if let transport = response.headers["transport"],
           let range = transport.range(of: "interleaved="),
           let chStr = transport[range.upperBound...].split(whereSeparator: { $0 == "-" || $0 == ";" }).first,
           let ch = UInt8(chStr) {
            return ch
        }
        return defaultChannel
    }

    private func sendPlay() {
        sendPlay(range: initialRange ?? "npt=0.000-")
    }

    private func sendPlay(range: String,
                          failOnError: Bool = true,
                          completion: ((Bool) -> Void)? = nil) {
        var headers: [String: String] = ["Range": range]
        if let scale { headers["Scale"] = String(format: "%g", scale) }
        sendRequest(method: "PLAY", uri: aggregateURI, headers: headers) { [weak self] response in
            guard let self else { return }
            guard response.statusCode == 200 else {
                if failOnError {
                    self.fail("PLAY failed (\(response.statusCode))")
                }
                completion?(false)
                return
            }
            Log.info("PLAY 200 \(range) — streaming (rtpChannel=\(self.videoRTPChannel))")
            if self.scale == nil || self.scale == 1 {
                self.audioPlayer?.setEnabled(true)
            } else {
                self.audioPlayer?.setEnabled(false)
            }
            self.emit(.playing)
            self.startKeepAlive()
            completion?(true)
        }
    }

    private func sendRequest(method: String, uri: String,
                             headers: [String: String] = [:],
                             completion: @escaping (RTSPResponse) -> Void) {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0"]
        lines.append("CSeq: \(cseq)")
        lines.append("User-Agent: MyIVMS/1.0")
        if let sessionID { lines.append("Session: \(sessionID)") }
        if var auth = authenticator {
            lines.append("Authorization: \(auth.authorization(method: method, uri: uri))")
            authenticator = auth // persist mutated nonce count
        }
        for (key, value) in headers { lines.append("\(key): \(value)") }
        let request = lines.joined(separator: "\r\n") + "\r\n\r\n"

        pendingResponse = completion
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("Send failed: \(error.localizedDescription)") }
        })
    }

    private func setupAuthenticator(from response: RTSPResponse) -> Bool {
        guard let header = response.headers["www-authenticate"] else { return false }
        authenticator = HTTPAuthenticator(header: header, username: username, password: password)
        return authenticator != nil
    }

    // MARK: Receive & parse

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffer()
            }
            if let error {
                guard !self.isStopping, !self.isFinished else { return }
                self.fail("Receive failed: \(error.localizedDescription)"); return
            }
            if isComplete {
                guard !self.isStopping, !self.isFinished else { return }
                self.fail("Connection closed by device"); return
            }
            self.receiveLoop()
        }
    }

    private func parseBuffer() {
        while let first = buffer.first {
            if first == 0x24 { // '$' interleaved RTP frame
                guard buffer.count >= 4 else { return }
                let channel = buffer[buffer.startIndex + 1]
                let length = (Int(buffer[buffer.startIndex + 2]) << 8) | Int(buffer[buffer.startIndex + 3])
                guard buffer.count >= 4 + length else { return }
                let packet = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + length))
                if channel == videoRTPChannel {
                    rtpPacketCount += 1
                    if rtpPacketCount == 1 { Log.info("first RTP video packet received") }
                    else if rtpPacketCount % 200 == 0 { Log.info("RTP packets=\(rtpPacketCount), frames=\(frameCount)") }
                    depacketizer?.handle(packet)
                } else if channel == audioRTPChannel {
                    audioPacketCount += 1
                    if audioPacketCount == 1 { Log.info("first RTP audio packet received") }
                    audioPlayer?.appendRTPPacket(packet)
                }
            } else { // RTSP text response
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                let contentLength = RTSPResponse.contentLength(in: headerText)
                let bodyStart = headerEnd.upperBound
                guard buffer.count >= (bodyStart - buffer.startIndex) + contentLength else { return }
                let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                buffer.removeSubrange(buffer.startIndex..<(bodyStart + contentLength))
                let response = RTSPResponse(header: headerText, body: String(decoding: body, as: UTF8.self))
                let handler = pendingResponse
                pendingResponse = nil
                handler?(response)
            }
        }
    }

    // MARK: Helpers

    private func resolveControl(_ control: String) -> String {
        if control.isEmpty || control == "*" { return aggregateURI }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        var base = contentBase ?? url.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return base + control
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, self.sessionID != nil else { return }
            self.sendRequest(method: "OPTIONS", uri: self.aggregateURI) { _ in }
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func emit(_ state: State) {
        onState?(state)
    }

    private func fail(_ message: String) {
        guard !isStopping, !isFinished else { return }
        isFinished = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        stopFallback?.cancel()
        stopFallback = nil
        audioPlayer?.stop()
        audioPlayer = nil
        emit(.failed(message))
        connection?.cancel()
        connection = nil
    }
}

/// A parsed RTSP response (status line + headers + body).
struct RTSPResponse {
    let statusCode: Int
    let headers: [String: String]   // keys lowercased
    let body: String

    init(header: String, body: String) {
        var lines = header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let comps = statusLine.split(separator: " ")
        self.statusCode = comps.count >= 2 ? (Int(comps[1]) ?? 0) : 0

        var dict: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            dict[key] = value
        }
        self.headers = dict
        self.body = body
    }

    static func contentLength(in header: String) -> Int {
        for line in header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }
}
