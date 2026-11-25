import Foundation
import XCTest
@testable import ScreenshotSyncMac

final class ConversationDraftTests: XCTestCase {
    @MainActor
    func testTypingImmediatelyAfterSendAndRecoveringAFailedSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(root: root)
        let suite = "ConversationDraftTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let device = try XCTUnwrap(ScreenshotDevice(source: .iOS, installationID: String(repeating: "a", count: 32)))
        let room = MacConversationRoom(device: device, defaults: defaults, store: store)

        room.draft = "第一条"
        room.send()
        XCTAssertEqual(room.draft, "")
        room.draft = "接着输入"
        try await waitForSend(room)
        XCTAssertEqual(room.draft, "接着输入")
        XCTAssertEqual(try store.messages(for: device).compactMap(\.text), ["第一条"])

        let oversized = String(repeating: "x", count: ConversationStore.maxTextBytes + 1)
        room.draft = oversized
        room.send()
        room.draft = "新草稿"
        try await waitForSend(room)
        XCTAssertEqual(room.draft, oversized + "\n新草稿")
        XCTAssertEqual(try store.messages(for: device).count, 1)
    }

    @MainActor
    private func waitForSend(_ room: MacConversationRoom) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while room.sending && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(room.sending)
    }
}
