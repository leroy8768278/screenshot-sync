import BackgroundTasks
import OSLog
import UIKit

enum BGRefresh {
    static var identifier: String { "\(Bundle.main.bundleIdentifier ?? "local.shotsync.ios").refresh" }
    private static let logger = Logger(subsystem: "local.shotsync.ios", category: "BackgroundRefresh")

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.info("Background refresh unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BGRefresh.identifier, using: .main) { task in
            MainActor.assumeIsolated {
                let sync = PhotoSync.shared
                if sync.acceptsBackgroundRefresh { BGRefresh.schedule() }
                let operation = Task { @MainActor in
                    let successful = await sync.scan(background: true)
                    task.setTaskCompleted(success: successful && !Task.isCancelled)
                }
                task.expirationHandler = { operation.cancel() }
            }
        }
        return true
    }
}
