import SwiftUI

/// Add / edit a device. Password is stored in the Keychain via `DeviceStore`.
struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var device: Device
    @State private var password: String
    private let isNew: Bool
    private let onSave: (Device, String) -> Void

    init(context: EditorContext, onSave: @escaping (Device, String) -> Void) {
        _device = State(initialValue: context.device)
        _password = State(initialValue: context.password)
        self.isNew = context.isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Device" : "Edit Device")
                .font(.headline)
                .padding()
            Divider()

            Form {
                Section("Identity") {
                    TextField("Name", text: $device.name, prompt: Text("My Camera"))
                    TextField("Host / IP", text: $device.host, prompt: Text("nvr.local"))
                }
                Section("Ports") {
                    TextField("RTSP Port", value: $device.rtspPort, format: .number.grouping(.never))
                    TextField("HTTP Port", value: $device.httpPort, format: .number.grouping(.never))
                }
                Section("Credentials") {
                    TextField("Username", text: $device.username)
                    SecureField("Password", text: $password)
                }
                if !device.model.isEmpty || !device.serial.isEmpty {
                    Section("Info") {
                        if !device.model.isEmpty { LabeledContent("Model", value: device.model) }
                        if !device.serial.isEmpty { LabeledContent("Serial", value: device.serial) }
                        if !device.firmware.isEmpty { LabeledContent("Firmware", value: device.firmware) }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(device, password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(device.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 520)
    }
}
