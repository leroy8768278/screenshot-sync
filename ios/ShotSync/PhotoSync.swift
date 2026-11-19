import Photos
import SwiftUI
import UniformTypeIdentifiers
import os

struct ScreenshotData: Sendable {
    fileprivate static let maxBytes = 64 * 1024 * 1024

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
    private static let sessionStartKey = "screenshotSyncSessionStart"

    @Published private(set) var receiver: Receiver?
    @Published private(set) var permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var working = false
    @Published private(set) var sentCount = 0
    @Published private(set) var lastSent: Date?
    @Published private(set) var errorMessage: String?

    private let observer = LibraryObserver()
    private var observingLibrary = false
    private var history: SyncHistory?
    private var sessionStart: Date?
    private var startedForegroundSession = false
    private var active = false
    private var scanAgain = false
    private var runningScan: Task<Bool, Never>?
    private var pendingScan: Task<Void, Never>?
    private var retryEvent: Task<Void, Never>?
    private var retryDelay = 15

    var canReadPhotos: Bool { permission == .authorized || permission == .limited }
    var acceptsBackgroundRefresh: Bool { receiver?.automatic == true && canReadPhotos && sessionStart != nil }

    private init() {
        sessionStart = UserDefaults.standard.object(forKey: Self.sessionStartKey) as? Date
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
        guard var receiver else { return }
        receiver.automatic = enabled
        if !enabled {
            self.receiver = receiver
            scanAgain = false
            pendingScan?.cancel()
            pendingScan = nil
            resetRetry()
            BGRefresh.cancel()
            runningScan?.cancel()
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
            if !startedForegroundSession {
                startedForegroundSession = true
                let start = Date.now
                sessionStart = start
                UserDefaults.standard.set(start, forKey: Self.sessionStartKey)
                runningScan?.cancel()
            }
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
        guard !Task.isCancelled else { return false }
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard let receiver, receiver.automatic || manual, canReadPhotos,
              let history, let sessionStart else { return true }
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
            await runScan(receiver: receiver, initialHistory: history, sessionStart: sessionStart, background: background)
        }
        runningScan = operation
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func runScan(receiver: Receiver, initialHistory: SyncHistory, sessionStart: Date, background: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        var history = initialHistory
        let screenshotPredicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0", Int(PHAssetMediaSubtype.photoScreenshot.rawValue)
        )
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            screenshotPredicate, NSPredicate(format: "creationDate >= %@", sessionStart as NSDate),
        ])
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var attempts = 0
        let deadline = ContinuousClock.now + .seconds(12)
        for index in 0..<assets.count {
            if index.isMultiple(of: 64) { await Task.yield() }
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
