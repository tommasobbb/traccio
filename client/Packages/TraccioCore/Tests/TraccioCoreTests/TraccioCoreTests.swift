import Testing

@testable import TraccioCore

/// Smoke test proving the package builds, links, and tests from the CLI.
///
/// Replaced by real model/decoding tests once TraccioCore gains content
/// generated from the OpenAPI schema.
@Test func exposesVersion() {
    #expect(!TraccioCore.version.isEmpty)
}
