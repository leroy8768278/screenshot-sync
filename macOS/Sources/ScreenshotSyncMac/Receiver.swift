import Foundation
import Network
import SystemConfiguration

final class Receiver: @unchecked Sendable {
    static let port: UInt16 = 43871
    private let queue = DispatchQueue(label: "local.screenshotsync.receiver")
    private let listener: NWListener
    private var folder: URL
    private var token: String
    private let conversations: ConversationStore
    private let onDeviceInfo: @Sendable (ScreenshotDevice, DeviceProfile, _ createdFile: Bool) -> Void
    private let onState: @Sendable (NWListener.State) -> Void
    private let onReceive: @Sendable (ScreenshotDevice?) -> Void
    private var connections: [UUID: UploadConnection] = [:]

    init(folder: URL, token: String, port: UInt16 = Receiver.port, conversations: ConversationStore = .shared,
         onDeviceInfo: @escaping @Sendable (ScreenshotDevice, DeviceProfile, _ createdFile: Bool) -> Void = { _, _, _ in },
         onState: @escaping @Sendable (NWListener.State) -> Void,
         onReceive: @escaping @Sendable (ScreenshotDevice?) -> Void) throws {
        self.folder = folder
        self.token = token
        self.conversations = conversations
        self.onDeviceInfo = onDeviceInfo
        self.onState = onState
        self.onReceive = onReceive
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, connections.count < 8, LocalAddress.accepts(connection.endpoint) else {
                connection.cancel()
                return
            }
            let id = UUID()
            let upload = UploadConnection(connection: connection, queue: queue, folder: folder, token: token,
                                          conversations: conversations, onDeviceInfo: onDeviceInfo, onReceive: onReceive) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            connections[id] = upload
            upload.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for upload in Array(self.connections.values) {
                upload.close()
            }
        }
    }

    func configure(folder: URL, token: String) {
        queue.async {
            self.folder = folder
            self.token = token
            for upload in Array(self.connections.values) {
                upload.close()
            }
        }
    }
}

private final class UploadConnection: @unchecked Sendable {
    static let maxHeader = 16 * 1024
    static let maxBody = 64 * 1024 * 1024
    static let maxVideoBody = 512 * 1024 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let folder: URL
    private let token: String
    private let conversations: ConversationStore
    private let onDeviceInfo: @Sendable (ScreenshotDevice, DeviceProfile, _ createdFile: Bool) -> Void
    private let onReceive: @Sendable (ScreenshotDevice?) -> Void
    private let onClose: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var header = Data()
    private var stage: Stage?
    private var chatUpload: ChatUpload?
    private var download: FileHandle?
    private struct ChatUpload {
        let device: ScreenshotDevice
        let id: UUID
        let file: StagedFile
        let filename: String?
        var remaining: Int
    }
    private var validationTask: Task<Void, Never>?
    private var responded = false
    private var closed = false

    private struct Stage {
        let file: StagedFile?
        let name: Inbox.FileName
        let device: ScreenshotDevice?
        let profile: DeviceProfile?
        let video: Inbox.Video?
        var remaining: Int
    }

    private struct StagedFile {
        let url: URL
        let handle: FileHandle
    }

    init(connection: NWConnection, queue: DispatchQueue, folder: URL, token: String, conversations: ConversationStore,
         onDeviceInfo: @escaping @Sendable (ScreenshotDevice, DeviceProfile, _ createdFile: Bool) -> Void,
         onReceive: @escaping @Sendable (ScreenshotDevice?) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.folder = folder
        self.token = token
        self.conversations = conversations
        self.onDeviceInfo = onDeviceInfo
        self.onReceive = onReceive
        self.onClose = onClose
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(120))
        timer.setEventHandler { [weak self] in self?.close() }
        timer.resume()
        self.timer = timer
        connection.start(queue: queue)
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !closed, !responded else { return }
            if let data, !data.isEmpty { consume(data) }
            guard !responded, !closed, validationTask == nil else { return }
            if isComplete || error != nil {
                close()
            } else {
                read()
            }
        }
    }

    private func consume(_ data: Data) {
        if chatUpload != nil {
            writeChat(data)
            return
        }
        if stage != nil {
            write(data)
            return
        }

        header.append(data)
        guard let end = header.range(of: Self.separator) else {
            if header.count >= Self.maxHeader { respond(431, "headers_too_large") }
            return
        }
        guard end.upperBound <= Self.maxHeader,
              let request = Request(bytes: header[..<end.lowerBound]) else {
            respond(400, "invalid_request")
            return
        }
        let body = Data(header[end.upperBound...])
        header.removeAll(keepingCapacity: false)
        if request.method == "GET", request.path == "/v1/health" {
            guard let authorization = request.headers["authorization"] else {
                respond(200, "ok", key: "status")
                return
            }
            if !authorized(authorization) {
                respond(401, "invalid_pairing_code")
            } else {
                do {
                    try sendJSON(["status": "ok", "macName": Self.computerName, "macFamily": MacFamily.current.rawValue])
                } catch {
                    respond(200, "ok", key: "status")
                }
            }
            return
        }
        if request.path.hasPrefix("/v1/chat/") {
            handleChat(request, body: body)
            return
        }
        guard request.path == "/v1/screenshots" || request.path == "/v1/devices" else {
            respond(404, "not_found")
            return
        }
        guard request.method == "POST" else {
            respond(405, "method_not_allowed")
            return
        }
        guard authorized(request.headers["authorization"]) else {
            respond(401, "invalid_pairing_code")
            return
        }
        guard request.headers["transfer-encoding"] == nil else {
            respond(400, "transfer_encoding_unsupported")
            return
        }
        guard let length = request.headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }),
              let size = Int(length) else {
            respond(411, "content_length_required")
            return
        }
        if request.path == "/v1/devices" {
            guard size == 0, body.isEmpty,
                  let platform = request.headers["x-device-platform"].flatMap(ScreenshotSource.init(rawValue:)),
                  let device = request.device(for: platform), let profile = request.profile(for: device) else {
                respond(400, "invalid_device_info")
                return
            }
            onDeviceInfo(device, profile, false)
            respond(200, "ok", key: "status")
            return
        }
        guard size > 0 else {
            respond(411, "content_length_required")
            return
        }
        let contentType = request.headers["content-type"]?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let video = Inbox.Video(contentType: contentType)
        guard contentType.hasPrefix("image/") || video != nil else {
            respond(415, "unsupported_media_type")
            return
        }
        guard size <= (video == nil ? Self.maxBody : Self.maxVideoBody) else {
            respond(413, video == nil ? "image_too_large" : "video_too_large")
            return
        }
        guard let id = request.headers["x-screenshot-id"], (1...256).contains(id.utf8.count),
              id.utf8.allSatisfy({ (33...126).contains($0) }) else {
            respond(400, "invalid_screenshot_id")
            return
        }

        let expectation = request.headers["expect"]?.lowercased()
        guard expectation == nil || expectation == "100-continue" else {
            respond(417, "unsupported_expectation")
            return
        }
        let name = Inbox.FileName(uploadID: id)
        let device = name.source.flatMap(request.device(for:))
        let profile = device.flatMap(request.profile(for:))
        var file: StagedFile?
        if !Inbox.contains(name, in: folder) {
            var url = folder.appendingPathComponent(".screenshotsync-incoming-\(UUID().uuidString)")
            if let video { url.appendPathExtension(video.rawValue) }
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                file = try StagedFile(url: url, handle: FileHandle(forWritingTo: url))
            } catch {
                try? FileManager.default.removeItem(at: url)
                respond(500, "cannot_write_inbox")
                return
            }
        }
        stage = Stage(file: file, name: name, device: device, profile: profile, video: video, remaining: size)
        if video != nil { timer?.schedule(deadline: .now() + .seconds(600)) }

        if expectation == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                            completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() }
            })
        }
        write(body)
    }

    private func write(_ data: Data) {
        guard var stage else { return }
        guard data.count <= stage.remaining else {
            respond(400, "body_exceeds_content_length")
            return
        }
        do {
            try stage.file?.handle.write(contentsOf: data)
            stage.remaining -= data.count
            self.stage = stage
            guard stage.remaining == 0 else { return }
            guard let file = stage.file else {
                finishUpload(stage, created: false)
                return
            }
            try file.handle.close()
            if let video = stage.video {
                validateVideo(at: file.url, format: video)
            } else {
                finishSave()
            }
        } catch {
            respond(500, "cannot_write_inbox")
        }
    }

    private func validateVideo(at url: URL, format: Inbox.Video) {
        validationTask = Task { [weak self] in
            let playable = await Inbox.playableVideo(at: url)
            guard !Task.isCancelled, let self else { return }
            queue.async { [weak self] in
                guard let self, !closed else { return }
                validationTask = nil
                if playable {
                    finishSave(videoSuffix: format.rawValue)
                } else {
                    respond(415, "invalid_video")
                }
            }
        }
    }

    private func finishSave(videoSuffix: String? = nil) {
        guard let stage, let file = stage.file else { return }
        do {
            let created: Bool
            if let videoSuffix {
                created = try Inbox.publish(staged: file.url, name: stage.name, device: stage.device,
                                            suffix: videoSuffix, in: folder)
            } else {
                created = try Inbox.save(staged: file.url, name: stage.name, device: stage.device, in: folder)
            }
            finishUpload(stage, created: created)
        } catch Inbox.SaveError.invalidImage {
            respond(415, "invalid_image")
        } catch {
            respond(500, "cannot_write_inbox")
        }
    }

    private func finishUpload(_ stage: Stage, created: Bool) {
        if created { onReceive(stage.device) }
        if let device = stage.device, let profile = stage.profile { onDeviceInfo(device, profile, created) }
        respond(created ? 201 : 200, created ? "saved" : "duplicate", key: "status")
    }

    private func authorized(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("Bearer ") else { return false }
        let given = Array(value.dropFirst(7).utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { difference, pair in
            difference | (pair.0 ^ pair.1)
        } == 0
    }

    private func respond(_ code: Int, _ message: String, key: String = "error") {
        guard !responded, !closed else { return }
        responded = true
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 409: reason = "Conflict"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 413: reason = "Content Too Large"
        case 415: reason = "Unsupported Media Type"
        case 417: reason = "Expectation Failed"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Internal Server Error"
        }
        let body = "{\"\(key)\":\"\(message)\"}"
        let reply = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        validationTask?.cancel()
        validationTask = nil
        timer?.cancel()
        timer = nil
        if let file = stage?.file {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        if let file = chatUpload?.file {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        try? download?.close()
        connection.cancel()
        onClose()
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]

        func device(for source: ScreenshotSource) -> ScreenshotDevice? {
            guard let id = headers["x-device-id"] else { return nil }
            return ScreenshotDevice(source: source, installationID: id)
        }

        func profile(for device: ScreenshotDevice) -> DeviceProfile? {
            guard headers["x-device-platform"] == device.source.rawValue, let header = headers["x-device-info"] else {
                return nil
            }
            return DeviceProfile(header: header)
        }

        init?(bytes: Data.SubSequence) {
            guard let text = String(data: bytes, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: false) ?? []
            guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return nil }
            method = String(parts[0])
            path = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let rawName = line[..<colon]
                guard !rawName.isEmpty, rawName.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) ||
                    (48...57).contains($0) || $0 == 45
                }) else { return nil }
                let name = rawName.lowercased()
                guard headers[name] == nil else { return nil }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
                headers[name] = value
            }
            self.headers = headers
        }
    }
}

private extension UploadConnection {
    static var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }

    struct MessagePage: Encodable {
        let messages: [ConversationMessage]
        let hasMore: Bool
        let macName: String
    }

    private func handleChat(_ request: Request, body: Data) {
        guard authorized(request.headers["authorization"]) else { respond(401, "invalid_pairing_code"); return }
        guard let platform = request.headers["x-device-platform"].flatMap(ScreenshotSource.init(rawValue:)),
              let device = request.device(for: platform),
              let key = request.headers["x-chat-key"] else { respond(403, "invalid_chat_identity"); return }
        guard request.headers["transfer-encoding"] == nil else { respond(400, "transfer_encoding_unsupported"); return }
        do {
            try conversations.authorize(device: device, key: key, pairingCode: token)
            let route = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            switch (request.method, route[0]) {
            case ("GET", "/v1/chat/messages"):
                var after = 0
                if route.count == 2 {
                    guard route[1].hasPrefix("after="), let value = Int(route[1].dropFirst(6)), value >= 0
                    else { respond(400, "invalid_cursor"); return }
                    after = value
                }
                let page = try conversations.page(for: device, after: after)
                if after == 0, let profile = request.profile(for: device) {
                    // Restore a missed pairing announcement even if this phone has never sent a screenshot.
                    onDeviceInfo(device, profile, false)
                }
                try sendJSON(MessagePage(messages: page.messages, hasMore: page.hasMore, macName: Self.computerName))
            case ("GET", let path) where path.hasPrefix("/v1/chat/files/"):
                guard route.count == 1, let id = UUID(uuidString: String(path.dropFirst("/v1/chat/files/".count)))
                else { respond(404, "file_not_found"); return }
                try sendFile(conversations.fileURL(for: id, device: device))
            case ("POST", "/v1/chat/text"), ("POST", "/v1/chat/file"):
                guard route.count == 1 else { respond(404, "not_found"); return }
                try beginChatUpload(request, from: device, body: body)
            default: respond(404, "not_found")
            }
        } catch { chatError(error) }
    }

    private func beginChatUpload(_ request: Request, from device: ScreenshotDevice, body: Data) throws {
        guard let length = request.headers["content-length"], !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int(length)
        else { respond(411, "content_length_required"); return }
        let isFile = request.path == "/v1/chat/file"
        guard size <= (isFile ? ConversationStore.maxFileBytes : ConversationStore.maxTextBytes)
        else { throw ConversationError.tooLarge }
        guard let id = request.headers["x-message-id"].flatMap(UUID.init(uuidString:))
        else { respond(400, "invalid_message_id"); return }
        var filename: String?
        if isFile {
            guard let field = request.headers["x-file-name"], let data = Data(base64Encoded: field),
                  let name = String(data: data, encoding: .utf8), ConversationStore.validFilename(name)
            else { throw ConversationError.invalidFile }
            filename = name
        } else if size == 0 { throw ConversationError.invalidText }
        let expectation = request.headers["expect"]?.lowercased()
        guard expectation == nil || expectation == "100-continue"
        else { respond(417, "unsupported_expectation"); return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapRelay-chat-" + UUID().uuidString)
        try Data().write(to: url, options: .withoutOverwriting)
        do {
            let file = try StagedFile(url: url, handle: FileHandle(forWritingTo: url))
            chatUpload = ChatUpload(device: device, id: id, file: file, filename: filename, remaining: size)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        timer?.schedule(deadline: .now() + .seconds(600))
        if expectation == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed {
                [weak self] error in if error != nil { self?.close() }
            })
        }
        writeChat(body)
    }

    func writeChat(_ data: Data) {
        guard var upload = chatUpload else { return }
        guard data.count <= upload.remaining else { respond(400, "body_exceeds_content_length"); return }
        do {
            try upload.file.handle.write(contentsOf: data)
            upload.remaining -= data.count
            chatUpload = upload
            guard upload.remaining == 0 else { return }
            try upload.file.handle.close()
            let message: ConversationMessage
            if let name = upload.filename {
                message = try conversations.receive(file: upload.file.url, filename: name,
                                                    from: upload.device, id: upload.id)
            } else {
                guard let text = String(data: try Data(contentsOf: upload.file.url), encoding: .utf8)
                else { throw ConversationError.invalidText }
                message = try conversations.receive(text: text, from: upload.device, id: upload.id)
            }
            try sendJSON(message)
        } catch { chatError(error) }
    }

    func chatError(_ error: Error) {
        switch error {
        case ConversationError.forbidden: respond(403, "invalid_chat_identity")
        case ConversationError.tooLarge: respond(413, "message_too_large")
        case ConversationError.notFound: respond(404, "file_not_found")
        case ConversationError.invalidText: respond(400, "invalid_message_text")
        case ConversationError.invalidFile: respond(400, "invalid_file")
        case ConversationError.conflict: respond(409, "message_id_conflict")
        default: respond(500, "conversation_storage_error")
        }
    }

    func successHeaders(type: String, bytes: Int) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
    }

    func sendJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        var response = successHeaders(type: "application/json", bytes: data.count)
        response.append(data)
        responded = true
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func sendFile(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        download = file
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        responded = true
        timer?.schedule(deadline: .now() + .seconds(600))
        connection.send(content: successHeaders(type: "application/octet-stream", bytes: Int(size)),
                        completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() } else { self?.sendNextChunk() }
        })
    }

    func sendNextChunk() {
        guard !closed else { return }
        do {
            guard let data = try download?.read(upToCount: 64 * 1024), !data.isEmpty else { close(); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendNextChunk() }
            })
        } catch { close() }
    }
}
