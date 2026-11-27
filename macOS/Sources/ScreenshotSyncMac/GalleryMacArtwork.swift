import AppKit

@MainActor
enum GalleryMacArtwork {
    static let current: NSImage? = {
        let family = MacFamily.current.rawValue.replacingOccurrences(of: "-", with: "_")
        return Bundle.main.url(forResource: "receiver_\(family)", withExtension: "png", subdirectory: "ReceiverModels")
            .flatMap(NSImage.init(contentsOf:))
    }()
}
