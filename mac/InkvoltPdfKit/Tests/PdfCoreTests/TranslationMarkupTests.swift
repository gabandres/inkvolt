import Foundation
import Testing
@testable import PdfCore

/// Processor time this thread has used (seconds): what a time limit measures, so other tests running at once don't
/// inflate it (Windows' `ThreadClock.Stopwatch`).
func threadSeconds() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
}

/// A seeded generator, the same numbers every run (.NET's `Random(seed)` in Windows' tests; not the same sequence).
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &self) }
}

let lookB = TextLook(bold: true)
let lookI = TextLook(italic: true)
let lookSub = TextLook(script: .sub)
let lookSup = TextLook(script: .superscript)

/// A span over the first `part` of `text` (UTF-16).
func span(_ text: String, _ part: String, _ look: TextLook) -> TextSpan {
    let r = (text as NSString).range(of: part)
    #expect(r.location != NSNotFound, "\(part)")
    return TextSpan(r.location, r.length, look)
}

/// The markup half of Windows' `TranslationLooksTests` (roadmap 3.1): looks out as tags, the reply's tags back as looks.
struct TranslationMarkupTests {
    static let source = "The quick <b>brown</b> fox jumps over d<sub>model</sub> and the lazy dog."

    @Test func aParagraphsOwnTagsAreNotTakenForMarkup() {
        let own = "Write <b> before a bold word and </b> after it."
        #expect(!TranslationText.request(own, "Spanish")[0].content.contains("<sup>"))
        let text = Array(repeating: own, count: 200).joined(separator: " ")
        let plan = TranslationPlan(data: [], pages: [], texts: [(text, 0)])
        let jobs = Translation.jobs(plan, Translation.pieceTokens(4096))
        #expect(jobs.count == 1)
        #expect(!jobs[0].marked)
        #expect(jobs[0].pieces.count > 1)
        #expect(jobs[0].pieces.allSatisfy { $0.contains("<b>") })
        #expect(Translation.requests(jobs, "Spanish").allSatisfy { !$0[0].content.contains("<sup>") })
    }

    @Test func looksAreWrittenAsNestedTagsInOneOrder() {
        let text = "An x2 and a bold italic word, H2O and e=mc2."
        let ns = text as NSString
        let x2 = ns.range(of: "x2").location, h2o = ns.range(of: "H2O").location, last2 = ns.range(of: "2", options: .backwards).location
        let spans = [
            span(text, "bold italic", lookB), span(text, "italic", TextLook(bold: true, italic: true)),
            TextSpan(x2, 1, lookI), TextSpan(x2 + 1, 1, lookSup), TextSpan(h2o + 1, 1, lookSub),
            TextSpan(last2, 1, TextLook(italic: true, script: .superscript)),
        ]
        #expect(TranslationMarkup.mark(text, spans) == "An <i>x</i><sup>2</sup> and a <b>bold <i>italic</i></b> word, H<sub>2</sub>O and e=mc<i><sup>2</sup></i>.")
    }

    @Test func everyLookAtOnceNestsFiveDeepAndComesBack() {
        let text = "A word in all of them."
        let all = TextLook(color: 0xFF0000, bold: true, italic: true, script: .superscript, underline: true)
        let spans = [span(text, "word", all)]
        #expect(TranslationMarkup.mark(text, spans) == "A <b><i><u><span><sup>word</sup></span></u></i></b> in all of them.")
        let (now, looks) = TranslationMarkup.read("Una <b><i><u><span><sup>palabra</sup></span></u></i></b> en todas.", text, spans)
        #expect(looks.count == 1)
        guard let look = looks.first else { return }
        #expect((now as NSString).substring(with: NSRange(location: look.start, length: look.length)) == "palabra")
        #expect(look.look.bold == true && look.look.italic == true && look.look.underline == true)
        #expect(look.look.script == .superscript && look.look.color == 0xFF0000)
    }

    // "< b" would be taken for a piece of a tag.
    @Test(arguments: ["a < b and c", "x <html> and c", "x<y and c", "a sub> and c"])
    func textWithAngleBracketsThatCouldBeReadAsTagsGoesWithoutMarkup(_ text: String) {
        #expect(TranslationMarkup.mark(text, [TextSpan(0, 1, lookB)]) == text)
    }

    @Test(arguments: [("x > y and c", "<b>x</b> > y and c"), ("p < 0.05 and c", "<b>p</b> < 0.05 and c"), ("x -> y and c", "<b>x</b> -> y and c")])
    func textWithAngleBracketsThatReadOnlyAsTextKeepsItsMarkup(_ text: String, _ marked: String) {
        #expect(TranslationMarkup.mark(text, [TextSpan(0, 1, lookB)]) == marked)
        let answer = marked.replacingOccurrences(of: "and", with: "y")
        let (now, spans) = TranslationMarkup.read(answer, text, [TextSpan(0, 1, lookB)])
        #expect(now == text.replacingOccurrences(of: "and", with: "y"))
        #expect(spans == [TextSpan(0, 1, lookB)])
    }

    @Test func aParagraphWithTooManyLooksGoesPlainQuickly() {
        let text = Array(repeating: "word", count: 20_000).joined(separator: " ")
        let spans = (0..<20_000).map { TextSpan($0 * 5, 4, $0 % 2 == 0 ? lookB : lookI) }
        let start = threadSeconds()
        #expect(TranslationMarkup.mark(text, spans) == text)
        #expect(threadSeconds() - start < 1)
    }

    @Test func aMarkedTextAsksTheModelToKeepItsTagsAndAPlainOneDoesnt() {
        let marked = TranslationText.request(Self.source, "Spanish", marked: true)
        #expect(marked[0].content.contains("<b>"))
        #expect(marked[1].content == Self.source)
        #expect(!TranslationText.request("The quick brown fox.", "Spanish")[0].content.contains("<b>"))
    }

    // A real model told of a <font> it wasn't sent wrote <font color="#0000FF"> around a bold label.
    @Test(arguments: [
        ("The <b>quick</b> fox.", "<b> (bold)"),
        ("The <span>red</span> fox and <b>d<sub>model</sub></b>.", "<b> (bold), <span> (another font or color) and <sub> (subscript)"),
        ("A <font>blue</font>, a <span>red</span> and an <u>underlined</u> word.", "<u> (underlined) and <span>, <font> (each another font or color)"),
    ])
    func aMarkedTextsRequestNamesOnlyTheTagsItHas(_ text: String, _ named: String) {
        #expect(TranslationMarkup.tagsNamed(text) == named)
        let system = TranslationText.request(text, "French", marked: true)[0].content
        #expect(system.contains(named + ":"))
        for other in ["<i>", "<mark>", "<sup>"] { #expect(!system.contains(other)) }
    }

    @Test func aMarkedParagraphTooLongForOneRequestGoesInMarkedPiecesEachClosingItsTags() {
        let text = Array(repeating: "A <b>sentence of the long paragraph</b> goes here.", count: 200).joined(separator: " ")
        var plan = TranslationPlan(data: [], pages: [], texts: [(text, 0)])
        plan.marked = [text]
        let jobs = Translation.jobs(plan, Translation.pieceTokens(4096))
        #expect(jobs.count == 1)
        #expect(jobs[0].pieces.count > 1)
        #expect(jobs[0].marked)
        #expect(jobs[0].text == text)
        #expect(jobs[0].pieces.allSatisfy { $0.components(separatedBy: "<b>").count == $0.components(separatedBy: "</b>").count })
        #expect(TranslationMarkup.plain(text) == TranslationMarkup.plain(jobs[0].pieces.joined(separator: " ")))
        #expect(Translation.requests(jobs, "Spanish").allSatisfy { $0[0].content.contains("<b> (bold)") })
    }

    @Test func aMarkedParagraphsPiecesAnsweredWithTheirTagsGiveTheWholeItsLooks() {
        // Every tenth sentence bold, one bold stretch long enough that a piece may end inside it.
        let plain = (0..<200).map { "Sentence \($0) of the long paragraph goes on and on here." }.joined(separator: " ")
        let spans = (0..<200).filter { $0 % 10 == 0 }.map { span(plain, "Sentence \($0) of the long paragraph goes on and on here.", lookB) }
        let text = TranslationMarkup.mark(plain, spans)
        #expect(text != plain)
        var plan = TranslationPlan(data: [], pages: [], texts: [(text, 0)])
        plan.marked = [text]
        let job = Translation.jobs(plan, 200)[0]
        #expect(job.pieces.count > 3)
        #expect(job.marked)
        let answer = job.pieces.map { $0.replacingOccurrences(of: "goes on", with: "sigue") }.joined(separator: " ")
        let (now, looks) = TranslationMarkup.read(answer, plain, spans)
        #expect(now == plain.replacingOccurrences(of: "goes on", with: "sigue"))
        let ns = now as NSString
        #expect(looks.filter { ns.substring(with: NSRange(location: $0.start, length: $0.length)).hasPrefix("Sentence") }.count == 20)
        #expect(looks.allSatisfy { $0.look == lookB })
    }

    @Test func aStretchCutByManyPieceSeamsIsOneStretchAgainWhenTheAnswersAreJoined() {
        // Sentences 10 to 159 bold: one stretch, cut at each piece's end. Joined as they are, the answer would have far
        // more bold stretches than the paragraph had and be read plain.
        let plain = (0..<200).map { "Sentence \($0) of the long paragraph goes on and on here." }.joined(separator: " ")
        let ns = plain as NSString
        let start = ns.range(of: "Sentence 10 ").location
        let end = ns.range(of: "Sentence 160 ").location - 1
        let spans = [TextSpan(start, end - start, lookB)]
        let text = TranslationMarkup.mark(plain, spans)
        let pieces = TranslationMarkup.pieces(text, 200)!
        #expect(pieces.filter { $0.contains("</b>") }.count > 4)
        let (now, looks) = TranslationMarkup.read(TranslationMarkup.join(pieces), plain, spans)
        #expect(now == plain)
        #expect(looks == [TextSpan(start, end - start, lookB)])
        // A seam joins only tags that close and open the same looks in order.
        #expect(TranslationMarkup.join(["<b>a</b>", "<i>b</i>"]) == "<b>a</b> <i>b</i>")
        #expect(TranslationMarkup.join(["<b><i>a</i></b>", "<b><i>b</i></b>"]) == "<b><i>a b</i></b>")
    }

    static func cuttingHandler(_ sent: AiRecorder<String>) -> FakeAiHandler {
        FakeAiHandler { r, _ in
            let said = TranslationRunTests.userText(r)
            sent.add(said)
            if said.utf16.count > 300 { return FakeAiHandler.json(200, #"{"choices":[{"message":{"content":"Cortado"},"finish_reason":"length"}]}"#) }
            return FakeAiHandler.sse(said)
        }
    }

    static func translateCut(_ text: String, _ sent: AiRecorder<String>) async -> TranslationAnswers {
        let client = TranslationRunTests.client(cuttingHandler(sent))
        var settings = TranslationSettings()
        settings.retryWaits = [0]
        settings.replyDeadline = 45
        return await Translation.translate([TranslationJob(text, 0, [text], marked: true)], "Spanish",
                                           { m, t, c in try await client.chat(m, onText: t, cancel: c) }, settings: settings)
    }

    @Test func aMarkedTextCutOffByTheModelsLimitIsAskedForInMarkedHalves() async {
        let text = Array(repeating: "A <b>sentence</b> of the long paragraph goes here.", count: 8).joined(separator: " ")
        let sent = AiRecorder<String>()
        let a = await Self.translateCut(text, sent)
        #expect(sent.count > 2)
        // Each half carries its tags, closed in it, and the halves' answers joined are the whole's markup.
        #expect(sent.all.dropFirst().allSatisfy { $0.components(separatedBy: "<b>").count == $0.components(separatedBy: "</b>").count })
        #expect(sent.all.dropFirst().allSatisfy { $0.contains("<b>sentence</b>") })
        #expect(a.done[text] == text)
    }

    @Test func aMarkedTextCutOffWhereNoHalfCanCloseItsTagsIsAskedForInPlainHalves() async throws {
        // No space anywhere, and as many words as make the half end inside a tag.
        let text = try #require((25..<65).map { String(repeating: "Word<b>bold</b>", count: $0) }
            .first { TranslationMarkup.pieces($0, max(20, AiText.estimateTokens($0) / 2)) == nil })
        let sent = AiRecorder<String>()
        let a = await Self.translateCut(text, sent)
        #expect(sent.count > 2)
        #expect(sent.all.dropFirst().allSatisfy { !$0.contains("<") })
        #expect(a.done[text].map { !$0.contains("<") } == true)
    }

    @Test func aReplyKeepsTheMarkupItWasSentAndLosesAnyOtherTag() {
        let (text, problem) = TranslationText.cleanReply("Una <b>palabra</b> <span>y</span> <sub>otra</sub>", "A <b>word</b> and d<sub>another</sub>", marked: true)
        #expect(problem == nil)
        #expect(text == "Una <b>palabra</b> y <sub>otra</sub>")
    }

    @Test(arguments: [("∗ †", false), ("<b></b><sup>∗ †</sup>", true)])
    func aReplyWhoseWordsAreAllGoneIsNotUsed(_ reply: String, _ marked: Bool) {
        let source = marked ? "<b>Aidan N. Gomez</b><sup>∗ †</sup>" : "Aidan N. Gomez ∗ †"
        let (text, problem) = TranslationText.cleanReply(reply, source, marked: marked)
        #expect(text == nil)
        #expect(problem != nil)
    }

    @Test(arguments: [
        ("<bold>Información adicional</bold><i>(si aplica)</i>", "<b>Información adicional</b><i>(si aplica)</i>"), // a real model's, Spanish
        ("<strong>Información</strong> <em>adicional</em>", "<b>Información</b> <i>adicional</i>"),
        ("Información <em>adicional</em> <sup>2</sup>", "Información <i>adicional</i> 2"), // no <sup> was sent
    ])
    func aModelsOwnNamesForBoldAndItalicAreReadAsOurs(_ reply: String, _ cleaned: String) {
        let (text, problem) = TranslationText.cleanReply(reply, "<b>Additional Information </b><i>(if applicable)</i>", marked: true)
        #expect(problem == nil)
        #expect(text == cleaned)
    }

    @Test(arguments: [
        ("<Aidan N. Gomez></sup>∗ †", "<b>Aidan N. Gomez</b><sup>∗ †</sup>", "Aidan N. Gomez∗ †"), // a real model's bold name in brackets
        ("<Décodage :> Le décodeur est composé.", "<b>Decoder:</b> The decoder is composed.", "Décodage : Le décodeur est composé."),
        ("<Décodage :> Le décodeur est composé.", "Decoder: The decoder is composed.", "Décodage : Le décodeur est composé."), // sent without markup
        ("Voir <Annexe A>, page 3.", "See <b>Annex</b> A, page 3.", "Voir Annexe A, page 3."), // no space before its comma
        ("Voir<Annexe A>page 3.", "See <b>Annex</b> A, page 3.", "Voir Annexe A page 3."), // a space from the letters beside it
        ("<font color=\"#0000FF\">Informations</font> <bold>en plus</bold><br/>", "<b>More</b> information", "Informations en plus"), // tag-shaped: only the tags go
    ])
    func wordsAModelPutInAngleBracketsStayAndOnlyTagsGo(_ reply: String, _ source: String, _ written: String) {
        let marked = source.contains("<b>")
        let (text, problem) = TranslationText.cleanReply(reply, source, marked: marked)
        #expect(problem == nil)
        let plain = marked ? TranslationMarkup.plain(source) : source
        let spans = marked ? [TextSpan(0, (plain as NSString).range(of: " ").location, lookB)] : []
        #expect(TranslationMarkup.read(text ?? "", plain, spans).text == written)
    }

    @Test func aQuotedParagraphAllInItalicKeepsItsQuotes() {
        let (text, problem) = TranslationText.cleanReply("\"<i>Hola, amigo mío</i>\"", "<i>\"Hello, my friend\"</i>", marked: true)
        #expect(problem == nil)
        #expect(text == "\"<i>Hola, amigo mío</i>\"")
    }

    // ---- Markup back ----

    static let text = "The quick brown fox jumps over dmodel and the lazy dog."
    static let looks = [span(text, "brown", lookB), span(text, "model", lookSub)]

    @Test func theMarkupAModelKeepsComesBackAsLooks() {
        let (text, spans) = TranslationMarkup.read("El zorro <b>marrón</b> salta sobre d<sub>model</sub> y el perro.", Self.text, Self.looks)
        #expect(text == "El zorro marrón salta sobre dmodel y el perro.")
        #expect(spans == [span(text, "marrón", lookB), span(text, "model", lookSub)])
    }

    @Test func nestedLooksComeBackCombined() {
        let text = "An x2 and a bold italic word."
        let looks = [span(text, "bold ", lookB), span(text, "italic", TextLook(bold: true, italic: true)), TextSpan(3, 1, lookI), TextSpan(4, 1, lookSup)]
        let (now, spans) = TranslationMarkup.read("Una <i>x</i><sup>2</sup> y una palabra <b>negrita <i>cursiva</i></b>.", text, looks)
        #expect(now == "Una x2 y una palabra negrita cursiva.")
        #expect(spans == [TextSpan(4, 1, lookI), TextSpan(5, 1, lookSup), span(now, "negrita ", lookB), span(now, "cursiva", TextLook(bold: true, italic: true))])
    }

    @Test func aTagTheModelDroppedLeavesOnlyThatStretchPlain() {
        let (text, spans) = TranslationMarkup.read("El zorro marrón salta sobre d<sub>model</sub> y el perro.", Self.text, Self.looks)
        #expect(text == "El zorro marrón salta sobre dmodel y el perro.")
        #expect(spans == [span(text, "model", lookSub)])
    }

    @Test func anEmptyTagAndSpacesAroundTagsLeaveOneSpace() {
        let (text, spans) = TranslationMarkup.read("El zorro <b> </b> <b>marrón </b> salta.", Self.text, Self.looks)
        #expect(text == "El zorro marrón salta.")
        #expect(spans == [span(text, "marrón ", lookB)])
    }

    @Test(arguments: [
        "El zorro <b>marrón salta sobre dmodel y el perro.", // never closed
        "El zorro marrón</b> salta sobre dmodel y el perro.", // never opened
        "El zorro <b>marrón <sub>salta</b> sobre</sub> dmodel.", // crossed
        "El zorro <b><b>marrón</b></b> salta.", // inside itself
        "El <i>zorro</i> marrón salta.", // invented: the source had no italic
        "El zorro marrón salta sobre d<sup>model</sup>.", // a subscript moved up
        "El zorro marrón salta sobre d<sub>mo<sup>d</sup>el</sub>.", // one inside the other
        "<b>El zorro marrón salta sobre dmodel y el perro perezoso, hasta que el perro se cansa.</b>", // the whole paragraph bold
        "El zorro marrón salta sobre d<sub>model y el perro perezoso hasta</sub>.", // a subscript far longer than it was
        "El zorro <span>marrón</span> salta.", // another tag
        "El zorro <b class=x>marrón</b> salta.", // a tag with more in it
        "El zorro <b>marrón</b> salta <b sobre dmodel.", // a tag cut short
        "El zorro <B>marrón</b> salta sobre <sub>dmodel.",
    ])
    func markupThatCantBeTrustedLeavesTheParagraphPlainWithNoTagText(_ reply: String) {
        let (text, spans) = TranslationMarkup.read(reply, Self.text, Self.looks)
        #expect(spans.isEmpty)
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(text.range(of: "sub", options: .caseInsensitive) == nil)
        #expect(!text.contains("span"))
        #expect(!text.contains("  "))
        #expect(text.contains("zorro"))
    }

    @Test(arguments: [
        ("El <b>negrita/b> palabra.", "El negrita palabra."),
        ("El zorro x /sub> y el perro.", "El zorro x y el perro."),
        ("El zorro word i> next.", "El zorro word next."),
        ("El zorro <b>marrón</b> salta sobre d<sub>model/SUB > y el perro.", "El zorro marrón salta sobre dmodel y el perro."),
        ("El zorro < sup>marrón</b salta.", "El zorro marrón salta."),
    ])
    func everyBrokenPieceOfOurTagsIsTakenOut(_ reply: String, _ plain: String) {
        let (text, spans) = TranslationMarkup.read(reply, Self.text, Self.looks)
        #expect(text == plain)
        #expect(spans.isEmpty)
    }

    @Test func anArrowOrAComparisonInAReplyStaysAsTextAndTheLooksAreKept() {
        let (text, spans) = TranslationMarkup.read("El zorro -> <b>marrón</b> salta sobre d<sub>model</sub> y x < y >= 2.", Self.text, Self.looks)
        #expect(text == "El zorro -> marrón salta sobre dmodel y x < y >= 2.")
        #expect(spans == [span(text, "marrón", lookB), span(text, "model", lookSub)])
    }

    @Test(arguments: ["i > 0", "b >= a", "i>0 y sub>2"])
    func aComparisonAfterALoneBOrIStaysAsTextAndTheLooksAreKept(_ comparison: String) {
        let (text, spans) = TranslationMarkup.read("El zorro <b>marrón</b> salta sobre d<sub>model</sub> si \(comparison).", Self.text, Self.looks)
        #expect(text == "El zorro marrón salta sobre dmodel si \(comparison).")
        #expect(spans == [span(text, "marrón", lookB), span(text, "model", lookSub)])
    }

    @Test func anArrowInAReplyWhoseMarkupCantBeTrustedStaysAsText() {
        let (text, spans) = TranslationMarkup.read("El zorro -> <b>marrón salta <span>sobre</span> a <= b.", Self.text, Self.looks)
        #expect(text == "El zorro -> marrón salta sobre a <= b.")
        #expect(spans.isEmpty)
    }

    @Test(arguments: ["El zorro <script>marrón</script> salta.", "El zorro <!-- marrón --> salta.", "El zorro <b>marrón</b> <a href=x>salta</a>."])
    func anotherTagBesideBareBracketsStillNeverReachesThePage(_ reply: String) {
        let (text, spans) = TranslationMarkup.read(reply, Self.text, Self.looks)
        #expect(spans.isEmpty)
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(text.contains("zorro"))
    }

    @Test func tagsInAReplyToAParagraphSentWithoutMarkupNeverReachThePage() {
        let (text, spans) = TranslationMarkup.read("El <b>zorro</b> <sub>marrón</sub>.", "The brown fox.", [])
        #expect(text == "El zorro marrón.")
        #expect(spans.isEmpty)
    }

    @Test func aReplyToTextWithAngleBracketsOfItsOwnIsLeftAsItIs() {
        let (text, spans) = TranslationMarkup.read("a < b y <b>c</b>", "a < b and <b>c</b>", [])
        #expect(text == "a < b y <b>c</b>")
        #expect(spans.isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func aCraftedReplyFullOfTagsIsReadQuicklyAndLeftPlain(_ kind: Int) {
        let reply = kind == 0 ? String(repeating: "<b>", count: 400_000) + "zorro"
            : kind == 1 ? String(repeating: "<b>x</b> ", count: 200_000)
            : String(repeating: "<b", count: 400_000) + String(repeating: "</sub>", count: 100_000)
        let start = threadSeconds()
        let (text, spans) = TranslationMarkup.read(reply, Self.text, Self.looks)
        #expect(threadSeconds() - start < 2)
        #expect(spans.isEmpty)
        #expect(!text.contains("<"))
    }
}

/// Windows' `TranslationMarkupHostileTests`: Translate's looks markup against crafted pages and crafted replies (the
/// hostile-input review before 1.10): no tag of ours reaches a page, and marking or reading stays linear.
@Suite(.serialized) struct TranslationMarkupHostileTests {
    static let ourTag = try! NSRegularExpression(pattern: #"<\s*/?\s*(?:b|i|span|sub|sup)\s*>"#, options: .caseInsensitive)

    static func hasOurTag(_ s: String) -> Bool { ourTag.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

    @Test(arguments: [false, true])
    func randomRepliesNeverLeaveATagOfOursInTheText(_ boldParagraph: Bool) {
        let text = "The quick brown fox jumps over d model and the lazy dog."
        // A regular word in a bold paragraph is marked the other way round: its bold around the rest.
        let face = boldParagraph ? TextLook(bold: false) : lookB
        let spans = [TextSpan(10, 5, face), TextSpan(33, 5, lookSub), TextSpan(43, 3, lookI), TextSpan(20, 5, TextLook(color: 0xFF0000))]
        let bits = ["<", ">", "/", "b", "i", "sub", "sup", "span", " ", "x", "<b>", "</b>", "<i>", "</i>", "<sub>", "</sub>", "<sup>", "</sup>",
                    "<span>", "</span>", "B", "!", "=", "1"]
        var random = Seeded(1234)
        for _ in 0..<50_000 {
            var reply = ""
            for _ in 0..<random.int(1..<14) { reply += bits[random.int(0..<bits.count)] }
            let (got, _) = TranslationMarkup.read(reply, text, spans)
            #expect(!Self.hasOurTag(got), "\(reply) -> \(got)")
            if Self.hasOurTag(got) { break }
        }
    }

    @Test func aHugeParagraphWithBracketsOfItsOwnIsCheckedQuickly() {
        // Whether its own brackets could be read as tags is one pass over it, however many there are.
        let text = String(repeating: "a < 0.5 -> c ", count: 150_000)
        let start = threadSeconds()
        let marked = TranslationMarkup.mark(text, [TextSpan(0, 1, lookB)])
        // 1.5 s on Windows' release build; swift test builds for debug (see aHugeParagraphWithManyLooksIsMarkedQuickly).
        #expect(threadSeconds() - start < 6, "\(threadSeconds() - start) s")
        #expect(marked.hasPrefix("<b>a</b> < 0.5"))
    }

    @Test func piecesOfMarkedTextEachCloseTheirTagsAndACutInsideATagGivesNone() throws {
        let text = Array(repeating: "A <b>long bold stretch of words</b> and <sup>2</sup> more.", count: 60).joined(separator: " ")
        let pieces = try #require(TranslationMarkup.pieces(text, 60))
        #expect(pieces.count > 3)
        // Each piece is markup of its own, and the pieces together say what the whole did.
        #expect(pieces.allSatisfy { $0.components(separatedBy: "<b>").count == $0.components(separatedBy: "</b>").count })
        #expect(TranslationMarkup.plain(text) == TranslationMarkup.plain(pieces.joined(separator: " ")))
        // No space to cut at: a cut lands inside a tag, and the text goes in plain pieces instead.
        #expect(TranslationMarkup.pieces(String(repeating: "<b>x</b><sub>y</sub>", count: 200), 20) == nil)
    }

    @Test func aHugeParagraphWithManyLooksIsMarkedQuickly() {
        // A crafted page: one paragraph of 4 million characters, 256 looks over all of it.
        let text = String(repeating: "a", count: 4_000_000)
        let spans = (0..<256).map { TextSpan(0, 4_000_000, $0 % 3 == 0 ? lookSub : $0 % 3 == 1 ? lookB : lookI) }
        let start = threadSeconds()
        _ = TranslationMarkup.mark(text, spans)
        // 750 ms on Windows, whose tests run a release build; swift test builds for debug, where copying 4 million
        // characters to UTF-16 and back alone takes about a second (2 s alone, 3.5 s beside the other suites).
        // Quadratic work would take hours.
        #expect(threadSeconds() - start < 6, "\(threadSeconds() - start) s")
    }

    @Test func overlappingLooksAreMarkedAsTheyLayOverEachOther() {
        // Bold and italic where any span gives them, the latest span's script: the same markup as the looks laid out one by one.
        let looks = [lookB, lookI, lookSub, lookSup, TextLook(bold: true, script: .sub), TextLook(italic: true, script: .superscript), TextLook(color: 0xFF0000)]
        var random = Seeded(77)
        for _ in 0..<5_000 {
            let text = String(repeating: "a", count: random.int(1..<40))
            var spans: [TextSpan] = []
            for _ in 0..<random.int(1..<6) {
                spans.append(TextSpan(random.int(-3..<(text.count + 3)), random.int(0..<20), looks[random.int(0..<looks.count)]))
            }
            let one = TranslationMarkup.mark(text, Self.oneByOne(text.count, spans)), all = TranslationMarkup.mark(text, spans)
            #expect(one == all)
            if one != all { break }
        }
    }

    /// The spans' looks laid over each other character by character, as disjoint spans.
    static func oneByOne(_ length: Int, _ spans: [TextSpan]) -> [TextSpan] {
        struct At: Equatable {
            var bold = false, italic = false, other = false
            var script: TextScript?
        }
        var at = [At](repeating: At(), count: length)
        for s in spans {
            var i = max(0, s.start)
            while i < min(length, s.end) {
                at[i] = At(bold: at[i].bold || s.look.bold == true, italic: at[i].italic || s.look.italic == true, other: at[i].other || s.look.color != nil,
                           script: s.look.script ?? at[i].script)
                i += 1
            }
        }
        var result: [TextSpan] = []
        var i = 0
        while i < length {
            var j = i + 1
            while j < length && at[j] == at[i] { j += 1 }
            let a = at[i]
            if a.bold || a.italic || a.other || a.script != nil {
                result.append(TextSpan(i, j - i, TextLook(color: a.other ? 0xFF0000 : nil, bold: a.bold ? true : nil, italic: a.italic ? true : nil, script: a.script)))
            }
            i = j
        }
        return result
    }

    @Test(arguments: ["<b ", "</", "< / ", "b> ", "<b>x</b> ", "<<b>b> "])
    func aLongReplyOfTagPiecesIsReadQuickly(_ unit: String) {
        // The longest answer a 100,000-character paragraph may get (400 + 12 × its length).
        let reply = String(repeating: unit, count: 1_200_000 / unit.count + 1)
        let text = "word " + String(repeating: "x", count: 100)
        let start = threadSeconds()
        let (got, _) = TranslationMarkup.read(reply, text, [TextSpan(0, 4, lookB)])
        // 1.5 s on Windows' release build; a debug build here, beside the other suites (3 s seen). Quadratic: hours.
        #expect(threadSeconds() - start < 5, "\(threadSeconds() - start) s")
        #expect(!Self.hasOurTag(got))
    }
}
