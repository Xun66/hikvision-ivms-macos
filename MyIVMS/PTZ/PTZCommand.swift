import Foundation

struct PTZVector: Equatable {
    var pan: Int
    var tilt: Int
    var zoom: Int

    static let stop = PTZVector(pan: 0, tilt: 0, zoom: 0)

    var clamped: PTZVector {
        PTZVector(pan: Self.clamp(pan), tilt: Self.clamp(tilt), zoom: Self.clamp(zoom))
    }

    private static func clamp(_ value: Int) -> Int {
        min(100, max(-100, value))
    }
}

enum PTZDirection {
    case up
    case down
    case left
    case right
    case upLeft
    case upRight
    case downLeft
    case downRight
    case zoomIn
    case zoomOut

    func vector(speed: Int) -> PTZVector {
        let s = min(100, max(1, speed))
        switch self {
        case .up: return PTZVector(pan: 0, tilt: s, zoom: 0)
        case .down: return PTZVector(pan: 0, tilt: -s, zoom: 0)
        case .left: return PTZVector(pan: -s, tilt: 0, zoom: 0)
        case .right: return PTZVector(pan: s, tilt: 0, zoom: 0)
        case .upLeft: return PTZVector(pan: -s, tilt: s, zoom: 0)
        case .upRight: return PTZVector(pan: s, tilt: s, zoom: 0)
        case .downLeft: return PTZVector(pan: -s, tilt: -s, zoom: 0)
        case .downRight: return PTZVector(pan: s, tilt: -s, zoom: 0)
        case .zoomIn: return PTZVector(pan: 0, tilt: 0, zoom: s)
        case .zoomOut: return PTZVector(pan: 0, tilt: 0, zoom: -s)
        }
    }

    func stepVector(controlSpeed: Int) -> PTZVector {
        vector(speed: min(100, max(70, controlSpeed + 35)))
    }

    var stepDurationNanos: UInt64 {
        switch self {
        case .zoomIn, .zoomOut:
            return 180_000_000
        default:
            return 300_000_000
        }
    }
}
