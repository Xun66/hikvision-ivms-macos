import SwiftUI

/// SADP-style discovery sheet: scans the LAN and lets the user add a device.
struct DiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = SADPDiscovery()
    var onAdd: (DiscoveredDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Discover Devices").font(.headline)
                Spacer()
                if discovery.isScanning { ProgressView().controlSize(.small) }
                Button(discovery.isScanning ? "Stop" : "Scan") {
                    discovery.isScanning ? discovery.stop() : discovery.start()
                }
            }
            .padding()

            Divider()

            if discovery.found.isEmpty {
                ContentUnavailableView(discovery.isScanning ? "Scanning…" : "No Devices Found",
                                       systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Devices on your local network will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(discovery.found) {
                    TableColumn("IP Address", value: \.ipv4)
                    TableColumn("Model", value: \.deviceType)
                    TableColumn("Serial", value: \.serial)
                    TableColumn("MAC", value: \.mac)
                    TableColumn("") { device in
                        Button("Add") {
                            onAdd(device)
                            dismiss()
                        }
                    }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 420)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }
}
