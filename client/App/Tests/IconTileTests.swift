import Foundation
import Testing
import TraccioCore

@testable import Traccio

/// Tests for the client-only icon presentation layer (`IconTile.swift`).
///
/// The `systemImageName` switches are exhaustive, so a missing mapping is a
/// compile error — no test needed for that. What a test *does* guard is that
/// the sectioned picker (`CategoryIcon.pickerSections`) covers every icon
/// exactly once, since a case left out of a section would silently vanish
/// from the picker.
struct IconTileTests {
    @Test func everyCategoryIconAppearsInExactlyOnePickerSection() {
        let sectioned = CategoryIcon.pickerSections.flatMap(\.icons)
        #expect(Set(sectioned) == Set(CategoryIcon.allCases))
        #expect(sectioned.count == CategoryIcon.allCases.count)  // no duplicates
    }

    @Test func everyCategoryIconMapsToANonEmptySymbol() {
        for icon in CategoryIcon.allCases {
            #expect(!icon.systemImageName.isEmpty)
        }
    }

    @Test func everyAccountIconMapsToANonEmptySymbol() {
        for icon in AccountIcon.allCases {
            #expect(!icon.systemImageName.isEmpty)
        }
    }
}
