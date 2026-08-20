import Foundation

/// One recorded segment returned by an ISAPI recording search.
struct Recording: Identifiable, Hashable {
    let id = UUID()
    var start: Date
    var end: Date
    var codec: String
    var playbackURI: String
    var fileSize: Int64?

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Talks to a device's ISAPI HTTP endpoints. Hikvision rejects `URLSession`'s
/// automatic Digest handling, so we perform the challenge/response manually
/// (same `HTTPAuthenticator` the RTSP client uses) — verified against a real
/// DS-7104N NVR.
final class ISAPIClient {
    let host: String
    let port: Int
    private let credentials: Credentials
    private let session: URLSession

    init(host: String, port: Int, credentials: Credentials) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.session = URLSession(configuration: Self.sessionConfiguration())
    }

    // MARK: Device info

    /// Basic device info from `/ISAPI/System/deviceInfo`.
    func fetchDeviceInfo() async throws -> DeviceInfo {
        DeviceInfoParser.parse(try await send(method: "GET", path: "/ISAPI/System/deviceInfo"))
    }

    /// Discover the actual streams the device serves, so we never guess stream
    /// IDs. NVRs advertise per-camera streams via `StreamingProxy/channels`;
    /// standalone cameras via `Streaming/channels`. As a last resort we derive
    /// main/sub streams from the `InputProxy` channel inventory.
    func fetchStreams() async throws -> [StreamInfo] {
        for path in ["/ISAPI/ContentMgmt/StreamingProxy/channels",
                     "/ISAPI/Streaming/channels"] {
            if let data = try? await send(method: "GET", path: path) {
                let streams = StreamListParser.parse(data)
                if !streams.isEmpty { return streams }
            }
        }
        // Fallback: synthesize main/sub from the channel list.
        if let data = try? await send(method: "GET", path: "/ISAPI/ContentMgmt/InputProxy/channels") {
            let channels = InputProxyChannelParser.parse(data)
            if !channels.isEmpty {
                return channels.flatMap { ch in
                    [StreamInfo(id: ch.id * 100 + 1, channelName: ch.name, codec: "", width: 0, height: 0),
                     StreamInfo(id: ch.id * 100 + 2, channelName: ch.name, codec: "", width: 0, height: 0)]
                }
            }
        }
        return []
    }

    /// Search recordings for a track (e.g. 101) in a time window.
    func searchRecordings(trackID: Int, start: Date, end: Date) async throws -> [Recording] {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <CMSearchDescription>
        <searchID>\(UUID().uuidString)</searchID>
        <trackList><trackID>\(trackID)</trackID></trackList>
        <timeSpanList><timeSpan>
        <startTime>\(Self.isoTime(start))</startTime>
        <endTime>\(Self.isoTime(end))</endTime>
        </timeSpan></timeSpanList>
        <maxResults>200</maxResults>
        <searchResultPostion>0</searchResultPostion>
        <metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>
        </CMSearchDescription>
        """
        let data = try await send(method: "POST", path: "/ISAPI/ContentMgmt/search",
                                  contentType: "application/xml", body: Data(body.utf8))
        return CMSearchResultParser.parse(data)
    }

    /// Try the Hikvision ContentMgmt download endpoint for one search result.
    func downloadRecording(_ recording: Recording, to destination: URL,
                           progress: ((Double?) -> Void)? = nil) async throws -> URL {
        guard !recording.playbackURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ISAPIError.missingPlaybackURI
        }
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <downloadRequest version="1.0" xmlns="http://www.isapi.org/ver20/XMLSchema">
        <playbackURI>\(Self.xmlEscaped(recording.playbackURI))</playbackURI>
        </downloadRequest>
        """
        try await download(method: "GET",
                           path: "/ISAPI/ContentMgmt/download",
                           contentType: "application/xml",
                           body: Data(body.utf8),
                           to: destination,
                           progress: progress)
        return destination
    }

    /// Continuous PTZ movement for one camera channel. Send `.stop` to halt.
    func movePTZ(channel: Int, vector: PTZVector) async throws {
        let v = vector.clamped
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <PTZData>
        <pan>\(v.pan)</pan>
        <tilt>\(v.tilt)</tilt>
        <zoom>\(v.zoom)</zoom>
        </PTZData>
        """
        _ = try await send(method: "PUT",
                           path: "/ISAPI/PTZCtrl/channels/\(channel)/continuous",
                           contentType: "application/xml",
                           body: Data(body.utf8))
    }

    // MARK: Manual Digest transport

    /// Sends a request, performing the Digest challenge/response by hand.
    private func send(method: String, path: String,
                      contentType: String? = nil, body: Data? = nil) async throws -> Data {
        // 1. Unauthenticated request to obtain the challenge.
        let (d0, r0) = try await session.data(for: makeRequest(method: method, path: path,
                                                               contentType: contentType, body: body,
                                                               authorization: nil))
        guard let h0 = r0 as? HTTPURLResponse else { throw ISAPIError.noResponse }
        if h0.statusCode == 200 { return d0 }
        guard h0.statusCode == 401,
              let challenge = h0.value(forHTTPHeaderField: "WWW-Authenticate"),
              var auth = HTTPAuthenticator(header: challenge,
                                           username: credentials.username,
                                           password: credentials.password) else {
            throw ISAPIError.httpStatus(h0.statusCode)
        }

        // 2. Retry with the computed Authorization (Digest URI = request path).
        let authorization = auth.authorization(method: method, uri: path)
        let (d1, r1) = try await session.data(for: makeRequest(method: method, path: path,
                                                               contentType: contentType, body: body,
                                                               authorization: authorization))
        guard let h1 = r1 as? HTTPURLResponse else { throw ISAPIError.noResponse }
        guard h1.statusCode == 200 else { throw ISAPIError.httpStatus(h1.statusCode) }
        return d1
    }

    /// Streams a response body to disk with the same manual Digest flow.
    private func download(method: String, path: String,
                          contentType: String? = nil,
                          body: Data? = nil,
                          to destination: URL,
                          progress: ((Double?) -> Void)? = nil) async throws {
        let downloader = ISAPIStreamDownloader(host: host, port: port, credentials: credentials)
        try await downloader.download(method: method,
                                      path: path,
                                      contentType: contentType,
                                      body: body,
                                      destination: destination,
                                      progress: progress)
    }

    private func makeRequest(method: String, path: String,
                             contentType: String? = nil, body: Data? = nil,
                             authorization: String?) throws -> URLRequest {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else { throw ISAPIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let authorization { req.setValue(authorization, forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        return req
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return config
    }

    static func isoTime(_ date: Date) -> String {
        HikvisionTime.isapiTimestamp(date)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Basic device information from ISAPI `deviceInfo`.
struct DeviceInfo: Equatable {
    var deviceName: String = ""
    var model: String = ""
    var serialNumber: String = ""
    var firmwareVersion: String = ""
    var deviceType: String = ""
}

enum ISAPIError: LocalizedError {
    case badURL
    case noResponse
    case httpStatus(Int)
    case httpStatusMessage(Int, String)
    case missingPlaybackURI
    case cannotCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid device URL"
        case .noResponse: return "No response from device"
        case .httpStatus(let code): return "Device returned HTTP \(code)"
        case .httpStatusMessage(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Device returned HTTP \(code)" }
            return "Device returned HTTP \(code): \(trimmed.prefix(240))"
        case .missingPlaybackURI: return "Recording does not include a playback URI"
        case .cannotCreateFile(let path): return "Cannot create download file at \(path)"
        }
    }
}

/// Parses `/ISAPI/ContentMgmt/InputProxy/channels` (NVR IP cameras) into
/// `Channel`s. The channel id is the first `<id>` in each `InputProxyChannel`.
private final class InputProxyChannelParser: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var inChannel = false
    private var gotID = false
    private var currentID: Int?
    private var currentName = ""
    private var channels: [(Int, String)] = []

    static func parse(_ data: Data) -> [Channel] {
        let parser = InputProxyChannelParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.channels
            .sorted { $0.0 < $1.0 }
            .map { Channel(id: $0.0, name: $0.1.isEmpty ? "Channel \($0.0)" : $0.1) }
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
        if e == "InputProxyChannel" { inChannel = true; gotID = false; currentID = nil; currentName = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case "id" where inChannel && !gotID:   // top-level channel id (ignore nested ids)
            currentID = Int(v); gotID = true
        case "name" where inChannel && currentName.isEmpty:
            currentName = v
        case "InputProxyChannel":
            if let id = currentID { channels.append((id, currentName)) }
            inChannel = false
        default: break
        }
        buffer = ""
    }
}

/// Parses `/ISAPI/System/deviceInfo`.
private final class DeviceInfoParser: NSObject, XMLParserDelegate {
    private var info = DeviceInfo()
    private var buffer = ""

    static func parse(_ data: Data) -> DeviceInfo {
        let parser = DeviceInfoParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.info
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) { buffer = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case "deviceName": info.deviceName = v
        case "model": info.model = v
        case "serialNumber": info.serialNumber = v
        case "firmwareVersion": info.firmwareVersion = v
        case "deviceType": info.deviceType = v
        default: break
        }
        buffer = ""
    }
}

/// Parses a `<StreamingChannelList>` (from `StreamingProxy/channels` or
/// `Streaming/channels`) into concrete `StreamInfo`s: id, name, codec and
/// resolution. Uses `first-seen` per field so nested `<enabled>`/`<id>` inside
/// `<Video>`/`<Audio>` don't clobber the channel-level values.
private final class StreamListParser: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var inChannel = false
    private var seen = Set<String>()
    private var id: Int?
    private var name = "", codec = ""
    private var width = 0, height = 0
    private var streams: [StreamInfo] = []

    static func parse(_ data: Data) -> [StreamInfo] {
        let parser = StreamListParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.streams.sorted { $0.id < $1.id }
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        buffer = ""
        if e == "StreamingChannel" {
            inChannel = true; seen = []; id = nil; name = ""; codec = ""; width = 0; height = 0
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if inChannel, !seen.contains(e) {
            switch e {
            case "id": id = Int(v); seen.insert(e)
            case "channelName": name = v; seen.insert(e)
            case "videoCodecType": codec = v; seen.insert(e)
            case "videoResolutionWidth": width = Int(v) ?? 0; seen.insert(e)
            case "videoResolutionHeight": height = Int(v) ?? 0; seen.insert(e)
            default: break
            }
        }
        if e == "StreamingChannel" {
            if let id { streams.append(StreamInfo(id: id, channelName: name, codec: codec, width: width, height: height)) }
            inChannel = false
        }
        buffer = ""
    }
}

/// Parses a `CMSearchResult` document into `Recording`s.
private final class CMSearchResultParser: NSObject, XMLParserDelegate {
    private var recordings: [Recording] = []
    private var buffer = ""

    private var inItem = false
    private var inTimeSpan = false
    private var currentStart: Date?
    private var currentEnd: Date?
    private var currentCodec = ""
    private var currentURI = ""
    private var currentFileSize: Int64?

    static func parse(_ data: Data) -> [Recording] {
        let parser = CMSearchResultParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.recordings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        buffer = ""
        switch elementName {
        case "searchMatchItem":
            inItem = true
            currentStart = nil; currentEnd = nil; currentCodec = ""; currentURI = ""; currentFileSize = nil
        case "timeSpan":
            inTimeSpan = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "startTime" where inItem && inTimeSpan:
            currentStart = Self.parseDate(value)
        case "endTime" where inItem && inTimeSpan:
            currentEnd = Self.parseDate(value)
        case "timeSpan":
            inTimeSpan = false
        case "codecType":
            currentCodec = value
        case "playbackURI":
            currentURI = value
            currentFileSize = currentFileSize ?? Self.fileSize(in: value)
        case "size" where inItem:
            currentFileSize = Self.byteCount(value)
        case "fileSize" where inItem:
            currentFileSize = Self.byteCount(value)
        case "searchMatchItem":
            if let s = currentStart, let e = currentEnd, !currentURI.isEmpty {
                recordings.append(Recording(start: s,
                                            end: e,
                                            codec: currentCodec,
                                            playbackURI: currentURI,
                                            fileSize: currentFileSize))
            }
            inItem = false
        default:
            break
        }
        buffer = ""
    }

    private static func parseDate(_ string: String) -> Date? {
        HikvisionTime.parseISAPITime(string)
    }

    private static func fileSize(in playbackURI: String) -> Int64? {
        guard let marker = playbackURI.firstIndex(of: "?") else { return nil }
        return playbackURI[playbackURI.index(after: marker)...]
            .split { $0 == "&" || $0 == ";" }
            .compactMap { item -> Int64? in
                let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].lowercased() == "size" else { return nil }
                return byteCount(parts[1])
            }
            .first
    }

    private static func byteCount(_ value: String) -> Int64? {
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int64(digits)
    }
}
