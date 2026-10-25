import Testing
@testable import mCore

struct AppSectionTests {
    @Test func navigationOrderMatchesPlan() {
        #expect(AppSection.allCases.map(\.title) == ["Chats", "Nodes", "Map", "Tools", "Settings"])
    }

    @Test func everySectionExceptSettingsHasAPlannedPhase() {
        for section in AppSection.allCases where section != .settings {
            #expect(section.plannedPhase != nil, "\(section) has no planned phase")
        }
        #expect(AppSection.settings.plannedPhase == nil)
    }
}
