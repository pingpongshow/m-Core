import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// Remote management of a repeater or room server: status, neighbours, telemetry and the command line.
struct RepeaterAdminView: View {
    let keyHex: String
    @Environment(RemoteNodeService.self) private var remote
    @Environment(MessagingService.self) private var messaging
    @State private var status: RepeaterStatus?
    @State private var neighbours: [Neighbour] = []
    @State private var message: String?
    @State private var isLoading = false
    @State private var showingLogin = false

    private var name: String { messaging.store?.contact(keyHex: keyHex)?.displayName ?? "Repeater" }
    private var isLoggedIn: Bool { remote.logins[keyHex] != nil }
    private var isAdmin: Bool { remote.logins[keyHex]?.isAdmin == true }

    var body: some View {
        List {
            Section {
                LabeledContent("Login", value: remote.logins[keyHex].map { $0.isAdmin ? "Admin" : "Guest" } ?? "Not logged in")
                Button(isLoggedIn ? "Log in again" : "Log in", systemImage: "person.badge.key") { showingLogin = true }
            } footer: {
                Text("Status works for guests; settings and the command line need an admin login.")
            }
            Section {
                Button("Refresh status", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isLoading)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if let status { statusSection(status) }
            if !neighbours.isEmpty { neighboursSection }
            Section {
                NavigationLink {
                    RemoteSettingsView(keyHex: keyHex, title: name)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .disabled(!isAdmin)
                NavigationLink {
                    CommandLineView(keyHex: keyHex, title: name)
                } label: {
                    Label("Command line", systemImage: "terminal")
                }
                .disabled(!isLoggedIn)
            } footer: {
                if isLoggedIn && !isAdmin {
                    Text("Settings need an admin login.")
                }
            }
        }
        .navigationTitle(name)
        .sheet(isPresented: $showingLogin) {
            RemoteLoginSheet(keyHex: keyHex, title: name) { _ in refresh() }
        }
        .task { if status == nil { refresh() } }
    }

    private func statusSection(_ status: RepeaterStatus) -> some View {
        Section("Status") {
            LabeledContent("Battery", value: String(format: "%.2f V", Double(status.batteryMillivolts) / 1000))
            LabeledContent(
                "Uptime",
                value: Duration.seconds(Int(status.uptimeSeconds))
                    .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
            )
            LabeledContent("Noise floor", value: "\(status.noiseFloor) dBm")
            LabeledContent("Last signal") {
                HStack { SignalBars(snr: status.lastSNR); Text("\(status.lastRSSI) dBm · \(status.lastSNR.formatted()) dB") }
            }
            LabeledContent("Packets", value: "\(status.packetsReceived) in · \(status.packetsSent) out")
            LabeledContent("Flood / direct sent", value: "\(status.sentFlood) / \(status.sentDirect)")
            LabeledContent("Flood / direct received", value: "\(status.receivedFlood) / \(status.receivedDirect)")
            LabeledContent("Duplicates dropped", value: "\(status.floodDuplicates + status.directDuplicates)")
            LabeledContent("Airtime", value: "TX \(minutes(status.airtimeSeconds)) · RX \(minutes(status.rxAirtimeSeconds ?? 0))")
            if let errors = status.receiveErrors { LabeledContent("Receive errors", value: "\(errors)") }
            LabeledContent("Queue", value: "\(status.txQueueLength)")
        }
    }

    private var neighboursSection: some View {
        Section("Neighbours (\(neighbours.count))") {
            ForEach(neighbours, id: \.self) { neighbour in
                let contact = messaging.store?.contact(prefixHex: neighbour.keyPrefixHex)
                HStack {
                    AvatarView(name: contact?.displayName ?? neighbour.keyPrefixHex, kind: contact?.avatarKind ?? .repeater, size: 32)
                    VStack(alignment: .leading) {
                        Text(contact?.displayName ?? neighbour.keyPrefixHex.uppercased())
                        Text("Heard \(RelativeAge.text(seconds: TimeInterval(neighbour.heardSecondsAgo)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SignalBars(snr: neighbour.snr)
                    Text("\(neighbour.snr.formatted()) dB").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func minutes(_ seconds: UInt32) -> String {
        Duration.seconds(Int(seconds)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func refresh() {
        isLoading = true
        message = "Asking \(name)…"
        Task {
            defer { isLoading = false }
            do {
                status = try await remote.status(keyHex: keyHex)
                neighbours = (try? await remote.neighbours(keyHex: keyHex)) ?? neighbours
                message = nil
            } catch RemoteRequestError.timedOut {
                message = "No answer. \(name) may be out of range."
            } catch {
                message = "Failed: \(errorMessage(error))"
            }
        }
    }
}

/// A terminal for repeater/room commands, or the connected radio's own CLI when `keyHex` is nil.
struct CommandLineView: View {
    let keyHex: String?
    let title: String
    @Environment(RemoteNodeService.self) private var remote
    @Environment(RadioController.self) private var radio
    @State private var command = ""
    @State private var isRunning = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private static let quickCommands = ["ver", "clock", "neighbors", "get radio", "get tx", "advert", "stats-core"]

    private var transcriptKey: String { keyHex ?? radio.selfInfo?.publicKey.hex ?? "local" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MCSpacing.xs) {
                    ForEach(remote.transcripts[transcriptKey] ?? []) { entry in
                        Text(entry.isCommand ? "> \(entry.text)" : entry.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(entry.isCommand ? MCColor.accent : Color.primary)
                            .textSelection(.enabled)
                            .accessibilityLabel(entry.isCommand ? "You sent: \(entry.text)" : entry.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(MCColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Self.quickCommands, id: \.self) { quick in
                        Button(quick) { run(quick) }.buttonStyle(.bordered).controlSize(.small).disabled(isRunning)
                    }
                }
                .padding(.horizontal)
            }
            HStack {
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { run(command) }
                Button("Run", systemImage: "return") { run(command) }
                    .disabled(command.isEmpty || isRunning)
            }
            .padding()
        }
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func run(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isRunning else { return }
        command = ""
        isRunning = true
        errorText = nil
        Task {
            defer { isRunning = false }
            // Replies land in the transcript; failures don't, so show them here.
            do {
                if let keyHex {
                    _ = try await remote.runCommand(trimmed, keyHex: keyHex)
                } else {
                    _ = try await remote.runLocalCommand(trimmed)
                }
            } catch RemoteRequestError.timedOut {
                errorText = "No reply to “\(trimmed)”. \(title) may be out of range."
            } catch {
                errorText = "“\(trimmed)” failed: \(errorMessage(error))"
            }
        }
    }
}
