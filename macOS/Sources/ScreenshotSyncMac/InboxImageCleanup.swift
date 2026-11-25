import Darwin
import Foundation
import UniformTypeIdentifiers

extension Inbox {
    struct ImageCleanupPlan: Sendable {
        let folder: URL
        fileprivate let directory: stat?
        fileprivate let images: [(url: URL, info: stat)]

        var count: Int { images.count }
    }

    struct ImageCleanupResult: Sendable {
        var moved = 0
        var skipped = 0
        var failures = 0
        var firstError: String?
    }

    static func prepareImageCleanup(in folder: URL) throws -> ImageCleanupPlan {
        guard let directory = try fileInfo(at: folder) else {
            return ImageCleanupPlan(folder: folder, directory: nil, images: [])
        }
        guard directory.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        let keys: Set<URLResourceKey> = [.contentTypeKey, .isAliasFileKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )
        var images: [(url: URL, info: stat)] = []
        for url in entries {
            guard let info = try fileInfo(at: url), info.st_mode & S_IFMT == S_IFREG else { continue }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isAliasFile != true,
                      (values.contentType ?? UTType(filenameExtension: url.pathExtension))?.conforms(to: .image) == true
                else { continue }
                images.append((url, info))
            } catch where isMissingFile(error) {
                continue
            }
        }
        guard let current = try fileInfo(at: folder), sameFile(directory, current) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return ImageCleanupPlan(folder: folder, directory: directory, images: images)
    }

    static func trashImages(in plan: ImageCleanupPlan, moveToTrash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) -> ImageCleanupResult {
        var result = ImageCleanupResult()
        guard let directory = plan.directory else { return result }
        for image in plan.images {
            do {
                // A volume can be remounted, or Finder can replace an item while the alert is open.
                guard let parent = try fileInfo(at: plan.folder), sameFile(directory, parent) else {
                    result.skipped = plan.count - result.moved - result.failures
                    break
                }
                guard let current = try fileInfo(at: image.url), sameFile(image.info, current),
                      current.st_size == image.info.st_size,
                      sameTime(current.st_mtimespec, image.info.st_mtimespec),
                      current.st_flags & UInt32(UF_HIDDEN) == 0 else {
                    result.skipped += 1
                    continue
                }
                try moveToTrash(image.url)
                result.moved += 1
            } catch where isMissingFile(error) {
                result.skipped += 1
            } catch {
                result.failures += 1
                if result.firstError == nil {
                    result.firstError = "「\(image.url.lastPathComponent)」\(error.localizedDescription)"
                }
            }
        }
        return result
    }

    // lstat reads fresh identity and timestamps without following links or using URL's resource cache.
    private static func fileInfo(at url: URL) throws -> stat? {
        var info = stat()
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileReadInvalidFileName) }
            if lstat(path, &info) == 0 { return info }
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSURLErrorKey: url])
        }
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            first.st_mode & S_IFMT == second.st_mode & S_IFMT &&
            sameTime(first.st_birthtimespec, second.st_birthtimespec)
    }

    private static func sameTime(_ first: timespec, _ second: timespec) -> Bool {
        first.tv_sec == second.tv_sec && first.tv_nsec == second.tv_nsec
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)) ||
            (nsError.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(nsError.code))
    }
}
