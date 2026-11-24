import Foundation

struct DeviceProfile: Codable, Equatable, Sendable {
    let name: String?
    let model: String?
    let osVersion: String?
}

extension DeviceProfile {
    init?(header: String) {
        guard header.utf8.count <= 2048, let data = Data(base64Encoded: header), data.base64EncodedString() == header,
              !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              Self.isDisplayable(decoded.name, limit: 256),
              Self.isDisplayable(decoded.model, limit: 256),
              Self.isDisplayable(decoded.osVersion, limit: 128) else { return nil }

        func trimmed(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespaces),
                  text.unicodeScalars.contains(where: {
                      !$0.properties.isDefaultIgnorableCodePoint && !$0.properties.isWhitespace
                  }) else { return nil }
            return text
        }
        self.init(name: trimmed(decoded.name), model: trimmed(decoded.model), osVersion: trimmed(decoded.osVersion))
        guard name != nil || model != nil || osVersion != nil else { return nil }
    }

    private static func isDisplayable(_ value: String?, limit: Int) -> Bool {
        guard let value else { return true }
        guard value.utf8.count <= limit else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            case .format: scalar == "\u{200C}" || scalar == "\u{200D}"  // Joining characters in names and emoji.
            default: true
            }
        }
    }
}
