import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class RegionCapture {
    private var activeProcess: Process?

    func select() async throws -> CGImage? {
        guard activeProcess == nil, !Task.isCancelled else { return nil }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("SnapRelay-Capture-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let output = directory.appendingPathComponent("selection.png")
        let log = directory.appendingPathComponent("stderr")
        try Data().write(to: log)
        let diagnostics = try FileHandle(forWritingTo: log)
        defer { try? diagnostics.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-Jselection", "-x", "-t", "png", output.path]
        process.standardError = diagnostics
        process.standardOutput = FileHandle.nullDevice
        activeProcess = process
        defer { if activeProcess === process { activeProcess = nil } }

        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                guard activeProcess === process, !Task.isCancelled else {
                    continuation.resume(returning: 0)
                    return
                }
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor in
                if self.activeProcess === process { self.cancel() }
            }
        }

        guard activeProcess === process, !Task.isCancelled else { return nil }
        if !files.fileExists(atPath: output.path) {
            let message = (try? String(contentsOf: log, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            // Escape can exit with no message or with a cancellation diagnostic.
            if (status == 0 || status == 1) && (message.isEmpty || message.contains("cancel")) { return nil }
            throw CaptureError.failed
        }
        guard status == 0 else { throw CaptureError.failed }
        let image = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: output)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw CaptureError.invalidImage }
            return image
        }.value
        return activeProcess === process && !Task.isCancelled ? image : nil
    }

    func cancel() {
        guard let process = activeProcess else { return }
        activeProcess = nil
        if process.isRunning { process.terminate() }
    }

    private enum CaptureError: LocalizedError {
        case failed, invalidImage

        var errorDescription: String? {
            switch self {
            case .failed: "截屏未完成，请重试。"
            case .invalidImage: "无法读取截取的图片，请重新截屏。"
            }
        }
    }
}
