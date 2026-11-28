import CoreWLAN
import Darwin
import Foundation
import PrintCore
import SystemConfiguration

/// What tells one of this Mac's networks from another with the same addresses, for the shared scanner (`NetworkPlace`):
/// the router SystemConfiguration's dynamic store names for the network service holding the address, the router's
/// hardware address from the routing table's neighbours (`sysctl` NET_RT_FLAGS/RTF_LLINFO, as `arp -a` reads it), and the
/// Wi-Fi network's name only when location access was already given (`WifiLocation.allowed`; never asked for here).
public enum NetworkPlaces {
    public static func place(of network: LocalNetwork) -> NetworkPlace {
        let service = self.service(holding: network.address)
        let router = service?.router
        var wifi: String?
        if WifiLocation.allowed, let name = service?.interface, let air = CWWiFiClient.shared().interface(withName: name),
           let ssid = air.ssidData(), !ssid.isEmpty {
            wifi = ssid.prefix(32).map { b in (b < 16 ? "0" : "") + String(b, radix: 16) }.joined()
        }
        return NetworkPlace(network, router: router, routerHardware: router.flatMap(neighbour), wifi: wifi)
    }

    /// The network service whose IPv4 addresses include `address`: its router and interface.
    static func service(holding address: String) -> (router: String?, interface: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "InkvoltPrint" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for key in keys.prefix(64) {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let addresses = value["Addresses"] as? [String], addresses.prefix(64).contains(address) else { continue }
            return (value["Router"] as? String, value["InterfaceName"] as? String)
        }
        return nil
    }

    /// The hardware address the routing table holds for the neighbour `ipv4` ("aa:bb:…"), nil when it holds none or the
    /// table can't be read.
    static func neighbour(_ ipv4: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, ipv4, &target) == 1 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0, size <= 16 << 20 else { return nil }
        size += 4096 // entries added between the two calls
        var table = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &table, &size, nil, 0) == 0, size <= table.count else { return nil }
        return neighbour(in: Array(table.prefix(size)), target.s_addr)
    }

    /// Reads routing messages (`rt_msghdr`, then the destination's sockaddr_in, then the link's sockaddr_dl) for `address`
    /// (network order): bounds checked at every step, so a short or odd table gives nil.
    static func neighbour(in table: [UInt8], _ address: in_addr_t) -> String? {
        let header = MemoryLayout<rt_msghdr>.size
        var at = 0
        while at + header <= table.count {
            let length = Int(table[at]) | Int(table[at + 1]) << 8 // rtm_msglen, little-endian
            guard length >= header, at + length <= table.count else { return nil }
            defer { at += length }
            let sin = at + header
            guard sin + 8 <= at + length, table[sin + 1] == UInt8(AF_INET) else { continue }
            let found = table[sin + 4..<sin + 8].withUnsafeBytes { $0.loadUnaligned(as: in_addr_t.self) }
            guard found == address else { continue }
            let sinLength = max(Int(table[sin]), 4)
            let dl = sin + (sinLength + 3) / 4 * 4
            guard dl + 8 <= at + length, table[dl + 1] == UInt8(AF_LINK) else { return nil }
            let nameLength = Int(table[dl + 5]), addressLength = Int(table[dl + 6])
            let start = dl + 8 + nameLength
            guard addressLength == 6, start + 6 <= at + length else { return nil }
            return table[start..<start + 6].map { b in (b < 16 ? "0" : "") + String(b, radix: 16) }.joined(separator: ":")
        }
        return nil
    }
}
