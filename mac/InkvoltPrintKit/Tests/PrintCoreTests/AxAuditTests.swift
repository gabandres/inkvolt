import Foundation
import Testing
@testable import PrintCore

/// Both Mac apps' accessibility audit (a Mac addition, no Windows counterpart; moved here from PdfCore's `UxRulesTests`
/// with its first tests, so Inkvolt Print's audit shares them): naming, pictures, values, raw keys and code, English in a
/// Spanish window, a dialog's title and the Tab order.
struct AxAuditTests {
    @Test func A_button_with_a_label_or_a_title_passes() {
        #expect(AxAudit.problem(role: "AXButton", label: "Zoom In", title: nil) == nil)
        #expect(AxAudit.problem(role: "AXButton", label: nil, title: "Open a file") == nil)
        #expect(AxAudit.problem(role: "AXPopUpButton", label: "  ", title: "Fit width") == nil)
    }

    @Test func A_control_without_a_name_fails() {
        #expect(AxAudit.problem(role: "AXButton", label: nil, title: nil) == "no name")
        #expect(AxAudit.problem(role: "AXPopUpButton", label: " \n", title: "") == "no name")
        #expect(AxAudit.problem(role: "AXSegmentedControl", label: nil, title: nil) == "no name")
    }

    @Test func A_field_named_only_by_its_placeholder_fails_with_its_reason() {
        let why = AxAudit.problem(role: "AXTextField", label: nil, title: nil, placeholder: "Find in document")
        #expect(why?.contains("placeholder") == true)
        // A placeholder doesn't name a button.
        #expect(AxAudit.problem(role: "AXButton", label: nil, title: nil, placeholder: "x") == "no name")
    }

    @Test func Text_and_groups_are_not_audited() {
        #expect(AxAudit.problem(role: "AXStaticText", label: nil, title: nil) == nil)
        #expect(AxAudit.problem(role: "AXGroup", label: nil, title: nil) == nil)
        #expect(AxAudit.problem(role: "AXImage", label: nil, title: nil) == nil)
    }

    @Test func A_label_beside_a_control_names_it() {
        #expect(AxAudit.labelName("Save to folder:") == "Save to folder")
        #expect(AxAudit.labelName("  Pages: ") == "Pages")
        #expect(AxAudit.labelName("Left") == "Left")
    }

    @Test func A_sentence_or_nothing_is_not_a_label() {
        #expect(AxAudit.labelName("") == nil)
        #expect(AxAudit.labelName(" : ") == nil)
        #expect(AxAudit.labelName("Pages that already have text are skipped.") == nil)
        #expect(AxAudit.labelName("One file per range, separated by semicolons and other words") == nil)
    }

    @Test func A_picture_VoiceOver_stops_on_must_say_what_it_shows() {
        #expect(AxAudit.imageProblem(role: "AXImage", label: nil, title: " ") != nil)
        #expect(AxAudit.imageProblem(role: "AXImage", label: "Page 3", title: nil) == nil)
        #expect(AxAudit.imageProblem(role: "AXButton", label: nil, title: nil) == nil)
    }

    @Test func A_slider_stepper_or_progress_bar_says_its_value() {
        #expect(AxAudit.valueProblem(role: "AXSlider", value: nil) != nil)
        #expect(AxAudit.valueProblem(role: "AXProgressIndicator", value: "") != nil)
        #expect(AxAudit.valueProblem(role: "AXIncrementor", value: "3") == nil)
        #expect(AxAudit.valueProblem(role: "AXLevelIndicator", value: "0.4") == nil)
        #expect(AxAudit.valueProblem(role: "AXButton", value: nil) == nil)
    }

    @Test func A_raw_key_or_code_is_not_a_name() {
        #expect(AxAudit.rawText("Page {0} of {1}") != nil)
        #expect(AxAudit.rawText("Saved %@") != nil)
        #expect(AxAudit.rawText("%lld pages") != nil)
        #expect(AxAudit.rawText("Black [ink]") != nil)
        #expect(AxAudit.rawText("square.and.arrow.up") != nil)
        #expect(AxAudit.rawText("aiSettings") != nil)
        #expect(AxAudit.rawText("scan_backs") != nil)
    }

    @Test func Words_numbers_and_file_names_are_not_code() {
        for words in ["Scan the Backs", "Página 3 de 10", "80 %", "1.4.0", "first.pdf", "Synthetic.pdf", "Zoom", "OK", "{ }",
                      "Usar la página [3]", "e.g. one", "printer.local", "iPhone", "macOS", "eSCL",
                      #"For example CASE-\d{4} finds CASE-0412"#, "[0-9]{2} digits"] {
            #expect(AxAudit.rawText(words) == nil, "\(words)")
        }
        // A static text may show a host's or a file's name.
        #expect(AxAudit.rawText("office.printer", isName: false) == nil)
        #expect(AxAudit.rawText("Page {0}", isName: false) != nil)
    }

    @Test func English_in_a_Spanish_window_is_found_whole_or_in_part() {
        let spanish = ["Scan the Backs": "Escanear los reversos", "Copies:": "Copias:", "Cancel": "Cancelar", "PDF": "PDF",
                       "Pages": "Páginas"]
        #expect(AxAudit.english("Scan the Backs", spanish: spanish)?.contains("Escanear") == true)
        #expect(AxAudit.english("Copies", spanish: spanish) != nil) // the label's name without its colon
        #expect(AxAudit.english("Pages: 3", spanish: spanish) != nil)
        #expect(AxAudit.english("Escanear los reversos", spanish: spanish) == nil)
        #expect(AxAudit.english("PDF", spanish: spanish) == nil) // the same in both
        #expect(AxAudit.english("Synthetic.pdf", spanish: spanish) == nil)
        #expect(AxAudit.english("Scan the Backs", spanish: [:]) == nil) // English: nothing to compare
    }

    @Test func A_dialog_is_titled_by_its_title_label_or_first_words() {
        #expect(AxAudit.dialogTitle(title: "Resize Pages", label: nil, heading: nil) == "Resize Pages")
        #expect(AxAudit.dialogTitle(title: "", label: nil, heading: " No blank pages ") == "No blank pages")
        #expect(AxAudit.dialogTitle(title: nil, label: " ", heading: nil) == nil)
        // An alert's window is labelled "alert" (its kind): its message names it.
        #expect(AxAudit.dialogTitle(title: "", label: "alert", heading: "Interleave Pages") == "Interleave Pages")
    }

    @Test func Tab_order_that_reads_down_or_by_columns_passes_and_a_jump_back_up_is_found() {
        func box(_ x: Double, _ y: Double, _ w: Double = 100) -> AxAudit.Box { AxAudit.Box(x: x, y: y, width: w, height: 22) }
        // A form's rows, each a label's field then a check box beside it, then the buttons.
        #expect(AxAudit.backwardSteps([box(120, 20), box(240, 20), box(120, 50), box(120, 80), box(300, 140, 80), box(390, 140, 80)]).isEmpty)
        // Down one column, then up to the top of the next.
        #expect(AxAudit.backwardSteps([box(20, 20), box(20, 50), box(20, 80), box(200, 20), box(200, 50)]).isEmpty)
        // The second row's field before the first's: one step back up.
        #expect(AxAudit.backwardSteps([box(120, 50), box(120, 20), box(120, 80)]) == [1])
        // The loop closing (the last stop back to the first) isn't a step of the order.
        #expect(AxAudit.backwardSteps([box(20, 20), box(20, 50), box(20, 80)]).isEmpty)
    }

    @Test func Stops_Tab_never_reaches_are_named_in_order() {
        #expect(AxAudit.unreached(["a", "b", "c", "d"], ["a", "c", "a"]) == ["b", "d"])
        #expect(AxAudit.unreached(["a"], ["a"]).isEmpty)
    }
}
