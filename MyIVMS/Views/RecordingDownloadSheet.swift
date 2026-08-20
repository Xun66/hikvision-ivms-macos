import SwiftUI
import AppKit

struct RecordingDownloadSheet: View {
    let device: Device
    var channels: [Channel]
    @EnvironmentObject var store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var channel: Int
    @State private var day: Date
    @State private var recordings: [Recording] = []
    @State private var selectedIDs = Set<UUID>()
    @State private var states: [UUID: DownloadState] = [:]
    @State private var saveDirectory: URL?
    @State private var searching = false
    @State private var downloading = false
    @State private var message: String?
    @State private var lastSelectedID: UUID?
    @State private var downloadTask: Task<Void, Never>?

    init(device: Device, channels: [Channel], initialChannel: Int, initialDay: Date) {
        self.device = device
        self.channels = channels
        _channel = State(initialValue: initialChannel)
        _day = State(initialValue: initialDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 540)
        .onAppear { search() }
        .onChange(of: channel) { _, _ in search() }
        .onChange(of: Calendar.current.startOfDay(for: day)) { _, _ in search() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if channels.isEmpty {
                Stepper("Channel \(channel)", value: $channel, in: 1...32)
            } else {
                Picker("Channel", selection: $channel) {
                    ForEach(channels) { ch in Text("\(ch.id) · \(ch.name)").tag(ch.id) }
                }
                .frame(width: 180)
            }

            HStack(spacing: 6) {
                Text("Date")
                DatePicker("", selection: $day, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .frame(width: 136)
            }
            .fixedSize(horizontal: true, vertical: false)

            Button {
                search()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(searching || downloading)

            if searching {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Button {
                chooseSaveDirectory()
            } label: {
                Label("Save To", systemImage: "folder")
            }
            .disabled(downloading)

            Button {
                selectAll()
            } label: {
                Label("Select All", systemImage: "checklist")
            }
            .disabled(recordings.isEmpty || downloading)
        }
        .padding(12)
    }

    private var content: some View {
        Group {
            if let message, recordings.isEmpty {
                ContentUnavailableView("No Downloadable Recordings",
                                       systemImage: "film",
                                       description: Text(message))
            } else if recordings.isEmpty {
                ContentUnavailableView("No Recordings",
                                       systemImage: "film",
                                       description: Text(searching ? "Searching..." : "Pick a day."))
            } else {
                List {
                    ForEach(recordings) { recording in
                        RecordingDownloadRow(recording: recording,
                                             selected: selectedIDs.contains(recording.id),
                                             state: states[recording.id] ?? .idle) {
                            toggle(recording)
                        }
                            .disabled(downloading)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(saveDirectory?.path ?? "No save folder selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Close") {
                dismiss()
            }
            .disabled(downloading)

            Button {
                if downloading {
                    cancelDownload()
                } else {
                    downloadSelected()
                }
            } label: {
                if downloading {
                    Label("Cancel", systemImage: "xmark.circle")
                } else {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!downloading && selectedIDs.isEmpty)
        }
        .padding(12)
    }

    private func search() {
        guard let credentials = store.credentials(for: device) else {
            message = "No password saved for this device."
            return
        }
        searching = true
        message = nil
        recordings = []
        selectedIDs = []
        lastSelectedID = nil
        states = [:]

        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let trackID = channel * 100 + 1
        let client = ISAPIClient(host: device.host,
                                 port: device.httpPort,
                                 credentials: credentials)

        Task {
            do {
                let results = try await client.searchRecordings(trackID: trackID, start: start, end: end)
                await MainActor.run {
                    recordings = results.sorted { $0.start < $1.start }
                    message = recordings.isEmpty ? "当前日期无录像" : nil
                    searching = false
                }
            } catch {
                await MainActor.run {
                    message = error.localizedDescription
                    searching = false
                }
            }
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK {
            saveDirectory = panel.url
        }
    }

    private func selectAll() {
        let allIDs = Set(recordings.map(\.id))
        selectedIDs = selectedIDs == allIDs ? [] : allIDs
        lastSelectedID = recordings.last?.id
    }

    private func toggle(_ recording: Recording) {
        defer { lastSelectedID = recording.id }
        let shift = NSEvent.modifierFlags.contains(.shift)
        guard shift,
              let lastSelectedID,
              let from = recordings.firstIndex(where: { $0.id == lastSelectedID }),
              let to = recordings.firstIndex(where: { $0.id == recording.id }) else {
            if selectedIDs.contains(recording.id) {
                selectedIDs.remove(recording.id)
            } else {
                selectedIDs.insert(recording.id)
            }
            return
        }
        let bounds = min(from, to)...max(from, to)
        selectedIDs.formUnion(recordings[bounds].map(\.id))
    }

    private func downloadSelected() {
        if saveDirectory == nil { chooseSaveDirectory() }
        guard let saveDirectory else { return }
        guard let credentials = store.credentials(for: device) else {
            message = "No password saved for this device."
            return
        }

        let selectedRecordings = recordings.filter { selectedIDs.contains($0.id) }
        guard !selectedRecordings.isEmpty else { return }
        downloading = true
        message = nil

        let client = ISAPIClient(host: device.host,
                                 port: device.httpPort,
                                 credentials: credentials)
        downloadTask = Task {
            for recording in selectedRecordings {
                await MainActor.run { states[recording.id] = .downloading(nil) }
                do {
                    try Task.checkCancellation()
                    let destination = saveDirectory.appendingPathComponent(fileName(for: recording))
                    let saved = try await client.downloadRecording(recording, to: destination) { fraction in
                        Task { @MainActor in states[recording.id] = .downloading(fraction) }
                    }
                    await MainActor.run { states[recording.id] = .finished(saved) }
                } catch is CancellationError {
                    await MainActor.run { states[recording.id] = .cancelled }
                    break
                } catch {
                    await MainActor.run { states[recording.id] = .failed(error.localizedDescription) }
                }
            }
            await MainActor.run {
                downloading = false
                downloadTask = nil
                if message == "Cancelling download..." {
                    message = nil
                }
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        message = "Cancelling download..."
    }

    private func fileName(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let start = formatter.string(from: recording.start)
        let end = formatter.string(from: recording.end)
        let unique = UUID().uuidString.prefix(8)
        let name = "\(device.displayName)-ch\(channel)-\(start)-\(end)-\(unique).dav"
        return sanitizedFileName(name)
    }

    private func sanitizedFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return value.components(separatedBy: forbidden).joined(separator: "_")
    }
}

private struct RecordingDownloadRow: View {
    let recording: Recording
    let selected: Bool
    let state: DownloadState
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRange)
                    .font(.body.monospacedDigit())
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stateView
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var stateView: some View {
        Group {
            switch state {
            case .idle:
                Text(selected ? "Ready" : "")
                    .foregroundStyle(.secondary)
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    if let fraction {
                        ProgressView(value: fraction)
                            .frame(width: 82)
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Downloading")
                            .font(.caption)
                    }
                }
            case .finished:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var timeRange: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(formatter.string(from: recording.start)) - \(formatter.string(from: recording.end))"
    }

    private var detailText: String {
        var parts = [recording.codec, durationText(recording.duration)]
        if let fileSize = recording.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

private enum DownloadState: Equatable {
    case idle
    case downloading(Double?)
    case finished(URL)
    case failed(String)
    case cancelled
}
