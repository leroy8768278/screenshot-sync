import Foundation
import Security

struct ConversationEntry: Decodable, Identifiable {
    enum Sender: String, Decodable { case mac, phone }
    enum Kind: String, Decodable { case text, file }

    let id: UUID
    let sequence: Int
    let createdAt: TimeInterval
    let sender: Sender
    let kind: Kind
    let text: String?
    let filename: String?
    let bytes: Int

    var snippet: String {
        switch kind {
        case .text: return text ?? ""
        case .file: return "文件 · \(filename ?? "附件")"
        }
    }
}

struct ConversationPage: Decodable {
    let messages: [ConversationEntry]
    let hasMore: Bool
    let macName: String
}

enum ConversationIssue: LocalizedError {
    case unavailable, identity, textSize, fileSize, invalidFile, missingFile

    var errorDescription: String? {
        switch self {
        case .unavailable: "请在 Mac 上打开支持设备对话的新版即图。"
        case .identity: "无法验证这台 iPhone 的对话身份。"
        case .textSize: "每条文字最多 64 KiB，请分条发送。"
        case .fileSize: "单个文件最大支持 128 MiB。"
        case .invalidFile: "无法读取此文件，请重新选择。"
        case .missingFile: "这份附件已无法从 Mac 取回。"
        }
    }
}

private enum ConversationCredential {
    static func key(for receiver: Receiver, deviceID: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "local.shotsync.ios").chat",
            kSecAttrAccount as String: deviceID + "." + receiver.historyKey
        ]
        func read() throws -> String? {
            var item: CFTypeRef?
            let lookup = query.merging([kSecReturnData as String: true]) { _, new in new }
            let result = SecItemCopyMatching(lookup as CFDictionary, &item)
            if result == errSecItemNotFound { return nil }
            guard result == errSecSuccess, let data = item as? Data,
                  data.count == 64, let value = String(data: data, encoding: .ascii)
            else { throw SyncIssue.storage }
            return value
        }
        if let existing = try read() { return existing }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SyncIssue.storage
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(value.utf8)
        let result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecDuplicateItem, let stored = try read() { return stored }
        guard result == errSecSuccess else { throw SyncIssue.storage }
        return value
    }
}

struct DraftAttachment: Identifiable {
    let id: UUID
    let url: URL
    let bytes: Int
    var name: String { url.lastPathComponent }

    static func fromPicker(_ source: URL, in directory: URL) throws -> Self {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        let name = try ConversationClient.safeName(source.lastPathComponent)
        let url = folder.appending(path: name)
        // File providers can materialize a selected cloud document during a coordinated read.
        var error: NSError?
        var result: Result<Int, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &error) { readable in
            result = Result {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize else { throw ConversationIssue.invalidFile }
                guard size <= ConversationClient.fileLimit else { throw ConversationIssue.fileSize }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: readable, to: url)
                let copied = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let copied, copied <= ConversationClient.fileLimit else { throw ConversationIssue.fileSize }
                return copied
            }
        }
        do {
            if let error { throw error }
            guard let result else { throw ConversationIssue.invalidFile }
            return try Self(id: id, url: url, bytes: result.get())
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

enum ConversationClient {
    static let fileLimit = 128 * 1024 * 1024
    static let textLimit = 64 * 1024
    private static let session = ReceiverClient.makeSession(requestTimeout: 12, resourceTimeout: 30)
    private static let transfer = ReceiverClient.makeSession(requestTimeout: 30, resourceTimeout: 900)

    static func safeName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 255 else { throw ConversationIssue.invalidFile }
        return name
    }

    @MainActor
    private static func request(_ receiver: Receiver, path: String, method: String) throws -> URLRequest {
        guard let active = try ReceiverStore.load(), active.code == receiver.code,
              active.displayAddress == receiver.displayAddress else { throw SyncIssue.receiverChanged }
        var request = ReceiverClient.deviceRequest(receiver, path: "/v1/chat/" + path)
        guard let deviceID = request.value(forHTTPHeaderField: "X-Device-ID") else { throw SyncIssue.storage }
        request.httpMethod = method
        request.setValue(try ConversationCredential.key(for: receiver, deviceID: deviceID), forHTTPHeaderField: "X-Chat-Key")
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw SyncIssue.invalidResponse }
        switch http.statusCode {
        case 200, 201: return
        case 401: throw SyncIssue.accessDenied
        case 403: throw ConversationIssue.identity
        case 404, 405: throw ConversationIssue.unavailable
        default: throw SyncIssue.httpStatus(http.statusCode)
        }
    }

    static func messages(_ receiver: Receiver, after: Int) async throws -> ConversationPage {
        let request = try await request(receiver, path: "messages?after=\(after)", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(ConversationPage.self, from: data)
    }

    static func send(_ text: String, id: UUID, to receiver: Receiver) async throws {
        guard text.utf8.count <= textLimit else { throw ConversationIssue.textSize }
        var request = try await request(receiver, path: "text", method: "POST")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(id.uuidString.lowercased(), forHTTPHeaderField: "X-Message-ID")
        let (_, response) = try await session.upload(for: request, from: Data(text.utf8))
        try validate(response)
    }

    static func send(_ file: DraftAttachment, to receiver: Receiver, onProgress: @escaping ReceiverClient.UploadProgress) async throws {
        var request = try await request(receiver, path: "file", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(file.id.uuidString.lowercased(), forHTTPHeaderField: "X-Message-ID")
        request.setValue(Data(file.name.utf8).base64EncodedString(), forHTTPHeaderField: "X-File-Name")
        let delegate = ReceiverClient.uploadDelegate(byteCount: Int64(file.bytes), onProgress: onProgress)
        let (_, response) = try await transfer.upload(for: request, fromFile: file.url, delegate: delegate)
        try validate(response)
    }

    static func localFile(_ entry: ConversationEntry, receiver: Receiver) throws -> URL {
        guard entry.kind == .file, let filename = entry.filename else { throw ConversationIssue.invalidFile }
        let name = try safeName(filename)
        return URL.applicationSupportDirectory
            .appending(path: "ConversationFiles/\(receiver.historyKey)/\(entry.id.uuidString)", directoryHint: .isDirectory)
            .appending(path: name)
    }

    static func receive(_ entry: ConversationEntry, receiver: Receiver) async throws -> URL {
        let url = try localFile(entry, receiver: receiver)
        guard (0...fileLimit).contains(entry.bytes) else { throw ConversationIssue.fileSize }
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == entry.bytes { return url }
        let request = try await request(receiver, path: "files/\(entry.id.uuidString.lowercased())", method: "GET")
        let (download, response) = try await transfer.download(for: request)
        defer { try? FileManager.default.removeItem(at: download) }
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw ConversationIssue.missingFile }
        try validate(response)
        guard (try download.resourceValues(forKeys: [.fileSizeKey])).fileSize == entry.bytes else {
            throw SyncIssue.invalidResponse
        }
        try Task.checkCancellation()
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: download)
        } else {
            try FileManager.default.moveItem(at: download, to: url)
        }
        return url
    }
}
