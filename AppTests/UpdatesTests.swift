import Foundation
import Testing
@testable import Suijin

/// The pieces of the update flow that run without a network or a release: the public key gate and the helper
/// handover comparison.
struct UpdatesTests {
    @Test func placeholderAndMalformedKeysAreRejected() {
        #expect(!UpdaterController.isUsablePublicKey(UpdaterController.publicKeyPlaceholder))
        #expect(!UpdaterController.isUsablePublicKey(""))
        #expect(!UpdaterController.isUsablePublicKey("not base64"))
        // 16 bytes: valid base64, wrong length for an EdDSA public key.
        #expect(!UpdaterController.isUsablePublicKey(Data(repeating: 7, count: 16).base64EncodedString()))
    }

    @Test func thirtyTwoByteKeyIsAccepted() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(UpdaterController.isUsablePublicKey(key))
        #expect(UpdaterController.isUsablePublicKey(" \(key)\n"))
    }

    @Test func shippedInfoPlistStillCarriesThePlaceholderOrARealKey() throws {
        let key = try #require(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #expect(key == UpdaterController.publicKeyPlaceholder || UpdaterController.isUsablePublicKey(key))
    }

    /// The feed is part of every shipped build and can never change afterwards, so it is pinned here.
    @Test func feedIsTheStableSuijinAddress() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == "https://suijin.app/appcast.xml")
        #expect(UpdaterController.hasFeedURL(in: .main))
    }

    /// The updater runs only with a real public key: with the placeholder it stays off, whatever the feed says.
    @Test func updaterIsConfiguredOnlyWithARealKey() throws {
        let key = try #require(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        #expect(UpdaterController.isConfigured(in: .main) == UpdaterController.isUsablePublicKey(key))
    }

    @Test func hostBuildStringIsParsed() {
        #expect(HelperVersionCheck.build(fromHostBuild: "0.1.0 (12)") == "12")
        #expect(HelperVersionCheck.build(fromHostBuild: "12") == "12")
        #expect(HelperVersionCheck.build(fromHostBuild: "dev") == nil)
        #expect(HelperVersionCheck.build(fromHostBuild: "") == nil)
        #expect(HelperVersionCheck.build(fromHostBuild: "0.1.0 ()") == nil)
    }

    @Test func staleOnlyWhenBuildsDiffer() {
        #expect(!HelperVersionCheck.isStale(hostBuild: "0.1.0 (1)", appBuild: "1"))
        #expect(HelperVersionCheck.isStale(hostBuild: "0.1.0 (1)", appBuild: "2"))
        #expect(HelperVersionCheck.isStale(hostBuild: "3", appBuild: "2"))
        #expect(!HelperVersionCheck.isStale(hostBuild: "dev", appBuild: "2"))
    }
}
