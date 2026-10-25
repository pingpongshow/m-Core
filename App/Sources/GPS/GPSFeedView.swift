import MeshCoreKit
import MeshDesign
import MeshServices
import SwiftUI

/// Settings → GPS Feed: where the radio's position comes from, how often it's updated, and who can see it.
struct GPSFeedView: View {
    @Environment(RadioController.self) private var radio
    @Environment(GPSFeedService.self) private var feed

    var body: some View {
        List {
            statusSection
            switch feed.source {
            case .phone:
                phoneSection
                if feed.settings.preset == .custom { customSection }
                advertSection
                lowPowerSection
            case .radioGPS(let isOn):
                radioGPSSection(isOn: isOn)
            case .unknown:
                EmptyView()
            }
            if radio.isConnected { privacySection }
        }
        .navigationTitle("GPS Feed")
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                StatusPill(gps: feed.displayStatus(now: context.date))
            }
            if feed.status == .pausedLowPower {
                Label("Paused while Low Power Mode is on. It resumes by itself.", systemImage: "battery.25percent")
                    .font(.footnote)
                    .foregroundStyle(MCColor.warning)
            }
            if let error = feed.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(MCColor.warning)
            }
        } footer: {
            Text(sourceExplanation)
        }
    }

    private var sourceExplanation: String {
        switch feed.source {
        case .unknown: "Connect a radio to set up its position."
        case .radioGPS: "This radio has its own GPS, so m-Core leaves its position alone."
        case .phone: "This radio has no GPS, so m-Core sends it your phone's position. "
            + "It keeps working in the background, and iOS shows a blue location indicator."
        }
    }

    private func radioGPSSection(isOn: Bool) -> some View {
        Section("Radio GPS") {
            LabeledContent("Status", value: isOn ? "On" : "Off")
            if !isOn {
                Button("Turn on radio GPS") {
                    Task { await feed.turnOnRadioGPS() }
                }
            }
            if let selfInfo = radio.selfInfo {
                LabeledContent("Radio position", value: positionText(latitudeE6: selfInfo.latitudeE6, longitudeE6: selfInfo.longitudeE6))
            }
        }
    }

    private var phoneSection: some View {
        Section {
            Toggle("Send phone position", isOn: binding(\.isEnabled))
            Picker("Update profile", selection: binding(\.preset)) {
                ForEach(GPSFeedSettings.Preset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            let limits = feed.settings.thresholds
            LabeledContent("Updates when", value: "moved \(Int(limits.minDistance)) m, at most every \(duration(limits.minInterval))")
            if let lastSent = feed.lastSent {
                LabeledContent("Last sent", value: positionText(latitudeE6: lastSent.latitudeE6, longitudeE6: lastSent.longitudeE6))
            }
            if let lastSentAt = feed.lastSentAt {
                LabeledContent("Sent at", value: lastSentAt.formatted(date: .omitted, time: .standard))
            }
            LabeledContent("Updates today", value: "\(feed.writesToday)")
        } header: {
            Text("Phone GPS")
        } footer: {
            Text("Each update is saved to the radio's memory, so m-Core only sends when you've moved.")
        }
    }

    private var customSection: some View {
        Section("Custom profile") {
            Stepper(value: binding(\.custom.minDistance), in: 10...1_000, step: 10) {
                LabeledContent("Minimum move", value: "\(Int(feed.settings.custom.minDistance)) m")
            }
            Stepper(value: binding(\.custom.minInterval), in: 10...3_600, step: 10) {
                LabeledContent("Minimum interval", value: duration(feed.settings.custom.minInterval))
            }
            Stepper(value: binding(\.custom.maxAccuracy), in: 10...200, step: 10) {
                LabeledContent("Ignore fixes worse than", value: "\(Int(feed.settings.custom.maxAccuracy)) m")
            }
            Stepper(value: binding(\.custom.heartbeat), in: 60...7_200, step: 60) {
                LabeledContent("Recheck every", value: duration(feed.settings.custom.heartbeat))
            }
        }
    }

    private var advertSection: some View {
        Section {
            Toggle("Advert when I move", isOn: binding(\.advertOnMove))
            if feed.settings.advertOnMove {
                Picker("After moving", selection: binding(\.advertDistance)) {
                    Text("500 m").tag(500.0)
                    Text("1 km").tag(1_000.0)
                    Text("5 km").tag(5_000.0)
                    Text("10 km").tag(10_000.0)
                }
                Toggle("Flood the advert", isOn: binding(\.advertFlood))
            }
        } footer: {
            Text("""
                Lets nearby nodes see your new position. At most one advert every 15 minutes; flooding reaches further \
                but uses more airtime.
                """)
        }
    }

    private var lowPowerSection: some View {
        Section {
            Toggle("Pause in Low Power Mode", isOn: Binding(
                get: { feed.pauseInLowPowerMode },
                set: { feed.setPauseInLowPowerMode($0) }
            ))
        } footer: {
            Text("""
                Stops using the phone's GPS while Low Power Mode is on, so the radio's position isn't updated until it's \
                off again. This applies to every radio.
                """)
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("Share position in adverts", isOn: Binding(
                get: { radio.selfInfo?.sharesLocationInAdverts ?? false },
                set: { share in Task { await feed.setShareInAdverts(share) } }
            ))
            Picker("Position in telemetry", selection: Binding(
                get: { radio.selfInfo?.telemetryModes.location ?? .deny },
                set: { mode in Task { await feed.setLocationTelemetry(mode) } }
            )) {
                Text("Nobody").tag(TelemetryMode.deny)
                Text("Favourites").tag(TelemetryMode.allowFlagged)
                Text("Everyone").tag(TelemetryMode.allowAll)
            }
            if feed.source == .phone {
                Picker("Precision", selection: binding(\.rounding)) {
                    ForEach(GPSFeedSettings.Rounding.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text(feed.source == .phone
                 ? "Advert and telemetry sharing are saved on the radio. Precision rounds the phone position before it's sent."
                 : "These are saved on the radio.")
        }
    }

    // MARK: Helpers

    private func binding<Value>(_ keyPath: WritableKeyPath<GPSFeedSettings, Value>) -> Binding<Value> {
        Binding(
            get: { feed.settings[keyPath: keyPath] },
            set: { newValue in feed.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func positionText(latitudeE6: Int32, longitudeE6: Int32) -> String {
        guard latitudeE6 != 0 || longitudeE6 != 0 else { return "Not set" }
        return String(format: "%.5f, %.5f", Double(latitudeE6) / 1e6, Double(longitudeE6) / 1e6)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
