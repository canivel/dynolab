import Foundation
import Darwin

/// Active IPv4 addresses for connection instructions. Loopback and point-to-point
/// (typically VPN) interfaces are omitted; multiple LAN adapters remain visible.
public enum NetworkAddresses {
    public static func localIPv4() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: host))
            }
        }
        return addresses.sorted()
    }
}
