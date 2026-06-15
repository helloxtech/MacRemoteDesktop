import Foundation

@main
struct RemoteAccessPersistenceTests {
    static func main() {
        testSavedRemoteConnectionPersistsAndReloads()
        testSavingSameURLUpdatesExistingConnection()
        testURLLikeNameFallsBackToRemoteMac()
        testLegacyURLLikeSavedNameLoadsAsRemoteMac()
        testRenamingSavedRemoteConnectionPersists()
        print("RemoteAccessPersistenceTests passed")
    }

    private static func testSavedRemoteConnectionPersistsAndReloads() {
        let suiteName = "RemoteAccessPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SavedRemoteConnectionStore(defaults: defaults)
        expect(store.connections.isEmpty, "new store should start empty")

        store.save(
            urlString: " https://steady.example.trycloudflare.com ",
            pairingCode: " 123 456 ",
            name: "Work Mac",
            now: Date(timeIntervalSince1970: 100)
        )

        let reloaded = SavedRemoteConnectionStore(defaults: defaults)
        expect(reloaded.connections.count == 1, "store should reload one saved connection")

        let connection = reloaded.connections[0]
        expect(connection.name == "Work Mac", "connection should keep the display name")
        expect(connection.urlString == "https://steady.example.trycloudflare.com", "connection should trim the URL")
        expect(connection.pairingCode == "123456", "connection should keep a sanitized pairing code")
        expect(connection.lastUsedAt == Date(timeIntervalSince1970: 100), "connection should keep last used date")
    }

    private static func testSavingSameURLUpdatesExistingConnection() {
        let suiteName = "RemoteAccessPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SavedRemoteConnectionStore(defaults: defaults)
        store.save(
            urlString: "https://steady.example.trycloudflare.com",
            pairingCode: "111111",
            name: "Old Name",
            now: Date(timeIntervalSince1970: 100)
        )
        store.save(
            urlString: " HTTPS://steady.example.trycloudflare.com ",
            pairingCode: "222222",
            name: "New Name",
            now: Date(timeIntervalSince1970: 200)
        )

        expect(store.connections.count == 1, "saving the same URL should update instead of duplicating")
        expect(store.connections[0].name == "New Name", "updated connection should keep the newest name")
        expect(store.connections[0].pairingCode == "222222", "updated connection should keep the newest code")
        expect(store.connections[0].lastUsedAt == Date(timeIntervalSince1970: 200), "updated connection should keep the newest date")
    }

    private static func testURLLikeNameFallsBackToRemoteMac() {
        let suiteName = "RemoteAccessPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SavedRemoteConnectionStore(defaults: defaults)
        store.save(
            urlString: "wss://steady.example.trycloudflare.com",
            pairingCode: "123456",
            name: "steady.example.trycloudflare.com",
            now: Date(timeIntervalSince1970: 100)
        )

        expect(store.connections.count == 1, "store should save one URL-like remote connection")
        expect(store.connections[0].name == "Remote Mac", "URL-like saved names should show a friendly default")
    }

    private static func testLegacyURLLikeSavedNameLoadsAsRemoteMac() {
        struct LegacyConnection: Codable {
            let id: String
            let name: String
            let urlString: String
            let pairingCode: String?
            let lastUsedAt: Date
        }

        let suiteName = "RemoteAccessPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let key = "airdesk.remoteAccess.savedConnections.v1"
        let legacy = LegacyConnection(
            id: "wss://steady.example.trycloudflare.com",
            name: "steady.example.trycloudflare.com",
            urlString: "wss://steady.example.trycloudflare.com",
            pairingCode: "123456",
            lastUsedAt: Date(timeIntervalSince1970: 100)
        )
        defaults.set(try! JSONEncoder().encode([legacy]), forKey: key)

        let store = SavedRemoteConnectionStore(defaults: defaults)
        expect(store.connections.count == 1, "store should load one legacy URL-like remote connection")
        expect(store.connections[0].name == "Remote Mac", "legacy URL-like saved names should load as a friendly default")
    }

    private static func testRenamingSavedRemoteConnectionPersists() {
        let suiteName = "RemoteAccessPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = SavedRemoteConnectionStore(defaults: defaults)
        store.save(
            urlString: "wss://steady.example.trycloudflare.com",
            pairingCode: "123456",
            name: nil,
            now: Date(timeIntervalSince1970: 100)
        )
        guard let connection = store.connections.first else {
            fatalError("Expected saved connection before rename")
        }

        store.rename(connection, to: "Office Mac")

        let reloaded = SavedRemoteConnectionStore(defaults: defaults)
        expect(reloaded.connections.count == 1, "renamed store should reload one saved connection")
        expect(reloaded.connections[0].name == "Office Mac", "renamed connection should keep the custom name")
        expect(reloaded.connections[0].urlString == "wss://steady.example.trycloudflare.com", "renaming should not change URL")
        expect(reloaded.connections[0].pairingCode == "123456", "renaming should not change pairing code")
        expect(reloaded.connections[0].lastUsedAt == Date(timeIntervalSince1970: 100), "renaming should not change last used date")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
