import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct PairingQRCode: Encodable, Equatable {
    let type = "snaprelay-pair"
    let version = 1
    let addresses: [String]
    let token: String

    init?(addresses: [LocalAddress], port: UInt16, token: String) {
        var hosts = Set<String>()
        // Prefer Wi-Fi and Ethernet over virtual bridges when both are available.
        let preferred = addresses.filter { $0.interface.hasPrefix("en") }
            + addresses.filter { !$0.interface.hasPrefix("en") }
        let urls = preferred.filter { hosts.insert($0.host).inserted }
            .prefix(16).map { "http://\($0.host):\(port)" }
        guard !urls.isEmpty, !token.isEmpty else { return nil }
        self.addresses = urls
        self.token = token
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    func image() -> CGImage? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = data
        generator.correctionLevel = "M"
        guard let symbol = generator.outputImage else { return nil }
        let bounds = symbol.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: .white).cropped(to: bounds)
        return Self.context.createCGImage(symbol.composited(over: background), from: bounds)
    }
}
