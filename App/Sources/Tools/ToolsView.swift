import Charts
import MeshCoreKit
import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

struct ToolsView: View {
    @Environment(RadioController.self) private var radio

    var body: some View {
        List {
            if !radio.isConnected {
                Section {
                    ContentUnavailableView(
                        "No radio",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Connect a radio to use the mesh and radio tools.")
                    )
                }
            }
            Section("Mesh") {
                NavigationLink { TraceView() } label: {
                    Label("Trace path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                NavigationLink { DiscoveryView() } label: {
                    Label("Local Mesh Discovery", systemImage: "dot.radiowaves.left.and.right")
                }
                ExtraToolLinks()
            }
            .disabled(!radio.isConnected)
            Section("Radio") {
                NavigationLink { RadioStatsView() } label: {
                    Label("Stats & noise floor", systemImage: "waveform.path.ecg")
                }
                NavigationLink {
                    CommandLineView(keyHex: nil, title: radio.selfInfo?.name ?? "Radio")
                } label: {
                    Label("Command line", systemImage: "terminal")
                }
            }
            .disabled(!radio.isConnected)
            Section("Phone") {
                NavigationLink { RouteRecorderView() } label: {
                    Label("Route recorder", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
                }
            }
        }
        .navigationTitle("Tools")
        .toolbar { ToolbarItem(placement: .topBarLeading) { ConnectionButton() } }
    }
}

struct RadioStatsView: View {
    @Environment(RadioStatsService.self) private var stats
    @Environment(RadioController.self) private var radio

    var body: some View {
        List {
            Section {
                Chart(stats.samples) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Noise floor", sample.noiseFloor))
                        .foregroundStyle(MCColor.accent)
                }
                .chartYScale(domain: ChartScale.paddedDomain(stats.samples.map { Double($0.noiseFloor) }))
                .chartYAxisLabel("dBm")
                .frame(height: 200)
                Toggle("Live", isOn: Binding(
                    get: { stats.isMonitoring },
                    set: { $0 ? stats.startMonitoring() : stats.stopMonitoring() }
                ))
            } header: {
                Text("Noise floor")
            } footer: {
                Text("Lower is quieter. A rising noise floor means interference near the radio.")
            }
            if let radio = stats.radioStats {
                Section("Radio") {
                    LabeledContent("Noise floor", value: "\(radio.noiseFloorDbm) dBm")
                    LabeledContent("Last packet", value: "\(radio.lastRSSI) dBm · \(radio.lastSNR.formatted()) dB SNR")
                    LabeledContent("Airtime", value: "TX \(radio.txAirtimeSeconds) s · RX \(radio.rxAirtimeSeconds) s")
                }
            }
            if let packets = stats.packets {
                Section("Packets") {
                    LabeledContent(
                        "Received", value: "\(packets.received) (\(packets.receivedFlood) flood, \(packets.receivedDirect) direct)"
                    )
                    LabeledContent("Sent", value: "\(packets.sent) (\(packets.sentFlood) flood, \(packets.sentDirect) direct)")
                    LabeledContent("Receive errors", value: "\(packets.receiveErrors)")
                }
            }
            if let core = stats.core {
                Section("Device") {
                    LabeledContent("Battery", value: radio.batteryChemistry.describe(millivolts: Int(core.batteryMillivolts)))
                    LabeledContent(
                        "Uptime",
                        value: Duration.seconds(Int(core.uptimeSeconds))
                            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
                    )
                    LabeledContent("Send queue", value: "\(core.outboundQueueLength)")
                }
            }
        }
        .navigationTitle("Stats")
        .refreshable { await stats.refresh() }
        .task { await stats.refresh() }
        .onAppear { stats.startMonitoring() }
        .onDisappear { stats.stopMonitoring() }
    }
}

/// Packet-level and planning tools.
struct ExtraToolLinks: View {
    var body: some View {
        NavigationLink { RxLogView() } label: {
            Label("RX log", systemImage: "list.bullet.rectangle")
        }
        NavigationLink { CoverageView() } label: {
            Label("Coverage walk", systemImage: "figure.walk")
        }
        NavigationLink { LineOfSightView() } label: {
            Label("Line of sight", systemImage: "mountain.2")
        }
    }
}
