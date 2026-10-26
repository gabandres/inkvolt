/// HP ADF scans stream JPEGs before the page length is known: the SOF header says height 0 and the real height arrives in
/// a DNL marker after the scan data. Most decoders reject that, so the DNL height is copied into the SOF header.
public enum JpegFix {
    public static func patchZeroHeight(_ jpeg: [UInt8]) -> [UInt8] {
        let sof = findSofHeightOffset(jpeg)
        guard sof >= 0, read16(jpeg, sof) == 0 else { return jpeg }
        let dnl = findDnlHeight(jpeg)
        guard dnl > 0 else { return jpeg }
        var copy = jpeg
        copy[sof] = UInt8(dnl >> 8)
        copy[sof + 1] = UInt8(dnl & 0xFF)
        return copy
    }

    /// Offset of the 16-bit height field in the first SOFn segment, or -1.
    static func findSofHeightOffset(_ j: [UInt8]) -> Int {
        guard j.count >= 4, j[0] == 0xFF, j[1] == 0xD8 else { return -1 }
        var i = 2
        while i + 4 <= j.count {
            if j[i] != 0xFF { return -1 }
            let marker = j[i + 1]
            if marker == 0xFF {
                i += 1
                continue
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = read16(j, i + 2)
            // SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC)
            if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                return i + 9 < j.count ? i + 5 : -1 // height(2) width(2) components(1) must all be present
            }
            if marker == 0xDA { return -1 } // start of scan before any SOF
            i += 2 + length
        }
        return -1
    }

    /// Height from the DNL (FFDC) marker, scanning entropy-coded data, or -1.
    static func findDnlHeight(_ j: [UInt8]) -> Int {
        var i = j.count - 6
        while i >= 2 {
            if j[i] == 0xFF && j[i + 1] == 0xDC && read16(j, i + 2) == 4 { return read16(j, i + 4) }
            i -= 1
        }
        return -1
    }

    private static func read16(_ j: [UInt8], _ at: Int) -> Int { Int(j[at]) << 8 | Int(j[at + 1]) }
}
