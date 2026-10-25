import CoreLocation
import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// Card for a tapped node pin.
struct NodePinCard: View {
    let contact: ContactRecord
    let phone: CLLocation?
    let onClose: () -> Void
    let onDetails: () -> Void
    let onMessage: (() -> Void)?
    /// The stored path drawn on the map, e.g. "Path: 3 hops · 1 hop without a position".
    var pathNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.m) {
            HStack(spacing: MCSpacing.m) {
                AvatarView(name: contact.displayName, kind: contact.avatarKind)
                VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                    Text(contact.displayName).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    if let pathNote {
                        Label(pathNote, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            HStack {
                Button("Details", systemImage: "info.circle", action: onDetails)
                    .buttonStyle(.bordered)
                if let onMessage {
                    Button("Message", systemImage: "message", action: onMessage)
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                if let coordinate = contact.coordinate {
                    Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        AppleMaps.open(latitude: coordinate.latitude, longitude: coordinate.longitude, label: contact.displayName)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(MCSpacing.l)
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous))
    }

    private var subtitle: String {
        var parts = [contact.advertType.label, contact.hopsText]
        if contact.lastSeen > .distantPast {
            parts.append(RelativeAge.text(seconds: Date().timeIntervalSince(contact.lastSeen)))
        }
        if let phone, let coordinate = contact.coordinate {
            let meters = phone.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            parts.append(Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        return parts.joined(separator: " · ")
    }
}

/// Card for the connected radio's own pin.
struct RadioPinCard: View {
    let name: String
    let coordinate: CLLocationCoordinate2D?
    let phone: CLLocation?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: MCSpacing.m) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.white)
                .frame(width: MCSize.avatarRow, height: MCSize.avatarRow)
                .background(MCColor.accent, in: Circle())
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                Text(name).font(.headline)
                Text(offsetText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(MCSpacing.l)
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous))
    }

    private var offsetText: String {
        guard let coordinate, let phone else { return "Position your radio reports" }
        let meters = phone.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        let distance = Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
        return "Reported position · \(distance) from your phone"
    }
}

/// A node from the Internet Map: add it as a contact before you're in range.
struct InternetNodeCard: View {
    let node: InternetMapNode
    let phone: CLLocation?
    let onClose: () -> Void
    @Environment(InternetMapService.self) private var internetMap
    @Environment(MessagingService.self) private var messaging
    @Environment(RadioController.self) private var radio
    @State private var status: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.m) {
            HStack(spacing: MCSpacing.m) {
                AvatarView(name: node.name, kind: node.type.avatarKind)
                VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                    Text(node.name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
            if let settings = node.radio {
                Label(settings.summary, systemImage: settings == radio.selfInfo?.radio ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(settings == radio.selfInfo?.radio || radio.selfInfo == nil ? Color.secondary : MCColor.warning)
            }
            HStack {
                Button(isAdding ? "Adding…" : "Add as contact", systemImage: "person.badge.plus", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(isAdding || node.advertPacket == nil || !radio.isConnected)
                Spacer()
                Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") {
                    AppleMaps.open(latitude: node.latitude, longitude: node.longitude, label: node.name)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(MCSpacing.l)
        .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.card, style: .continuous))
    }

    private var subtitle: String {
        var parts = [node.type.label, "Internet Map"]
        if let heard = node.lastAdvert ?? node.updated {
            parts.append(RelativeAge.text(seconds: Date().timeIntervalSince(heard)))
        }
        if let phone {
            let meters = phone.distance(from: CLLocation(latitude: node.latitude, longitude: node.longitude))
            parts.append(Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        isAdding = true
        status = nil
        Task {
            defer { isAdding = false }
            do {
                try await internetMap.importContact(node)
                await messaging.syncContacts()
                status = node.radio == radio.selfInfo?.radio || node.radio == nil
                    ? "Added. You can message it once it's in range."
                    : "Added, but it uses different radio settings, so you'll only hear it on those settings."
            } catch let error as InternetMapError {
                status = error.description
            } catch {
                status = "The radio didn't accept it: \(errorMessage(error))"
            }
        }
    }
}
