import Foundation
import Combine

/// Loads a device's basic info + channel list over ISAPI. Views observe this
/// to show device details and populate the channel picker.
@MainActor
final class DeviceInfoModel: ObservableObject {
    @Published var info: DeviceInfo?
    @Published var streams: [StreamInfo] = []
    @Published var channels: [Channel] = []   // derived from streams, for playback
    @Published var isLoading = false
    @Published var error: String?
    @Published var errorDetail: String?

    func load(device: Device, credentials: Credentials?) {
        guard let credentials else {
            error = "No password saved for this device."
            errorDetail = nil
            return
        }
        isLoading = true
        error = nil
        errorDetail = nil

        let client = ISAPIClient(host: device.host, port: device.httpPort,
                                 credentials: credentials)
        Task {
            do {
                let info = try await client.fetchDeviceInfo()
                let streams = try await client.fetchStreams()
                self.info = info
                if streams.isEmpty {
                    // Nothing advertised — fall back to a single main stream.
                    self.streams = [StreamInfo(id: 101, channelName: "", codec: "", width: 0, height: 0)]
                } else {
                    self.streams = streams
                }
                // Distinct channels that have at least one stream (for playback).
                let channelNumbers = Set(self.streams.map(\.channel)).sorted()
                self.channels = channelNumbers.map { Channel(id: $0, name: "Channel \($0)") }
                self.isLoading = false
            } catch {
                self.error = "Device info unavailable"
                self.errorDetail = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}
