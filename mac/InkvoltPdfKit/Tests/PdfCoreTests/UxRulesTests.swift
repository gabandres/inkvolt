import Foundation
import Testing
@testable import PdfCore

/// The Mac UX review's rules (a Mac addition, no Windows counterpart): the document window's toolbar defaults. The
/// accessibility audit's rules are PrintCore's `AxAudit` (`AxAuditTests`).
struct UxRulesTests {
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
