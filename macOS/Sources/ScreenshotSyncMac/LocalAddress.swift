import Darwin
import Foundation
import Network

struct LocalAddress: Identifiable, Equatable {
    let host: String
    let interface: String

    var id: String { "\(interface)/\(host)" }

    static func available() -> [Self] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(first) }

        var addresses: [Self] = []
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let current = next {
            let entry = current.pointee
            next = entry.ifa_next
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING)) == UInt32(IFF_UP | IFF_RUNNING),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let interface = String(cString: entry.ifa_name)
            if let ip = IPv4Address(host), accepts(ip.rawValue, loopback: false) {
                addresses.append(Self(host: host, interface: interface))
            }
        }
        return Array(Set(addresses.map(\.id))).compactMap { id in
            addresses.first { $0.id == id }
        }.sorted { ($0.interface, $0.host) < ($1.interface, $1.host) }
    }

    static func accepts(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return accepts(address.rawValue, loopback: true)
        case .ipv6(let address):
            if address == .loopback { return true }
            let bytes = address.rawValue
            guard bytes.prefix(10).allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xff, bytes[11] == 0xff else { return false }
            return accepts(Data(bytes.suffix(4)), loopback: true)
        default:
            return false
        }
    }

    private static func accepts(_ address: Data, loopback: Bool) -> Bool {
        let bytes = Array(address)
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (172, 16...31), (192, 168), (169, 254):
            return true
        case (127, _):
            return loopback
        default:
            return false
        }
    }
}
