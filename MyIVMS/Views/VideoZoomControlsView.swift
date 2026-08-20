import SwiftUI

struct VideoZoomControlsView: View {
    @Binding var scale: CGFloat
    @Binding var selectionMode: Bool
    let minScale: CGFloat
    let maxScale: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            iconButton("plus.magnifyingglass", help: "Zoom In") {
                scale = min(maxScale, scale * 1.35)
            }
            .disabled(scale >= maxScale)

            iconButton("minus.magnifyingglass", help: "Zoom Out") {
                scale = max(minScale, scale / 1.35)
                if scale == minScale { selectionMode = false }
            }
            .disabled(scale <= minScale)

            iconButton("1.magnifyingglass", help: "Actual Size") {
                scale = minScale
                selectionMode = false
            }
            .disabled(scale == minScale && !selectionMode)

            iconButton(selectionMode ? "viewfinder.circle.fill" : "viewfinder",
                       help: "Zoom To Selection") {
                selectionMode.toggle()
            }
        }
        .buttonStyle(.borderless)
    }

    private func iconButton(_ systemName: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 24, height: 24)
        }
        .help(help)
    }
}
