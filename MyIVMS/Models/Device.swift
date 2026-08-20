import Foundation

/// A saved / discovered Hikvision device.
///
/// Credentials are *not* stored in this struct so it can be persisted to
/// `UserDefaults` as plain JSON. The password lives in the Keychain, keyed by
/// the device `id`. See `DeviceStore`.
struct Device: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var rtspPort: Int = 554
    var httpPort: Int = 80
    var username: String = "admin"

    // Purely informational fields, typically filled in by SADP discovery.
    var model: String = ""
    var serial: String = ""
    var firmware: String = ""
    var mac: String = ""

    var displayName: String { name.isEmpty ? host : name }
}

/// One camera channel on a device. NVRs expose many; a standalone camera
/// exposes a single channel (1).
struct Channel: Identifiable, Hashable {
    var id: Int          // 1-based channel number
    var name: String
    var mainStreamID: Int { id * 100 + 1 }   // e.g. channel 1 -> 101
    var subStreamID: Int { id * 100 + 2 }    // e.g. channel 1 -> 102
}

enum StreamKind: String, CaseIterable, Identifiable {
    case main = "Main"
    case sub = "Sub"
    var id: String { rawValue }
}

/// A concrete stream advertised by the device (from ISAPI StreamingProxy /
/// Streaming channel config) — no guessing which stream IDs exist.
struct StreamInfo: Identifiable, Hashable {
    var id: Int                 // e.g. 101, 102, 201…
    var channelName: String
    var codec: String
    var width: Int
    var height: Int

    var channel: Int { id / 100 }
    var streamType: Int { id % 100 }

    var streamLabel: String {
        switch streamType {
        case 1: return "Main"
        case 2: return "Sub"
        case 3: return "Third"
        default: return "Stream \(streamType)"
        }
    }
    var resolution: String { width > 0 && height > 0 ? "\(width)×\(height)" : "" }

    var displayName: String {
        let base = (channelName.isEmpty || channelName == "\(id)") ? "Ch \(channel)" : channelName
        let res = resolution.isEmpty ? "" : " (\(resolution))"
        return "\(base) · \(streamLabel)\(res)"
    }
}
