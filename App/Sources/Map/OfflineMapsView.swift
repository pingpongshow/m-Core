import MeshDesign
import MeshMaps
import SwiftUI
import UniformTypeIdentifiers

/// Saved offline areas, running and paused downloads, imports, and the way into downloading a new area.
struct OfflineMapsView: View {
    let styleURL: URL?
    var startBounds: GeoBounds?
    let onShow: (OfflineMapArea) -> Void
    @Environment(OfflineMapStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(OfflineMapSettings.storageCapKey) private var capGigabytes = 0
    @AppStorage(OfflineMapSettings.customSourceKey) private var customSource = ""
    @State private var activity = OfflineMapActivity.shared
    @State private var renaming: OfflineMapArea?
    @State private var newName = ""
    @State private var error: String?
    @State private var showImporter = false
    @State private var importingName: String?
    @State private var importNotice: ImportNotice?

    var body: some View {
        NavigationStack {
            List {
                // At the top, where it's seen: a swipe action's result would otherwise land below the fold.
                if let message = error ?? activity.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(MCColor.warning)
                }
                downloadSections
                Section {
                    NavigationLink {
                        DownloadAreaView(styleURL: styleURL, startBounds: startBounds)
                    } label: {
                        Label("Download area", systemImage: "square.dashed")
                    }
                    .disabled(store.activeDownload != nil)
                    Button { showImporter = true } label: {
                        Label("Import map file", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importingName != nil)
                    if let importingName {
                        HStack(spacing: MCSpacing.s) {
                            ProgressView().controlSize(.small)
                            Text("Importing \(importingName)…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("""
                        Frame an area on the map and m-Core copies just those map tiles from the public OpenStreetMap \
                        build made by Protomaps. Downloaded maps work with no signal. You can also import .pmtiles or \
                        .mbtiles vector maps from Files or AirDrop.
                        """)
                }
                if !store.areas.isEmpty { savedAreas }
                settingsSection
                #if DEBUG
                developerSection
                #endif
            }
            .navigationTitle("Offline Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename area", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let renaming { attempt { try store.rename(renaming.id, to: newName) } }
                }
            }
            .alert(importNotice?.title ?? "", isPresented: Binding(get: { importNotice != nil }, set: { if !$0 { importNotice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importNotice?.message ?? "")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: OfflineMapFileTypes.all) { result in
                switch result {
                case .success(let url): importFile(url)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
        .onAppear {
            applySettings()
            importPendingFile()
            OfflineMapThumbnails.shared.generateMissing(in: store)
        }
        .onChange(of: capGigabytes) { applySettings() }
        .onChange(of: customSource) { applySettings() }
        .onChange(of: router.pendingMapImport) { importPendingFile() }
    }

    // MARK: Sections

    @ViewBuilder private var downloadSections: some View {
        if let download = store.activeDownload {
            Section(download.replacesAreaID == nil ? "Downloading" : "Refreshing") {
                DownloadProgressRow(download: download, onPause: { store.pauseDownload() }, onCancel: { store.cancelDownload() })
            }
        }
        if !store.pausedDownloads.isEmpty {
            Section {
                ForEach(store.pausedDownloads) { paused in
                    PausedDownloadRow(paused: paused, canResume: store.activeDownload == nil) {
                        activity.run(store) { try await $0.resumeDownload(paused.id) }
                    }
                    .swipeActions {
                        Button("Discard", systemImage: "trash", role: .destructive) { store.discardDownload(paused.id) }
                            .tint(MCColor.critical)
                    }
                    .contextMenu {
                        Button("Resume", systemImage: "play.fill") {
                            activity.run(store) { try await $0.resumeDownload(paused.id) }
                        }
                        .disabled(store.activeDownload != nil)
                        Button("Discard", systemImage: "trash", role: .destructive) { store.discardDownload(paused.id) }
                    }
                }
            } header: {
                Text("Paused")
            } footer: {
                Text("Resuming carries on where the download stopped. If the map build has changed since, it starts again.")
            }
        }
    }

    private var savedAreas: some View {
        Section {
            ForEach(store.areas) { area in
                Button { onShow(area) } label: { AreaRow(area: area, thumbnail: thumbnail(for: area)) }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button("Show on map", systemImage: "map") { onShow(area) }
                        Button("Rename", systemImage: "pencil") {
                            newName = area.name
                            renaming = area
                        }
                        if area.canRefresh {
                            Button("Refresh", systemImage: "arrow.clockwise") { refresh(area) }
                                .disabled(store.activeDownload != nil)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(area) }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(area) }
                            .tint(MCColor.critical)
                        if area.canRefresh && store.activeDownload == nil {
                            Button("Refresh", systemImage: "arrow.clockwise") { refresh(area) }
                                .tint(MCColor.accentFill)
                        }
                    }
            }
        } header: {
            Text("Saved areas")
        } footer: {
            Text("""
                Using \(store.totalBytes.formatted(.byteCount(style: .file))). A world overview is built in. \
                Refresh re-downloads an area from the newest map build.
                """)
        }
    }

    private var settingsSection: some View {
        Section {
            Picker("Storage limit", selection: $capGigabytes) {
                ForEach(OfflineMapSettings.capChoices, id: \.self) { Text(OfflineMapSettings.capTitle(gigabytes: $0)).tag($0) }
            }
        } footer: {
            Text("Downloads that would take offline maps past this limit aren't started.")
        }
    }

    #if DEBUG
    private var developerSection: some View {
        Section {
            TextField("Custom PMTiles URL", text: $customSource)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Developer")
        } footer: {
            Text("""
                Debug builds only. A base URL with dated YYYYMMDD.pmtiles builds, or one .pmtiles file, used instead of \
                the Protomaps builds. Leave empty to use Protomaps.
                """)
        }
    }
    #endif

    // MARK: Actions

    private func thumbnail(for area: OfflineMapArea) -> UIImage? {
        AreaThumbnailCache.image(for: area, in: store)
    }

    private func applySettings() {
        OfflineMapSettings.apply(to: store, capGigabytes: capGigabytes, customSource: customSource)
    }

    private func refresh(_ area: OfflineMapArea) {
        error = nil
        activity.run(store) { try await $0.refresh(area.id) }
    }

    private func delete(_ area: OfflineMapArea) {
        attempt { try store.delete(area.id) }
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Imports a file the router received from Files or AirDrop.
    private func importPendingFile() {
        guard let url = router.pendingMapImport else { return }
        router.pendingMapImport = nil
        importFile(url)
    }

    private func importFile(_ url: URL) {
        error = nil
        importingName = url.lastPathComponent
        let store = store
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                // Files opened from other apps arrive as a copy in our inbox; it isn't needed once imported.
                if Self.isInboxCopy(url) { try? FileManager.default.removeItem(at: url) }
                importingName = nil
            }
            do {
                let result = try await store.importArchive(at: url)
                OfflineMapThumbnails.shared.generateMissing(in: store)
                if case let .missingLayers(layers)? = result.warnings.first {
                    importNotice = ImportNotice(
                        title: "Imported \(result.area.name)",
                        message: """
                            This map has no \(layers.formatted(.list(type: .and))) layer\(layers.count == 1 ? "" : "s"). \
                            m-Core's style is made for Protomaps maps, so it may show little or nothing from this file.
                            """
                    )
                }
            } catch {
                importNotice = ImportNotice(title: "Couldn't import the map", message: error.localizedDescription)
            }
        }
    }

    private static func isInboxCopy(_ url: URL) -> Bool {
        let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory).resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(inbox + "/")
    }
}

private struct ImportNotice {
    var title: String
    var message: String
}

private struct AreaRow: View {
    let area: OfflineMapArea
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: MCSpacing.m) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "map").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 48)
            .background(MCColor.chipBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                Text(area.name).font(.body.weight(.medium))
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var details: String {
        var parts = [area.importedFrom == nil ? area.detail.title : "Imported", area.fileSize.formatted(.byteCount(style: .file)),
                     area.createdAt.formatted(date: .abbreviated, time: .omitted)]
        if let build = area.sourceBuildDate {
            // Builds are named by their UTC day; in local time west of UTC that would show the day before.
            var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            style.timeZone = .gmt
            parts.append("map data \(build.formatted(style))")
        } else if let file = area.importedFrom {
            parts.append(file)
        }
        return parts.joined(separator: " · ")
    }
}

extension OfflineMapDetail {
    var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        }
    }

    var summary: String {
        switch self {
        case .standard: "Streets and town names"
        case .high: "Every street, paths, more labels"
        }
    }
}
