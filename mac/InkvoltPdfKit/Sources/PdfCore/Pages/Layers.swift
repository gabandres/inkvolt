import Foundation
import PrintCore

/// An optional-content group (layer), the Windows app's `LayerInfo`.
public struct LayerInfo: Sendable, Equatable {
    /// The group's object number: the key for `Layers.withVisibility`.
    public let id: Int
    public let name: String
    /// Visible in the default configuration (/OCProperties /D: /BaseState, /ON, /OFF).
    public let defaultVisible: Bool
    /// Listed in /D /Locked: the author doesn't want users toggling it.
    public let locked: Bool

    public init(id: Int, name: String, defaultVisible: Bool, locked: Bool) {
        self.id = id
        self.name = name
        self.defaultVisible = defaultVisible
        self.locked = locked
    }
}

/// A node of the layer panel tree (/D /Order): a layer (with optional sub-layers) or a labeled group.
public struct LayerOrderNode: Sendable, Equatable {
    public let label: String?
    public let layerId: Int?
    public var children: [LayerOrderNode]
}

/// Optional content (layers): list them and produce copies with chosen layers shown or hidden (the Windows app's `Layers`).
public enum Layers {
    public static func list(_ data: [UInt8], _ password: String?) throws -> [LayerInfo] {
        listIn(try open(data, password))
    }

    static func listIn(_ doc: MuDoc) -> [LayerInfo] {
        let props = doc.catalog.dict("OCProperties")
        guard let ocgs = props?.array("OCGs") else { return [] }
        let d = props?.dict("D")
        let on = ids(d?.array("ON")), off = ids(d?.array("OFF")), locked = ids(d?.array("Locked"))
        let baseOff = d?.name("BaseState") == "OFF"
        var list: [LayerInfo] = []
        var seen = Set<Int>()
        for item in ocgs.elements where item.isRef && item.isDict {
            let id = item.num
            guard seen.insert(id).inserted else { continue }
            let visible = off.contains(id) ? false : on.contains(id) || !baseOff
            list.append(LayerInfo(id: id, name: item.text("Name") ?? "Layer \(id)", defaultVisible: visible, locked: locked.contains(id)))
        }
        return list
    }

    /// The layer panel tree from /D /Order (layers in the order the author arranged them); flat when absent.
    public static func readOrder(_ data: [UInt8], _ password: String?) throws -> [LayerOrderNode] {
        let doc = try open(data, password)
        let known = listIn(doc).map(\.id)
        guard let order = doc.catalog.dict("OCProperties")?.dict("D")?.array("Order") else {
            return known.map { LayerOrderNode(label: nil, layerId: $0, children: []) }
        }
        var budget = 10_000
        return parse(order.elements, Set(known), 0, &budget)
    }

    /// `budget`: elements left to visit: an /Order whose arrays repeat or contain themselves would otherwise take
    /// exponential time.
    private static func parse(_ elements: [PObj], _ known: Set<Int>, _ depth: Int, _ budget: inout Int) -> [LayerOrderNode] {
        var nodes: [LayerOrderNode] = []
        if depth > 32 { return nodes }
        for e in elements {
            budget -= 1
            if budget < 0 { break }
            if e.isRef && known.contains(e.num) && e.isDict {
                nodes.append(LayerOrderNode(label: nil, layerId: e.num, children: []))
            } else if e.isArray {
                let sub = e.elements
                if let label = sub.first?.text, sub.first?.kind == .string {
                    nodes.append(LayerOrderNode(label: label, layerId: nil, children: parse(Array(sub.dropFirst()), known, depth + 1, &budget)))
                } else {
                    // An array right after a layer holds that layer's children.
                    let children = parse(sub, known, depth + 1, &budget)
                    if let last = nodes.last, last.layerId != nil, last.children.isEmpty {
                        nodes[nodes.count - 1].children = children
                    } else {
                        nodes.append(LayerOrderNode(label: nil, layerId: nil, children: children))
                    }
                }
            }
        }
        return nodes
    }

    /// A copy of the document whose default layer configuration shows or hides the given layers (others keep their
    /// default), for viewing and printing only: decrypted and written in memory (never saved), so the view engine opens it
    /// without a password. Usage-based automatic states (/AS) are dropped so the choice is what renders.
    public static func withVisibility(_ data: [UInt8], _ password: String?, _ visibility: [Int: Bool]) throws -> [UInt8] {
        let doc = try open(data, password)
        guard apply(doc, visibility, forViewing: true) else { return data }
        try doc.checkFailure()
        return try doc.write("decrypt=yes,encrypt=no")
    }

    /// Saves the given layer states as the document's default (what other viewers show when opening it): one edit.
    public static func setDefaultVisibility(_ data: [UInt8], _ password: String?, _ visibility: [Int: Bool]) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in _ = apply(doc, visibility, forViewing: false) }
    }

    /// Writes /D's /BaseState, /ON and /OFF from the current states and `visibility`; false when there are no layers.
    private static func apply(_ doc: MuDoc, _ visibility: [Int: Bool], forViewing: Bool) -> Bool {
        guard let props = doc.catalog.dict("OCProperties"), let ocgs = props.array("OCGs") else { return false }
        let current = Dictionary(listIn(doc).map { ($0.id, $0.defaultVisible) }, uniquingKeysWith: { a, _ in a })
        var d = props.dict("D")
        if d == nil {
            props.set("D", doc.dict())
            d = props.dict("D")
        }
        guard let d else { return false }
        let on = doc.array(), off = doc.array()
        var placed = Set<Int>()
        for item in ocgs.elements where item.isRef {
            guard var visible = current[item.num], placed.insert(item.num).inserted else { continue }
            if let wanted = visibility[item.num] { visible = wanted }
            (visible ? on : off).append(item)
        }
        d.set("BaseState", doc.name("ON"))
        d.set("ON", on)
        d.set("OFF", off)
        if forViewing { d.remove("AS") }
        return true
    }

    private static func open(_ data: [UInt8], _ password: String?) throws -> MuDoc {
        do {
            return try PdfEdit.openToRead(data, password)
        } catch let e as PdfEditError {
            throw PdfEditError(e.message.replacingOccurrences(of: loc("This PDF can't be read"), with: loc("This PDF's layers can't be read")))
        }
    }

    private static func ids(_ array: PObj?) -> Set<Int> { Set(array?.elements.filter(\.isRef).map(\.num) ?? []) }
}
