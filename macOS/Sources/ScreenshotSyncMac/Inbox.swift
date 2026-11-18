import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ReceivedScreenshot: Identifiable {
    let url: URL
    let date: Date
    let bytes: Int64

    var id: URL { url }
}

enum Inbox {
    static let supportedTypes = [
        "public.png": "png",
        "public.jpeg": "jpg",
        "public.heic": "heic",
        "public.heif": "heif",
        "org.webmproject.webp": "webp",
        "com.compuserve.gif": "gif",
        "public.tiff": "tiff",
        "com.microsoft.bmp": "bmp"
    ]

    static func stem(for id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "Screenshot-\(suffix)"
    }

    static func contains(_ stem: String, in folder: URL) -> Bool {
        supportedTypes.values.contains { suffix in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem).\(suffix)").path)
        }
    }

    static func recent(in folder: URL) -> [ReceivedScreenshot] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? []
        let screenshots = files.compactMap { url -> ReceivedScreenshot? in
            guard url.lastPathComponent.hasPrefix("Screenshot-"),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  let date = info.contentModificationDate, let bytes = info.fileSize else { return nil }
            return ReceivedScreenshot(url: url, date: date, bytes: Int64(bytes))
        }
        return Array(screenshots.sorted { $0.date > $1.date }.prefix(30))
    }

    static func save(staged: URL, stem: String, in folder: URL) throws -> Bool {
        if contains(stem, in: folder) { return false }
        guard let image = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let type = CGImageSourceGetType(image) as String?,
              let suffix = supportedTypes[type],
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete else {
            throw SaveError.invalidImage
        }
        try FileManager.default.moveItem(at: staged, to: folder.appendingPathComponent("\(stem).\(suffix)"))
        return true
    }

    enum SaveError: Error {
        case invalidImage
    }
}
