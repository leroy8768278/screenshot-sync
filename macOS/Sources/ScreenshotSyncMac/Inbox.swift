import CryptoKit
import Foundation
import ImageIO

enum ScreenshotSource: String, CaseIterable, Sendable {
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

struct ScreenshotDevice: Hashable, Identifiable, Sendable {
    let source: ScreenshotSource
    let installationID: String

    var id: String { "\(source.rawValue):\(installationID)" }

    init?(source: ScreenshotSource, installationID: String) {
        guard Self.isDeviceID(installationID) else { return nil }
        self.source = source
        self.installationID = installationID
    }

    init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let source = ScreenshotSource(rawValue: String(parts[0])) else { return nil }
        self.init(source: source, installationID: String(parts[1]))
    }

    fileprivate static func isDeviceID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ReceivedScreenshot: Identifiable, Sendable {
    let url: URL
    let date: Date
    let bytes: Int64
    let device: ScreenshotDevice?

    var id: URL { url }
}

enum Inbox {
    private static let filePrefix = "Screenshot-"
    private static let originsDirectoryName = ".screenshotsync-origins"

    struct FileName {
        let stem: String
        let legacyStem: String
        let source: ScreenshotSource?

        init(uploadID: String) {
            let digest = SHA256.hash(data: Data(uploadID.utf8))
            let suffix = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
            legacyStem = "\(Inbox.filePrefix)\(suffix)"
            source = ScreenshotSource(uploadID: uploadID)
            if let source {
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

    private static let imageExtensions = Set(supportedTypes.values).union(["jpeg", "tif"])

    static func contains(_ name: FileName, in folder: URL) -> Bool {
        let stems = name.stem == name.legacyStem ? [name.stem] : [name.stem, name.legacyStem]
        return stems.contains { stem in
            supportedTypes.values.contains { suffix in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem).\(suffix)").path)
            }
        }
    }

    static func recent(in folder: URL) throws -> [ScreenshotSource?: [ReceivedScreenshot]] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        }

        let origins = originDirectory(in: folder)
        let originStems = isOriginDirectory(origins)
            ? Set((try? FileManager.default.contentsOfDirectory(atPath: origins.path)) ?? [])
            : []
        var screenshots: [ScreenshotSource?: [ReceivedScreenshot]] = [:]
        for url in files {
            guard url.lastPathComponent.hasPrefix(filePrefix),
                  imageExtensions.contains(url.pathExtension.lowercased()),
                  let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  let date = info.contentModificationDate, let bytes = info.fileSize else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let source = source(ofStem: stem)
            let device = source.flatMap { source in
                originStems.contains(stem) ? readOrigin(at: origins.appendingPathComponent(stem), source: source) : nil
            }
            screenshots[source, default: []].append(
                ReceivedScreenshot(url: url, date: date, bytes: Int64(bytes), device: device)
            )
        }
        return screenshots.mapValues { files in
            files.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
        }
    }

    private static func source(ofStem stem: String) -> ScreenshotSource? {
        let suffix = stem.dropFirst(filePrefix.count)
        let parts = suffix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, ScreenshotDevice.isDeviceID(String(parts[1])) else { return nil }
        return ScreenshotSource(rawValue: String(parts[0]))
    }

    private static func originDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent(originsDirectoryName, isDirectory: true)
    }

    private static func isOriginDirectory(_ url: URL) -> Bool {
        let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return info?.isDirectory == true && info?.isSymbolicLink != true
    }

    private static func readOrigin(at url: URL, source: ScreenshotSource) -> ScreenshotDevice? {
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == 32,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 33),
              let installationID = String(data: data, encoding: .utf8) else { return nil }
        return ScreenshotDevice(source: source, installationID: installationID)
    }

    static func save(staged: URL, name: FileName, device: ScreenshotDevice?, in folder: URL) throws -> Bool {
        if contains(name, in: folder) { return false }
        guard let image = CGImageSourceCreateWithURL(staged as CFURL, nil),
              let type = CGImageSourceGetType(image) as String?,
              let suffix = supportedTypes[type],
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete else {
            throw SaveError.invalidImage
        }
        let directory = originDirectory(in: folder)
        let origin = directory.appendingPathComponent(name.stem)
        let manager = FileManager.default
        if let device {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard isOriginDirectory(directory) else { throw SaveError.invalidOriginDirectory }
            try Data(device.installationID.utf8).write(to: origin, options: .atomic)
        } else if let source = name.source, isOriginDirectory(directory), readOrigin(at: origin, source: source) != nil {
            // A cancelled save can leave an origin entry for a filename that was never published.
            try manager.removeItem(at: origin)
        }
        do {
            // Publish the image only after its origin is ready for readers.
            try manager.moveItem(at: staged, to: folder.appendingPathComponent("\(name.stem).\(suffix)"))
        } catch {
            if device != nil && !contains(name, in: folder) { try? manager.removeItem(at: origin) }
            throw error
        }
        return true
    }

    enum SaveError: Error {
        case invalidImage
        case invalidOriginDirectory
    }
}
