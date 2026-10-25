import MeshMaps
import SwiftUI
import UniformTypeIdentifiers

/// Offline map settings kept in `UserDefaults`.
enum OfflineMapSettings {
    /// Storage limit in GB; 0 means unlimited.
    static let storageCapKey = "maps.storageCapGB"
    /// Debug builds only: a PMTiles base URL (or single `.pmtiles` file) used instead of the Protomaps builds.
    /// Empty by default; release builds never read it.
    static let customSourceKey = "maps.debugSourceURL"
    static let capChoices = [0, 1, 2, 5, 10]

    static func capBytes(gigabytes: Int) -> Int64? {
        gigabytes > 0 ? Int64(gigabytes) * 1_000_000_000 : nil
    }

    static func capTitle(gigabytes: Int) -> String {
        gigabytes > 0 ? "\(gigabytes) GB" : "Unlimited"
    }

    /// Hands the current settings to the store.
    @MainActor
    static func apply(to store: OfflineMapStore, capGigabytes: Int, customSource: String) {
        store.storageCap = capBytes(gigabytes: capGigabytes)
        #if DEBUG
        store.customSourceURL = customSourceURL(from: customSource)
        #endif
    }

    #if DEBUG
    /// A usable HTTP(S) URL from the debug setting, or nil.
    static func customSourceURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }
    #endif
}

/// The map file types m-Core imports (declared in the app's Info.plist).
enum OfflineMapFileTypes {
    static let pmtiles = UTType(importedAs: "com.protomaps.pmtiles", conformingTo: .data)
    static let mbtiles = UTType(importedAs: "com.mapbox.mbtiles", conformingTo: .data)
    /// Ours, plus whatever type the system maps the extensions to when another app declared them first.
    static let all: [UTType] = {
        var types = [pmtiles, mbtiles]
        for type in ["pmtiles", "mbtiles"].compactMap({ UTType(filenameExtension: $0) }) where !types.contains(type) {
            types.append(type)
        }
        return types
    }()
}

/// Runs offline map downloads independently of any screen, under a background task that pauses the download
/// (keeping its progress) if iOS runs out of background time, and reports failures for Offline Maps to show.
@MainActor
@Observable
final class OfflineMapActivity {
    static let shared = OfflineMapActivity()

    /// The last failure worth telling the user about.
    var message: String?

    /// Starts `operation` (a download, resume or refresh) and makes a thumbnail when it finishes.
    func run(_ store: OfflineMapStore, _ operation: @escaping @MainActor (OfflineMapStore) async throws -> OfflineMapArea) {
        message = nil
        Task {
            let token = BackgroundTaskToken()
            token.identifier = UIApplication.shared.beginBackgroundTask(withName: "Offline map download") {
                // Out of background time: stop resumably rather than lose the partial download.
                store.pauseDownload()
                token.end()
            }
            defer { token.end() }
            do {
                _ = try await operation(store)
                OfflineMapThumbnails.shared.generateMissing(in: store)
            } catch OfflineMapStoreError.downloadPaused {
                return
            } catch is CancellationError {
                return
            } catch let error as OfflineMapStoreError {
                message = error.errorDescription
            } catch ProtomapsBuildLocatorError.noBuildFound {
                message = "Couldn't find a recent map build. Try again later."
            } catch {
                message = store.pausedDownloads.isEmpty
                    ? "The download failed. Check your connection and try again."
                    : "The download stopped. You can resume it in Offline Maps."
            }
        }
    }
}

/// Holds a background task identifier so the expiration handler and the task can both end it once.
@MainActor
private final class BackgroundTaskToken {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
