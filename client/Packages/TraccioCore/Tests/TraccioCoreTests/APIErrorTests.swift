import Foundation
import Testing

@testable import TraccioCore

struct APIErrorTests {
    @Test func isCancellationIsTrueForAWrappedURLErrorCancelled() {
        let error = APIError.transport(underlying: URLError(.cancelled))
        #expect(error.isCancellation)
    }

    @Test func isCancellationIsTrueForAWrappedCancellationError() {
        let error = APIError.transport(underlying: CancellationError())
        #expect(error.isCancellation)
    }

    @Test func isCancellationIsFalseForAnyOtherTransportFailure() {
        let error = APIError.transport(underlying: URLError(.notConnectedToInternet))
        #expect(!error.isCancellation)
    }

    @Test func isCancellationIsFalseForNonTransportCases() {
        #expect(!APIError.badStatus(500).isCancellation)
        #expect(!APIError.unauthorized.isCancellation)
        #expect(!APIError.notHTTP.isCancellation)
        #expect(!APIError.invalidURL.isCancellation)
    }

    @Test func isCancellationErrorRecognizesAPlainCancellationError() {
        let error: any Error = CancellationError()
        #expect(error.isCancellationError)
    }

    @Test func isCancellationErrorRecognizesAWrappedAPIError() {
        let error: any Error = APIError.transport(underlying: URLError(.cancelled))
        #expect(error.isCancellationError)
    }

    @Test func isCancellationErrorIsFalseForAnUnrelatedError() {
        let error: any Error = APIError.badStatus(404)
        #expect(!error.isCancellationError)
    }
}
