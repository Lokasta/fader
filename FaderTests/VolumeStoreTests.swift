import XCTest
@testable import Fader

final class VolumeStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "fader.tests.\(UUID().uuidString)")
    }

    func testUnknownAppsStartAtFullVolume() {
        let store = VolumeStore(defaults: defaults)
        XCTAssertEqual(store.volume(for: "com.spotify.client"), 1)
        XCTAssertFalse(store.isMuted("com.spotify.client"))
    }

    func testRemembersVolumeAndMute() {
        let store = VolumeStore(defaults: defaults)
        store.save(volume: 0.4, muted: true, for: "com.spotify.client")

        XCTAssertEqual(store.volume(for: "com.spotify.client"), 0.4, accuracy: 1e-6)
        XCTAssertTrue(store.isMuted("com.spotify.client"))

        store.save(volume: 1, muted: false, for: "com.spotify.client")
        XCTAssertNil(defaults.dictionary(forKey: "appVolumes")?["com.spotify.client"], "100% isn't worth storing")
        XCTAssertFalse(store.isMuted("com.spotify.client"))
    }

    func testDisablingMemoryIgnoresSavedValues() {
        let store = VolumeStore(defaults: defaults)
        store.save(volume: 0.2, muted: true, for: "app")
        store.remembers = false

        XCTAssertEqual(store.volume(for: "app"), 1)
        XCTAssertFalse(store.isMuted("app"))
    }
}
