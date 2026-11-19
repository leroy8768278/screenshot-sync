import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum GalleryImage {
    struct Pixels: Sendable {
        let width: Int
        let height: Int
    }

    struct Decoded: Sendable {
        let image: CGImage
        let pixels: Pixels?
    }

    struct Representation: Sendable {
        let type: String
        let data: Data
    }

    private static var readOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    static func decode(_ url: URL, maximumDimension: Int) async -> Decoded? {
        let task = Task.detached(priority: .utility) { () -> Decoded? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, readOptions),
                  let image = thumbnail(source, maximumDimension: maximumDimension) else { return nil }
            return Decoded(image: image, pixels: dimensions(of: source))
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor
    static func copy(_ url: URL, to pasteboard: NSPasteboard = .general) async throws {
        let representations = try await Task.detached(priority: .userInitiated) {
            try copyRepresentations(for: url)
        }.value
        try Task.checkCancellation()

        let item = NSPasteboardItem()
        for representation in representations {
            guard item.setData(representation.data, forType: .init(representation.type)) else {
                throw ImageError.copyFailed
            }
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ImageError.copyFailed }
    }

    private static func copyRepresentations(for url: URL) throws -> [Representation] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, readOptions),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image),
              CGImageSourceGetStatusAtIndex(source, index(of: source)) == .statusComplete else {
            throw ImageError.unreadable
        }
        let original = Representation(type: identifier, data: try Data(contentsOf: url, options: .mappedIfSafe))
        if type == .png { return [original] }

        // Keep the original representation and offer PNG to apps that only read common image types.
        guard let size = dimensions(of: source),
              size.width <= 64_000_000 / max(1, size.height),
              let image = thumbnail(source, maximumDimension: max(size.width, size.height)),
              let mutable = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutable, UTType.png.identifier as CFString, 1, nil) else {
            return [original]
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return [original] }
        return [Representation(type: UTType.png.identifier, data: mutable as Data), original]
    }

    private static func thumbnail(_ source: CGImageSource, maximumDimension: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index(of: source), [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func index(of source: CGImageSource) -> Int {
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        return (0..<CGImageSourceGetCount(source)).contains(primary) ? primary : 0
    }

    private static func dimensions(of source: CGImageSource) -> Pixels? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index(of: source), nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? Pixels(width: height, height: width) : Pixels(width: width, height: height)
    }

    enum ImageError: LocalizedError {
        case unreadable
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取这张截图。"
            case .copyFailed: "无法将图片写入剪贴板。"
            }
        }
    }
}

struct GalleryImageView: View {
    let url: URL
    let date: Date
    let maximumDimension: Int
    var onDecoded: ((GalleryImage.Pixels?) -> Void)?

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading, image(GalleryImage.Decoded), failed
    }

    private var imageKey: String { "\(url.absoluteString)|\(date.timeIntervalSinceReferenceDate)|\(maximumDimension)" }

    var body: some View {
        Group {
            switch state {
            case .loading:
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            case .image(let decoded):
                Image(decorative: decoded.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: imageKey) {
            state = .loading
            let decoded = await GalleryThumbnails.image(for: url, key: imageKey, maximumDimension: maximumDimension)
            guard !Task.isCancelled else { return }
            state = decoded.map(LoadState.image) ?? .failed
            onDecoded?(decoded?.pixels)
        }
    }
}

@MainActor
private enum GalleryThumbnails {
    private final class CacheEntry {
        let decoded: GalleryImage.Decoded

        init(_ decoded: GalleryImage.Decoded) { self.decoded = decoded }
    }

    private static let cache: NSCache<NSString, CacheEntry> = {
        let storage = NSCache<NSString, CacheEntry>()
        storage.totalCostLimit = 48 * 1024 * 1024
        return storage
    }()

    static func image(for url: URL, key: String, maximumDimension: Int) async -> GalleryImage.Decoded? {
        let cacheKey = key as NSString
        if let existing = cache.object(forKey: cacheKey) { return existing.decoded }
        guard let decoded = await GalleryImage.decode(url, maximumDimension: maximumDimension),
              !Task.isCancelled else { return nil }
        cache.setObject(CacheEntry(decoded), forKey: cacheKey, cost: decoded.image.bytesPerRow * decoded.image.height)
        return decoded
    }
}
