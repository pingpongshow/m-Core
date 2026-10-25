import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI

/// Listens on several LoRa settings in turn to find which ones are in use nearby.
struct DiscoveryView: View {
    @Environment(MeshDiscoveryService.self) private var discovery
    @Environment(RadioController.self) private var radio
    @Environment(PresetCatalog.self) private var presetCatalog
    @State private var selected: Set<String> = []
    @State private var dwellSeconds = 60
    @State private var expandedRegions: Set<String> = []
    @State private var editing: PresetDraft?

    var body: some View {
        List {
            Section {
                ForEach(presetCatalog.presets) { preset in
                    PresetRow(preset: preset, isSelected: selected.contains(preset.id)) { toggle(preset) }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                selected.remove(preset.id)
                                presetCatalog.delete(id: preset.id)
                            }
                            .tint(MCColor.critical)
                            Button("Edit", systemImage: "pencil") { editing = PresetDraft(preset) }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = PresetDraft(preset) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                selected.remove(preset.id)
                                presetCatalog.delete(id: preset.id)
                            }
                        }
                }
                Button("Add custom setting", systemImage: "plus") {
                    editing = PresetDraft(radio: radio.selfInfo?.radio)
                }
            } header: {
                Text("My settings")
            } footer: {
                Text("Add the frequency and LoRa settings a local mesh uses if they aren't listed below.")
            }
            ForEach(presetCatalog.regions, id: \.self) { region in
                let presets = presetCatalog.official.filter { $0.region == region }
                let count = presets.filter { selected.contains($0.id) }.count
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedRegions.contains(region) },
                        set: { if $0 { expandedRegions.insert(region) } else { expandedRegions.remove(region) } }
                    )) {
                        ForEach(presets) { preset in
                            PresetRow(preset: preset, isSelected: selected.contains(preset.id)) { toggle(preset) }
                        }
                    } label: {
                        LabeledContent(region, value: count > 0 ? "\(count) selected" : "")
                    }
                }
            }
            Section {
                Picker("Listen on each for", selection: $dwellSeconds) {
                    Text("30 s").tag(30)
                    Text("1 min").tag(60)
                    Text("3 min").tag(180)
                    Text("5 min").tag(300)
                }
                if discovery.isRunning {
                    statusRow
                    Button("Stop", role: .destructive) { discovery.cancel() }
                } else {
                    Button("Start scan (\(selected.count))", systemImage: "play.fill") {
                        let presets = presetCatalog.allPresets.filter { selected.contains($0.id) }
                        discovery.start(presets: presets, dwell: .seconds(dwellSeconds))
                    }
                    .disabled(selected.isEmpty || !radio.isConnected)
                }
                if let error = discovery.lastError { Text(error).font(.footnote).foregroundStyle(MCColor.warning) }
            } footer: {
                Text("""
                    Your radio is unreachable on its usual settings while scanning. m-Core always switches back \
                    afterwards, even if the scan is interrupted.
                    """)
            }
            if !discovery.results.isEmpty {
                Section("Results") {
                    ForEach(discovery.results) { result in
                        VStack(alignment: .leading, spacing: MCSpacing.xs) {
                            HStack {
                                Text(result.preset.name).font(.headline)
                                Spacer()
                                Text("\(result.nodes.count) nodes · \(result.packetsHeard) packets")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !result.nodes.isEmpty {
                                Text(result.nodes.map(\.name).joined(separator: ", ")).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Mesh Discovery")
        .sheet(item: $editing) { draft in
            CustomPresetEditor(draft: draft) { saved in
                selected.insert(saved.id)
            }
        }
        .onAppear(perform: preselect)
        .task { await presetCatalog.refreshOfficial() }
    }

    private func toggle(_ preset: RadioPreset) {
        if selected.contains(preset.id) { selected.remove(preset.id) } else { selected.insert(preset.id) }
    }

    /// Starts with the presets of the radio's region (or, with no matching preset, its band) and the user's own
    /// settings in that band, and opens those regions.
    private func preselect() {
        guard selected.isEmpty, let current = radio.selfInfo?.radio else { return }
        let sameBand = presetCatalog.allPresets.filter { $0.radio.frequencyKHz / 100_000 == current.frequencyKHz / 100_000 }
        let picks: [RadioPreset]
        if let region = presetCatalog.official.first(where: { $0.radio == current })?.region {
            picks = sameBand.filter { $0.region == region || $0.isCustom }
        } else {
            picks = sameBand
        }
        selected = Set(picks.map(\.id))
        expandedRegions = Set(picks.map(\.region))
    }

    @ViewBuilder
    private var statusRow: some View {
        switch discovery.state {
        case let .listening(preset, index, total, endsAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LabeledContent("Listening on \(preset.name) (\(index + 1)/\(total))",
                               value: "\(max(0, Int(endsAt.timeIntervalSince(context.date)))) s")
            }
        case .restoring:
            Text("Restoring your settings…")
        default:
            EmptyView()
        }
    }
}

private struct PresetRow: View {
    let preset: RadioPreset
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                VStack(alignment: .leading) {
                    Text(preset.name).foregroundStyle(Color.primary)
                    Text(preset.radio.summary + (preset.pathHashSize.map { " · \($0)-byte paths" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? MCColor.accent : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension RadioParameters {
    /// "910.525 MHz · 62.5 kHz · SF7 · CR5"
    var summary: String {
        let frequency = frequencyMHz.formatted(.number.precision(.fractionLength(0...3)))
        return "\(frequency) MHz · \(bandwidthKHz.formatted()) kHz · SF\(spreadingFactor) · CR\(codingRate)"
    }
}

/// Values being typed into the custom setting editor.
struct PresetDraft: Identifiable {
    var id: String?
    var name = ""
    var frequencyMHz = 910.525
    var bandwidthKHz = 62.5
    var spreadingFactor = 7
    var codingRate = 5

    init(radio: RadioParameters?) {
        if let radio {
            frequencyMHz = radio.frequencyMHz
            bandwidthKHz = radio.bandwidthKHz
            spreadingFactor = Int(radio.spreadingFactor)
            codingRate = Int(radio.codingRate)
        }
    }

    init(_ preset: RadioPreset) {
        self.init(radio: preset.radio)
        id = preset.id
        name = preset.name
    }
}

struct CustomPresetEditor: View {
    @State var draft: PresetDraft
    let onSave: (RadioPreset) -> Void
    @Environment(PresetCatalog.self) private var presetCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Valley mesh)", text: $draft.name)
                }
                Section {
                    LabeledContent("Frequency") {
                        HStack(spacing: MCSpacing.xs) {
                            TextField("MHz", value: $draft.frequencyMHz, format: .number.precision(.fractionLength(0...3)))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                            Text("MHz").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Bandwidth", selection: $draft.bandwidthKHz) {
                        ForEach(PresetCatalog.bandwidthsKHz, id: \.self) { Text("\($0.formatted()) kHz").tag($0) }
                    }
                    Picker("Spreading factor", selection: $draft.spreadingFactor) {
                        ForEach(5...12, id: \.self) { Text("SF\($0)").tag($0) }
                    }
                    Picker("Coding rate", selection: $draft.codingRate) {
                        ForEach(5...8, id: \.self) { Text("4/\($0)").tag($0) }
                    }
                } footer: {
                    Text("Use the exact values your local mesh publishes. Radios only hear each other when all four match.")
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(MCColor.critical)
                }
            }
            .navigationTitle(draft.id == nil ? "Custom Setting" : "Edit Setting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        do {
            let preset = try presetCatalog.save(
                id: draft.id, name: draft.name, frequencyMHz: draft.frequencyMHz, bandwidthKHz: draft.bandwidthKHz,
                spreadingFactor: draft.spreadingFactor, codingRate: draft.codingRate
            )
            onSave(preset)
            dismiss()
        } catch {
            self.error = error.description
        }
    }
}
