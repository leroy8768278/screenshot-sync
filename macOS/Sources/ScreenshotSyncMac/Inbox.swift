import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotSource: String, CaseIterable {
    case iOS = "ios"
    case android
    case harmony

    var label: String {
        switch self {
        case .iOS: "iOS"
        case .android: "Android"
        case .harmony: "鸿蒙"
        }
    }

    init?(uploadID: String) {
        let parts = uploadID.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        self.init(rawValue: String(parts[0]))
    }
}

struct ReceivedScreenshot: Identifiable {
    let url: URL
    let date: Date
    let bytes: Int64

    var id: URL { url }
}

enum Inbox {
    private static let filePrefix = "Screenshot-"

    struct FileName {
        let stem: String
        let legacyStem: String

        init(uploadID: String) {
            let digest = SHA256.hash(data: Data(uploadID.utf8))
            let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            legacyStem = "\(Inbox.filePrefix)\(suffix)"
            if let source = ScreenshotSource(uploadID: uploadID) {
                stem = "\(Inbox.filePrefix)\(source.rawValue)-\(suffix)"
            } else {
                stem = legacyStem
            }
        }
    }

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

    static func contains(_ name: FileName, in folder: URL) -> Bool {
        let stems = name.stem == name.legacyStem ? [name.stem] : [name.stem, name.legacyStem]
        return stems.contains { stem in
            supportedTypes.values.contains { suffix in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem).\(suffix)").path)
            }
        }
    }

    static func recent(in folder: URL) -> [ScreenshotSource?: [ReceivedScreenshot]] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? []
        let screenshots = files.compactMap { url -> ReceivedScreenshot? in
            guard url.lastPathComponent.hasPrefix(filePrefix),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  let date = info.contentModificationDate, let bytes = info.fileSize else { return nil }
            return ReceivedScreenshot(url: url, date: date, bytes: Int64(bytes))
        }
        return Dictionary(grouping: screenshots) { source(of: $0.url) }.mapValues { files in
            Array(files.sorted { $0.date > $1.date }.prefix(30))
        }
    }

    private static func source(of url: URL) -> ScreenshotSource? {
        let stem = url.deletingPathExtension().lastPathComponent.dropFirst(filePrefix.count)
        let parts = stem.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].utf8.count == 32,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return ScreenshotSource(rawValue: String(parts[0]))
    }

    static func save(staged: URL, name: FileName, in folder: URL) throws -> Bool {
        if contains(name, in: folder) { return false }
        guard let image = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let type = CGImageSourceGetType(image) as String?,
              let suffix = supportedTypes[type],
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete else {
            throw SaveError.invalidImage
        }
        try FileManager.default.moveItem(at: staged, to: folder.appendingPathComponent("\(name.stem).\(suffix)"))
        return true
    }

    enum SaveError: Error {
        case invalidImage
    }
}
