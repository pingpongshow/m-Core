import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI

/// Adds a contact shared as a `meshcore://contact/add` link.
struct ContactImportSheet: View {
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @Environment(\.dismiss) private var dismiss
    let link: MeshLink
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                if case let .contact(name, keyHex, type) = link {
                    LabeledContent("Name", value: name.isEmpty ? "Unnamed" : name)
                    LabeledContent("Type", value: AdvertType(rawValue: UInt8(clamping: type)).label)
                    LabeledContent("Key") { Text(keyHex.prefix(12).uppercased()).font(.body.monospaced()) }
                }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                } else if !radio.isConnected {
                    Text("Connect a radio to add this contact to it.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Contact")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!radio.isConnected)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add() {
        guard case let .contact(name, keyHex, type) = link, let key = PublicKey(hex: keyHex) else {
            status = "This link doesn't contain a valid contact key."
            return
        }
        Task {
            do {
                guard let session = await radio.session() else { throw MessagingError.notConnected }
                let contact = Contact(publicKey: key, type: AdvertType(rawValue: UInt8(clamping: type)), name: name)
                try await session.perform(.addUpdateContact(contact))
                await messaging.syncContacts()
                dismiss()
            } catch {
                status = "Couldn't add: \(errorMessage(error))"
            }
        }
    }
}

extension AdvertType {
    var label: String {
        switch self {
        case .chat: "Companion"
        case .repeater: "Repeater"
        case .room: "Room server"
        case .sensor: "Sensor"
        case .none: "Unknown"
        case .other(let raw): "Type \(raw)"
        }
    }
}
