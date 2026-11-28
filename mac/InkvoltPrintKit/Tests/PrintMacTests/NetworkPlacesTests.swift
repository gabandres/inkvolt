import Darwin
import Foundation
import PrintCore
@testable import PrintMac
import Testing

/// The router's hardware address read from the routing table's neighbours (the shared scanner's `NetworkPlace`): a table as
/// `sysctl` returns it, and short or odd ones, which give nothing rather than a read past the end.
struct NetworkPlacesTests {
    /// One RTF_LLINFO message: the header, the neighbour's sockaddr_in, the link's sockaddr_dl ("en0" and its address).
    private static func message(_ ip: String, _ mac: [UInt8]) -> [UInt8] {
        var sin = [UInt8](repeating: 0, count: 16)
        sin[0] = 16
        sin[1] = UInt8(AF_INET)
        var a = in_addr()
        _ = inet_pton(AF_INET, ip, &a)
        withUnsafeBytes(of: a.s_addr) { for (i, b) in $0.enumerated() { sin[4 + i] = b } }
        var dl: [UInt8] = [20, UInt8(AF_LINK), 4, 0, 6, 3, UInt8(mac.count), 0] + Array("en0".utf8) + mac
        dl += [UInt8](repeating: 0, count: max(0, 20 - dl.count))
        let length = MemoryLayout<rt_msghdr>.size + sin.count + dl.count
        var header = [UInt8](repeating: 0, count: MemoryLayout<rt_msghdr>.size)
        header[0] = UInt8(length & 0xFF)
        header[1] = UInt8(length >> 8)
        return header + sin + dl
    }

    private static func address(_ ip: String) -> in_addr_t {
        var a = in_addr()
        _ = inet_pton(AF_INET, ip, &a)
        return a.s_addr
    }

    @Test func theRoutersHardwareAddressIsReadFromItsNeighbourEntry() {
        let table = Self.message("192.0.2.9", [1, 2, 3, 4, 5, 6]) + Self.message("192.0.2.1", [0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f])
        #expect(NetworkPlaces.neighbour(in: table, Self.address("192.0.2.1")) == "0a:1b:2c:3d:4e:5f")
        #expect(NetworkPlaces.neighbour(in: table, Self.address("192.0.2.77")) == nil)
    }

    @Test func aShortOrOddTableGivesNothing() {
        let entry = Self.message("192.0.2.1", [0x0a, 0x1b, 0x2c, 0x3d, 0x4e, 0x5f])
        let router = Self.address("192.0.2.1")
        #expect(NetworkPlaces.neighbour(in: [], router) == nil)
        #expect(NetworkPlaces.neighbour(in: Array(entry.dropLast(3)), router) == nil) // cut short
        var zeroLength = entry
        zeroLength[0] = 0
        zeroLength[1] = 0
        #expect(NetworkPlaces.neighbour(in: zeroLength, router) == nil) // a length of 0 never loops
        var tooLong = entry
        tooLong[0] = 0xFF
        tooLong[1] = 0xFF
        #expect(NetworkPlaces.neighbour(in: tooLong, router) == nil)
        #expect(NetworkPlaces.neighbour(in: Self.message("192.0.2.1", [1, 2, 3]), router) == nil) // not an Ethernet address
    }

    @Test func thisMacsPlaceReadsWithoutAskingForAnything() {
        // Whatever network this Mac is on: a place with its subnet; never a question (location access isn't asked for).
        for network in SocketNetworkScanner().localNetworks().prefix(4) {
            #expect(NetworkPlaces.place(of: network).subnet.hasSuffix("/\(network.prefixLength)"))
        }
    }
}
