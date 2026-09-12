import XCTest
@testable import FocusTracker

/// Tests for the #14 settings store (binding vault-path criteria): the
/// injected-suite seam gives each test an isolated, disposable
/// `UserDefaults` suite; save→reload across instances, the missing-value
/// case, and explicit clearing.
final class AppSettingsTests: XCTestCase {

    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AppSettingsTests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    // MARK: - Save → reload across instances (binding criterion)

    func testSaveThenReloadAcrossInstancesReturnsSamePath() throws {
        var writer = try AppSettings(suiteName: suiteName)
        XCTAssertNil(writer.vaultPath, "fresh suite starts empty")

        let path = "/Users/test/Documents/MyVault"
        writer.vaultPath = path

        // A new instance over the SAME injected suite — the relaunch path.
        let reader = try AppSettings(suiteName: suiteName)
        XCTAssertEqual(reader.vaultPath, path)
        XCTAssertEqual(writer.vaultPath, path)
    }

    // MARK: - Missing value (first-launch onboarding state)

    func testNoStoredValueReturnsNil() throws {
        let settings = try AppSettings(suiteName: suiteName)
        XCTAssertNil(settings.vaultPath)
    }

    // MARK: - Explicit clearing

    func testSettingNilRemovesTheStoredPath() throws {
        var settings = try AppSettings(suiteName: suiteName)
        settings.vaultPath = "/tmp/vault"
        settings.vaultPath = nil

        let reloaded = try AppSettings(suiteName: suiteName)
        XCTAssertNil(reloaded.vaultPath)
    }
}
