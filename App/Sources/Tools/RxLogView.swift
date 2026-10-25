import MeshCoreKit
import MeshDesign
import MeshServices
import MeshTools
import SwiftUI
import UniformTypeIdentifiers

/// Every packet the radio hears, decoded.
struct RxLogView: View {
    @Environment(RxLogService.self) private var log
    @Environment(MessagingService.self) private var messaging
    @State private var typeFilter: String?

    var body: some View {
        @Bindable var log = log
        let records = log.records.filter { typeFilter == nil || ($0.packet?.payloadType.name ?? "Unknown") == typeFilter }
        let names = contactNamesByHash
        List {
            Section {
                LabeledContent("Heard since launch", value: log.totalHeard.formatted())
                Toggle("Pause", isOn: $log.isPaused)
                if !records.isEmpty {
                    ShareLink(item: RxLogCSV(records: records), preview: SharePreview(csvTitle(count: records.count))) {
                        Label(typeFilter == nil ? "Export CSV" : "Export \(typeFilter ?? "") as CSV", systemImage: "tablecells")
                    }
                }
            } footer: {
                Text("Kept on this device only and cleared when m-Core quits. The export includes the packets shown.")
            }
            if records.isEmpty {
                ContentUnavailableView("Nothing heard yet", systemImage: "waveform",
                                       description: Text("Packets appear here as your radio hears them."))
            }
            ForEach(records) { record in
                NavigationLink {
                    RxPacketDetailView(record: record)
                } label: {
                    RxLogRow(record: record, senderName: senderName(for: record, names: names))
                }
            }
        }
        .navigationTitle("RX Log")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: $typeFilter) {
                        Text("All types").tag(String?.none)
                        ForEach(log.countsByType, id: \.name) { item in
                            Text("\(item.name) (\(item.count))").tag(Optional(item.name))
                        }
                    }
                    Button("Clear", systemImage: "trash", role: .destructive) { log.clear() }
                        .foregroundStyle(MCColor.critical)
                } label: {
                    Label(
                        "Options",
                        systemImage: typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
                    )
                }
            }
        }
    }

    private func csvTitle(count: Int) -> String {
        "RX log, \(count) packet\(count == 1 ? "" : "s") (CSV)"
    }

    /// Display names by one-byte key hash, built with one contact fetch per render rather than one per row (the log
    /// re-renders on every packet). The first contact by name wins, as with `contact(prefixHex:)`.
    private var contactNamesByHash: [String: String] {
        _ = messaging.revision
        var names: [String: String] = [:]
        for contact in messaging.store?.contacts() ?? [] where names[String(contact.keyHex.prefix(2))] == nil {
            names[String(contact.keyHex.prefix(2))] = contact.displayName
        }
        return names
    }

    private func senderName(for record: RxLogRecord, names: [String: String]) -> String? {
        if let advert = record.packet?.advert { return advert.name }
        guard let source = record.packet?.addressHashes?.source else { return nil }
        return names[String(format: "%02x", source)]
    }
}

/// The shown RX log records as a CSV file, written only when the user shares it.
struct RxLogCSV: Transferable {
    let records: [RxLogRecord]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let url = FileManager.default.temporaryDirectory.appending(path: "m-Core RX log \(stamp).csv")
            try RxLogService.csv(export.records).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

private struct RxLogRow: View {
    let record: RxLogRecord
    let senderName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.xxs) {
            HStack {
                Text(record.packet?.payloadType.name ?? "Unreadable")
                    .font(.body.weight(.medium))
                if let route = record.packet?.routeType {
                    Text(route.logLetter == "D" ? "Direct" : "Flood")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MCColor.chipBackground, in: Capsule())
                }
                Spacer()
                Text(record.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: MCSpacing.s) {
                SignalBars(snr: record.snr)
                Text("\(record.snr.formatted()) dB · \(record.rssi) dBm")
                if let packet = record.packet {
                    Text("· \(packet.hopCount) hop\(packet.hopCount == 1 ? "" : "s")")
                }
                if let senderName {
                    Text("· \(senderName)").lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RxPacketDetailView: View {
    let record: RxLogRecord
    @Environment(InternetMapService.self) private var internetMap
    @Environment(RadioController.self) private var radio
    @State private var confirmUpload = false
    @State private var uploadStatus: String?

    var body: some View {
        List {
            Section("Signal") {
                LabeledContent("Received", value: record.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("SNR", value: "\(record.snr.formatted()) dB")
                LabeledContent("RSSI", value: "\(record.rssi) dBm")
                LabeledContent("Size", value: "\(record.raw.count) bytes")
            }
            if let packet = record.packet {
                Section("Packet") {
                    LabeledContent("Type", value: packet.payloadType.name)
                    LabeledContent("Route", value: packet.routeType.name)
                    LabeledContent("Hash", value: packet.hashHex).font(.body.monospaced())
                    if packet.hopCount > 0 {
                        LabeledContent("Path", value: packet.path.hashes.map { Data($0).hexString.uppercased() }.joined(separator: " → "))
                    }
                    if let addresses = packet.addressHashes {
                        LabeledContent("From → to", value: String(format: "%02X → %02X", addresses.source, addresses.destination))
                    }
                    if let channel = packet.channelHash {
                        LabeledContent("Channel hash", value: String(format: "%02X", channel))
                    }
                }
                if let advert = packet.advert {
                    Section("Advert") {
                        if let name = advert.name { LabeledContent("Name", value: name) }
                        LabeledContent("Type", value: advert.type.label)
                        LabeledContent("Key", value: advert.publicKey.prefix.hex.uppercased())
                        if let latitude = advert.latitude, let longitude = advert.longitude {
                            LabeledContent("Position", value: String(format: "%.5f, %.5f", latitude, longitude))
                        }
                        LabeledContent("Sent", value: advert.timestampDate.formatted(date: .abbreviated, time: .standard))
                        if advert.type == .repeater || advert.type == .room || advert.type == .sensor {
                            Button("Add to Internet Map", systemImage: "globe") { confirmUpload = true }
                                .disabled(!radio.isConnected || advert.latitude == nil)
                                .confirmationDialog(
                                    "Add this node to the public map?", isPresented: $confirmUpload, titleVisibility: .visible
                                ) {
                                    Button("Add to map") { upload() }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("Its signed advert and your radio's settings are sent to map.meshcore.io, signed by your radio.")
                                }
                            if let uploadStatus { Text(uploadStatus).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Raw") {
                Text(record.raw.hexString.uppercased())
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(record.packet?.payloadType.name ?? "Packet")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func upload() {
        uploadStatus = "Uploading…"
        Task {
            do {
                uploadStatus = try await internetMap.upload(advertPacket: record.raw) ?? "Sent. It can take a few minutes to appear."
            } catch let error as InternetMapError {
                uploadStatus = error.description
            } catch {
                uploadStatus = "Upload failed: \(error.localizedDescription)"
            }
        }
    }
}
