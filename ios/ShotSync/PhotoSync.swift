import CoreTransferable
import CryptoKit
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
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

extension PhotosPickerItem {
    var isVideoSelection: Bool {
        let primary = supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        return primary?.conforms(to: .movie) == true
    }
}

final class SelectedVideo: Transferable, Sendable {
    static let maxBytes = 512 * 1024 * 1024

    let file: URL
    let byteCount: Int
    let mimeType: String
    let fileExtension: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try Self(staging: received.file)
        }
    }

    init(staging source: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw SyncIssue.unavailableVideo
        }
        guard size <= Self.maxBytes else { throw SyncIssue.videoTooLarge }
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "mp4": mimeType = "video/mp4"
        case "mov": mimeType = "video/quicktime"
        case "m4v": mimeType = "video/x-m4v"
        default: throw SyncIssue.unsupportedVideo
        }

        byteCount = size
        fileExtension = ext
        let temporaryFile = FileManager.default.temporaryDirectory
            .appending(path: "SelectedVideo-\(UUID()).\(ext)", directoryHint: .notDirectory)
        try Task.checkCancellation()
        do {
            try FileManager.default.copyItem(at: source, to: temporaryFile)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: temporaryFile)
            throw error
        }
        file = temporaryFile
    }

    deinit { try? FileManager.default.removeItem(at: file) }

    func uploadID() async throws -> String {
        let fingerprint = Task.detached(priority: .userInitiated) { [self] in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            return "ios-\(hash.finalize().map { String(format: "%02x", $0) }.joined())"
        }
        return try await withTaskCancellationHandler {
            try await fingerprint.value
        } onCancel: {
            fingerprint.cancel()
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
        Task { @MainActor [weak self] in self?.sync?.scanWhileActive() }
    }
}

@MainActor
private final class ScreenshotTransferTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(operation: Task<Bool, Never>) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Send screenshot") { [weak self] in
            operation.cancel()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

@MainActor
final class PhotoSync: ObservableObject {
    static let shared = PhotoSync()

    struct ManualUploadProgress: Sendable {
        let item: Int
        var sent: Int64 = 0
        var total: Int64? = nil
    }

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
    @Published private(set) var recent: [TransferReceipt] = []
    @Published private(set) var lastSent: Date?
    @Published private(set) var errorMessage: String?

    private let observer = LibraryObserver()
    private var observingLibrary = false
    private var history: SyncHistory?
    private var registration: Task<Void, Never>?
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
        try await connect { try await ReceiverClient.check(candidate) }
    }

    func connect(scannedCode: String) async throws {
        try await connect { try await ReceiverClient.verifiedReceiver(in: scannedCode) }
    }

    private func connect(verify: () async throws -> Receiver) async throws {
        guard !changingReceiver, !sendingManually else { throw SyncIssue.syncBusy }
        changingReceiver = true
        defer {
            changingReceiver = false
            scanWhileActive()
        }

        let candidate = try await verify()
        try Task.checkCancellation()
        let connectedAt = Date.now
        await haltAutomaticWork()
        try Task.checkCancellation()

        var verified = candidate
        verified.pairedAt = connectedAt
        if let receiver {
            verified.automatic = receiver.automatic
            if receiver.code == candidate.code {
                verified.pairedAt = receiver.pairedAt ?? connectedAt
                verified.macProfile = candidate.macProfile ?? receiver.macProfile
            }
        }
        let history = try SyncHistory(key: verified.historyKey)
        try ReceiverStore.save(verified)
        receiver = verified
        self.history = history
        registerDevice(with: verified)
        errorMessage = nil
        updateStats()
    }

    func disconnect() async throws {
        guard !changingReceiver, !sendingManually else { throw SyncIssue.syncBusy }
        changingReceiver = true
        defer {
            changingReceiver = false
            scanWhileActive()
        }
        await haltAutomaticWork()
        try ReceiverStore.clear()
        registration?.cancel()
        registration = nil
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
                scanWhileActive()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPhotoAccess() async {
        updatePhotoAccess(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        if canReadPhotos { scanWhileActive() }
    }

    func phaseChanged(_ phase: ScenePhase) {
        active = phase == .active
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        if active {
            resetRetry()
            if history == nil { reloadReceiver() }
            if registration == nil, let receiver, receiver.pairedAt != nil {
                registerDevice(with: receiver, verifyAddress: true)
            }
            scanWhileActive()
        } else {
            pendingScan?.cancel()
            pendingScan = nil
            resetRetry()
            if phase == .background && acceptsBackgroundRefresh { BGRefresh.schedule() }
        }
    }

    func scanWhileActive() {
        guard active, !changingReceiver, !sendingManually, let receiver,
              receiver.pairedAt == nil || (receiver.automatic && canReadPhotos) else { return }
        if runningScan != nil {
            scanAgain = true
            return
        }
        guard pendingScan == nil else { return }
        pendingScan = Task {
            guard !Task.isCancelled else { return }
            pendingScan = nil
            _ = await scan()
        }
    }

    // Shortcuts invokes this in the app process when iOS saves a screenshot, including while the UI is inactive.
    func syncScreenshotsFromAutomation() async throws {
        if receiver == nil || history == nil { reloadReceiver() }
        guard let destination = receiver, let cutoff = destination.pairedAt else {
            throw AutomationIssue("请先在即图中完成 Mac 配对。")
        }
        guard destination.automatic else { return }
        let started = ContinuousClock.now
        var checkedID: String?
        // Deliver what is already visible immediately. A save trigger can arrive while Photos still shows
        // the prior screenshot; briefly re-fetch its newest asset, even if another scan just uploaded one.
        let visibilityChecks: [Duration] = [.zero, .milliseconds(250), .milliseconds(750), .seconds(2)]
        for offset in visibilityChecks {
            if offset != .zero { try await Task.sleep(until: started + offset, clock: .continuous) }
            try checkAutomationDestination(destination)
            // An existing scan may have fetched its snapshot before this screenshot was saved.
            while let earlier = runningScan {
                _ = await earlier.value
                try checkAutomationDestination(destination)
            }
            guard let latest = Self.screenshots(after: cutoff, limit: 1).firstObject else { continue }
            let id = Self.uploadID(latest.localIdentifier)
            guard id != checkedID else { continue }
            let success = await scan(background: true)
            try checkAutomationDestination(destination)
            guard success, history?.sent.contains(id) == true else {
                throw AutomationIssue(errorMessage ?? "截图尚未发送到 Mac，请重试。")
            }
            checkedID = id
        }
        if checkedID == nil {
            throw AutomationIssue("相册中尚未发现配对后的新截图，请确认截图已存储到「照片」。")
        }
    }

    private struct AutomationIssue: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func checkAutomationDestination(_ destination: Receiver) throws {
        try Task.checkCancellation()
        guard !changingReceiver, !sendingManually else { throw SyncIssue.syncBusy }
        guard let receiver, receiver.isSamePairing(as: destination), receiver.automatic else {
            throw SyncIssue.receiverChanged
        }
        guard history != nil else { throw SyncIssue.storage }
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard permission == .authorized else {
            throw AutomationIssue("请在系统设置中允许即图完全访问照片，以读取刚保存的截图。")
        }
    }

    @discardableResult
    func scan(background: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard background || active else { return true }
        updatePhotoAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard !changingReceiver, !sendingManually, let receiver, history != nil,
              receiver.pairedAt == nil || (receiver.automatic && canReadPhotos) else { return true }
        guard runningScan == nil else {
            if !background { scanAgain = true }
            return true
        }
        working = true
        errorMessage = nil
        let operation = Task {
            defer {
                runningScan = nil
                working = false
                if scanAgain {
                    scanAgain = false
                    scanWhileActive()
                }
            }
            return await runAutomatic(receiver, background: background)
        }
        runningScan = operation
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func sendSelection(
        _ items: [PhotosPickerItem], to destination: Receiver,
        onProgress: @escaping @MainActor @Sendable (ManualUploadProgress) -> Void
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
            scanWhileActive()
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
            let ordinal = index + 1
            let report: ReceiverClient.UploadProgress = { sent, total in
                onProgress(ManualUploadProgress(item: ordinal, sent: sent, total: total))
            }
            onProgress(ManualUploadProgress(item: ordinal))
            do {
                try Task.checkCancellation()
                let assetID = item.itemIdentifier.map(Self.uploadID)
                if let assetID, history?.sent.contains(assetID) == true {
                    result.alreadySent += 1
                } else if item.isVideoSelection {
                    guard let video = try await item.loadTransferable(type: SelectedVideo.self) else {
                        throw SyncIssue.unavailableVideo
                    }
                    let id: String
                    if let assetID { id = assetID }
                    else { id = try await video.uploadID() }
                    if history?.sent.contains(id) == true {
                        result.alreadySent += 1
                    } else {
                        let name = Self.uploadFilename(id: id, timestamp: .now, extension: video.fileExtension)
                        try Task.checkCancellation()
                        try await ReceiverClient.send(video, named: name, id: id, to: verified, onProgress: report)
                        try recordDelivery(.init(id: id, kind: .video, delivered: .now, bytes: video.byteCount, thumbnail: nil), to: verified)
                        result.sent += 1
                    }
                } else {
                    guard let image = try await item.loadTransferable(type: ScreenshotData.self) else {
                        throw SyncIssue.unavailableImage
                    }
                    let id = assetID ?? "ios-\(digest(image.bytes))"
                    if history?.sent.contains(id) == true {
                        result.alreadySent += 1
                    } else {
                        try await upload(image, id: id, timestamp: .now, kind: .photo, to: verified, onProgress: report)
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
        }
        return result
    }

    private func verifyLegacyPairing(_ current: Receiver) async throws -> Receiver {
        if current.pairedAt != nil { return current }
        var verified = try await ReceiverClient.check(current)
        try Task.checkCancellation()
        guard receiver == current else { throw SyncIssue.receiverChanged }
        verified.pairedAt = .now
        try ReceiverStore.save(verified)
        receiver = verified
        registerDevice(with: verified)
        return verified
    }

    private func registerDevice(with receiver: Receiver, verifyAddress: Bool = false) {
        registration?.cancel()
        registration = Task {
            do {
                if verifyAddress {
                    let checked = try await ReceiverClient.check(receiver)
                    try Task.checkCancellation()
                    guard var active = self.receiver, active.isSamePairing(as: receiver) else { return }
                    if active.macProfile != checked.macProfile {
                        active.macProfile = checked.macProfile
                        try ReceiverStore.save(active)
                        self.receiver = active
                    }
                }
                try await ReceiverClient.registerDevice(with: receiver)
                if !Task.isCancelled, self.receiver?.macProfile == nil { registration = nil }
            } catch {
                // A replaced pairing owns a new task. Only this pairing may schedule a retry.
                if !Task.isCancelled { registration = nil }
            }
        }
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

    private func upload(_ image: ScreenshotData, id: String, timestamp: Date, kind: TransferReceipt.Kind,
                        to receiver: Receiver, onProgress: ReceiverClient.UploadProgress? = nil) async throws {
        try Task.checkCancellation()
        let filename = Self.uploadFilename(id: id, timestamp: timestamp, extension: image.fileExtension)
        try await ReceiverClient.send(image, named: filename, id: id, to: receiver, onProgress: onProgress)
        let thumbnail = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil),
                  let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 112
                  ] as CFDictionary) else { return nil as Data? }
            return UIImage(cgImage: small).jpegData(compressionQuality: 0.72)
        }.value
        try recordDelivery(.init(id: id, kind: kind, delivered: .now, captured: kind == .screenshot ? timestamp : nil, bytes: image.bytes.count, thumbnail: thumbnail), to: receiver)
    }

    private static func uploadFilename(id: String, timestamp: Date, extension suffix: String) -> String {
        let timestamp = Self.filenameFormatter.string(from: timestamp)
        return "iOS-\(timestamp)-\(id.suffix(8)).\(suffix)"
    }

    private func recordDelivery(_ receipt: TransferReceipt, to receiver: Receiver) throws {
        guard self.receiver?.code == receiver.code, var history else { throw SyncIssue.receiverChanged }
        try history.markSent(receipt)
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

        let assets = Self.screenshots(after: pairedAt)

        var transferTime: ScreenshotTransferTime?
        defer { transferTime?.end() }
        var attempts = 0
        let deadline = ContinuousClock.now + .seconds(12)
        for index in 0..<assets.count {
            if index.isMultiple(of: 64) { await Task.yield() }
            if Task.isCancelled { return false }
            if !background && !active { break }
            if background && (attempts >= 5 || ContinuousClock.now >= deadline) { break }
            let asset = assets.object(at: index)
            guard let capturedAt = asset.creationDate, capturedAt > pairedAt else { continue }
            let id = Self.uploadID(asset.localIdentifier)
            guard history?.sent.contains(id) == false else { continue }
            attempts += 1
            if !background, transferTime == nil, let runningScan {
                transferTime = ScreenshotTransferTime(operation: runningScan)
            }

            do {
                let image = try await ScreenshotData.load(asset)
                try await upload(image, id: id, timestamp: capturedAt, kind: .screenshot, to: verified)
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

    private static func screenshots(after cutoff: Date, limit: Int = 0) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0 AND creationDate > %@",
            Int(PHAssetMediaSubtype.photoScreenshot.rawValue), cutoff as NSDate
        )
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    func clearRecent(ids: Set<String>, for destination: Receiver) {
        guard receiver?.historyKey == destination.historyKey, !changingReceiver, var history else { return }
        do {
            try history.clearRecent(ids: ids)
            self.history = history
            updateStats()
        } catch {
            errorMessage = "清除最近传输记录失败，请重试。"
        }
    }

    private func updateStats() {
        sentCount = history?.sent.count ?? 0
        recent = history?.recent ?? []
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
