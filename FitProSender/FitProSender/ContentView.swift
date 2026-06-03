import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: FitProBLEManager
    @State private var message = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case message
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Please pair the watch first.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    connectionSection
                    smsSection
                    logSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                setCurrentTimeIfEmpty()
            }
            .navigationTitle("LT716 Sender")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Status")
                    .font(.body)
                Spacer()
                Text(ble.status)
                    .font(.body.weight(.semibold))
            }

            HStack {
                Button("Connect") {
                    focusedField = nil
                    ble.scanAndConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ble.isConnected || ble.isConnectionBusy || ble.isCommandBusy)

                Button("Disconnect") {
                    focusedField = nil
                    ble.disconnect()
                }
                .buttonStyle(.bordered)
                .disabled(!ble.isConnected || ble.isSMSBusy || ble.isCommandBusy)
            }

            Toggle("Vibration", isOn: $ble.isVibrationEnabled)

            if !ble.discoveredDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ble.discoveredDevices.prefix(8)) { device in
                        Button {
                            focusedField = nil
                            ble.connect(deviceID: device.id)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text("RSSI \(device.rssi)  \(device.serviceSummary)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if device.isMatch {
                                    Text("Match")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(ble.isConnected || ble.isConnectionBusy || ble.isCommandBusy)
                    }
                }
            }
        }
    }

    private var smsSection: some View {
        VStack(spacing: 12) {
            TextEditor(text: $message)
                .font(.body)
                .frame(minHeight: 96, maxHeight: 180)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .message)

            Button(ble.isSMSBusy ? "Sending..." : "Send") {
                sendSMS()
            }
            .buttonStyle(.borderedProminent)
            .disabled(message.isEmpty || ble.isSMSBusy || ble.isConnectionBusy || ble.isCommandBusy)
        }
    }

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ble.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 160, maxHeight: 300)
            .onChange(of: ble.logLines.count) { _, newValue in
                guard newValue > 0 else { return }
                proxy.scrollTo(newValue - 1, anchor: .bottom)
            }
        }
    }

    private func sendSMS() {
        guard !message.isEmpty, !ble.isSMSBusy, !ble.isCommandBusy else {
            return
        }
        focusedField = nil
        ble.sendSMSNotification(text: message, asciiOnly: false)
    }

    private func setCurrentTimeIfEmpty() {
        guard message.isEmpty else {
            return
        }
        message = ContentView.currentTimeMessage()
    }

    private static func currentTimeMessage() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
