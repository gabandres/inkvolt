import Foundation
import Testing
@testable import PdfCore

/// The Mac UX review's rules (a Mac addition, no Windows counterpart): the accessibility audit's naming rule and the
/// document window's toolbar defaults.
struct UxRulesTests {
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

    @Test func The_default_toolbar_is_the_command_bar_and_every_item_is_allowed() {
        // The sidebar, the command bar's eight groups (the pointer tools and seven split items), Search.
        let items = ToolbarLayout.defaults.filter {
            ![ToolbarLayout.flexibleSpace, ToolbarLayout.space, ToolbarLayout.trackingSeparator].contains($0)
        }
        #expect(items.count == 10)
        #expect(ToolbarLayout.groups.compactMap(ToolbarLayout.groupId) == CommandBar.groups.map(\.id))
        #expect(Set(ToolbarLayout.defaults).isSubset(of: Set(ToolbarLayout.allowed)))
        #expect(ToolbarLayout.defaults.first == ToolbarLayout.sidebar)
        #expect(ToolbarLayout.defaults.last == ToolbarLayout.search) // search on the trailing edge (HIG)
    }

    @Test func Every_toolbar_item_is_also_in_a_menu() {
        let items = ToolbarLayout.allowed.filter {
            ![ToolbarLayout.flexibleSpace, ToolbarLayout.space, ToolbarLayout.trackingSeparator].contains($0)
        }
        #expect(items.allSatisfy(ToolbarLayout.menuEquivalentExists(for:)))
        #expect(Set(ToolbarLayout.allowed).count == ToolbarLayout.allowed.count)
    }
}
