import Foundation
import PrintCore

/// One /VRI entry: which of the stored data belongs to one signature.
struct VriEntry {
    /// The uppercase hex SHA-1 of the signature's /Contents.
    let key: String
    let certs: [[UInt8]]
    let ocsps: [[UInt8]]
    let crls: [[UInt8]]
}

/// The Document Security Store (ISO 32000-2 12.8.4.3, ETSI EN 319 142-1): the catalog's /DSS with the certificates, OCSP
/// responses and CRLs a signature will need when it is checked years from now, and /VRI saying which belong to which (the
/// Windows app's `Dss`). Reading treats it as hostile: anything of the wrong shape or too large is skipped
/// (`RevocationPool` keeps the limits), compressed streams are inflated only up to what is allowed, and a damaged store is
/// simply no store.
enum Dss {
    private static let maxEntries = 1024

    /// What `doc`'s store holds goes into `pool`.
    static func readInto(_ doc: MuDoc, _ pool: RevocationPool) {
        guard let dss = doc.catalog.dict("DSS") else { return }
        readList(dss["Certs"], RevocationPool.maxCertBytes, pool.addCert, pool)
        readList(dss["OCSPs"], RevocationPool.maxOcspBytes, pool.addOcsp, pool)
        readList(dss["CRLs"], RevocationPool.maxCrlBytes, pool.addCrl, pool)
        // /VRI's lists normally name the same streams; a writer may have put some there alone.
        guard let vri = dss.dict("VRI") else { return }
        for i in 0..<min(vri.count, maxEntries) {
            if pool.outOfBudget { return }
            guard let entry = vri.value(at: i), entry.isDict else { continue }
            readList(entry["Cert"], RevocationPool.maxCertBytes, pool.addCert, pool)
            readList(entry["OCSP"], RevocationPool.maxOcspBytes, pool.addOcsp, pool)
            readList(entry["CRL"], RevocationPool.maxCrlBytes, pool.addCrl, pool)
        }
    }

    private static func readList(_ list: PObj?, _ maxBytes: Int, _ add: ([UInt8]) -> Void, _ pool: RevocationPool) {
        guard let list, list.isArray else { return }
        for i in 0..<min(list.count, maxEntries) {
            if pool.outOfBudget { return }
            if let item = list[i], let bytes = bytes(item, maxBytes) { add(bytes) }
        }
    }

    /// A stored stream's bytes: unfiltered or plain Flate, at most `maxBytes` (inflating no further). Other filters
    /// aren't used for this data.
    private static func bytes(_ stream: PObj, _ maxBytes: Int) -> [UInt8]? {
        guard stream.isStream else { return nil }
        if let filter = stream["Filter"] {
            let name = filter.isArray ? (filter.count == 1 ? filter[0]?.name : nil) : filter.name
            guard name == "FlateDecode", stream["DecodeParms"] == nil else { return nil }
        }
        guard let head = stream.streamHead(maxBytes), !head.more else { return nil }
        return head.bytes
    }

    /// Appends an incremental update that adds these to the store, leaving every earlier byte as it was. Data already in
    /// the store is pointed at, not repeated. Throws `SigningError` when the update can't be written.
    static func append(_ data: [UInt8], _ password: String?, _ entries: [VriEntry]) throws -> [UInt8] {
        let failed = SigningError(loc("This document's file structure can't be extended, so long-term data can't be added without breaking its signatures. Nothing was changed."))
        guard let doc = try? PdfEdit.open(data, password), doc.canAppend else { throw failed }
        let catalog = doc.catalog
        let dss: PObj
        if let found = catalog.dict("DSS") {
            dss = found
        } else {
            dss = doc.add(doc.dict())
            catalog.set("DSS", dss)
        }
        let certs = stored(doc, dss, "Certs")
        let ocsps = stored(doc, dss, "OCSPs")
        let crls = stored(doc, dss, "CRLs")
        let vri: PObj
        if let found = dss.dict("VRI") {
            vri = found
        } else {
            vri = doc.dict()
            dss.set("VRI", vri)
        }
        let now = doc.text(PdfDates.format(Date()))
        for e in entries {
            let entry = doc.dict()
            if !e.certs.isEmpty { entry.set("Cert", references(doc, e.certs, certs)) }
            if !e.ocsps.isEmpty { entry.set("OCSP", references(doc, e.ocsps, ocsps)) }
            if !e.crls.isEmpty { entry.set("CRL", references(doc, e.crls, crls)) }
            entry.set("TU", now)
            vri.set(e.key, entry)
        }
        // The store is an extension of PDF 1.7 (ISO 32000-2 has it itself); say so unless the file already speaks for one.
        let extensions: PObj
        if let found = catalog.dict("Extensions") {
            extensions = found
        } else {
            extensions = doc.dict()
            catalog.set("Extensions", extensions)
        }
        if extensions["ESIC"] == nil && extensions["ADBE"] == nil {
            extensions.set("ESIC", doc.dict([("BaseVersion", doc.name("1.7")), ("ExtensionLevel", doc.int(5))]))
        }
        do {
            try doc.checkFailure()
            return try doc.append(original: data)
        } catch {
            throw SigningError(loc("Long-term data can't be appended to this PDF. Nothing was changed."))
        }
    }

    /// The store already holds all of this, under these signatures' /VRI keys: an update would add nothing.
    static func holds(_ data: [UInt8], _ password: String?, _ entries: [VriEntry]) -> Bool {
        guard let doc = try? PdfEdit.openToRead(data, password), let dss = doc.catalog.dict("DSS"), let vri = dss.dict("VRI") else { return false }
        func hashes(_ key: String) -> Set<[UInt8]> {
            guard let list = dss.array(key) else { return [] }
            var set = Set<[UInt8]>()
            for i in 0..<min(list.count, maxEntries) {
                if let item = list[i], let b = bytes(item, RevocationPool.maxCrlBytes) { set.insert(hash(b)) }
            }
            return set
        }
        let certs = hashes("Certs"), ocsps = hashes("OCSPs"), crls = hashes("CRLs")
        return entries.allSatisfy { e in
            vri[e.key] != nil && e.certs.allSatisfy { certs.contains(hash($0)) } && e.ocsps.allSatisfy { ocsps.contains(hash($0)) }
                && e.crls.allSatisfy { crls.contains(hash($0)) }
        }
    }

    /// One /DSS list: its array (made when missing) and what it already holds, by the hash of the bytes.
    private final class Store {
        let array: PObj
        var known: [[UInt8]: PObj] = [:]
        init(_ array: PObj) { self.array = array }
    }

    private static func stored(_ doc: MuDoc, _ dss: PObj, _ key: String) -> Store {
        let array: PObj
        if let found = dss.array(key) {
            array = found
        } else {
            array = doc.array()
            dss.set(key, array)
        }
        let store = Store(array)
        for i in 0..<min(array.count, maxEntries) {
            guard let item = array[i], let b = bytes(item, RevocationPool.maxCrlBytes) else { continue }
            let h = hash(b)
            if store.known[h] == nil { store.known[h] = item }
        }
        return store
    }

    private static func references(_ doc: MuDoc, _ items: [[UInt8]], _ store: Store) -> PObj {
        let refs = doc.array()
        for bytes in items {
            let h = hash(bytes)
            let ref: PObj
            if let known = store.known[h] {
                ref = known
            } else {
                ref = doc.addStream(bytes, deflate: false)
                store.array.append(ref)
                store.known[h] = ref
            }
            refs.append(ref)
        }
        return refs
    }

    private static func hash(_ b: [UInt8]) -> [UInt8] { DigestAlgorithm.sha256.hash(b) }
}
