import Foundation
import XCTest
@testable import ScreenshotSyncMac

final class InboxImageCleanupTests: XCTestCase {
    private let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var inbox: URL { workspace.appendingPathComponent("传图") }
    private var trash: URL { workspace.appendingPathComponent("模拟废纸篓") }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workspace)
    }

    private func moveToTestTrash(_ file: URL) throws {
        try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
    }

    func testCleanupIncludesEverySourceAndOrdinaryPicturesButLeavesOtherFilesAlone() throws {
        let manager = FileManager.default
        let stem = String(repeating: "a", count: 32)
        let pictures = ["Screenshot-ios-\(stem).png", "Screenshot-android-\(stem).jpg",
                        "Screenshot-harmony-\(stem).heic", "Screenshot-mac-\(stem).png",
                        "Screenshot-\(stem).gif", "从访达放入的图片.JPEG"]
        let other = ["Screenshot-ios-\(stem).mp4", "演示.mov", "记录.txt", ".screenshotsync-local-123.png"]
        for name in pictures + other {
            try Data(name.utf8).write(to: inbox.appendingPathComponent(name))
        }
        let nested = inbox.appendingPathComponent("子文件夹.png")
        try manager.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedImage = nested.appendingPathComponent("保留.png")
        try Data("子文件".utf8).write(to: nestedImage)
        let outsideImage = workspace.appendingPathComponent("外部.png")
        try Data("外部文件".utf8).write(to: outsideImage)
        let link = inbox.appendingPathComponent("外部链接.png")
        try manager.createSymbolicLink(at: link, withDestinationURL: outsideImage)

        let plan = try Inbox.prepareImageCleanup(in: inbox)
        XCTAssertEqual(plan.count, pictures.count)
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: trash.path).isEmpty)
        let result = Inbox.trashImages(in: plan, moveToTrash: moveToTestTrash)

        XCTAssertEqual(result.moved, pictures.count)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: trash.path)), Set(pictures))
        for name in other {
            XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(name)), Data(name.utf8))
        }
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link.path), outsideImage.path)
        XCTAssertTrue(manager.fileExists(atPath: nestedImage.path))
        XCTAssertTrue(manager.fileExists(atPath: outsideImage.path))
        XCTAssertEqual(try Inbox.prepareImageCleanup(in: inbox).count, 0)
    }

    func testConfirmUsesSnapshotWhenImagesArriveDisappearOrAreReplaced() throws {
        let manager = FileManager.default
        let original = inbox.appendingPathComponent("将被替换.png")
        let gone = inbox.appendingPathComponent("已移走.png")
        let edited = inbox.appendingPathComponent("重新编辑.png")
        let retained = Data("替换后的图片".utf8)
        for url in [original, gone, edited, inbox.appendingPathComponent("普通图片.png")] {
            try Data("原文件".utf8).write(to: url)
        }
        let plan = try Inbox.prepareImageCleanup(in: inbox)
        XCTAssertEqual(plan.count, 4)
        try manager.moveItem(at: original, to: workspace.appendingPathComponent("旧副本.png"))
        try retained.write(to: original)
        try manager.removeItem(at: gone)
        let handle = try FileHandle(forWritingTo: edited)
        try handle.write(contentsOf: retained)
        try handle.close()
        let late = inbox.appendingPathComponent("确认期间收到.png")
        try retained.write(to: late)

        let result = Inbox.trashImages(in: plan, moveToTrash: moveToTestTrash)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(try Data(contentsOf: original), retained)
        XCTAssertEqual(try Data(contentsOf: edited), retained)
        XCTAssertEqual(try Data(contentsOf: late), retained)
    }

    func testMovingTheOriginalFolderDoesNotClearItsReplacement() throws {
        let manager = FileManager.default
        let name = "同名.png"
        try Data([1]).write(to: inbox.appendingPathComponent(name))
        let plan = try Inbox.prepareImageCleanup(in: inbox)
        let formerInbox = workspace.appendingPathComponent("原传图目录")
        try manager.moveItem(at: inbox, to: formerInbox)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: false)
        try Data([2]).write(to: inbox.appendingPathComponent(name))

        let result = Inbox.trashImages(in: plan, moveToTrash: moveToTestTrash)
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(name)), Data([2]))
        XCTAssertEqual(try Data(contentsOf: formerInbox.appendingPathComponent(name)), Data([1]))
    }

    func testPartialFailureCanBeRetriedWithoutLosingTheRemainingPicture() throws {
        let failed = inbox.appendingPathComponent("暂时不能移动.png")
        let other = inbox.appendingPathComponent("可移动.png")
        try Data([1]).write(to: failed)
        try Data([2]).write(to: other)
        let plan = try Inbox.prepareImageCleanup(in: inbox)

        let result = Inbox.trashImages(in: plan) { url in
            if url.lastPathComponent == failed.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
            try self.moveToTestTrash(url)
        }
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(try Data(contentsOf: failed), Data([1]))

        let retry = try Inbox.prepareImageCleanup(in: inbox)
        XCTAssertEqual(retry.count, 1)
        XCTAssertEqual(Inbox.trashImages(in: retry, moveToTrash: moveToTestTrash).moved, 1)
        XCTAssertEqual(try Inbox.prepareImageCleanup(in: inbox).count, 0)
    }
}
