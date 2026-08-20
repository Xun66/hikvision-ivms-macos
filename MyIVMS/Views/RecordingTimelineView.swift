import SwiftUI

struct RecordingTimelineView: View {
    let day: Date
    let recordings: [Recording]
    var visibleStart: Date? = nil
    var visibleEnd: Date? = nil
    @Binding var currentTime: Date
    var onScrub: (Date, Bool) -> Void

    private var dayStart: Date {
        Calendar.current.startOfDay(for: day)
    }

    private var dayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    }

    private var timelineStart: Date {
        max(visibleStart ?? dayStart, dayStart)
    }

    private var timelineEnd: Date {
        min(visibleEnd ?? dayEnd, dayEnd)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 18)

                ForEach(segments, id: \.id) { segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue.opacity(0.78))
                        .frame(width: max(2, width * segment.widthFraction),
                               height: 18)
                        .offset(x: width * segment.startFraction)
                }

                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: 30)
                    .offset(x: min(width - 2, max(0, width * positionFraction(for: currentTime))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(time(at: value.location.x, width: width), false)
                    }
                    .onEnded { value in
                        onScrub(time(at: value.location.x, width: width), true)
                    }
            )
            .overlay(alignment: .bottom) {
                HStack {
                    tick(at: 0)
                    Spacer()
                    tick(at: 0.25)
                    Spacer()
                    tick(at: 0.5)
                    Spacer()
                    tick(at: 0.75)
                    Spacer()
                    tick(at: 1)
                }
                .padding(.top, 24)
                .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 50)
    }

    private var segments: [TimelineSegment] {
        recordings.compactMap { recording in
            let start = max(recording.start, timelineStart)
            let end = min(recording.end, timelineEnd)
            guard end > start else { return nil }
            return TimelineSegment(id: recording.id,
                                   startFraction: positionFraction(for: start),
                                   widthFraction: end.timeIntervalSince(start) / timelineEnd.timeIntervalSince(timelineStart))
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Date {
        let fraction = min(1, max(0, x / width))
        return timelineStart.addingTimeInterval(timelineEnd.timeIntervalSince(timelineStart) * fraction)
    }

    private func positionFraction(for date: Date) -> Double {
        guard timelineEnd > timelineStart else { return 0 }
        return min(1, max(0, date.timeIntervalSince(timelineStart) / timelineEnd.timeIntervalSince(timelineStart)))
    }

    private func tick(at fraction: Double) -> some View {
        Text(tickText(at: fraction))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func tickText(at fraction: Double) -> String {
        let date = timelineStart.addingTimeInterval(timelineEnd.timeIntervalSince(timelineStart) * fraction)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct TimelineSegment {
    var id: UUID
    var startFraction: Double
    var widthFraction: Double
}
