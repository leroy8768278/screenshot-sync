import CryptoKit
import Darwin
import Foundation
import Security

struct Receiver: Codable, Equatable {
    let address: String
    let port: Int
    let code: String
    let startDate: Date?
    var automatic: Bool

    var displayAddress: String { "\(address):\(port)" }
    var historyKey: String { digest(code) }

    init(address: String, port: String, code: String, startDate: Date?, automatic: Bool) throws {
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
        self.startDate = startDate
        self.automatic = automatic
    }

    func request(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://\(displayAddress)\(path)")!)
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        return request
    }
}

final class ReceiverClient: NSObject, URLSessionTaskDelegate {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
        ]
        return URLSession(configuration: configuration, delegate: ReceiverClient(), delegateQueue: nil)
    }()

    static func check(_ receiver: Receiver) async throws {
        let (data, response) = try await session.data(for: receiver.request(path: "/v1/health"))
        try validate(response)
        guard let body = try? JSONDecoder().decode([String: String].self, from: data),
              body["status"] == "ok" else { throw SyncIssue.invalidResponse }
    }

    static func send(_ image: ScreenshotData, named filename: String, id: String, to receiver: Receiver) async throws {
        var request = receiver.request(path: "/v1/screenshots")
        request.httpMethod = "POST"
        request.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(id, forHTTPHeaderField: "X-Screenshot-ID")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        let (_, response) = try await session.upload(for: request, from: image.bytes)
        try validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw SyncIssue.invalidResponse }
        switch response.statusCode {
        case 200, 201: return
        case 401, 403: throw SyncIssue.accessDenied
        case 413: throw SyncIssue.imageTooLarge
        case 415, 422: throw SyncIssue.unsupportedImage
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
            startDate: receiver.startDate, automatic: receiver.automatic
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

func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

enum SyncIssue: LocalizedError {
    case invalidAddress, invalidPort, invalidCode, invalidResponse, accessDenied
    case imageTooLarge, unsupportedImage, unavailableImage, storage, syncBusy
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入 Mac 显示的局域网 IPv4 地址，例如 192.168.1.25。"
        case .invalidPort: "请输入 1 到 65535 之间的端口号。"
        case .invalidCode: "请输入 Mac 显示的 24 位配对码。"
        case .invalidResponse: "Mac 返回了无法识别的响应。"
        case .accessDenied: "配对码无效，请核对 Mac 上的配对码。"
        case .imageTooLarge: "有截图超过了 64 MB，已跳过。"
        case .unsupportedImage: "有截图的图像格式无法发送，已跳过。"
        case .unavailableImage: "有截图暂未下载到手机，下载后会重新尝试。"
        case .storage: "无法访问本机同步设置，请解锁手机后重试。"
        case .syncBusy: "正在发送截图，请稍后重试。"
        case .httpStatus(let status): "Mac 返回了 HTTP \(status)。"
        }
    }
}
