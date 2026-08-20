import Foundation
import Combine

/// Persists the list of devices to `UserDefaults` (as JSON) and their
/// passwords to the Keychain. Observable so SwiftUI views update live.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []

    private let defaultsKey = "savedDevices.v1"

    init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Device].self, from: data)
        else { return }
        devices = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: Mutations

    /// Insert a new device (with password) or update an existing one.
    func upsert(_ device: Device, password: String?) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            devices[idx] = device
        } else {
            devices.append(device)
        }
        if let password, !password.isEmpty {
            Keychain.setPassword(password, for: device.id)
        }
        persist()
    }

    func remove(_ device: Device) {
        devices.removeAll { $0.id == device.id }
        Keychain.deletePassword(for: device.id)
        persist()
    }

    func password(for device: Device) -> String? {
        Keychain.password(for: device.id)
    }

    /// Build credentials for connecting; returns nil if no password saved.
    func credentials(for device: Device) -> Credentials? {
        guard let pw = password(for: device) else { return nil }
        return Credentials(username: device.username, password: pw)
    }
}

struct Credentials {
    let username: String
    let password: String
}
