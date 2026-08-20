import SwiftUI

struct LiveView: View {
    let device: Device
    var streams: [StreamInfo] = []
    @EnvironmentObject var store: DeviceStore
    @StateObject private var session = StreamSession()

    @State private var selectedStreamID: Int = 101
    @State private var noCredentials = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VideoRenderView(layer: session.displayLayer)
                StatusOverlay(status: session.status)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            controlBar
        }
        .onDisappear { session.stop() }
        .onChange(of: streams.map(\.id)) { _, ids in
            if let first = ids.first, !ids.contains(selectedStreamID) { selectedStreamID = first }
        }
        .alert("No Password Saved", isPresented: $noCredentials) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Edit this device to add a password before connecting.")
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            if streams.isEmpty {
                Text("Reading streams…").foregroundStyle(.secondary)
            } else {
                Picker("Stream", selection: $selectedStreamID) {
                    ForEach(streams) { s in
                        Text(s.displayName).tag(s.id)
                    }
                }
                .frame(maxWidth: 320)
            }

            Spacer()

            PTZControlsView(device: device, channel: selectedStreamID / 100)
                .disabled(streams.isEmpty)

            if session.status == .playing || session.status == .connecting {
                Button { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { play() } label: { Label("Play", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(streams.isEmpty)
            }
        }
        .padding(12)
        .onChange(of: selectedStreamID) { _, _ in if session.status == .playing { play() } }
    }

    private func play() {
        guard let credentials = store.credentials(for: device) else {
            noCredentials = true
            return
        }
        // selectedStreamID is a real device stream id — no guessing.
        guard let url = HikvisionURLs.live(host: device.host, port: device.rtspPort, streamID: selectedStreamID) else { return }
        session.start(url: url, credentials: credentials)
    }
}
