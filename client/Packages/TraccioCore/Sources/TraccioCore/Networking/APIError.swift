import Foundation

/// An error raised while talking to the backend.
///
/// The cases carry only non-sensitive context: a status code, or an underlying
/// system/decoding error. No response body and no financial data ever enter an
/// `APIError` — a bank response body must never reach a log or an error message
/// (see `.claude/rules/data-safety.md`). In particular the transport and
/// decoding cases wrap the framework error, never the payload that produced it.
public enum APIError: Error, Sendable {
    /// The request never produced an HTTP response (offline, DNS, TLS, …).
    case transport(underlying: any Error)
    /// The server answered with a non-2xx status. Carries the code only.
    case badStatus(Int)
    /// The response was received but could not be decoded into the model.
    case decoding(underlying: any Error)
    /// The response was not an `HTTPURLResponse` (should not happen over HTTP).
    case notHTTP
}
