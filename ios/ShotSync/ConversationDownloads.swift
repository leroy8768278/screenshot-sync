import CryptoKit
import Foundation

struct DownloadedChatFile: Identifiable {
    let id: UUID
    let url: URL
}

struct ChatFileExport: Codable, Identifiable {
    let id: UUID
    let folderBookmark: Data
    let filename: String
    let created: Date?
    let digest: Data
}

struct ChatDownloadSnapshot: Identifiable {
    let id = UUID()
    let downloads: [DownloadedChatFile]
    let exports: [ChatFileExport]
    var count: Int { downloads.count + exports.count }
}

/// Receipt and file operations are serialized per process, including retries after a provider error.
actor ConversationDownloads {
    static let shared = ConversationDownloads()

    private func directory(_ receiver: Receiver) -> URL {
        URL.applicationSupportDirectory.appending(path: "ConversationFiles/\(receiver.historyKey)", directoryHint: .isDirectory)
    }

    private func ledger(_ receiver: Receiver) -> URL { directory(receiver).appending(path: "exports.plist") }

    private func records(_ receiver: Receiver) throws -> [ChatFileExport] {
        do { return try PropertyListDecoder().decode([ChatFileExport].self, from: Data(contentsOf: ledger(receiver))) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    private func store(_ exports: [ChatFileExport], for receiver: Receiver) throws {
        try FileManager.default.createDirectory(at: directory(receiver), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(exports).write(to: ledger(receiver), options: .atomic)
    }

    func snapshot(_ receiver: Receiver) throws -> ChatDownloadSnapshot {
        let manager = FileManager.default
        let root = directory(receiver)
        let dirs: [URL]
        do { dirs = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { dirs = [] }
        var downloads: [DownloadedChatFile] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let info = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
            for url in try manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let file = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if file.isRegularFile == true, file.isSymbolicLink != true { downloads.append(.init(id: id, url: url)) }
            }
        }
        downloads.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        return try ChatDownloadSnapshot(downloads: downloads, exports: records(receiver))
    }

    /// Choosing a folder grants access to save the named document there again after an app restart.
    func export(_ source: URL, to pickedFolder: URL, receiver: Receiver) throws -> String {
        let access = pickedFolder.startAccessingSecurityScopedResource()
        defer { if access { pickedFolder.stopAccessingSecurityScopedResource() } }
        let bookmark = try pickedFolder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
        let original = try ConversationClient.safeName(source.lastPathComponent)
        var entries = try records(receiver)
        let checksum = try Self.hash(source)
        let manager = FileManager.default
        var savedName = original
        var index = 1
        while manager.fileExists(atPath: pickedFolder.appending(path: savedName).path) {
            index += 1
            let suffix = source.pathExtension
            savedName = source.deletingPathExtension().lastPathComponent + " (\(index))" + (suffix.isEmpty ? "" : "." + suffix)
        }
        let url = pickedFolder.appendingPathComponent(savedName)
        try Self.coordinate(url, options: []) { destination in
            try manager.copyItem(at: source, to: destination)
            do {
                let created = try destination.resourceValues(forKeys: [.creationDateKey]).creationDate
                entries.append(ChatFileExport(id: UUID(), folderBookmark: bookmark, filename: savedName,
                                              created: created, digest: checksum))
                try store(entries, for: receiver)
            } catch {
                try? manager.removeItem(at: destination)
                throw error
            }
        }
        return savedName
    }

    func remove(_ snapshot: ChatDownloadSnapshot, receiver: Receiver) throws -> Int {
        let manager = FileManager.default
        var failed = 0
        for file in snapshot.downloads {
            let dir = directory(receiver).appending(path: file.id.uuidString, directoryHint: .isDirectory)
            guard file.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else {
                failed += 1
                continue
            }
            do { try manager.removeItem(at: file.url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
            catch { failed += 1; continue }
            if (try? manager.contentsOfDirectory(atPath: dir.path).isEmpty) == true { try? manager.removeItem(at: dir) }
        }
        var records = try self.records(receiver)
        for record in snapshot.exports where records.contains(where: { $0.id == record.id }) {
            do {
                var stale = false
                let folder = try URL(resolvingBookmarkData: record.folderBookmark, options: .withoutUI,
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
                let scoped = folder.startAccessingSecurityScopedResource()
                defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                let name = try ConversationClient.safeName(record.filename)
                try Self.coordinate(folder.appendingPathComponent(name), options: .forDeleting) { url in
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true,
                          record.created == nil || record.created == info.creationDate,
                          try Self.hash(url) == record.digest else { throw ConversationIssue.invalidFile }
                    try manager.removeItem(at: url)
                }
                records.removeAll { $0.id == record.id }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                records.removeAll { $0.id == record.id }
            } catch { failed += 1 }
        }
        if !snapshot.exports.isEmpty { try store(records, for: receiver) }
        return failed
    }

    private static func coordinate(_ url: URL, options: NSFileCoordinator.WritingOptions,
                                   operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { location in
            outcome = Result { try operation(location) }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw ConversationIssue.invalidFile }
        try outcome.get()
    }

    private static func hash(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return Data(hash.finalize())
    }
}
