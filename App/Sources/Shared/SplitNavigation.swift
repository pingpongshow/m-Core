import SwiftUI

/// A list that drives a split view's selection on iPad, or pushes its links on iPhone.
struct AdaptiveList<Content: View>: View {
    /// Set in a split view; nil when the list sits in a navigation stack.
    var selection: Binding<String?>?
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let selection {
            List(selection: selection, content: content)
        } else {
            List(content: content)
        }
    }
}

/// On regular width (iPad), a list beside the selected item; on compact width, a stack that pushes.
struct ListDetailTab<ListContent: View, Detail: View, Empty: View>: View {
    @Binding var path: [String]
    @ViewBuilder var list: (Binding<String?>?) -> ListContent
    @ViewBuilder var detail: (String) -> Detail
    @ViewBuilder var empty: () -> Empty
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                list(selection)
            } detail: {
                NavigationStack {
                    if let id = path.last {
                        // A fresh view per item, so state from the previous one doesn't carry over.
                        detail(id).id(id)
                    } else {
                        empty()
                    }
                }
            }
        } else {
            NavigationStack(path: $path) { list(nil) }
        }
    }

    /// The selected item is the last entry of the router path, so links, notifications and the palette work in
    /// both layouts.
    private var selection: Binding<String?> {
        Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] })
    }
}
