import Foundation
import PrintCore

/// Which embeddings API an endpoint speaks.
public enum EmbedApi: Sendable {
    /// Ollama's own `POST /api/embed` (`{"embeddings":[[…]]}`), on the server's root.
    case ollama
    /// The OpenAI-compatible `POST {base}/embeddings` (`{"data":[{"index":0,"embedding":[…]}]}`).
    case openAi
}

/// Embeddings (roadmap 4.21; the Windows `AiEmbeddings`): a model on the user's own endpoint turns text into numbers (a
/// vector) such that texts close in meaning get vectors close in direction. Requests carry the model and the texts only;
/// answers are read as data: every vector the same length, every number finite, one per text, or the answer is refused.
public enum AiEmbeddings {
    /// Most numbers in one vector (the largest common models give 4,096).
    public static let maxDimensions = 8192
    /// Texts sent in one request.
    public static let batchSize = 16

    /// The request body, the same for both APIs: the model and the texts, nothing else.
    public static func requestJson(_ model: String, _ inputs: [String]) -> String {
        "{\"model\":\(AiProtocol.quote(model)),\"input\":[\(inputs.map(AiProtocol.quote).joined(separator: ","))]}"
    }

    /// Where the request goes on `endpoint`.
    public static func urlFor(_ endpoint: AiEndpoint, _ api: EmbedApi) -> String {
        api == .ollama ? endpoint.origin + "/api/embed" : endpoint.key + "/embeddings"
    }

    static var notEmbeddings: AiError { AiError(loc("The AI server's answer isn't a list of embeddings, one for each text sent.")) }

    /// The vectors of an answer, one per text asked about, in the order asked.
    /// - Throws: `AiError` when the answer isn't that (another shape, a count or length that doesn't match, a number that
    ///   isn't one).
    public static func parse(_ json: String, _ api: EmbedApi, _ count: Int) throws -> [[Float]] {
        guard let root = AiProtocol.parse(json) as? [String: Any] else { throw notEmbeddings }
        var vectors = [[Float]?](repeating: nil, count: count)
        switch api {
        case .ollama:
            guard let list = root["embeddings"] as? [Any], list.count == count else { throw notEmbeddings }
            for (i, v) in list.enumerated() { vectors[i] = try vector(v) }
        case .openAi:
            guard let data = root["data"] as? [Any], data.count == count else { throw notEmbeddings }
            for (at, item) in data.enumerated() {
                guard let item = item as? [String: Any], let v = item["embedding"] else { throw notEmbeddings }
                var index = at
                if let n = item["index"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = Int(exactly: n.doubleValue) { index = i }
                guard index >= 0, index < count, vectors[index] == nil else { throw notEmbeddings }
                vectors[index] = try vector(v)
            }
        }
        let done = vectors.compactMap { $0 }
        guard done.count == count, let first = done.first, done.allSatisfy({ $0.count == first.count }) else { throw notEmbeddings }
        return done
    }

    private static func vector(_ value: Any) throws -> [Float] {
        guard let list = value as? [Any], !list.isEmpty, list.count <= maxDimensions else { throw notEmbeddings }
        var out = [Float]()
        out.reserveCapacity(list.count)
        for x in list {
            guard let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw notEmbeddings }
            let d = n.doubleValue
            guard d.isFinite, abs(d) <= 1e6 else { throw notEmbeddings }
            out.append(Float(d))
        }
        return out
    }
}
