import ScreenCaptureKit
import XCTest
@testable import ScreenshotSyncMac

@MainActor
final class ScreenCaptureAccessTests: XCTestCase {
    func testChecksShareableContentOnlyWhenPreflightCannotConfirmAccess() async throws {
        var checks = 0
        try await LocalCaptureController.confirmScreenAccess(preflightGranted: true) { checks += 1 }
        XCTAssertEqual(checks, 0)
        try await LocalCaptureController.confirmScreenAccess(preflightGranted: false) { checks += 1 }
        XCTAssertEqual(checks, 1)
    }

    func testDeclinedAccessAndSystemFailuresKeepTheirDistinctErrorCodes() async {
        for code: SCStreamError.Code in [.userDeclined, .failedToStart] {
            do {
                try await LocalCaptureController.confirmScreenAccess(preflightGranted: false) {
                    throw NSError(domain: SCStreamErrorDomain, code: code.rawValue)
                }
                XCTFail("Expected ScreenCaptureKit error")
            } catch let error as SCStreamError {
                XCTAssertEqual(error.code, code)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
