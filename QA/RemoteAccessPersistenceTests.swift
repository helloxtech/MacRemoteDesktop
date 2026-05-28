import Foundation

@main
struct RemoteAccessPersistenceTests {
    static func main() {
        testSavedRemoteConnectionPersistsAndReloads()
        testSavingSameURLUpdatesExistingConnection()
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
