import Foundation
import Network

final class Receiver: @unchecked Sendable {
    static let port: UInt16 = 43871
    private let queue = DispatchQueue(label: "local.screenshotsync.receiver")
    private let listener: NWListener
    private var folder: URL
    private var token: String
    private let onState: @Sendable (NWListener.State) -> Void
    private let onReceive: @Sendable () -> Void
    private var connections: [UUID: UploadConnection] = [:]

    init(folder: URL, token: String,
         onState: @escaping @Sendable (NWListener.State) -> Void,
         onReceive: @escaping @Sendable () -> Void) throws {
        self.folder = folder
        self.token = token
        self.onState = onState
        self.onReceive = onReceive
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
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
                                          onReceive: onReceive) { [weak self] in
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
    private static let separator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let folder: URL
    private let token: String
    private let onReceive: @Sendable () -> Void
    private let onClose: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var header = Data()
    private var stage: Stage?
    private var responded = false
    private var closed = false

    private struct Stage {
        let file: StagedFile?
        let name: Inbox.FileName
        var remaining: Int
    }

    private struct StagedFile {
        let url: URL
        let handle: FileHandle
    }

    init(connection: NWConnection, queue: DispatchQueue, folder: URL, token: String,
         onReceive: @escaping @Sendable () -> Void, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.folder = folder
        self.token = token
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
            guard !responded, !closed else { return }
            if isComplete || error != nil {
                close()
            } else {
                read()
            }
        }
    }

    private func consume(_ data: Data) {
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
            if let authorization = request.headers["authorization"], !authorized(authorization) {
                respond(401, "invalid_pairing_code")
            } else {
                respond(200, "ok", key: "status")
            }
            return
        }
        guard request.path == "/v1/screenshots" else {
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
              let size = Int(length), size > 0 else {
            respond(411, "content_length_required")
            return
        }
        guard size <= Self.maxBody else {
            respond(413, "image_too_large")
            return
        }
        guard let contentType = request.headers["content-type"],
              contentType.lowercased().hasPrefix("image/") else {
            respond(415, "image_required")
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
        var file: StagedFile?
        if !Inbox.contains(name, in: folder) {
            let url = folder.appendingPathComponent(".screenshotsync-incoming-\(UUID().uuidString)")
            do {
                try Data().write(to: url, options: .withoutOverwriting)
                file = try StagedFile(url: url, handle: FileHandle(forWritingTo: url))
            } catch {
                try? FileManager.default.removeItem(at: url)
                respond(500, "cannot_write_inbox")
                return
            }
        }
        stage = Stage(file: file, name: name, remaining: size)

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
                respond(200, "duplicate", key: "status")
                return
            }
            try file.handle.close()
            let created = try Inbox.save(staged: file.url, name: stage.name, in: folder)
            if created { onReceive() }
            respond(created ? 201 : 200, created ? "saved" : "duplicate", key: "status")
        } catch Inbox.SaveError.invalidImage {
            respond(415, "invalid_image")
        } catch {
            respond(500, "cannot_write_inbox")
        }
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
        timer?.cancel()
        timer = nil
        if let file = stage?.file {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        connection.cancel()
        onClose()
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]

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
