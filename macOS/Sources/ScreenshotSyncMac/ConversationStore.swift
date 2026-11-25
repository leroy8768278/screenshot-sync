import CryptoKit
import Foundation
import SQLite3

struct ConversationMessage: Codable, Identifiable, Sendable {
    let id: UUID
    let sequence: Int
    let createdAt: Double
    let sender: String
    let kind: String
    let text: String?
    let filename: String?
    let bytes: Int
}

extension Notification.Name {
    static let conversationDidChange = Notification.Name("SnapRelayConversationDidChange")
}

enum ConversationError: LocalizedError {
    case invalidText, invalidFile, tooLarge, notFound, forbidden, conflict, storage

    var errorDescription: String? {
        switch self {
        case .invalidText: "请输入有效文字。"
        case .invalidFile: "无法发送此文件。"
        case .tooLarge: "文字最多为 64 KB，每个文件最大为 128 MB。"
        case .notFound: "找不到这份附件。"
        case .forbidden: "这台设备的对话凭据无效。"
        case .conflict: "此消息编号已被使用。"
        case .storage: "无法读写本机的对话记录。"
        }
    }
}

/// SQLite commits message order and metadata together. Attachment copies are published before their row.
final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore(root: URL.applicationSupportDirectory
        .appendingPathComponent("SnapRelay/Conversations", isDirectory: true))
    static let maxTextBytes = 64 * 1024
    static let maxFileBytes = 128 * 1024 * 1024

    private let root: URL
    private let queue = DispatchQueue(label: "local.screenshotsync.conversations")
    private var database: OpaquePointer?

    init(root: URL) { self.root = root }

    deinit { if let database { sqlite3_close(database) } }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("messages.sqlite").path, &handle) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw ConversationError.storage
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS credentials(device TEXT PRIMARY KEY, digest TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS messages(
              seq INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, id TEXT NOT NULL,
              time REAL NOT NULL, sender TEXT NOT NULL, kind TEXT NOT NULL, text TEXT, filename TEXT,
              bytes INTEGER NOT NULL, UNIQUE(device, id));
            CREATE INDEX IF NOT EXISTS conversation_order ON messages(device, seq);
            CREATE TABLE IF NOT EXISTS mac_history(
              device TEXT PRIMARY KEY, cleared_through INTEGER NOT NULL);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw ConversationError.storage
        }
        database = handle
        return handle
    }

    private func statement<T>(_ sql: String, _ values: [String?],
                              run: (OpaquePointer) throws -> T) throws -> T {
        let handle = try open()
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw ConversationError.storage
        }
        defer { sqlite3_finalize(result) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            if let value {
                // Explicit length preserves NULs pasted into a message.
                code = sqlite3_bind_text(result, position, value, Int32(value.utf8.count),
                                         unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                code = sqlite3_bind_null(result, position)
            }
            guard code == SQLITE_OK else { throw ConversationError.storage }
        }
        return try run(result)
    }

    private func execute(_ sql: String, _ values: [String?]) throws {
        try statement(sql, values) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw ConversationError.storage }
        }
    }

    func authorize(device: ScreenshotDevice, key: String, pairingCode: String) throws {
        guard key.utf8.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ConversationError.forbidden }
        let hash = Data(SHA256.hash(data: Data(key.utf8))).base64EncodedString()
        let epoch = Data(SHA256.hash(data: Data(pairingCode.utf8))).base64EncodedString()
        let identity = epoch + "/" + device.id
        try queue.sync {
            try statement("SELECT digest FROM credentials WHERE device = ?", [identity]) { stmt in
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    let stored = String(cString: sqlite3_column_text(stmt, 0))
                    guard stored == hash else { throw ConversationError.forbidden }
                case SQLITE_DONE:
                    try execute("INSERT INTO credentials VALUES (?, ?)", [identity, hash])
                default: throw ConversationError.storage
                }
            }
        }
    }

    private func rows(where clause: String, values: [String]) throws -> [ConversationMessage] {
        let sql = "SELECT id, seq, time, sender, kind, text, filename, bytes FROM messages WHERE " + clause
        return try statement(sql, values) { stmt in
            func string(_ col: Int32) -> String? {
                guard let pointer = sqlite3_column_text(stmt, col) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(stmt, col))),
                              as: UTF8.self)
            }
            var result: [ConversationMessage] = []
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    guard let id = string(0).flatMap(UUID.init(uuidString:)), let sender = string(3),
                          let kind = string(4) else { throw ConversationError.storage }
                    result.append(ConversationMessage(id: id, sequence: Int(sqlite3_column_int64(stmt, 1)),
                        createdAt: sqlite3_column_double(stmt, 2), sender: sender, kind: kind, text: string(5),
                        filename: string(6), bytes: Int(sqlite3_column_int64(stmt, 7))))
                case SQLITE_DONE: return result
                default: throw ConversationError.storage
                }
            }
        }
    }

    func messages(for device: ScreenshotDevice) throws -> [ConversationMessage] {
        try queue.sync {
            try rows(where: """
                device = ?1 AND seq > COALESCE(
                    (SELECT cleared_through FROM mac_history WHERE device = ?1), 0)
                ORDER BY seq
                """, values: [device.id])
        }
    }

    // The phone fetches its own history from the delivery log even after a local Mac clear.
    func clearHistory(for device: ScreenshotDevice, through sequence: Int) throws {
        let changed = try queue.sync {
            try execute("""
                INSERT INTO mac_history(device, cleared_through)
                SELECT device, MAX(seq) FROM messages WHERE device = ? AND seq <= ? GROUP BY device
                ON CONFLICT(device) DO UPDATE SET cleared_through = excluded.cleared_through
                WHERE excluded.cleared_through > mac_history.cleared_through
                """, [device.id, String(sequence)])
            return sqlite3_changes(try open()) > 0
        }
        if changed { NotificationCenter.default.post(name: .conversationDidChange, object: device.id) }
    }

    func page(for device: ScreenshotDevice, after: Int) throws -> (messages: [ConversationMessage], hasMore: Bool) {
        try queue.sync {
            let page = try rows(where: "device = ? AND seq > ? ORDER BY seq LIMIT 33",
                                values: [device.id, String(after)])
            // Control characters may expand to six ASCII bytes each during JSON encoding.
            // File bodies are downloaded separately and do not count toward this page budget.
            var textBytes = 0
            let messages = page.prefix(32).prefix { message in
                textBytes += message.kind == "text" ? message.bytes : 0
                return textBytes <= 256 * 1024
            }
            return (Array(messages), page.count > messages.count)
        }
    }

    private func existing(id: UUID, device: ScreenshotDevice) throws -> ConversationMessage? {
        try rows(where: "device = ? AND id = ?", values: [device.id, id.uuidString]).first
    }

    func send(text: String, to device: ScreenshotDevice, id: UUID = UUID()) throws -> ConversationMessage {
        try append(text: text, source: nil, filename: nil, sender: "mac", device: device, id: id)
    }

    func send(file: URL, to device: ScreenshotDevice, id: UUID = UUID()) throws -> ConversationMessage {
        try append(text: nil, source: file, filename: file.lastPathComponent, sender: "mac", device: device, id: id)
    }

    func receive(text: String, from device: ScreenshotDevice, id: UUID) throws -> ConversationMessage {
        try append(text: text, source: nil, filename: nil, sender: "phone", device: device, id: id)
    }

    func receive(file: URL, filename: String, from device: ScreenshotDevice, id: UUID) throws -> ConversationMessage {
        try append(text: nil, source: file, filename: filename, sender: "phone", device: device, id: id)
    }

    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".." &&
        name.rangeOfCharacter(from: .controlCharacters.union(CharacterSet(charactersIn: "/\\:"))) == nil
    }

    private func attachmentDirectory(for device: ScreenshotDevice, id: UUID) -> URL {
        root.appendingPathComponent(device.source.rawValue, isDirectory: true)
            .appendingPathComponent(device.installationID, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func append(text: String?, source: URL?, filename: String?, sender: String,
                        device: ScreenshotDevice, id: UUID) throws -> ConversationMessage {
        let bytes: Int
        if let text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationError.invalidText
            }
            bytes = text.utf8.count
            guard bytes <= Self.maxTextBytes else { throw ConversationError.tooLarge }
        } else {
            guard let source, let filename, Self.validFilename(filename),
                  let info = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize
            else { throw ConversationError.invalidFile }
            bytes = size
            guard size <= Self.maxFileBytes else { throw ConversationError.tooLarge }
        }
        let kind = source == nil ? "text" : "file"
        let (message, inserted): (ConversationMessage, Bool) = try queue.sync {
            let manager = FileManager.default
            let directory = attachmentDirectory(for: device, id: id)
            if let previous = try existing(id: id, device: device) {
                guard previous.sender == sender, previous.kind == kind, previous.text == text,
                      previous.filename == filename, previous.bytes == bytes else { throw ConversationError.conflict }
                if let source, let filename,
                   !manager.contentsEqual(atPath: source.path, andPath: directory.appendingPathComponent(filename).path) {
                    throw ConversationError.conflict
                }
                return (previous, false)
            }
            do {
                if let source, let filename {
                    // Discard an unpublished file left by a process exit before the SQLite insert.
                    if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let target = directory.appendingPathComponent(filename)
                    if sender == "phone" { try manager.moveItem(at: source, to: target) }
                    else { try manager.copyItem(at: source, to: target) }
                    guard try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes else {
                        throw ConversationError.invalidFile
                    }
                }
                let now = Date().timeIntervalSince1970
                let sql = "INSERT INTO messages(device,id,time,sender,kind,text,filename,bytes) VALUES (?,?,?,?,?,?,?,?)"
                try execute(sql, [device.id, id.uuidString, String(now), sender, kind, text, filename, String(bytes)])
                let sequence = Int(sqlite3_last_insert_rowid(try open()))
                return (ConversationMessage(id: id, sequence: sequence, createdAt: now, sender: sender,
                                            kind: kind, text: text, filename: filename, bytes: bytes), true)
            } catch {
                if source != nil { try? manager.removeItem(at: directory) }
                throw error
            }
        }
        if inserted { NotificationCenter.default.post(name: .conversationDidChange, object: device.id) }
        return message
    }

    func fileURL(for message: ConversationMessage, device: ScreenshotDevice) throws -> URL {
        try fileURL(for: message.id, device: device)
    }

    func fileURL(for id: UUID, device: ScreenshotDevice) throws -> URL {
        try queue.sync {
            guard let name = try existing(id: id, device: device)?.filename, Self.validFilename(name) else {
                throw ConversationError.notFound
            }
            let url = attachmentDirectory(for: device, id: id).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ConversationError.notFound }
            return url
        }
    }

}
