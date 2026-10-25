import MeshDesign
import MeshServices
import SwiftUI

/// Optional phone-as-observer uplink (off by default).
struct ObserverSettingsView: View {
    @Environment(ObserverService.self) private var observer
    @State private var draft = ObserverSettings()
    @State private var password = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Share heard packets", isOn: $draft.isEnabled)
                statusRow
            } footer: {
                Text("""
                    Sends every packet your radio hears to an MQTT broker, so community maps and analyzers can see \
                    your part of the mesh. Message contents stay encrypted; packet headers, signal strength and your \
                    radio's public key are shared.
                    """)
            }
            Section {
                Picker("Broker", selection: $draft.broker) {
                    ForEach(ObserverSettings.Broker.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // Labelled, so a filled-in code isn't a bare "SFO" with nothing saying what it is.
                LabeledContent("Region code") {
                    TextField("e.g. SFO", text: $draft.iata)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Only on Wi-Fi", isOn: $draft.wifiOnly)
                Toggle("Pause in background", isOn: $draft.pauseInBackground)
            } footer: {
                if draft.broker == .custom {
                    Text("""
                        The region code is the nearest airport's three-letter IATA code. Pause in background disconnects \
                        while m-Core isn't open.
                        """)
                } else {
                    Text("""
                        LetsMesh signs you in with a token your radio signs, so no password is needed. The region code \
                        is the nearest airport's three-letter IATA code. Pause in background disconnects while m-Core \
                        isn't open.
                        """)
                }
            }
            if draft.broker == .custom {
                Section("Custom broker") {
                    TextField("Host", text: $draft.customHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    LabeledContent("Port") {
                        TextField("Port", value: $draft.customPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Connection", selection: $draft.customTransport) {
                        ForEach(ObserverSettings.CustomTransport.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if draft.customTransport == .webSocket || draft.customTransport == .secureWebSocket {
                        TextField("Path", text: $draft.customPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Username", text: $draft.customUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            }
            if let topic = observer.packetsTopic, observer.settings.isEnabled {
                Section("Publishing to") {
                    Text(topic).font(.caption.monospaced()).textSelection(.enabled)
                    LabeledContent("Packets sent", value: observer.packetsSent.formatted())
                }
            }
        }
        .navigationTitle("Observer Uplink")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = observer.settings
            password = observer.customPassword
        }
        // Applied after a pause in typing, so a running uplink isn't restarted on every keystroke.
        .task(id: draft) {
            guard loaded, draft != observer.settings else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            observer.update(draft)
        }
        .onDisappear { if loaded { observer.update(draft) } }
        .onChange(of: password) { observer.customPassword = password }
    }

    @ViewBuilder private var statusRow: some View {
        switch observer.status {
        case .off:
            EmptyView()
        case .needsSetup(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(MCColor.warning)
        case .waitingForRadio:
            Label("Waiting for your radio", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
        case .waitingForWiFi:
            Label("Paused until you're on Wi-Fi", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case .pausedInBackground:
            Label("Paused while m-Core is in the background", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .connecting:
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .connected(let since):
            Label("Connected since \(since.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(MCColor.positive)
        case let .retrying(reason, at):
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(MCColor.warning)
                Text("Retrying at \(at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
