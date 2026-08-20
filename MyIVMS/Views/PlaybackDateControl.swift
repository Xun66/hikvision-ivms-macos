import SwiftUI

struct PlaybackDateControl: View {
    @Binding var day: Date
    @State private var showingCalendar = false

    private let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 6) {
            Text("Date")
                .foregroundStyle(.secondary)

            Button {
                shiftDay(-1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Previous Day")

            Button {
                showingCalendar.toggle()
            } label: {
                Text(displayFormatter.string(from: day))
                    .font(.body.monospacedDigit())
                    .frame(width: 92)
            }
            .popover(isPresented: $showingCalendar) {
                DatePicker("", selection: dayBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
            }

            Button {
                shiftDay(1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Next Day")
        }
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { day },
            set: { newValue in
                day = Calendar.current.startOfDay(for: newValue)
            }
        )
    }

    private func shiftDay(_ amount: Int) {
        let start = Calendar.current.startOfDay(for: day)
        day = Calendar.current.date(byAdding: .day, value: amount, to: start) ?? start
    }
}
