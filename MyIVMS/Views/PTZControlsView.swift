import SwiftUI

struct PTZControlsView: View {
    let device: Device
    let channel: Int
    @EnvironmentObject var store: DeviceStore

    @State private var speed = 45.0
    @State private var activeDirection: PTZDirection?
    @State private var pressingDirection: PTZDirection?
    @State private var longPressArmed = false
    @State private var longPressTask: Task<Void, Never>?
    @State private var continuousMoveTask: Task<Void, Never>?
    @State private var tapStepTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                directionPad
                zoomControls
                speedControl
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .onDisappear {
            longPressTask?.cancel()
            continuousMoveTask?.cancel()
            tapStepTask?.cancel()
            send(.stop)
        }
    }

    private var speedControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speedometer")
                .foregroundStyle(.secondary)
            Slider(value: $speed, in: 1...100)
                .frame(width: 86)
            Text("\(Int(speed.rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .help("PTZ hold speed")
    }

    private var directionPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                ptzButton(.upLeft, systemImage: "arrow.up.left")
                ptzButton(.up, systemImage: "arrow.up")
                ptzButton(.upRight, systemImage: "arrow.up.right")
            }
            GridRow {
                ptzButton(.left, systemImage: "arrow.left")
                Button {
                    send(.stop)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .frame(width: 28, height: 24)
                .help("Stop PTZ")
                ptzButton(.right, systemImage: "arrow.right")
            }
            GridRow {
                ptzButton(.downLeft, systemImage: "arrow.down.left")
                ptzButton(.down, systemImage: "arrow.down")
                ptzButton(.downRight, systemImage: "arrow.down.right")
            }
        }
    }

    private var zoomControls: some View {
        VStack(spacing: 4) {
            ptzButton(.zoomIn, systemImage: "plus.magnifyingglass")
            ptzButton(.zoomOut, systemImage: "minus.magnifyingglass")
        }
    }

    private func ptzButton(_ direction: PTZDirection, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .frame(width: 28, height: 24)
            .background(activeDirection == direction ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        startPress(direction)
                    }
                    .onEnded { _ in
                        endPress(direction)
                    }
            )
            .help("Click to step, hold to move continuously")
    }

    private func startPress(_ direction: PTZDirection) {
        guard pressingDirection == nil else { return }
        pressingDirection = direction
        longPressArmed = false

        let holdSpeed = Int(speed.rounded())
        longPressTask?.cancel()
        longPressTask = Task {
            do {
                try await Task.sleep(nanoseconds: 260_000_000)
                await MainActor.run {
                    guard pressingDirection == direction else { return }
                    longPressArmed = true
                    activeDirection = direction
                    startContinuousMove(direction, initialSpeed: holdSpeed)
                }
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func endPress(_ direction: PTZDirection) {
        let shouldStopContinuous = longPressArmed
        longPressTask?.cancel()
        longPressTask = nil
        continuousMoveTask?.cancel()
        continuousMoveTask = nil
        pressingDirection = nil
        longPressArmed = false
        activeDirection = nil

        if shouldStopContinuous {
            send(.stop)
        } else {
            step(direction)
        }
    }

    private func startContinuousMove(_ direction: PTZDirection, initialSpeed: Int) {
        continuousMoveTask?.cancel()
        send(direction.vector(speed: initialSpeed))
        continuousMoveTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                    let shouldContinue = await MainActor.run {
                        pressingDirection == direction && longPressArmed
                    }
                    guard shouldContinue else { break }
                    await MainActor.run {
                        send(direction.vector(speed: Int(speed.rounded())))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    private func step(_ direction: PTZDirection) {
        let stepSpeed = Int(speed.rounded())
        tapStepTask?.cancel()
        send(direction.stepVector(controlSpeed: stepSpeed))
        tapStepTask = Task {
            do {
                try await Task.sleep(nanoseconds: direction.stepDurationNanos)
                await MainActor.run {
                    send(.stop)
                    tapStepTask = nil
                }
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func send(_ vector: PTZVector) {
        guard let credentials = store.credentials(for: device) else {
            error = "No password saved."
            return
        }
        let targetChannel = channel
        Task {
            do {
                let client = ISAPIClient(host: device.host,
                                         port: device.httpPort,
                                         credentials: credentials)
                try await client.movePTZ(channel: targetChannel, vector: vector)
                await MainActor.run { error = nil }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}
