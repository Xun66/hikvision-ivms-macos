import Foundation
import AVFoundation
import AppKit
import Combine

/// Drives one live/playback stream: owns the `RTSPClient` and the
/// `AVSampleBufferDisplayLayer` that VideoToolbox renders decoded frames into.
@MainActor
final class StreamSession: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case playing
        case paused
        case error(String)
    }

    @Published private(set) var status: Status = .idle

    /// The layer the SwiftUI view displays. Sample buffers are enqueued here.
    let displayLayer = AVSampleBufferDisplayLayer()
    let fullScreenDisplayLayer = AVSampleBufferDisplayLayer()

    private var client: RTSPClient?
    private var stoppingClient: RTSPClient?
    private var pendingStart: StartRequest?
    private var clientToken = 0
    private var mirrorFullScreen = false
    private var lastSampleBuffer: CMSampleBuffer?
    var hasActiveClient: Bool { client != nil || stoppingClient != nil }

    private struct StartRequest {
        let url: URL
        let credentials: Credentials
        let range: String?
        let scale: Double?
    }

    init() {
        configure(displayLayer)
        configure(fullScreenDisplayLayer)
    }

    func start(url: URL, credentials: Credentials,
               range: String? = nil, scale: Double? = nil) {
        let request = StartRequest(url: url,
                                   credentials: credentials,
                                   range: range,
                                   scale: scale)
        if let client {
            pendingStart = request
            stop(client, statusAfterStop: .connecting)
            return
        }
        if stoppingClient != nil {
            pendingStart = request
            status = .connecting
            flush()
            return
        }
        startFresh(request)
    }

    func stop() {
        pendingStart = nil
        if let client {
            stop(client, statusAfterStop: .idle)
            return
        }
        status = .idle
        flush()
    }

    /// Change playback speed (playback streams only).
    func setScale(_ scale: Double) {
        client?.setScale(scale)
    }

    func pause() {
        client?.pause()
    }

    func resume() {
        client?.resume()
    }

    func seek(nptSeconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let client else {
            completion(false)
            return
        }
        client.seek(nptSeconds: nptSeconds) { success in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    func setFullScreenMirroring(_ enabled: Bool) {
        mirrorFullScreen = enabled
        if enabled {
            fullScreenDisplayLayer.flushAndRemoveImage()
            if let lastSampleBuffer {
                enqueue(lastSampleBuffer, on: fullScreenDisplayLayer, label: "fullscreen restore")
            }
        } else {
            fullScreenDisplayLayer.flushAndRemoveImage()
        }
    }

    func refreshFullScreenFrame() {
        guard mirrorFullScreen, let lastSampleBuffer else { return }
        enqueue(lastSampleBuffer, on: fullScreenDisplayLayer, label: "fullscreen refresh")
    }

    // MARK: Private

    private func startFresh(_ request: StartRequest) {
        status = .connecting
        flush()
        clientToken += 1
        let token = clientToken

        let client = RTSPClient(url: request.url,
                                username: request.credentials.username,
                                password: request.credentials.password,
                                range: request.range,
                                scale: request.scale)
        client.onSampleBuffer = { [weak self] sample in
            // Enqueue on main; the layer decodes & displays.
            DispatchQueue.main.async {
                guard let self, self.clientToken == token else { return }
                self.enqueue(sample)
            }
        }
        client.onState = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.clientToken == token else { return }
                self.apply(state)
            }
        }
        self.client = client
        client.start()
    }

    private func stop(_ client: RTSPClient, statusAfterStop: Status) {
        clientToken += 1
        let token = clientToken
        self.client = nil
        stoppingClient = client
        status = statusAfterStop
        flush()

        client.stop { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.clientToken == token else { return }
                self.stoppingClient = nil
                if let request = self.pendingStart {
                    self.pendingStart = nil
                    self.startFresh(request)
                } else {
                    self.status = .idle
                }
            }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer) {
        lastSampleBuffer = sample
        enqueue(sample, on: displayLayer, label: "inline")
        if mirrorFullScreen {
            enqueue(sample, on: fullScreenDisplayLayer, label: "fullscreen")
        }
        enqueuedCount += 1
        if enqueuedCount == 1 {
            Log.info("first sample enqueued to displayLayer (status=\(displayLayer.status.rawValue), ready=\(displayLayer.isReadyForMoreMediaData))")
        } else if enqueuedCount % 100 == 0 {
            Log.info("enqueued=\(enqueuedCount), layer status=\(displayLayer.status.rawValue), ready=\(displayLayer.isReadyForMoreMediaData)")
        }
    }

    private var enqueuedCount = 0

    private func flush() {
        displayLayer.flushAndRemoveImage()
        fullScreenDisplayLayer.flushAndRemoveImage()
        enqueuedCount = 0
        lastSampleBuffer = nil
    }

    private func configure(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    private func enqueue(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer, label: String) {
        if layer.status == .failed {
            logDisplayLayerFailure(label, phase: "before enqueue", layer: layer)
            layer.flushAndRemoveImage()
        }
        layer.enqueue(sample)
        if layer.status == .failed {
            logDisplayLayerFailure(label, phase: "after enqueue", layer: layer)
        }
    }

    private func logDisplayLayerFailure(_ label: String, phase: String, layer: AVSampleBufferDisplayLayer) {
        let message = layer.error.map { "\($0)" } ?? "unknown"
        Log.info("displayLayer[\(label)] FAILED \(phase): \(message)")
    }

    private func apply(_ state: RTSPClient.State) {
        switch state {
        case .connecting, .describing:
            status = .connecting
        case .playing:
            status = .playing
        case .paused:
            status = .paused
        case .stopped:
            status = .idle
        case .failed(let message):
            status = .error(message)
        }
    }
}
