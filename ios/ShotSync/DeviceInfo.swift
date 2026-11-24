import Darwin
import UIKit

struct DeviceInfo: Encodable {
    let name: String?
    let model: String?
    let osVersion: String?

    @MainActor
    init() {
        let device = UIDevice.current
        let reportedName = Self.field(device.name, maxBytes: 256)
        // iOS may return only the generic device family instead of a personal name.
        name = reportedName == device.model || reportedName == device.localizedModel ? nil : reportedName
        model = Self.field(Self.modelName ?? device.model, maxBytes: 256)
        osVersion = Self.field(device.systemVersion, maxBytes: 128)
    }

    private static func field(_ value: String, maxBytes: Int) -> String? {
        guard value.utf8.count <= maxBytes, value.unicodeScalars.allSatisfy({ scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            case .format: scalar == "\u{200C}" || scalar == "\u{200D}"
            default: true
            }
        }) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.unicodeScalars.contains(where: {
            !$0.properties.isDefaultIgnorableCodePoint && !$0.properties.isWhitespace
        }) else { return nil }
        return trimmed
    }

    private static let modelName: String? = {
#if targetEnvironment(simulator)
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
#else
        var info = utsname()
        guard uname(&info) == 0 else { return nil }
        let identifier: String? = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
#endif
        guard let identifier, !identifier.isEmpty else { return nil }
        return iphoneNames[identifier] ?? identifier
    }()

    // Hardware identifiers and display names from Xcode's iPhone device profiles.
    private static let iphoneNames = [
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air", "iPhone18,5": "iPhone 17e",
        "iPhone19,2": "iPhone 18 Pro", "iPhone19,3": "iPhone 18 Pro Max", "iPhone19,4": "iPhone Duo",
    ]
}
