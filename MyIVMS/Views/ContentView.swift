import SwiftUI

/// Carries a device + its password into the add/edit sheet.
struct EditorContext: Identifiable {
    let id = UUID()
    var device: Device
    var password: String
    var isNew: Bool
}

struct ContentView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var selection: Device.ID?
    @State private var showDiscovery = false
    @State private var editor: EditorContext?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    ForEach(store.devices) { device in
                        Label(device.displayName, systemImage: "video.fill")
                            .tag(device.id)
                            .contextMenu {
                                Button("Edit…") { edit(device) }
                                Button("Remove", role: .destructive) { store.remove(device) }
                            }
                    }
                }
            }
            .navigationTitle("MyIVMS")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showDiscovery = true
                    } label: {
                        Label("Discover", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        editor = EditorContext(device: Device(name: "", host: ""),
                                               password: "", isNew: true)
                    } label: {
                        Label("Add Device", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let id = selection, let device = store.devices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else {
                ContentUnavailableView("No Device Selected",
                                       systemImage: "video.slash",
                                       description: Text("Add or discover a Hikvision device to begin."))
            }
        }
        .sheet(isPresented: $showDiscovery) {
            DiscoveryView { discovered in
                editor = EditorContext(device: draft(from: discovered),
                                       password: "", isNew: true)
            }
        }
        .sheet(item: $editor) { ctx in
            AddDeviceView(context: ctx) { device, password in
                store.upsert(device, password: password)
                selection = device.id
            }
        }
    }

    private func edit(_ device: Device) {
        editor = EditorContext(device: device,
                               password: store.password(for: device) ?? "",
                               isNew: false)
    }

    private func draft(from d: DiscoveredDevice) -> Device {
        Device(name: d.description_.isEmpty ? d.deviceType : d.description_,
               host: d.ipv4,
               rtspPort: 554,
               httpPort: d.httpPort,
               username: "admin",
               model: d.deviceType,
               serial: d.serial,
               firmware: d.firmware,
               mac: d.mac)
    }
}
