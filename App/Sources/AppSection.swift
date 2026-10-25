/// Top-level navigation (PLAN.md §4.9): a tab bar on iPhone, a sidebar on iPad.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case chats
    case nodes
    case map
    case tools
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .nodes: "Nodes"
        case .map: "Map"
        case .tools: "Tools"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right.fill"
        case .nodes: "antenna.radiowaves.left.and.right"
        case .map: "map.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .settings: "gearshape.fill"
        }
    }
}
