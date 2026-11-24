import CryptoKit
import Darwin
import Foundation
import Security

struct Receiver: Codable, Equatable {
    let address: String
    let port: Int
    let code: String
    var automatic: Bool
    var pairedAt: Date?

    var displayAddress: String { "\(address):\(port)" }
    var historyKey: String { digest(code) }

    init(address: String, port: String, code: String, automatic: Bool, pairedAt: Date? = nil) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var binaryAddress = in_addr()
        guard inet_pton(AF_INET, address, &binaryAddress) == 1 else {
            throw SyncIssue.invalidAddress
        }

        let host = UInt32(bigEndian: binaryAddress.s_addr)
        let isPrivate = host >> 24 == 10 || host >> 20 == 0xAC1 ||
            host >> 16 == 0xC0A8 || host >> 16 == 0xA9FE
#if targetEnvironment(simulator)
        let allowLoopback = host == 0x7F000001
#else
        let allowLoopback = false
#endif
        guard isPrivate || allowLoopback else { throw SyncIssue.invalidAddress }

        guard let port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { throw SyncIssue.invalidPort }

        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.utf8.count == 24, code.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw SyncIssue.invalidCode }

        self.address = address
        self.port = port
        self.code = code
        self.automatic = automatic
        self.pairedAt = pairedAt
    }

    func request(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://\(displayAddress)\(path)")!)
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        return request
    }
}

private struct PairingCode: Decodable {
    let type: String
    let version: Int
    let token: String
    let addresses: [String]

    static func receivers(in text: String) throws -> [Receiver] {
        guard text.utf8.count <= 4096,
              let pairing = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              pairing.type == "snaprelay-pair", pairing.version == 1,
              pairing.token.utf8.count == 24, (1...16).contains(pairing.addresses.count)
        else { throw SyncIssue.invalidPairingQR }

        var receivers = [Receiver]()
        for address in pairing.addresses {
            guard address.hasPrefix("http://") else { throw SyncIssue.invalidPairingQR }
            var endpoint = address.dropFirst("http://".count)
            if endpoint.last == "/" { endpoint.removeLast() }
            let fields = endpoint.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] == "43871",
                  fields[0].utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }),
                  !fields[0].hasPrefix("127."),
                  let receiver = try? Receiver(address: String(fields[0]), port: "43871", code: pairing.token, automatic: true)
            else { throw SyncIssue.invalidPairingQR }
            if !receivers.contains(receiver) { receivers.append(receiver) }
        }
        return receivers
    }
}

final class ReceiverClient: NSObject, URLSessionTaskDelegate {
    private static let session = makeSession(requestTimeout: 8, resourceTimeout: 20)
    private static let videoSession = makeSession(requestTimeout: 25, resourceTimeout: 600)

    private static func makeSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
        ]
        return URLSession(configuration: configuration, delegate: ReceiverClient(), delegateQueue: nil)
    }

    static func check(_ receiver: Receiver) async throws {
        struct Health: Decodable { let status: String }
        let (data, response) = try await session.data(for: receiver.request(path: "/v1/health"))
        try validate(response)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Health.self, from: data),
              body.status == "ok" else { throw SyncIssue.invalidResponse }
    }

    static func verifiedReceiver(in qr: String) async throws -> Receiver {
        let candidates = try PairingCode.receivers(in: qr)
        return try await withThrowingTaskGroup(of: Result<Receiver, Error>.self) { group in
            var remaining = candidates.makeIterator()
            var lastError: Error = URLError(.cannotConnectToHost)
            func probe(_ candidate: Receiver) async -> Result<Receiver, Error> {
                do {
                    try await check(candidate)
                    return .success(candidate)
                } catch { return .failure(error) }
            }
            for _ in 0..<min(3, candidates.count) {
                if let candidate = remaining.next() { group.addTask { await probe(candidate) } }
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case .success(let receiver):
                    group.cancelAll()
                    return receiver
                case .failure(let error):
                    if error is SyncIssue || lastError is URLError { lastError = error }
                    if let candidate = remaining.next() { group.addTask { await probe(candidate) } }
                }
            }
            throw lastError
        }
    }

    @MainActor
    private static func deviceRequest(_ receiver: Receiver, path: String) -> URLRequest {
        var request = receiver.request(path: path)
        request.httpMethod = "POST"
        request.setValue(InstallationIdentity.deviceID, forHTTPHeaderField: "X-Device-ID")
        request.setValue("ios", forHTTPHeaderField: "X-Device-Platform")
        let info = try? JSONEncoder().encode(DeviceInfo())
        request.setValue(info?.base64EncodedString(), forHTTPHeaderField: "X-Device-Info")
        return request
    }

    @MainActor
    static func registerDevice(with receiver: Receiver) async throws {
        try Task.checkCancellation()
        guard receiver.pairedAt != nil else { return }
        var request = deviceRequest(receiver, path: "/v1/devices")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncIssue.invalidResponse }
        switch http.statusCode {
        case 200..<300, 404, 405: return  // Older receivers can still accept media.
        default: throw SyncIssue.httpStatus(http.statusCode)
        }
    }

    static func send(_ image: ScreenshotData, named filename: String, id: String, to receiver: Receiver) async throws {
        let request = await uploadRequest(mimeType: image.mimeType, filename: filename, id: id, receiver: receiver)
        let (_, response) = try await session.upload(for: request, from: image.bytes)
        try validate(response)
    }

    static func send(_ video: SelectedVideo, named filename: String, id: String, to receiver: Receiver) async throws {
        let request = await uploadRequest(mimeType: video.mimeType, filename: filename, id: id, receiver: receiver)
        let (_, response) = try await videoSession.upload(for: request, fromFile: video.file)
        try validate(response, video: true)
    }

    @MainActor
    private static func uploadRequest(mimeType: String, filename: String, id: String, receiver: Receiver) -> URLRequest {
        var request = deviceRequest(receiver, path: "/v1/screenshots")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: "X-Screenshot-ID")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        return request
    }

    private static func validate(_ response: URLResponse, video: Bool = false) throws {
        guard let response = response as? HTTPURLResponse else { throw SyncIssue.invalidResponse }
        switch response.statusCode {
        case 200, 201: return
        case 401, 403: throw SyncIssue.accessDenied
        case 413: throw video ? SyncIssue.videoTooLarge : SyncIssue.imageTooLarge
        case 415, 422: throw video ? SyncIssue.unsupportedVideo : SyncIssue.unsupportedImage
        default: throw SyncIssue.httpStatus(response.statusCode)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum InstallationIdentity {
    static let deviceID = try? loadOrCreate()

    private static func loadOrCreate() throws -> String {
        var directory = URL.applicationSupportDirectory.appending(path: "InstallationIdentity", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)

        let file = directory.appending(path: "device-id")
        if FileManager.default.fileExists(atPath: file.path) {
            let stored = try Data(contentsOf: file)
            if stored.count == 32, stored.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                return String(decoding: stored, as: UTF8.self)
            }
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try Data(id.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return id
    }
}

enum ReceiverStore {
    private static var key: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "local.shotsync.ios").receiver",
            kSecAttrAccount as String: "mac",
        ]
    }

    static func load() throws -> Receiver? {
        let query = key.merging([kSecReturnData as String: true]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncIssue.storage }
        let receiver = try JSONDecoder().decode(Receiver.self, from: data)
        return try Receiver(
            address: receiver.address, port: String(receiver.port), code: receiver.code,
            automatic: receiver.automatic, pairedAt: receiver.pairedAt
        )
    }

    static func save(_ receiver: Receiver) throws {
        let data = try JSONEncoder().encode(receiver)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = key.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SyncIssue.storage }
        } else if status != errSecSuccess {
            throw SyncIssue.storage
        }
    }

    static func clear() throws {
        let status = SecItemDelete(key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncIssue.storage }
    }
}

struct SyncHistory {
    private let file: URL
    private(set) var sent: Set<String>
    private(set) var lastSent: Date?

    init(key: String) throws {
        var directory = URL.applicationSupportDirectory.appending(path: "ScreenshotHistory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let file = directory.appending(path: "\(key).log")
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            let contents = String(decoding: data, as: UTF8.self)
            sent = Set(contents.split(separator: "\n").compactMap { line in
                guard line.utf8.count == 68, line.hasPrefix("ios-") else { return nil }
                return String(line)
            })
            lastSent = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } else {
            sent = []
        }
    }

    mutating func markSent(_ id: String) throws {
        // A leading newline separates new records from any interrupted write.
        let data = Data("\n\(id)\n".utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        sent.insert(id)
        lastSent = .now
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func digest(_ value: String) -> String { digest(Data(value.utf8)) }

enum SyncIssue: LocalizedError {
    case invalidAddress, invalidPort, invalidCode, invalidResponse, accessDenied, invalidPairingQR
    case imageTooLarge, unsupportedImage, unavailableImage, videoTooLarge, unsupportedVideo, unavailableVideo
    case storage, syncBusy, receiverChanged
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入 Mac 显示的局域网 IPv4 地址，例如 192.168.1.25。"
        case .invalidPort: "请输入 1 到 65535 之间的端口号。"
        case .invalidCode: "请输入 Mac 显示的 24 位配对码。"
        case .invalidPairingQR: "无法识别配对码。请扫描 Mac 端即图在「扫码配对」中显示的二维码。"
        case .invalidResponse: "Mac 返回了无法识别的响应。"
        case .accessDenied: "配对码无效，请核对 Mac 上的配对码。"
        case .imageTooLarge: "图片超过 64 MB，无法发送。"
        case .unsupportedImage: "图片格式无法发送。"
        case .unavailableImage: "无法读取图片。请确认已下载到手机后重试。"
        case .videoTooLarge: "视频超过 512 MiB，无法发送。"
        case .unsupportedVideo: "无法发送此视频。支持 MP4、MOV 和 M4V。"
        case .unavailableVideo: "无法读取视频。请确认已下载到手机后重试。"
        case .storage: "无法访问本机同步设置，请解锁手机后重试。"
        case .syncBusy: "正在处理另一次连接或手动发送，请稍后重试。"
        case .receiverChanged: "Mac 连接已变更，请重新选择要发送的项目。"
        case .httpStatus(let status): "Mac 返回了 HTTP \(status)。"
        }
    }
}
