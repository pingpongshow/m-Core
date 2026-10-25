import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// Manage the radio's channel slots: add hashtag or private channels, share and remove them.
struct ChannelsView: View {
    /// True when shown as a sheet (from Chats); pushed in Settings it has a back button instead.
    var showsDoneButton = false
    @Environment(MessagingService.self) private var messaging
    @Environment(\.dismiss) private var dismiss
    @State private var showingAdd = false
    @State private var sharing: ChannelRecord?
    @State private var errorText: String?

    var body: some View {
        let channels: [ChannelRecord] = {
            _ = messaging.revision
            return messaging.store?.channels() ?? []
        }()
        List {
            Section {
                ForEach(channels, id: \.index) { channel in
                    HStack(spacing: MCSpacing.m) {
                        AvatarView(name: channel.name, kind: channel.avatarKind, size: 36)
                        VStack(alignment: .leading) {
                            Text(channel.name)
                            Text("Slot \(channel.index) · \(channel.kindText)").font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        Button("Share", systemImage: "qrcode") { sharing = channel }
                            .labelStyle(.iconOnly)
                    }
                    .swipeActions {
                        if !channel.isPublic {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task {
                                    do {
                                        try await messaging.removeChannel(index: channel.index)
                                    } catch {
                                        errorText = "Couldn't remove: \(errorMessage(error))"
                                    }
                                }
                            }
                            .tint(MCColor.critical)
                        }
                    }
                }
            } footer: {
                Text("\(channels.count) of \(messaging.maxChannels) slots used on the radio.")
            }
            if let errorText {
                Text(errorText).foregroundStyle(MCColor.critical)
            }
        }
        .navigationTitle("Channels")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add channel", systemImage: "plus") { showingAdd = true }
                    .disabled(messaging.store == nil || channels.count >= messaging.maxChannels)
            }
        }
        .sheet(isPresented: $showingAdd) { AddChannelSheet() }
        .sheet(item: $sharing) { channel in
            ShareCodeSheet(
                title: channel.name,
                url: MeshLink.channel(name: channel.name, secretHex: channel.secret.hexString).url,
                note: channel.isHashtag ? "Anyone who joins \(channel.name) can read it." : "Anyone with this code can read and post."
            )
        }
    }
}

struct AddChannelSheet: View {
    enum Kind: String, CaseIterable {
        case hashtag = "Hashtag"
        case privateChannel = "Private"
    }

    @Environment(MessagingService.self) private var messaging
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .hashtag
    @State private var name = ""
    @State private var secretText = ""
    @State private var errorText: String?
    var prefilledName: String?
    var prefilledSecretHex: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Section {
                    TextField(kind == .hashtag ? "#channel" : "Channel name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if kind == .privateChannel {
                        TextField("Shared key (hex, optional)", text: $secretText)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(kind == .hashtag
                         ? "Hashtag channels use a key derived from the name, so anyone using the same name joins the same channel."
                         : "Leave the key empty to create a new private channel, or paste a 32-character hex key to join one.")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(MCColor.critical)
                }
            }
            .navigationTitle("Add Channel")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                if let prefilledName { name = prefilledName }
                if let prefilledSecretHex, !prefilledSecretHex.isEmpty {
                    kind = .privateChannel
                    secretText = prefilledSecretHex
                }
                if prefilledName?.hasPrefix("#") == true { kind = .hashtag }
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private func add() {
        var channelName = trimmedName
        var secret: Data?
        switch kind {
        case .hashtag:
            if !channelName.hasPrefix("#") { channelName = "#" + channelName }
        case .privateChannel:
            let hex = secretText.trimmingCharacters(in: .whitespaces)
            if !hex.isEmpty {
                guard let data = Data(hexString: hex), data.count == 16 else {
                    errorText = "The key must be 32 hex characters."
                    return
                }
                guard data != Data(count: 16) else {
                    errorText = "An all-zero key isn't private."
                    return
                }
                secret = data
            }
        }
        Task {
            do {
                try await messaging.addChannel(name: channelName, secret: secret)
                dismiss()
            } catch MessagingError.noFreeChannelSlot {
                errorText = "All channel slots on the radio are in use."
            } catch {
                errorText = "Couldn't add: \(errorMessage(error))"
            }
        }
    }
}

/// Shows a QR code and share link.
struct ShareCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: URL
    let note: String

    var body: some View {
        NavigationStack {
            VStack(spacing: MCSpacing.l) {
                if let image = QRCode.image(for: url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .accessibilityLabel("QR code for \(title)")
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: MCRadius.card))
                }
                Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .tint(MCColor.accentFill)
            }
            .padding()
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Log in to a room server or repeater, optionally remembering the password in the Keychain.
struct RemoteLoginSheet: View {
    /// Logs in through the remote-node service so the login is remembered (Manage repeater reads it).
    @Environment(RemoteNodeService.self) private var remote
    @Environment(\.dismiss) private var dismiss
    let keyHex: String
    let title: String
    @State private var password = ""
    @State private var remember = true
    @State private var status: String?
    @State private var isWorking = false
    var onSuccess: ((LoginResult) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Password (blank for guest)", text: $password)
                Toggle("Remember password", isOn: $remember)
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Log in to \(title)")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isWorking ? "Logging in…" : "Log in") { login() }.disabled(isWorking)
                }
            }
            .onAppear { password = Keychain.password(for: keyHex) ?? "" }
        }
        .presentationDetents([.medium])
    }

    private func login() {
        isWorking = true
        status = "Waiting for \(title)…"
        Task {
            defer { isWorking = false }
            do {
                let result = try await remote.login(keyHex: keyHex, password: password)
                Keychain.setPassword(remember ? password : nil, for: keyHex)
                onSuccess?(result)
                dismiss()
            } catch MessagingError.loginFailed {
                status = "Wrong password."
            } catch MessagingError.loginTimedOut {
                status = "No answer. The node may be out of range."
            } catch {
                status = "Couldn't log in: \(errorMessage(error))"
            }
        }
    }
}
