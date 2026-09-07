import Foundation

// Settings / tracking-start endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Fetch the current user's settings (ADR 0024).
    ///
    /// Mirrors `GET /settings`. Only `tracking_start_date` so far — the day
    /// the dashboard and Movimenti begin from, or `nil` for no floor.
    public func settings() async throws -> TrackingStartResponse {
        try await get("settings")
    }

    /// Set or clear the tracking start date (ADR 0024).
    ///
    /// Mirrors `POST /settings`. `nil` clears the floor (show everything);
    /// either way nothing is deleted, only which movements are shown changes.
    /// Returns the value now stored.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The new floor, or `nil` to clear it.
    public func setTrackingStart(_ date: CalendarDate?) async throws -> TrackingStartResponse {
        try await post("settings", body: SetTrackingStartRequest(trackingStartDate: date))
    }

    /// Fetch a suggested tracking start and the per-account first-movement
    /// dates it is derived from (ADR 0024).
    ///
    /// Mirrors `GET /settings/tracking-start/suggestion`.
    public func trackingStartSuggestion() async throws -> TrackingStartSuggestionResponse {
        try await get("settings/tracking-start/suggestion")
    }
}
