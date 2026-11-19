import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

struct ScreenshotData: Sendable, Transferable {
    fileprivate static let maxBytes = 64 * 1024 * 1024

    let bytes: Data
    let mimeType: String
    let fileExtension: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let source = CGImageSourceCreateWithURL(received.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            let format = try imageFormat(source.flatMap(CGImageSourceGetType) as String?)
            let size = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size, size > 0 else { throw SyncIssue.unavailableImage }
            guard size <= maxBytes else { throw SyncIssue.imageTooLarge }
            let data = try Data(contentsOf: received.file, options: .mappedIfSafe)
            guard data.count <= maxBytes else { throw SyncIssue.imageTooLarge }
            return Self(bytes: data, mimeType: format.mime, fileExtension: format.ext)
        }
    }

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
        let format = try imageFormat(resource.uniformTypeIdentifier)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let request = PhotoReadRequest()
        return try await request.read {
            let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                request.append(data)
            } completionHandler: { error in
                request.finishResource(mimeType: format.mime, fileExtension: format.ext, failed: error != nil)
            }
            return { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }

    private static func loadCurrentImage(_ asset: PHAsset) async throws -> Self {
        let options = PHImageRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = false

        let request = PhotoReadRequest()
        return try await request.read {
            let id = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data, !data.isEmpty else {
                    request.finish(.failure(SyncIssue.unavailableImage))
                    return
                }
                guard data.count <= maxBytes else {
                    request.finish(.failure(SyncIssue.imageTooLarge))
                    return
                }
                request.finish(Result {
                    let format = try imageFormat(uti)
                    return Self(bytes: data, mimeType: format.mime, fileExtension: format.ext)
                })
            }
            return { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    private static func imageFormat(_ identifier: String?) throws -> (mime: String, ext: String) {
        guard let identifier, let type = UTType(identifier), type.conforms(to: .image),
              let mime = type.preferredMIMEType, mime.hasPrefix("image/"),
              let ext = type.preferredFilenameExtension else {
            throw SyncIssue.unsupportedImage
        }
        return (mime, ext)
    }
}

struct PickerThumbnail: Transferable, Sendable {
    let image: CGImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let options: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(received.file as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw SyncIssue.unavailableImage
            }
            return Self(image: image)
        }
    }
}

// PhotoKit can complete a read on its own queue while the sync task is being cancelled.
private final class PhotoReadRequest: Sendable {
    typealias Cancel = @Sendable () -> Void
    private struct State: Sendable {
        var continuation: CheckedContinuation<ScreenshotData, Error>?
        var cancelRead: Cancel?
        var finished = false
        var needsCancellation = false
        var bytes = Data()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func read(_ start: () -> Cancel) async throws -> ScreenshotData {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = state.withLock { state in
                    guard !state.finished else { return false }
                    state.continuation = continuation
                    return true
                }
                guard shouldStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let cancel = start()
                let needsCancellation = state.withLock { state in
                    if !state.finished { state.cancelRead = cancel }
                    return state.needsCancellation
                }
                if needsCancellation { cancel() }
            }
        } onCancel: {
            self.resolve(cancelRead: true) { _ in .failure(CancellationError()) }
        }
    }

    func append(_ data: Data) {
        resolve(cancelRead: true) { state in
            guard data.count <= ScreenshotData.maxBytes - state.bytes.count else {
                return .failure(SyncIssue.imageTooLarge)
            }
            state.bytes.append(data)
            return nil
        }
    }

    func finishResource(mimeType: String, fileExtension: String, failed: Bool) {
        resolve { state in
            guard !failed, !state.bytes.isEmpty else { return .failure(SyncIssue.unavailableImage) }
            return .success(ScreenshotData(bytes: state.bytes, mimeType: mimeType, fileExtension: fileExtension))
        }
    }

    func finish(_ result: Result<ScreenshotData, Error>) {
        resolve { _ in result }
    }

    private func resolve(
        cancelRead: Bool = false,
        _ result: @Sendable (inout State) -> Result<ScreenshotData, Error>?
    ) {
        let completion = state.withLock { state -> (CheckedContinuation<ScreenshotData, Error>?, Result<ScreenshotData, Error>, Cancel?)? in
            guard !state.finished, let result = result(&state) else { return nil }
            let completion = (state.continuation, result, cancelRead ? state.cancelRead : nil)
            state = State(finished: true, needsCancellation: cancelRead)
            return completion
        }
        if let (continuation, result, cancel) = completion {
            continuation?.resume(with: result)
            // A size limit can be reached from inside a PhotoKit callback.
            if let cancel { DispatchQueue.global().async(execute: cancel) }
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

    struct ManualResult {
        var remaining: [PhotosPickerItem]
        var sent = 0
        var alreadySent = 0
        var message: String?
    }

    @Published private(set) var receiver: Receiver?
    @Published private(set) var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var working = false
    @Published private(set) var sendingManually = false
    @Published private(set) var sentCount = 0
    @Published private(set) var lastSent: Date?
    @Published private(set) var errorMessage: String?

    private let observer = LibraryObserver()
    private var observingLibrary = false
    private var history: SyncHistory?
    private var changingReceiver = false
    private var active = false
    private var scanAgain = false
    private var runningScan: Task<Bool, Never>?
    private var pendingScan: Task<Void, Never>?
    private var retryEvent: Task<Void, Never>?
    private var retryDelay = 15

    var canReadPhotos: Bool { permission == .authorized || permission == .limited }
    var acceptsBackgroundRefresh: Bool { receiver?.automatic == true && canReadPhotos && receiver?.pairedAt != nil }

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
        guard !changingReceiver, !sendingManually else { throw SyncIssue.syncBusy }
        changingReceiver = true
        defer {
            changingReceiver = false
            libraryChanged()
        }

        try await ReceiverClient.check(candidate)
        try Task.checkCancellation()
        let connectedAt = Date.now
        await haltAutomaticWork()
        try Task.checkCancellation()

        var verified = candidate
        if let receiver, receiver.code == candidate.code {
            verified.pairedAt = receiver.pairedAt ?? connectedAt
            verified.automatic = receiver.automatic
        } else {
            verified.pairedAt = connectedAt
        }
        let history = try SyncHistory(key: verified.historyKey)
        try ReceiverStore.save(verified)
        receiver = verified
        self.history = history
        errorMessage = nil
        updateStats()
    }

    func disconnect() async throws {
        guard !changingReceiver, !sendingManually else { throw SyncIssue.syncBusy }
        changingReceiver = true
        defer {
            changingReceiver = false
            libraryChanged()
        }
        await haltAutomaticWork()
        try ReceiverStore.clear()
        BGRefresh.cancel()
        receiver = nil
        history = nil
        errorMessage = nil
        updateStats()
    }

    func setAutomatic(_ enabled: Bool) {
        guard !changingReceiver, var receiver else { return }
        receiver.automatic = enabled
        if !enabled {
            self.receiver = receiver
            BGRefresh.cancel()
            cancelAutomaticWork()
        }
        do {
            try ReceiverStore.save(receiver)
            errorMessage = nil
            if enabled {
                self.receiver = receiver
                libraryChanged()
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
        guard active, !changingReceiver, !sendingManually, let receiver,
              receiver.pairedAt == nil || (receiver.automatic && canReadPhotos) else { return }
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
    func scan(background: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard !changingReceiver, !sendingManually, let receiver, history != nil,
              receiver.pairedAt == nil || (receiver.automatic && canReadPhotos) else { return true }
        guard runningScan == nil else {
            if !background { scanAgain = true }
            return true
        }
        working = true
        errorMessage = nil
        defer {
            runningScan = nil
            working = false
            if scanAgain {
                scanAgain = false
                libraryChanged()
            }
        }

        let operation = Task {
            await runAutomatic(receiver, background: background)
        }
        runningScan = operation
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func sendSelection(
        _ items: [PhotosPickerItem], to destination: Receiver, onProgress: (Int) -> Void
    ) async -> ManualResult {
        guard let receiver, receiver.code == destination.code, receiver.displayAddress == destination.displayAddress,
              destination.pairedAt == nil || destination.pairedAt == receiver.pairedAt else {
            return ManualResult(remaining: items, message: SyncIssue.receiverChanged.localizedDescription)
        }
        guard !changingReceiver, !sendingManually else {
            return ManualResult(remaining: items, message: SyncIssue.syncBusy.localizedDescription)
        }
        guard history != nil else {
            return ManualResult(remaining: items, message: SyncIssue.storage.localizedDescription)
        }
        sendingManually = true
        defer {
            sendingManually = false
            libraryChanged()
        }
        await haltAutomaticWork()

        var result = ManualResult(remaining: [])
        let verified: Receiver
        do {
            try Task.checkCancellation()
            // A migrated pairing must be verified before any transfer can establish its cutoff.
            verified = try await verifyLegacyPairing(self.receiver ?? receiver)
        } catch {
            return ManualResult(remaining: items, message: Self.manualErrorMessage(error))
        }

        for (index, item) in items.enumerated() {
            do {
                try Task.checkCancellation()
                let assetID = item.itemIdentifier.map(Self.uploadID)
                if let assetID, history?.sent.contains(assetID) == true {
                    result.alreadySent += 1
                } else {
                    guard let image = try await item.loadTransferable(type: ScreenshotData.self) else {
                        throw SyncIssue.unavailableImage
                    }
                    let id = assetID ?? "ios-\(digest(image.bytes))"
                    if history?.sent.contains(id) == true {
                        result.alreadySent += 1
                    } else {
                        try await upload(image, id: id, timestamp: .now, to: verified)
                        result.sent += 1
                    }
                }
            } catch {
                if Task.isCancelled || error is URLError || Self.isServerFailure(error) || Self.isPairingFailure(error) {
                    result.remaining.append(contentsOf: items[index...])
                    result.message = Self.manualErrorMessage(error)
                    break
                }
                result.remaining.append(item)
                if result.message == nil { result.message = error.localizedDescription }
            }
            onProgress(index + 1)
        }
        return result
    }

    private func verifyLegacyPairing(_ current: Receiver) async throws -> Receiver {
        if current.pairedAt != nil { return current }
        try await ReceiverClient.check(current)
        try Task.checkCancellation()
        guard receiver == current else { throw SyncIssue.receiverChanged }
        var verified = current
        verified.pairedAt = .now
        try ReceiverStore.save(verified)
        receiver = verified
        return verified
    }

    private func cancelAutomaticWork() {
        scanAgain = false
        pendingScan?.cancel()
        pendingScan = nil
        resetRetry()
        runningScan?.cancel()
    }

    private func haltAutomaticWork() async {
        let operation = runningScan
        cancelAutomaticWork()
        _ = await operation?.value
    }

    private func upload(_ image: ScreenshotData, id: String, timestamp: Date, to receiver: Receiver) async throws {
        try Task.checkCancellation()
        let timestamp = Self.filenameFormatter.string(from: timestamp)
        let filename = "iOS-\(timestamp)-\(id.suffix(8)).\(image.fileExtension)"
        try await ReceiverClient.send(image, named: filename, id: id, to: receiver)
        guard self.receiver?.code == receiver.code, var history else { throw SyncIssue.receiverChanged }
        try history.markSent(id)
        self.history = history
        updateStats()
    }

    private static func uploadID(_ identifier: String) -> String { "ios-\(digest(identifier))" }

    private static func isServerFailure(_ error: Error) -> Bool {
        if case .httpStatus(let status) = error as? SyncIssue { return status >= 500 }
        return false
    }

    private static func isPairingFailure(_ error: Error) -> Bool {
        switch error as? SyncIssue {
        case .accessDenied, .receiverChanged, .storage: true
        default: false
        }
    }

    private static func manualErrorMessage(_ error: Error) -> String {
        if Task.isCancelled { return "已停止发送。" }
        return error is URLError ? connectionError : error.localizedDescription
    }

    private func runAutomatic(_ receiver: Receiver, background: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let verified: Receiver
        do {
            verified = try await verifyLegacyPairing(receiver)
        } catch {
            guard !Task.isCancelled else { return false }
            errorMessage = error is URLError ? Self.connectionError : error.localizedDescription
            if error is URLError || Self.isServerFailure(error) { scheduleRetry() }
            return false
        }
        guard verified.automatic, canReadPhotos, let pairedAt = verified.pairedAt else { return true }

        let screenshotPredicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0", Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            screenshotPredicate, NSPredicate(format: "creationDate > %@", pairedAt as NSDate),
        ])
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var attempts = 0
        let deadline = ContinuousClock.now + .seconds(12)
        for index in 0..<assets.count {
            if index.isMultiple(of: 64) { await Task.yield() }
            if Task.isCancelled { return false }
            if background && (attempts >= 5 || ContinuousClock.now >= deadline) { break }
            let asset = assets.object(at: index)
            guard let capturedAt = asset.creationDate, capturedAt > pairedAt else { continue }
            let id = Self.uploadID(asset.localIdentifier)
            guard history?.sent.contains(id) == false else { continue }
            attempts += 1

            do {
                let image = try await ScreenshotData.load(asset)
                try await upload(image, id: id, timestamp: capturedAt, to: verified)
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
        guard retryEvent == nil, active, !changingReceiver, !sendingManually, let receiver,
              receiver.pairedAt == nil || receiver.automatic else { return }
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
