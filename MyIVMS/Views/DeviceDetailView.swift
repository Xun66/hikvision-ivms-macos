import SwiftUI

struct DeviceDetailView: View {
    let device: Device
    @EnvironmentObject var store: DeviceStore
    @StateObject private var infoModel = DeviceInfoModel()
    @State private var mode: Mode = .live

    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live"
        case playback = "Playback"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            infoBar

            Divider()

            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                Spacer()
            }
            .padding(8)

            Divider()

            switch mode {
            case .live:
                LiveView(device: device, streams: infoModel.streams)
            case .playback:
                PlaybackView(device: device, channels: infoModel.channels)
            }
        }
        .navigationTitle(device.displayName)
        .navigationSubtitle("\(device.host):\(device.rtspPort)")
        .onAppear {
            infoModel.load(device: device,
                           credentials: store.credentials(for: device))
        }
    }

    @ViewBuilder private var infoBar: some View {
        HStack(spacing: 14) {
            if infoModel.isLoading {
                ProgressView().controlSize(.small)
                Text("Reading device info…").foregroundStyle(.secondary)
            } else if let error = infoModel.error {
                Text(device.displayName)
                Spacer()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
                    .help(infoModel.errorDetail ?? error)
                Button("Retry") {
                    infoModel.load(device: device,
                                   credentials: store.credentials(for: device))
                }
            } else if let info = infoModel.info {
                Label(info.model.isEmpty ? device.displayName : info.model, systemImage: "cpu")
                Label("\(infoModel.channels.count) channel\(infoModel.channels.count == 1 ? "" : "s")",
                      systemImage: "square.grid.2x2")
                if !info.firmwareVersion.isEmpty {
                    Text("FW \(info.firmwareVersion)").foregroundStyle(.secondary)
                }
            } else {
                Text(device.displayName).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Small overlay showing connection status on top of the video.
struct StatusOverlay: View {
    let status: StreamSession.Status

    var body: some View {
        switch status {
        case .idle:
            VideoMessageOverlay(message: "Not playing", systemImage: "play.rectangle")
        case .connecting:
            VideoMessageOverlay(message: "Connecting...", showsProgress: true)
        case .paused:
            VideoMessageOverlay(message: "Paused", systemImage: "pause.fill")
        case .error(let message):
            VideoMessageOverlay(message: message, systemImage: "exclamationmark.triangle.fill")
        case .playing:
            EmptyView()
        }
    }
}
