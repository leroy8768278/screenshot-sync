import Foundation
import XCTest
@testable import ScreenshotSyncMac

final class ConversationStoreTests: XCTestCase {
    func testRetryAfterRestartAndDeviceIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("history")
        let file = root.appendingPathComponent("验收.txt")
        let bytes = Data("验收记录\n第二行".utf8)
        try bytes.write(to: file)
        let sender = try XCTUnwrap(ScreenshotDevice(source: .iOS, installationID: String(repeating: "a", count: 32)))
        let other = try XCTUnwrap(ScreenshotDevice(source: .iOS, installationID: String(repeating: "b", count: 32)))
        let credential = String(repeating: "c", count: 64)
        let id = UUID()
        let original: ConversationMessage
        do {
            let store = ConversationStore(root: storage)
            try store.authorize(device: sender, key: credential, pairingCode: "first")
            original = try store.receive(file: file, filename: file.lastPathComponent, from: sender, id: id)
        }
        let reopened = ConversationStore(root: storage)
        // The receiver stages a new file for every HTTP attempt.
        try bytes.write(to: file)
        let retry = try reopened.receive(file: file, filename: file.lastPathComponent, from: sender, id: id)
        XCTAssertEqual(retry.sequence, original.sequence)
        try Data(repeating: 0, count: bytes.count).write(to: file)
        XCTAssertThrowsError(try reopened.receive(file: file, filename: file.lastPathComponent, from: sender, id: id))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(for: id, device: sender)), bytes)
        XCTAssertThrowsError(try reopened.fileURL(for: id, device: other))
        XCTAssertTrue(try reopened.messages(for: other).isEmpty)

        let alternate = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try reopened.authorize(device: sender, key: alternate, pairingCode: "first"))
        XCTAssertNoThrow(try reopened.authorize(device: sender, key: alternate, pairingCode: "rotated"))
        let reply = try reopened.send(text: "收到", to: sender)
        let page = try reopened.page(for: sender, after: original.sequence)
        XCTAssertEqual(page.messages.map(\.id), [reply.id])
        XCTAssertEqual(page.messages.first?.sender, "mac")
        XCTAssertEqual(try reopened.messages(for: sender).count, 2)
    }
}
