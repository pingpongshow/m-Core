import Foundation
import MeshCoreKit
import MeshServices
import Testing
@testable import mCore

struct ChatListDateTests {
    private let calendar = Calendar.current
    /// Midday, so adding or removing a few hours never crosses midnight.
    private var now: Date { calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    @Test func todayShowsTheTime() {
        let date = daysAgo(0, hour: 9)
        #expect(date.chatListText(now: now) == date.formatted(date: .omitted, time: .shortened))
    }

    @Test func yesterdayEvenWhenLessThanADayAgo() {
        #expect(daysAgo(1, hour: 23).chatListText(now: now) == "Yesterday")
    }

    @Test func weekdayWithinTheLastSixDays() {
        let date = daysAgo(6)
        #expect(date.chatListText(now: now) == date.formatted(.dateTime.weekday(.wide)))
    }

    @Test func sameWeekdayLastWeekIsADateNotToday() {
        // 6 days 23 hours ago used to count as "within a week" and showed today's weekday name.
        let date = daysAgo(7, hour: 13)
        #expect(date.chatListText(now: now) == date.formatted(date: .numeric, time: .omitted))
    }

    @Test func futureDatesFromAFastClockShowTheDate() {
        let date = calendar.date(byAdding: .day, value: 2, to: now)!
        #expect(date.chatListText(now: now) == date.formatted(date: .numeric, time: .omitted))
    }
}

struct MeshLinkTests {
    private let key = String(repeating: "ab", count: 32)

    @Test func contactRoundTrips() throws {
        let link = MeshLink.contact(name: "Alice Chen", keyHex: key, type: 2)
        guard case let .contact(name, keyHex, type) = try #require(MeshLink(url: link.url)) else {
            Issue.record("Expected a contact link")
            return
        }
        #expect(name == "Alice Chen")
        #expect(keyHex == key)
        #expect(type == 2)
    }

    @Test func contactKeyMustBeHexAndIsLowercased() throws {
        let bad = try #require(URL(string: "meshcore://contact/add?name=x&public_key=\(String(repeating: "zz", count: 32))&type=1"))
        #expect(MeshLink(url: bad) == nil)
        let upper = try #require(URL(string: "meshcore://contact/add?name=x&public_key=\(key.uppercased())&type=1"))
        guard case let .contact(_, keyHex, _) = try #require(MeshLink(url: upper)) else {
            Issue.record("Expected a contact link")
            return
        }
        #expect(keyHex == key)
    }

    @Test func channelNeedsAName() throws {
        #expect(MeshLink(url: try #require(URL(string: "meshcore://channel/add?name=&secret=00"))) == nil)
        #expect(MeshLink(url: try #require(URL(string: "https://example.com/channel/add?name=x"))) == nil)
        guard case let .channel(name, secret) = try #require(MeshLink(url: MeshLink.channel(name: "#test", secretHex: "0a").url)) else {
            Issue.record("Expected a channel link")
            return
        }
        #expect(name == "#test")
        #expect(secret == "0a")
    }
}

struct ErrorMessageTests {
    private enum PlainError: Error, CustomStringConvertible {
        case broken
        var description: String { "Something broke." }
    }

    @Test func packageErrorsReadAsSentences() {
        #expect(errorMessage(MessagingError.notConnected) == "The radio isn't connected.")
        #expect(errorMessage(MessagingError.messageTooLong(maxBytes: 150)) == "Too long: messages can be up to 150 bytes.")
        #expect(errorMessage(RemoteRequestError.timedOut) == "No answer. The node may be out of range.")
        #expect(errorMessage(MeshError.timeout(.getContacts)) == "The radio didn't answer in time.")
        #expect(errorMessage(MeshError.device(.tableFull, .getContacts)) == "The radio's list is full.")
        #expect(errorMessage(TransportError.disconnected(nil)) == "The radio disconnected.")
    }

    @Test func otherErrorsUseTheirOwnDescription() {
        #expect(errorMessage(PlainError.broken) == "Something broke.")
        let system = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(errorMessage(system) == system.localizedDescription)
        let offline = URLError(.notConnectedToInternet)
        #expect(errorMessage(offline) == offline.localizedDescription)
    }
}

@MainActor
struct CompassNameTests {
    @Test(arguments: [
        (0.0, "north"), (22.4, "north"), (22.5, "north-east"), (90, "east"), (180, "south"),
        (269, "west"), (337.6, "north"), (359.9, "north"), (-90, "west"), (450, "east"),
    ])
    func compassName(bearing: Double, expected: String) {
        #expect(NodeRow.compassName(bearing) == expected)
    }
}

@MainActor
struct AppRouterTests {
    @Test func openingAConversationSwitchesToChats() {
        let router = AppRouter()
        router.selection = .map
        router.openConversation("ch:1")
        #expect(router.selection == .chats)
        #expect(router.chatPath == ["ch:1"])
    }

    @Test func settingsRoutesReplaceTheStack() {
        let router = AppRouter()
        router.open(SettingsRoute.channels)
        router.open(SettingsRoute.radio)
        #expect(router.selection == .settings)
        #expect(router.settingsPath == [.radio])
    }
}

struct ChartScaleTests {
    @Test func steadyReadingsGetARangeAroundThem() {
        let domain = ChartScale.paddedDomain([3.9, 3.9, 3.9])
        #expect(domain.lowerBound < 3.9 && domain.upperBound > 3.9)
    }

    @Test func varyingReadingsAreAllInside() {
        let domain = ChartScale.paddedDomain([-4, 12.5, 3])
        #expect(domain.lowerBound < -4 && domain.upperBound > 12.5)
    }

    @Test func noReadingsStillGiveARange() {
        #expect(ChartScale.paddedDomain([]) == 0...1)
    }
}

struct MessagePreviewTests {
    @Test func previewDropsMarkdownMarkers() {
        #expect(MessageText.plainPreview("You: Sounds great, **Saturday** at 9?") == "You: Sounds great, Saturday at 9?")
        #expect(MessageText.plainPreview("see https://example.com/a_b_c") == "see https://example.com/a_b_c")
        #expect(MessageText.plainPreview("2 * 3 = 6") == "2 * 3 = 6")
    }
}
