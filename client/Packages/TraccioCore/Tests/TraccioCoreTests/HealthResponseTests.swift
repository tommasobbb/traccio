import Foundation
import Testing

@testable import TraccioCore

struct HealthResponseTests {
    @Test func decodesStatusAndVersion() throws {
        let json = """
            { "status": "ok", "version": "0.1.0" }
            """
        let health = try TraccioCore.jsonDecoder().decode(
            HealthResponse.self,
            from: Data(json.utf8)
        )
        #expect(health.status == "ok")
        #expect(health.version == "0.1.0")
    }
}
