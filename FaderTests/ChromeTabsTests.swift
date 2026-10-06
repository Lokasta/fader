import Combine
import Carbon
import XCTest
@testable import Fader

final class ChromeTabsTests: XCTestCase {
    private var defaultsDomains: [String] = []

    private func isolatedDefaults() -> UserDefaults {
        let name = "fader.tests.chrome.\(UUID())"
        defaultsDomains.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for domain in defaultsDomains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        super.tearDown()
    }

    @MainActor
    func testTestHostDoesNotTouchLiveAudioOrBrowser() {
        XCTAssertFalse(Mixer.touchesAudio)
    }

    private func tab(_ id: String, playing: Int = 1, title: String = "Music", document: String = "document", muted: Bool = false) -> ChromeTab {
        ChromeTab(id: id, windowID: 1, documentID: document, title: title, url: "https://www.example.com/player", playingCount: playing, hasVideo: false, volume: 1, muted: muted)
    }

    @MainActor
    func testOnlyPlayingTabsAreListedIncludingFaderMutedPlayers() {
        let tabs = ChromeTabs.playingTabs([tab("paused", playing: 0), tab("music"), tab("muted", muted: true)])
        XCTAssertEqual(Set(tabs.map(\.id)), ["music", "muted"])
        XCTAssertEqual(tabs.first?.site, "example.com")
    }

    @MainActor
    func testDuplicateTitlesKeepDistinctTabIdentities() {
        let tabs = ChromeTabs.playingTabs([tab("2"), tab("1")])
        XCTAssertEqual(tabs.map(\.id), ["1", "2"])
    }

    @MainActor
    func testOptInAndPermissionFailureDoNotChangeAppAudio() async {
        let defaults = isolatedDefaults()
        let client = Client()
        client.error = ChromeAutomation.Failure.automationDenied
        let model = ChromeTabs(client: client, defaults: defaults)
        XCTAssertFalse(model.isEnabled)
        model.refresh(visible: true)
        XCTAssertTrue(client.requests.isEmpty)
        let finished = expectation(description: "permission state")
        let observation = model.$status.filter { $0 == .automationDenied }.prefix(1).sink { _ in finished.fulfill() }
        model.setEnabled(true)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "chromeTabControlsEnabled"))
        observation.cancel()
    }

    @MainActor
    func testDisablingRestoresManagedTabAndKeepsOtherTabsUntouched() async {
        let client = Client()
        client.reply.tabs = [tab("music"), tab("other")]
        let model = ChromeTabs(client: client, defaults: isolatedDefaults())
        let ready = expectation(description: "ready")
        let observation = model.$status.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        model.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        model.setVolume(0.25, for: "music")
        model.toggleMute("music")
        XCTAssertEqual(model.tabs.first { $0.id == "music" }?.volume, 0.25)
        let restored = expectation(description: "release")
        client.onRequest = { request in
            if request.updates.contains(where: { $0.restore }) { restored.fulfill() }
        }
        model.setEnabled(false)
        await fulfillment(of: [restored], timeout: 2)
        let releases = client.requests.last!.updates
        XCTAssertEqual(releases.map(\.id), ["music"])
        XCTAssertTrue(releases[0].restore)
        XCTAssertFalse(model.isEnabled)
        observation.cancel()
    }

    @MainActor
    func testNavigationDoesNotCarryVolumeToNewPage() async {
        let client = Client()
        client.reply.tabs = [tab("music")]
        let model = ChromeTabs(client: client, defaults: isolatedDefaults())
        let ready = expectation(description: "ready")
        let observation = model.$status.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        model.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        observation.cancel()
        client.reply.tabs = [tab("music", document: "new-page")]
        model.setVolume(0.2, for: "music")
        let navigated = expectation(description: "navigation refresh")
        let updated = model.$tabs.filter { $0.first?.documentID == "new-page" }.prefix(1).sink { _ in navigated.fulfill() }
        model.refresh(visible: true, force: true)
        await fulfillment(of: [navigated], timeout: 2)
        XCTAssertEqual(model.tabs[0].volume, 1)
        XCTAssertEqual(client.requests.last?.updates.first?.documentID, "document")
        updated.cancel()
        await model.prepareForQuit()
    }

    func testScriptSafelyEncodesIdentifiersAndIncludesBundledMediaProbe() throws {
        let update = ChromeTabUpdate(id: "1\"\\\n", windowID: 1, documentID: "quoted\"document", volume: 0.5, muted: false)
        let script = try ChromeAutomation.script(updates: [update], scanAll: true, leaseID: "test")
        let line = script.components(separatedBy: "\n")[0]
        let data = Data(line.dropFirst("const request = ".count).dropLast().utf8)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap((request["updates"] as? [[String: Any]])?.first)
        XCTAssertEqual(encoded["id"] as? String, update.id)
        XCTAssertEqual(encoded["documentID"] as? String, update.documentID)
        XCTAssertFalse((request["media"] as? String ?? "").isEmpty, "The actual bundled probe must ship with the app")
    }

    func testUnresponsiveTabDoesNotPreventFollowingTabsFromBeingDiscovered() throws {
        let info = ["sleeping", "music", "video"].map {
            ChromeAutomation.TabInfo(id: $0, windowID: 42, title: $0, url: "https://example.com")
        }
        var visited: [String] = []
        let reply = try ChromeAutomation.probe(info, media: "fixture", updates: [], leaseID: "test") { event, timeout in
            XCTAssertEqual(timeout, 0.3)
            XCTAssertEqual(event.eventClass, 0x43725375)
            XCTAssertEqual(event.eventID, 0x45784A61)
            let object = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            let id = try XCTUnwrap(object.forKeyword(AEKeyword(keyAEKeyData))?.stringValue)
            XCTAssertEqual(object.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, "42")
            visited.append(id)
            if id == "sleeping" { throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }
            let response = NSAppleEventDescriptor(eventClass: 0, eventID: 0, targetDescriptor: nil, returnID: 0, transactionID: 0)
            response.setParam(NSAppleEventDescriptor(string: "{\"documentID\":\"page\",\"playingCount\":1,\"hasVideo\":false,\"volume\":1,\"muted\":false}"), forKeyword: keyDirectObject)
            return response
        }
        XCTAssertEqual(visited, ["sleeping", "music", "video"])
        XCTAssertEqual(reply.unavailableTabIDs, ["sleeping"])
        XCTAssertEqual(reply.tabs.map(\.id), ["music", "video"])
        XCTAssertFalse(reply.javascriptBlocked)
    }

    func testBackedOffTabIsNotSentAnotherAppleEvent() throws {
        let info = [ChromeAutomation.TabInfo(id: "sleeping", windowID: 1, title: "Sleeping", url: "https://example.com")]
        let reply = try ChromeAutomation.probe(info, media: "fixture", updates: [], leaseID: "test", skippedTabIDs: ["sleeping"]) { _, _ in
            XCTFail("An unavailable tab must not delay every poll")
            throw ChromeAutomation.Failure.unavailable
        }
        XCTAssertEqual(reply.unavailableTabIDs, ["sleeping"])
    }

    @MainActor
    func testPendingVolumeSurvivesTimeoutAndCanBeRestoredOnQuit() async {
        let client = Client()
        client.reply.tabs = [tab("music")]
        let model = ChromeTabs(client: client, defaults: isolatedDefaults())
        let ready = expectation(description: "ready")
        let observation = model.$status.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        model.setEnabled(true)
        await fulfillment(of: [ready], timeout: 2)
        observation.cancel()
        client.reply = ChromeTabReply(tabs: [], javascriptBlocked: false, unavailableTabIDs: ["music"])
        let unavailable = expectation(description: "timeout")
        let hidden = model.$tabs.dropFirst().filter { $0.isEmpty }.prefix(1).sink { _ in unavailable.fulfill() }
        model.setVolume(0.25, for: "music")
        await fulfillment(of: [unavailable], timeout: 2)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(client.requests.count, 2, "Failed commands must not spin immediately")
        await model.prepareForQuit()
        XCTAssertEqual(client.requests.last?.updates.first?.volume, 0.25)
        XCTAssertEqual(client.requests.last?.updates.first?.restore, true)
        hidden.cancel()
    }

    private final class Client: ChromeTabClient {
        struct Request { let updates: [ChromeTabUpdate]; let scanAll: Bool }
        var isRunning = true
        var reply = ChromeTabReply(tabs: [], javascriptBlocked: false)
        var error: Error?
        var requests: [Request] = []
        var onRequest: ((Request) -> Void)?

        func execute(updates: [ChromeTabUpdate], scanAll: Bool, leaseID: String) async throws -> ChromeTabReply {
            let request = Request(updates: updates, scanAll: scanAll)
            requests.append(request)
            onRequest?(request)
            if let error { throw error }
            return reply
        }
    }
}
