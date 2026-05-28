import Foundation

@main
struct ClientVersionCompatibilityTests {
    static func main() {
        testRemoteAccessMinimumVersion()
        testPatchVersionsCompareNumerically()
        testMalformedVersionsAreRejected()
        print("ClientVersionCompatibilityTests passed")
    }

    private static func testRemoteAccessMinimumVersion() {
        expect(AirDeskAppVersion.isVersion("1.2.5", atLeast: "1.2.5"), "minimum version should pass")
        expect(AirDeskAppVersion.isVersion("1.2.6", atLeast: "1.2.5"), "newer patch should pass")
        expect(!AirDeskAppVersion.isVersion("1.2.4", atLeast: "1.2.5"), "older patch should fail")
    }

    private static func testPatchVersionsCompareNumerically() {
        expect(AirDeskAppVersion.isVersion("1.2.10", atLeast: "1.2.5"), "numeric comparison should not be lexical")
        expect(AirDeskAppVersion.isVersion("1.3", atLeast: "1.2.5"), "missing patch should be padded with zero")
        expect(!AirDeskAppVersion.isVersion("1.2", atLeast: "1.2.5"), "missing patch should compare as zero")
    }

    private static func testMalformedVersionsAreRejected() {
        expect(!AirDeskAppVersion.isVersion("", atLeast: "1.2.5"), "empty version should fail")
        expect(!AirDeskAppVersion.isVersion("beta", atLeast: "1.2.5"), "non-numeric version should fail")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
