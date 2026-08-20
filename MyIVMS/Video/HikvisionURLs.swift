import Foundation

/// Builds the RTSP URLs Hikvision devices expose. Credentials are *not*
/// embedded — they are supplied to `RTSPClient` for Digest auth instead.
enum HikvisionURLs {
    /// Live view: rtsp://host:port/Streaming/Channels/<id>
    /// Main stream = channel*100+1 (e.g. 101), sub = channel*100+2 (e.g. 102).
    static func live(host: String, port: Int, streamID: Int) -> URL? {
        URL(string: "rtsp://\(host):\(port)/Streaming/Channels/\(streamID)")
    }

    /// Playback by absolute time:
    /// rtsp://host:port/Streaming/tracks/<trackID>?starttime=...&endtime=...
    static func playback(host: String, port: Int, trackID: Int,
                         start: Date, end: Date) -> URL? {
        let s = hikTime(start)
        let e = hikTime(end)
        return URL(string: "rtsp://\(host):\(port)/Streaming/tracks/\(trackID)?starttime=\(s)&endtime=\(e)")
    }

    /// Hikvision time format. The device treats the trailing z as a literal,
    /// so the timestamp is formatted in local time.
    static func hikTime(_ date: Date) -> String {
        HikvisionTime.rtspTimestamp(date)
    }
}
