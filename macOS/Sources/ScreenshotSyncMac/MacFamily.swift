import Darwin
import Foundation
import IOKit

enum MacFamily: String {
    case mini = "mac-mini"
    case studio = "mac-studio"
    case imac
    case pro = "mac-pro"
    case book = "macbook"
    case air = "macbook-air"
    case bookPro = "macbook-pro"
    case neo = "macbook-neo"
    case mac

    static let current: Self = {
        if let name = productName(), let family = family(for: name) {
            return family
        }
        // Intel model identifiers contain the family, e.g. MacBookPro16,1.
        var length = 0
        guard sysctlbyname("hw.model", nil, &length, nil, 0) == 0, length > 0 else { return .mac }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctlbyname("hw.model", &bytes, &length, nil, 0) == 0 else { return .mac }
        return family(for: String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)) ?? .mac
    }()

    static func family(for model: String) -> Self? {
        // Both the marketing name (Mac mini (2024)) and an older identifier
        // (Macmini9,1) put the family before the generation or screen size.
        let family = model.prefix { $0 != "(" && !$0.isNumber }.filter { !$0.isWhitespace }.lowercased()
        switch family {
        case "macmini": return .mini
        case "macstudio": return .studio
        case "imac", "imacpro": return .imac
        case "macpro": return .pro
        case "macbookair": return .air
        case "macbookpro": return .bookPro
        case "macbookneo": return .neo
        case "macbook": return .book
        default: return nil
        }
    }

    private static func productName() -> String? {
        // Apple silicon's hw.model is opaque (e.g. Mac16,10). The device tree
        // supplies a human-readable hardware name independent of the computer's nickname.
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(product) }
        let value = IORegistryEntryCreateCFProperty(product, "product-name" as CFString,
                                                     kCFAllocatorDefault, 0)?.takeRetainedValue()
        if let data = value as? Data {
            return String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return value as? String
    }
}
