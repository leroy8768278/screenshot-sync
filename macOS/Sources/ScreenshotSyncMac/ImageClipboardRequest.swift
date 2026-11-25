import AppKit

// Publish the new item in the copy action, before a paste or another copy can arrive.
@MainActor
final class ImageClipboardRequest {
    private let board: NSPasteboard
    private let revision: Int
    private let preparation: ImagePasteboardProvider
    private let types: [NSPasteboard.PasteboardType]

    init(types: [NSPasteboard.PasteboardType], to board: NSPasteboard = .general,
         prepare: @escaping @Sendable () throws -> [GalleryImage.Representation]) throws {
        self.board = board
        self.types = types
        preparation = ImagePasteboardProvider(prepare: prepare)
        let item = NSPasteboardItem()
        guard item.setDataProvider(preparation, forTypes: types) else { throw GalleryImage.ImageError.copyFailed }
        board.clearContents()
        guard board.writeObjects([item]) else { throw GalleryImage.ImageError.copyFailed }
        revision = board.changeCount
    }

    func finish() async throws {
        let result = await preparation.result()
        guard board.changeCount == revision else { throw CancellationError() }
        let representations = try result.get()
        let available = representations.map { NSPasteboard.PasteboardType($0.type) }
        if Set(available) != Set(types) {
            // A conversion may only yield the original format.
            board.declareTypes(available, owner: nil)
        }
        // Materialize the data so that it also remains available after the app quits.
        for image in representations {
            guard board.setData(image.data, forType: .init(image.type)) else { throw GalleryImage.ImageError.copyFailed }
        }
    }
}

private final class ImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    typealias Output = Result<[GalleryImage.Representation], Error>
    private let queue = DispatchQueue(label: "local.screenshotsync.prepare-copy", qos: .userInitiated)
    private let prepare: @Sendable () throws -> [GalleryImage.Representation]
    // Accessed exclusively on queue, including when AppKit requests a paste during encoding.
    private lazy var output: Output = Result(catching: prepare)

    init(prepare: @escaping @Sendable () throws -> [GalleryImage.Representation]) {
        self.prepare = prepare
        super.init()
        queue.async { _ = self.output }
    }

    func result() async -> Output {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.output) }
        }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if let images = try? queue.sync(execute: { try output.get() }),
           let requested = images.first(where: { $0.type == type.rawValue }) {
            item.setData(requested.data, forType: type)
        }
    }
}
