import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ScreenshotData {
    let bytes: Data
    let mimeType: String
    let fileExtension: String

    static func load(_ asset: PHAsset) async throws -> Self {
        let resources = PHAssetResource.assetResources(for: asset)
        if let edited = resources.first(where: { $0.type == .fullSizePhoto }) {
            return try await loadResource(edited)
        }
        if resources.contains(where: { $0.type == .adjustmentData }) {
            return try await loadCurrentImage(asset)
        }
        guard let original = resources.first(where: { $0.type == .photo }) else {
            throw SyncIssue.unavailableImage
        }
        return try await loadResource(original)
    }

    private static func loadResource(_ resource: PHAssetResource) async throws -> Self {
        guard let type = UTType(resource.uniformTypeIdentifier), type.conforms(to: .image),
              let mime = type.preferredMIMEType, mime.hasPrefix("image/"),
              let ext = type.preferredFilenameExtension else {
            throw SyncIssue.unsupportedImage
        }
        let output = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: output, options: options)
        } catch {
            throw SyncIssue.unavailableImage
        }
        try Task.checkCancellation()
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw SyncIssue.unavailableImage }
        guard size <= 64 * 1024 * 1024 else { throw SyncIssue.imageTooLarge }
        let data = try Data(contentsOf: output, options: .mappedIfSafe)
        return Self(bytes: data, mimeType: mime, fileExtension: ext)
    }

    private static func loadCurrentImage(_ asset: PHAsset) async throws -> Self {
        let options = PHImageRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: SyncIssue.unavailableImage)
                    return
                }
                guard data.count <= 64 * 1024 * 1024 else {
                    continuation.resume(throwing: SyncIssue.imageTooLarge)
                    return
                }
                guard let uti, let type = UTType(uti), type.conforms(to: .image),
                      let mime = type.preferredMIMEType, mime.hasPrefix("image/"),
                      let ext = type.preferredFilenameExtension else {
                    continuation.resume(throwing: SyncIssue.unsupportedImage)
                    return
                }
                continuation.resume(returning: Self(bytes: data, mimeType: mime, fileExtension: ext))
            }
        }
    }
}

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    weak var sync: PhotoSync?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.sync?.libraryChanged() }
    }
}

@MainActor
final class PhotoSync: ObservableObject {
    static let shared = PhotoSync()

    @Published private(set) var receiver: Receiver?
    @Published private(set) var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var working = false
    @Published private(set) var sentCount = 0
    @Published private(set) var lastSent: Date?
    @Published private(set) var errorMessage: String?

    private let observer = LibraryObserver()
    private var observingLibrary = false
    private var history: SyncHistory?
    private var active = false
    private var scanAgain = false
    private var pendingScan: Task<Void, Never>?
    private var retryEvent: Task<Void, Never>?
    private var retryDelay = 15

    var canReadPhotos: Bool { permission == .authorized || permission == .limited }
    var acceptsBackgroundRefresh: Bool { receiver?.automatic == true && canReadPhotos }

    private init() {
        observer.sync = self
        reloadReceiver()
    }

    private func updatePhotoAccess(_ status: PHAuthorizationStatus) {
        permission = status
        if observingLibrary != canReadPhotos {
            observingLibrary = canReadPhotos
            if observingLibrary {
                PHPhotoLibrary.shared().register(observer)
            } else {
                PHPhotoLibrary.shared().unregisterChangeObserver(observer)
            }
        }
    }

    private func reloadReceiver() {
        do {
            receiver = try ReceiverStore.load()
            history = try receiver.map { try SyncHistory(key: $0.historyKey) }
            updateStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect(_ candidate: Receiver) async throws {
        guard !working else { throw SyncIssue.syncBusy }
        try await ReceiverClient.check(candidate)
        try Task.checkCancellation()
        guard !working else { throw SyncIssue.syncBusy }
        let history = try SyncHistory(key: candidate.historyKey)
        try ReceiverStore.save(candidate)
        receiver = candidate
        self.history = history
        errorMessage = nil
        updateStats()
        if candidate.automatic { libraryChanged() }
    }

    func setAutomatic(_ enabled: Bool) {
        guard var receiver, !working else { return }
        receiver.automatic = enabled
        do {
            try ReceiverStore.save(receiver)
            self.receiver = receiver
            if enabled {
                libraryChanged()
            } else {
                BGRefresh.cancel()
                resetRetry()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPhotoAccess() async {
        updatePhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        if canReadPhotos { libraryChanged() }
    }

    func phaseChanged(_ phase: ScenePhase) {
        active = phase == .active
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if active {
            resetRetry()
            if history == nil { reloadReceiver() }
            libraryChanged()
        } else {
            pendingScan?.cancel()
            pendingScan = nil
            resetRetry()
            if phase == .background && acceptsBackgroundRefresh { BGRefresh.schedule() }
        }
    }

    fileprivate func libraryChanged() {
        guard active, receiver?.automatic == true, canReadPhotos else { return }
        pendingScan?.cancel()
        pendingScan = Task {
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            pendingScan = nil
            _ = await scan()
        }
    }

    @discardableResult
    func scan(manual: Bool = false, background: Bool = false) async -> Bool {
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard let receiver, receiver.automatic || manual, canReadPhotos, var history else { return true }
        guard !working else {
            if !background { scanAgain = true }
            return true
        }
        working = true
        errorMessage = nil
        defer {
            working = false
            if scanAgain {
                scanAgain = false
                libraryChanged()
            }
        }

        let screenshotPredicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0", Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let startDate = receiver.startDate {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                screenshotPredicate, NSPredicate(format: "creationDate >= %@", startDate as NSDate),
            ])
        } else {
            options.predicate = screenshotPredicate
        }
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var attempts = 0
        let deadline = ContinuousClock.now + .seconds(12)
        for index in 0..<assets.count {
            if Task.isCancelled { return false }
            if background && (attempts >= 5 || ContinuousClock.now >= deadline) { break }
            let asset = assets.object(at: index)
            let id = "ios-\(digest(asset.localIdentifier))"
            guard !history.sent.contains(id) else { continue }
            attempts += 1

            do {
                let image = try await ScreenshotData.load(asset)
                try Task.checkCancellation()
                let timestamp = Self.filenameFormatter.string(from: asset.creationDate ?? .now)
                let filename = "iOS-\(timestamp)-\(id.suffix(8)).\(image.fileExtension)"
                try await ReceiverClient.send(image, named: filename, id: id, to: receiver)
                try history.markSent(id)
                self.history = history
                updateStats()
            } catch let issue as SyncIssue {
                if Task.isCancelled { return false }
                errorMessage = issue.localizedDescription
                switch issue {
                case .unavailableImage, .imageTooLarge, .unsupportedImage: continue
                case .httpStatus(let status) where status >= 500:
                    scheduleRetry()
                    return false
                default: return false
                }
            } catch is URLError {
                if Task.isCancelled { return false }
                errorMessage = Self.connectionError
                scheduleRetry()
                return false
            } catch {
                if Task.isCancelled { return false }
                errorMessage = error.localizedDescription
                return false
            }
        }

        resetRetry()
        return !Task.isCancelled
    }

    private func updateStats() {
        sentCount = history?.sent.count ?? 0
        lastSent = history?.lastSent
    }

    private func scheduleRetry() {
        guard retryEvent == nil, active, receiver?.automatic == true else { return }
        let seconds = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        retryEvent = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            retryEvent = nil
            _ = await scan()
        }
    }

    private func resetRetry() {
        retryEvent?.cancel()
        retryEvent = nil
        retryDelay = 15
    }

    static let connectionError = "无法连接到 Mac。请检查两台设备是否连接同一网络、Mac 接收端是否在运行，以及系统设置中的本地网络权限。"

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
