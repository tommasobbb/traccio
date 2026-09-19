import Foundation

/// An error raised while talking to the backend.
///
/// The cases carry only non-sensitive context: a status code, or an underlying
/// system/decoding error. No response body and no financial data ever enter an
/// `APIError` — a bank response body must never reach a log or an error message
/// (see `docs/engineering.md`). In particular the transport and
/// decoding cases wrap the framework error, never the payload that produced it.
public enum APIError: Error, Sendable {
    /// The request never produced an HTTP response (offline, DNS, TLS, …).
    case transport(underlying: any Error)
    /// The server answered with a non-2xx status. Carries the code only.
    case badStatus(Int)
    /// The server answered `401` — a missing, incorrect, or revoked API
    /// token (ADR 0014). Split out from `badStatus` so the client can show
    /// "check your server token" rather than a generic network-error message.
    case unauthorized
    /// The response was received but could not be decoded into the model.
    case decoding(underlying: any Error)
    /// A request body could not be encoded to JSON before sending.
    case encoding(underlying: any Error)
    /// The response was not an `HTTPURLResponse` (should not happen over HTTP).
    case notHTTP
    /// The request path and query could not be assembled into a valid URL.
    case invalidURL

    /// `true` when this wraps a cancelled request rather than a genuine
    /// failure.
    ///
    /// `URLSession` reports a cancelled `Task` (SwiftUI tears down the
    /// `.refreshable` scroll view mid-request, a view disappears mid-`.task`,
    /// …) as `URLError.cancelled` through `.transport`, indistinguishable at
    /// a glance from a real offline/DNS/TLS failure. A caller that maps every
    /// `.transport` straight to a user-facing "impossibile caricare" message
    /// must check this first — a self-inflicted cancellation is not news.
    public var isCancellation: Bool {
        guard case .transport(let underlying) = self else { return false }
        return underlying is CancellationError || (underlying as? URLError)?.code == .cancelled
    }
}

extension Error {
    /// `true` for a plain `CancellationError`, or an `APIError` wrapping one
    /// (`APIError.isCancellation`) — the one check a `catch` block needs
    /// regardless of which shape the cancellation surfaced in, since `error`
    /// there is typed `any Error`, not `APIError`.
    public var isCancellationError: Bool {
        self is CancellationError || (self as? APIError)?.isCancellation == true
    }
}
