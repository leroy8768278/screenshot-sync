import Foundation
import XCTest
@testable import ScreenshotSyncMac

final class ConversationStoreTests: XCTestCase {
    func testClearingMacHistoryPreservesNewMessagesAndPhoneDeliveryAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = root.appendingPathComponent("history")
        let original = root.appendingPathComponent("截图说明.txt")
        let data = Data("验收记录".utf8)
        try data.write(to: original)
        let phone = try XCTUnwrap(ScreenshotDevice(source: .iOS, installationID: String(repeating: "a", count: 32)))
        let other = try XCTUnwrap(ScreenshotDevice(source: .android, installationID: phone.installationID))
        let key = String(repeating: "c", count: 64)
        let attachment: ConversationMessage
        let start: ConversationMessage
        let arrivedDuringConfirmation: ConversationMessage
        do {
            let store = ConversationStore(root: storage)
            try store.authorize(device: phone, key: key, pairingCode: "pair")
            start = try store.receive(text: "开始验收", from: phone, id: UUID())
            attachment = try store.send(file: original, to: phone)
            _ = try store.send(text: "其他手机", to: other, id: start.id)
            arrivedDuringConfirmation = try store.receive(text: "又一条", from: phone, id: UUID())

            try store.clearHistory(for: phone, through: attachment.sequence)
            try store.clearHistory(for: phone, through: start.sequence)
            XCTAssertEqual(try store.messages(for: phone).map(\.id), [arrivedDuringConfirmation.id])
            XCTAssertEqual(try store.messages(for: other).compactMap(\.text), ["其他手机"])
        }

        let reopened = ConversationStore(root: storage)
        XCTAssertEqual(try reopened.messages(for: phone).map(\.id), [arrivedDuringConfirmation.id])
        let replay = try reopened.receive(text: "开始验收", from: phone, id: start.id)
        XCTAssertEqual(replay.sequence, start.sequence)
        XCTAssertEqual(try reopened.messages(for: phone).map(\.id), [arrivedDuringConfirmation.id])
        XCTAssertEqual(try reopened.page(for: phone, after: 0).messages.map(\.id),
                       [start.id, attachment.id, arrivedDuringConfirmation.id])
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(for: attachment.id, device: phone)), data)
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertNoThrow(try reopened.authorize(device: phone, key: key, pairingCode: "pair"))
        XCTAssertThrowsError(try reopened.authorize(device: phone, key: String(repeating: "e", count: 64),
                                                   pairingCode: "pair"))

        try reopened.clearHistory(for: phone, through: arrivedDuringConfirmation.sequence)
        XCTAssertTrue(try reopened.messages(for: phone).isEmpty)
        let next = try reopened.send(text: "继续验收", to: phone)
        XCTAssertEqual(try reopened.messages(for: phone).map(\.id), [next.id])
        XCTAssertEqual(try reopened.page(for: phone, after: arrivedDuringConfirmation.sequence).messages.map(\.id),
                       [next.id])
    }

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
