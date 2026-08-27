import Foundation
import Testing

@testable import TraccioCore

/// Tests for `TraccioCore.institutionLogoURL(_:width:scale:)` — appends the
/// uploadcare-style resize transform to a bank logo URL.
struct InstitutionLogoTests {
    @Test func appendsAResizeTransformScaledByTheDisplayScale() {
        let url = TraccioCore.institutionLogoURL(
            "https://enablebanking.com/brands/IT/Revolut/", width: 40, scale: 3
        )
        #expect(url?.absoluteString == "https://enablebanking.com/brands/IT/Revolut/-/resize/120x/")
    }

    @Test func insertsASlashWhenTheBaseDoesNotEndWithOne() {
        let url = TraccioCore.institutionLogoURL(
            "https://logos.example.test/tb01", width: 10, scale: 1
        )
        #expect(url?.absoluteString == "https://logos.example.test/tb01/-/resize/10x/")
    }

    @Test func clampsScaleAndWidthToAtLeastOnePixel() {
        let url = TraccioCore.institutionLogoURL(
            "https://logos.example.test/x/", width: 0, scale: 0
        )
        #expect(url?.absoluteString == "https://logos.example.test/x/-/resize/1x/")
    }

    @Test func returnsNilForNilBlankOrNonHTTPInput() {
        #expect(TraccioCore.institutionLogoURL(nil, width: 40) == nil)
        #expect(TraccioCore.institutionLogoURL("   ", width: 40) == nil)
        #expect(TraccioCore.institutionLogoURL("ftp://x/logo", width: 40) == nil)
        #expect(TraccioCore.institutionLogoURL("/relative/path", width: 40) == nil)
    }
}
