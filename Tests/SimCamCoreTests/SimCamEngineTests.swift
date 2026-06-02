import XCTest

final class SimCamEngineTests: XCTestCase {

    func testActivateLicenseValidProKey() {
        let engine = SimCamEngine.shared
        switch engine.activateLicense(key: "SIMCAM-PRO-ABCDEF") {
        case .success(let lic):
            XCTAssertEqual(lic, .pro)
            XCTAssertEqual(engine.state.license, .pro)
        case .failure(let e):
            XCTFail("expected pro, got \(e)")
        }
        // restore trial for subsequent tests
        _ = engine.activateLicense(key: "trial")
    }

    func testActivateLicenseInvalidKeyFails() {
        let engine = SimCamEngine.shared
        let result = engine.activateLicense(key: "BOGUS-KEY")
        switch result {
        case .success: XCTFail("expected failure")
        case .failure(let e):
            XCTAssertEqual(e.description, EngineError.licenseRequired.description)
        }
    }

    func testTrialBlocksProSources() {
        let engine = SimCamEngine.shared
        _ = engine.activateLicense(key: "trial")
        let result = engine.setSource(.qr(payload: "AUTH"))
        switch result {
        case .success: XCTFail("trial should not allow QR injection")
        case .failure(let e):
            XCTAssertTrue(e.description.contains("Pro license"))
        }
    }

    func testProUnlocksDemoSwitch() {
        let engine = SimCamEngine.shared
        defer { _ = engine.activateLicense(key: "trial"); engine.stop() }

        _ = engine.activateLicense(key: "SIMCAM-PRO-LOCAL01")
        let result = engine.setSource(.demo)
        switch result {
        case .success(let st):
            XCTAssertEqual(st.source, .demo)
            XCTAssertTrue(st.isStreaming)
        case .failure(let e):
            XCTFail("demo should always be allowed: \(e)")
        }
        engine.stop()
        XCTAssertFalse(engine.state.isStreaming)
    }

    func testDiagnoseReturnsKnownKeys() {
        let diag = SimCamEngine.shared.diagnose()
        let keys = diag.map(\.key)
        XCTAssertTrue(keys.contains("license"))
        XCTAssertTrue(keys.contains("cmio extension"))
        XCTAssertTrue(keys.contains("simulator hooks"))
        XCTAssertTrue(keys.contains("cameras"))
        XCTAssertTrue(keys.contains("macos"))
    }
}

final class LicenseKeyTests: XCTestCase {
    func testIsValidProKey() {
        XCTAssertTrue(LicenseManager.isValidProKey("SIMCAM-PRO-ABCDEF"))
        XCTAssertTrue(LicenseManager.isValidProKey("SIMCAM-PRO-AGENT-001"))
        XCTAssertFalse(LicenseManager.isValidProKey("SIMCAM-PRO-"))      // tail too short
        XCTAssertFalse(LicenseManager.isValidProKey("SIMCAM-PRO-A!B@C")) // invalid chars
        XCTAssertFalse(LicenseManager.isValidProKey("trial"))
        XCTAssertFalse(LicenseManager.isValidProKey(""))
    }
}
