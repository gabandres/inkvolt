import Foundation
import Testing
@testable import PdfCore

extension ProGated {
    /// Ported from FieldLockTests.cs: certifying with a choice of fields to lock (FieldMDP): the dictionaries as ISO 32000-1
    /// has them (Tables 233, 253, 254, 256), and the verifier holding a later change to them. In the Pro suites: ProTests
    /// turns `Pro.enforced` on meanwhile, and signing with a lock asks it. Adapted: the dictionaries are read with MuPDF
    /// (PDFsharp on Windows), so the lock's being indirect is read from the update's bytes.
    @Suite struct FieldLockTests {
        /// A form with text fields Name, City and Notes, filled in, and no signature yet.
        static func form() throws -> [UInt8] {
            try FormEditor.setValues(Core2Pdf.form([
                "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 600 300 630] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
                "<< /Type /Annot /Subtype /Widget /FT /Tx /T (City) /Rect [72 550 300 580] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
                "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Notes) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            ]), nil, ["Name": "Ada", "City": "Ponce", "Notes": "none"])
        }

        private static func certify(_ form: [UInt8], _ lock: FieldLock?) async throws -> [UInt8] {
            try await SigningTests.sign(form, try SigningTests.rsaId()) {
                $0.certify = .formFilling
                $0.lock = lock
            }
        }

        /// The file with field `name`'s value changed in a later incremental update, as another tool would.
        private static func change(_ pdf: [UInt8], _ name: String, _ value: String) throws -> [UInt8] {
            let doc = try Core2Pdf.open(pdf)
            let n = try #require((1..<doc.objectCount).last { doc.object($0).isDict && doc.object($0).text("T") == name })
            let original = try SignatureChangeTests.body(pdf, n)
            let re = try NSRegularExpression(pattern: #"/V\s*(\([^)]*\)|<[^>]*>)"#)
            let body = re.stringByReplacingMatches(in: original, range: NSRange(location: 0, length: (original as NSString).length), withTemplate: "/V (\(value))")
            return SignatureChangeTests.append(pdf, [n: body])
        }

        private static func certification(_ pdf: [UInt8]) throws -> SignatureInfo {
            try #require(Signatures.verify(pdf).first { $0.certificationLevel != nil })
        }

        @Test func theDictionariesAreAsIso32000HasThem() async throws {
            let form = try Self.form()
            let signed = try await Self.certify(form, FieldLock(.include, ["Name", "City"]))
            let update = latin1(Array(signed[form.count...]))

            // Table 253: a DocMDP reference first, then a FieldMDP one with /Data (the catalog: required for FieldMDP in PDF 1.x).
            let doc = try Core2Pdf.open(signed)
            let catalog = doc.catalog
            let sig = try #require(catalog.dict("Perms")?.dict("DocMDP"))
            let refs = try #require(sig.array("Reference")).elements
            #expect(refs.map { $0.name("TransformMethod") } == ["DocMDP", "FieldMDP"])
            for r in refs { #expect(r.name("Type") == "SigRef") }
            #expect(refs[1]["Data"]?.isRef == true && refs[1]["Data"]?.num == doc.trailer["Root"]?.num)
            #expect(refs[0]["Data"] == nil)
            // Table 254: DocMDP's parameters, P 2 and V /1.2.
            let docMdp = try #require(refs[0].dict("TransformParams"))
            #expect(docMdp.name("Type") == "TransformParams" && docMdp.int("P") == 2 && docMdp.name("V") == "1.2")
            // Table 256: FieldMDP's parameters, /Action, /Fields as text strings, V /1.2.
            let fieldMdp = try #require(refs[1].dict("TransformParams"))
            #expect(fieldMdp.name("Type") == "TransformParams" && fieldMdp.name("Action") == "Include" && fieldMdp.name("V") == "1.2")
            #expect(fieldMdp.array("Fields")?.elements.compactMap(\.text) == ["Name", "City"])
            // Table 233: the signature field's /Lock says the same, as a /SigFieldLock (indirect, as the table requires).
            let sigField: PObj? = (1..<doc.objectCount).lazy.map { doc.object($0) }.first { $0.isDict && $0.name("FT") == "Sig" }
            let field = try #require(sigField)
            #expect(field["Lock"]?.isRef == true)
            let lockDict = try #require(field.dict("Lock"))
            #expect(lockDict.name("Type") == "SigFieldLock" && lockDict.name("Action") == "Include")
            #expect(lockDict.array("Fields")?.elements.compactMap(\.text) == ["Name", "City"])
            // As bytes: the names as names.
            #expect(update.range(of: #"/TransformMethod\s*/FieldMDP"#, options: .regularExpression) != nil)
            #expect(update.range(of: #"/Action\s*/Include"#, options: .regularExpression) != nil)
            #expect(update.range(of: #"/Type\s*/SigFieldLock"#, options: .regularExpression) != nil)

            // All: no /Fields (Table 256: required only for Include and Exclude).
            let all = try Core2Pdf.open(try await Self.certify(try Self.form(), .allFields))
            var references: [PObj] = []
            for n in 1..<all.objectCount where all.object(n).isDict {
                references += all.object(n).array("Reference")?.elements ?? []
            }
            let allRef = try #require(references.first { $0.name("TransformMethod") == "FieldMDP" })
            let p = try #require(allRef.dict("TransformParams"))
            #expect(p.name("Action") == "All")
            #expect(p["Fields"] == nil)
        }

        @Test func aChangeToALockedFieldIsNotAllowedAndToAnOpenOneItIs() async throws {
            // These fields: Name locked, City open.
            let these = try await Self.certify(try Self.form(), FieldLock(.include, ["Name"]))
            #expect(try Self.certification(these).status == .valid)
            let widgets = try FormEditor.read(these, nil)
            #expect(widgets.first { $0.fieldName == "Name" }?.readOnly == true)
            #expect(widgets.first { $0.fieldName == "City" }?.readOnly == false)
            #expect(try Self.certification(try Self.change(these, "City", "Mayaguez")).status == .modifiedAfterSigning)
            let s = try Self.certification(try Self.change(these, "Name", "Eve"))
            #expect(s.status == .disallowedChanges)
            #expect(s.detail?.contains("locked field \"Name\"") == true, "\(s.detail ?? "")")

            // All but these: Notes open, the others locked.
            let allBut = try await Self.certify(try Self.form(), FieldLock(.exclude, ["Notes"]))
            #expect(try Self.certification(try Self.change(allBut, "Notes", "late")).status == .modifiedAfterSigning)
            #expect(try Self.certification(try Self.change(allBut, "City", "Mayaguez")).detail?.contains("locked field \"City\"") == true)

            // All of them.
            let all = try await Self.certify(try Self.form(), .allFields)
            for w in try FormEditor.read(all, nil) where w.kind == .text { #expect(w.readOnly) }
            #expect(try Self.certification(try Self.change(all, "Notes", "late")).status == .disallowedChanges)

            // No lock: filling in after a form-filling certification stays allowed.
            #expect(try Self.certification(try Self.change(try await Self.certify(try Self.form(), nil), "Name", "Eve")).status == .modifiedAfterSigning)
        }

        @Test func aLockNeedsFieldsThatAreThere() async throws {
            let form = try Self.form()
            do {
                _ = try await Self.certify(form, FieldLock(.include, []))
                Issue.record("no fields: refused")
            } catch let e as SigningError {
                #expect(e.message.contains("at least one field"))
            }
            do {
                _ = try await Self.certify(form, FieldLock(.exclude, ["Nmae"]))
                Issue.record("a field that isn't there: refused")
            } catch let e as SigningError {
                #expect(e.message.contains("\"Nmae\""))
            }
        }

        @Test func theDialogsChoicesMakeTheLocks() {
            #expect(FieldLocks.choices.count == 4)
            #expect(FieldLocks.from(0, ["Name"]) == nil)
            #expect(FieldLocks.from(1, [])?.action == .all)
            #expect(FieldLocks.from(2, ["Name"])?.fields == ["Name"])
            #expect(FieldLocks.from(3, ["Notes"])?.action == .exclude)
            for i in 0..<4 { #expect(!FieldLocks.note(i).trimmingCharacters(in: .whitespaces).isEmpty) }
            #expect(Pro.locked(.fieldLocking).lowercased().contains("lock"))
            #expect(!Pro.describe(.fieldLocking).isEmpty)
            #expect(Pro.allows(.fieldLocking)) // the gate stays off, as for the other Pro features
        }
    }
}
