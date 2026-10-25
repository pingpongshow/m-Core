import SwiftUI

/// One page of the built-in help. Bodies use inline Markdown and work offline.
struct HelpArticle: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let body: [String]

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || body.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// Built-in help, available with no signal.
struct HelpView: View {
    @State private var query = ""

    var body: some View {
        let articles = HelpArticle.all.filter { $0.matches(query) }
        // Destination links, not value links: Help is pushed onto Settings' [SettingsRoute] path, which can't hold an article.
        List(articles) { article in
            NavigationLink {
                HelpArticleView(article: article)
            } label: {
                Label(article.title, systemImage: article.symbol)
            }
        }
        .overlay {
            if articles.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, prompt: "Search help")
        .navigationTitle("Help")
    }
}

struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(article.body.enumerated()), id: \.offset) { _, paragraph in
                    Text(Self.rendered(paragraph))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
