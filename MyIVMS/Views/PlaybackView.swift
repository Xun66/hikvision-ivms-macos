import Combine
import AVFoundation
import SwiftUI

struct PlaybackView: View {
    let device: Device
    var channels: [Channel] = []
    @EnvironmentObject var store: DeviceStore
    @StateObject private var session = StreamSession()
    @StateObject private var fullScreenPresenter = FullScreenWindowPresenter()

    @State private var channel = 1
    @State private var day = Date()
    @State private var recordings: [Recording] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var speed: Double = 1.0
    @State private var currentTime = Self.defaultRangeStart
    @State private var timelineMessage: String?
    @State private var videoMessage: String?
    @State private var videoMessageSystemImage: String?
    @State private var videoMessageShowsProgress = false
    @State private var videoMessageIsTransient = false
    @State private var playbackClockStart: Date?
    @State private var playbackClockWallStart: Date?
    @State private var isScrubbingTimeline = false
    @State private var showingFullScreen = false
    @State private var showingDownloadSheet = false
    @State private var zoomIndex = 0
    @State private var videoZoomScale: CGFloat = 1
    @State private var videoZoomAnchor = UnitPoint.center
    @State private var selectingVideoZoom = false
    @State private var videoSelectionStart: CGPoint?
    @State private var videoSelectionRect: CGRect?

    private let speeds: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    private let zoomDurations: [TimeInterval] = [86_400, 43_200, 21_600, 7_200, 1_800]
    private let minVideoZoomScale: CGFloat = 1
    private let maxVideoZoomScale: CGFloat = 6
    private let playbackClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static var defaultRangeStart: Date {
        Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            videoPane(showLayer: !showingFullScreen, layer: session.displayLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            timelineBar
            Divider()
            playbackControlBar(isFullScreen: false)
        }
        .sheet(isPresented: $showingDownloadSheet) {
            RecordingDownloadSheet(device: device,
                                   channels: channels,
                                   initialChannel: channel,
                                   initialDay: day)
                .environmentObject(store)
        }
        .onAppear {
            configureInitialChannel()
            refreshRecordings()
        }
        .onDisappear {
            closeFullScreen()
            session.stop()
        }
        .onChange(of: channels.map(\.id)) { _, ids in
            if let first = ids.first, !ids.contains(channel) {
                channel = first
                resetPlaybackDay()
            }
        }
        .onChange(of: channel) { _, _ in resetPlaybackDay() }
        .onChange(of: Calendar.current.startOfDay(for: day)) { _, _ in resetPlaybackDay() }
        .onChange(of: currentTime) { _, _ in refreshFullScreenIfNeeded() }
        .onChange(of: recordings) { _, _ in refreshFullScreenIfNeeded() }
        .onChange(of: session.status) { _, status in
            if case .error(let message) = status, videoMessageIsTransient {
                clearPlaybackClock()
                setVideoMessage(message)
            } else if status == .playing, videoMessageIsTransient {
                setVideoMessage(nil)
            } else if status == .idle {
                clearPlaybackClock()
            }
            refreshFullScreenIfNeeded()
        }
        .onChange(of: zoomIndex) { _, _ in refreshFullScreenIfNeeded() }
        .onChange(of: videoMessage) { _, _ in refreshFullScreenIfNeeded() }
        .onChange(of: videoZoomScale) { _, _ in refreshFullScreenIfNeeded() }
        .onChange(of: selectingVideoZoom) { _, _ in refreshFullScreenIfNeeded() }
        .onReceive(playbackClock) { _ in
            advancePlaybackClock()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if channels.isEmpty {
                Stepper("Channel \(channel)", value: $channel, in: 1...32)
            } else {
                Picker("Channel", selection: $channel) {
                    ForEach(channels) { ch in Text("\(ch.id) · \(ch.name)").tag(ch.id) }
                }
                .frame(width: 190)
            }

            PlaybackDateControl(day: $day)

            Button {
                refreshRecordings()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(searching)

            if searching {
                ProgressView()
                    .controlSize(.small)
            }
            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showingDownloadSheet = true
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func videoPane(showLayer: Bool, layer: AVSampleBufferDisplayLayer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    if showLayer {
                        VideoRenderView(layer: layer)
                            .scaleEffect(videoZoomScale, anchor: videoZoomAnchor)
                    }
                    if let videoSelectionRect {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.12))
                            .frame(width: videoSelectionRect.width, height: videoSelectionRect.height)
                            .offset(x: videoSelectionRect.midX - proxy.size.width / 2,
                                    y: videoSelectionRect.midY - proxy.size.height / 2)
                    }
                    if let videoMessage {
                        VideoMessageOverlay(message: videoMessage,
                                            systemImage: videoMessageSystemImage,
                                            showsProgress: videoMessageShowsProgress)
                    } else {
                        StatusOverlay(status: session.status)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(videoSelectionGesture(in: proxy.size))
            }
            .background(Color.black)

            VideoZoomControlsView(scale: $videoZoomScale,
                                  selectionMode: $selectingVideoZoom,
                                  minScale: minVideoZoomScale,
                                  maxScale: maxVideoZoomScale)
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: videoZoomScale) { _, newValue in
                    if newValue == minVideoZoomScale { videoZoomAnchor = .center }
                }
                .onChange(of: selectingVideoZoom) { _, enabled in
                    if !enabled {
                        videoSelectionStart = nil
                        videoSelectionRect = nil
                    }
                }
            }
    }

    private var fullScreenPlayback: some View {
        VStack(spacing: 0) {
            videoPane(showLayer: true, layer: session.fullScreenDisplayLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            timelineBar
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            playbackControlBar(isFullScreen: true)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var timelineBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(timeText(currentTime))
                    .font(.body.monospacedDigit())
                Text(visibleRangeText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let timelineMessage {
                    Text(timelineMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    zoomOut()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Timeline Zoom Out")
                .disabled(zoomIndex == 0)

                Button {
                    zoomIn()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Timeline Zoom In")
                .disabled(zoomIndex == zoomDurations.count - 1)

                Button {
                    zoomIndex = 0
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("Show Whole Day")
                .disabled(zoomIndex == 0)
            }
            RecordingTimelineView(day: day,
                                  recordings: recordings,
                                  visibleStart: visibleRange.start,
                                  visibleEnd: visibleRange.end,
                                  currentTime: $currentTime) { time, committed in
                scrubTimeline(to: time, committed: committed)
            }
            .frame(height: 50)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func playbackControlBar(isFullScreen: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                togglePlayPause()
            } label: {
                Label(playPauseTitle, systemImage: playPauseIcon)
            }
            .disabled(session.status == .connecting)

            Button {
                stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!session.hasActiveClient)

            Divider()
                .frame(height: 22)

            Image(systemName: "speedometer")
            Picker("Speed", selection: $speed) {
                ForEach(speeds, id: \.self) { s in
                    Text(speedLabel(s)).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 90)
            .onChange(of: speed) { _, newValue in
                anchorPlaybackClockAtCurrentTime()
                session.setScale(newValue)
            }

            Spacer()

            if isFullScreen {
                Button {
                    closeFullScreen()
                } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            } else {
                Button {
                    openFullScreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func configureInitialChannel() {
        if let first = channels.first, !channels.map(\.id).contains(channel) {
            channel = first.id
        }
    }

    private func resetPlaybackDay() {
        closeFullScreen()
        session.stop()
        clearPlaybackClock()
        currentTime = dayStart
        zoomIndex = 0
        refreshRecordings()
    }

    private func refreshRecordings() {
        guard let credentials = store.credentials(for: device) else {
            searchError = "No password saved for this device."
            setVideoMessage(searchError)
            return
        }
        searching = true
        searchError = nil
        timelineMessage = nil
        setVideoMessage("Searching recordings...", systemImage: nil, showsProgress: true, transient: true)

        let start = dayStart
        let end = dayEnd
        let requestedChannel = channel
        let requestedTime = currentTime
        let trackID = channel * 100 + 1
        let client = ISAPIClient(host: device.host,
                                 port: device.httpPort,
                                 credentials: credentials)

        Task {
            do {
                let results = try await client.searchRecordings(trackID: trackID, start: start, end: end)
                await MainActor.run {
                    guard channel == requestedChannel, dayStart == start else { return }
                    let sorted = results.sorted { $0.start < $1.start }
                    recordings = sorted
                    currentTime = clampedToDay(requestedTime)
                    if sorted.isEmpty {
                        timelineMessage = nil
                        setVideoMessage("当前日期无录像", systemImage: "film")
                    } else if sorted.contains(where: { $0.start <= currentTime && currentTime < $0.end }) {
                        timelineMessage = "\(sorted.count) recording\(sorted.count == 1 ? "" : "s")"
                        if videoMessageIsTransient {
                            setVideoMessage(nil)
                        }
                    } else {
                        timelineMessage = "\(sorted.count) recording\(sorted.count == 1 ? "" : "s")"
                        setVideoMessage("当前时间无录像", systemImage: "film")
                    }
                    searching = false
                }
            } catch {
                await MainActor.run {
                    guard channel == requestedChannel, dayStart == start else { return }
                    searchError = error.localizedDescription
                    timelineMessage = nil
                    setVideoMessage(error.localizedDescription)
                    searching = false
                }
            }
        }
    }

    private func togglePlayPause() {
        switch session.status {
        case .playing:
            setVideoMessage(nil)
            anchorPlaybackClockAtCurrentTime()
            session.pause()
        case .paused:
            setVideoMessage(nil)
            startPlaybackClock(at: currentTime)
            session.resume()
        default:
            play(at: currentTime)
        }
    }

    private func stopPlayback() {
        session.stop()
        clearPlaybackClock()
        setVideoMessage("播放已停止", systemImage: "stop.fill")
    }

    private func scrubTimeline(to time: Date, committed: Bool) {
        isScrubbingTimeline = !committed
        currentTime = time
        guard let recording = recording(containing: time) else {
            timelineMessage = nil
            setVideoMessage("当前时间无录像", systemImage: "film")
            if committed {
                session.stop()
                clearPlaybackClock()
            }
            return
        }
        timelineMessage = timeRange(recording)
        if !videoMessageIsTransient {
            setVideoMessage(nil)
        }
        guard committed else { return }
        isScrubbingTimeline = false
        setVideoMessage("正在切换到 \(timeText(time))", systemImage: nil, showsProgress: true, transient: true)
        Log.info("playback timeline commit channel=\(channel) time=\(HikvisionTime.rtspTimestamp(time))")
        play(at: time)
    }

    private func play(at time: Date) {
        guard recording(containing: time) != nil else {
            setVideoMessage("当前时间无录像", systemImage: "film")
            session.stop()
            clearPlaybackClock()
            return
        }
        if !videoMessageIsTransient {
            setVideoMessage(nil)
        }
        searchError = nil
        startPlayback(at: time)
    }

    private func startPlayback(at time: Date) {
        guard let credentials = store.credentials(for: device) else {
            searchError = "No password saved for this device."
            setVideoMessage(searchError)
            return
        }
        let trackID = channel * 100 + 1
        guard let url = HikvisionURLs.playback(host: device.host,
                                               port: device.rtspPort,
                                               trackID: trackID,
                                               start: time,
                                               end: dayEnd) else {
            searchError = "Invalid playback URL."
            setVideoMessage(searchError)
            return
        }
        session.start(url: url, credentials: credentials,
                      range: "npt=0.000-", scale: speed)
        startPlaybackClock(at: time)
    }

    private func openFullScreen() {
        session.setFullScreenMirroring(true)
        showingFullScreen = true
        fullScreenPresenter.present(AnyView(fullScreenPlayback), onEscape: closeFullScreen)
        DispatchQueue.main.async {
            session.refreshFullScreenFrame()
        }
    }

    private func closeFullScreen() {
        showingFullScreen = false
        fullScreenPresenter.close()
        session.setFullScreenMirroring(false)
    }

    private func refreshFullScreenIfNeeded() {
        guard showingFullScreen else { return }
        fullScreenPresenter.present(AnyView(fullScreenPlayback), onEscape: closeFullScreen)
    }

    private func zoomIn() {
        guard zoomIndex < zoomDurations.count - 1 else { return }
        zoomIndex += 1
    }

    private func zoomOut() {
        guard zoomIndex > 0 else { return }
        zoomIndex -= 1
    }

    private func videoSelectionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard selectingVideoZoom else { return }
                let start = videoSelectionStart ?? value.startLocation
                videoSelectionStart = start
                videoSelectionRect = normalizedRect(from: start, to: value.location, in: size)
            }
            .onEnded { value in
                guard selectingVideoZoom else { return }
                let start = videoSelectionStart ?? value.startLocation
                let rect = normalizedRect(from: start, to: value.location, in: size)
                if rect.width >= 12, rect.height >= 12 {
                    zoomVideo(to: rect, in: size)
                }
                selectingVideoZoom = false
                videoSelectionStart = nil
                videoSelectionRect = nil
            }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        let x0 = min(max(0, start.x), size.width)
        let y0 = min(max(0, start.y), size.height)
        let x1 = min(max(0, end.x), size.width)
        let y1 = min(max(0, end.y), size.height)
        return CGRect(x: min(x0, x1),
                      y: min(y0, y1),
                      width: abs(x1 - x0),
                      height: abs(y1 - y0))
    }

    private func zoomVideo(to rect: CGRect, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = min(1, max(0, rect.midX / size.width))
        let y = min(1, max(0, rect.midY / size.height))
        let fitScale = min(size.width / max(rect.width, 1),
                           size.height / max(rect.height, 1))
        videoZoomAnchor = UnitPoint(x: x, y: y)
        videoZoomScale = min(maxVideoZoomScale, max(videoZoomScale, fitScale))
    }

    private func recording(containing time: Date) -> Recording? {
        recordings.first { $0.start <= time && time < $0.end }
    }

    private func clampedToDay(_ time: Date) -> Date {
        min(dayEnd.addingTimeInterval(-0.001), max(dayStart, time))
    }

    private func setVideoMessage(_ message: String?,
                                 systemImage: String? = "exclamationmark.triangle.fill",
                                 showsProgress: Bool = false,
                                 transient: Bool = false) {
        videoMessage = message
        videoMessageSystemImage = message == nil ? nil : systemImage
        videoMessageShowsProgress = message == nil ? false : showsProgress
        videoMessageIsTransient = message == nil ? false : transient
    }

    private func startPlaybackClock(at time: Date) {
        currentTime = time
        playbackClockStart = time
        playbackClockWallStart = Date()
    }

    private func anchorPlaybackClockAtCurrentTime() {
        playbackClockStart = currentTime
        playbackClockWallStart = Date()
    }

    private func clearPlaybackClock() {
        playbackClockStart = nil
        playbackClockWallStart = nil
    }

    private func advancePlaybackClock() {
        guard session.status == .playing, !isScrubbingTimeline,
              let playbackClockStart, let playbackClockWallStart else { return }
        let elapsed = Date().timeIntervalSince(playbackClockWallStart) * speed
        let nextTime = playbackClockStart.addingTimeInterval(elapsed)
        guard nextTime < dayEnd else {
            stopPlayback()
            setVideoMessage("当前时间无录像", systemImage: "film")
            return
        }
        guard recording(containing: nextTime) != nil else {
            currentTime = nextTime
            stopPlayback()
            setVideoMessage("当前时间无录像", systemImage: "film")
            return
        }
        currentTime = nextTime
    }

    // MARK: Time

    private var dayStart: Date {
        Calendar.current.startOfDay(for: day)
    }

    private var dayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    }

    private var visibleRange: (start: Date, end: Date) {
        let dayLength = dayEnd.timeIntervalSince(dayStart)
        let duration = min(zoomDurations[zoomIndex], dayLength)
        guard duration < dayLength else { return (dayStart, dayEnd) }
        let half = duration / 2
        let center = min(dayEnd.addingTimeInterval(-half),
                         max(dayStart.addingTimeInterval(half), currentTime))
        return (center.addingTimeInterval(-half), center.addingTimeInterval(half))
    }

    private var visibleRangeText: String {
        "\(timeText(visibleRange.start)) - \(timeText(visibleRange.end))"
    }

    private var playPauseTitle: String {
        session.status == .playing ? "Pause" : "Play"
    }

    private var playPauseIcon: String {
        session.status == .playing ? "pause.fill" : "play.fill"
    }

    private func timeRange(_ rec: Recording) -> String {
        "\(timeText(rec.start)) - \(timeText(rec.end))"
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func speedLabel(_ s: Double) -> String {
        s < 1 ? "\(s)x" : "\(Int(s))x"
    }
}
