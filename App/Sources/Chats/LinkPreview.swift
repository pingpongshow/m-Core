import LinkPresentation
import MeshDesign
import SwiftUI
import UniformTypeIdentifiers

/// Chat preferences kept in UserDefaults.
enum MessagingSettings {
    /// Link-preview cards and inline images (on by default); the only chat feature that uses the internet.
    static let linkPreviewsKey = "messaging.linkPreviews"
}

/// What a link in a message points at: a page (title, site, image) or an image to show inline.
struct LinkPreview: Equatable, Sendable {
    var url: URL
    var title: String?
    var siteName: String
    var imageData: Data?
    var isImage: Bool
}

/// Loads link previews with LinkPresentation and keeps them in memory per URL for the app's lifetime.
@MainActor
@Observable
final class LinkPreviewCache {
    static let shared = LinkPreviewCache()

    private(set) var previews: [URL: LinkPreview] = [:]
    @ObservationIgnored private var unavailable: Set<URL> = []
    @ObservationIgnored private var loading: Set<URL> = []

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
    /// Preview images bigger than this are dropped rather than kept in memory.
    private static let maxImageBytes = 4_000_000

    /// First web (http or https) link in a message.
    static func firstWebURL(in text: String) -> URL? {
        guard let detector = MessageText.linkDetector else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    func preview(for url: URL) -> LinkPreview? {
        previews[url]
    }

    /// Fetches the preview once; later calls for the same URL do nothing.
    func load(_ url: URL) async {
        guard previews[url] == nil, !unavailable.contains(url), !loading.contains(url) else { return }
        loading.insert(url)
        defer { loading.remove(url) }
        let site = url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString

        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            previews[url] = LinkPreview(url: url, siteName: site, isImage: true)
            return
        }
        if await Self.servesImage(url) {
            previews[url] = LinkPreview(url: url, siteName: site, isImage: true)
            return
        }
        guard let metadata = await Self.metadata(for: url), metadata.title != nil || metadata.imageData != nil else {
            unavailable.insert(url)
            return
        }
        let imageData = metadata.imageData.flatMap { $0.count <= Self.maxImageBytes ? $0 : nil }
        previews[url] = LinkPreview(url: url, title: metadata.title, siteName: site, imageData: imageData, isImage: false)
    }

    /// Asks the server for the content type without downloading the body.
    nonisolated private static func servesImage(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.mimeType?.hasPrefix("image/") == true
    }

    nonisolated private static func metadata(for url: URL) async -> (title: String?, imageData: Data?)? {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let title = metadata.title
        guard let imageProvider = metadata.imageProvider ?? metadata.iconProvider else { return (title, nil) }
        let data: Data? = await withCheckedContinuation { continuation in
            imageProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        return (title, data)
    }
}

/// The preview for a message's first link: a page card, or the image itself when the link is an image.
/// Shows nothing until the message row has loaded the preview (``LinkPreviewCache/load(_:)``).
struct MessageLinkPreview: View {
    let url: URL
    @State private var showingImage = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let cache = LinkPreviewCache.shared
        Group {
            if let preview = cache.preview(for: url) {
                if preview.isImage {
                    InlineImage(url: url)
                        .onTapGesture { showingImage = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Image from \(preview.siteName)")
                } else {
                    card(preview)
                        .onTapGesture { openURL(url) }
                        .accessibilityAddTraits(.isLink)
                }
            }
        }
        .fullScreenCover(isPresented: $showingImage) {
            ImageViewer(url: url)
        }
    }

    private func card(_ preview: LinkPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let data = preview.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: MCSpacing.xxs) {
                if let title = preview.title {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Text(preview.siteName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(MCSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .combine)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 260)
    }
}

/// An image link shown in the bubble, size-limited.
struct InlineImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                Label("Image unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(MCSpacing.s)
            default:
                ProgressView().frame(width: 120, height: 90)
            }
        }
        .frame(maxWidth: 240, maxHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Full-screen image with pinch to zoom.
struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, settledScale * $0.magnification) }
                                .onEnded { _ in settledScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { scale = scale > 1 ? 1 : 2.5 }
                            settledScale = scale
                        }
                } else if phase.error != nil {
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
