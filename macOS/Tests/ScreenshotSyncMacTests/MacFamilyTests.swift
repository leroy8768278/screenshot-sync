import XCTest
@testable import ScreenshotSyncMac

final class MacFamilyTests: XCTestCase {
    func testMarketingNamesAndIntelIdentifiers() {
        let examples: [(String, MacFamily)] = [
            ("Mac mini (2024)", .mini), ("Macmini9,1", .mini),
            ("Mac Studio", .studio), ("MacPro7,1", .pro),
            ("iMac 24-inch (2024)", .imac), ("iMacPro1,1", .imac),
            ("MacBook Pro (14-inch, 2023)", .bookPro), ("MacBookPro16,1", .bookPro),
            ("MacBook Air 13-inch (M4)", .air), ("MacBook Neo", .neo),
            ("MacBook10,1", .book),
        ]
        for (model, family) in examples {
            XCTAssertEqual(MacFamily.family(for: model), family, model)
        }
    }

    func testUnknownFamilyAndOpaqueModelDoNotGuess() {
        XCTAssertNil(MacFamily.family(for: "Mac16,10"))
        XCTAssertNil(MacFamily.family(for: "MacBook Future"))
        XCTAssertNil(MacFamily.family(for: "VirtualMac2,1"))
    }
}
