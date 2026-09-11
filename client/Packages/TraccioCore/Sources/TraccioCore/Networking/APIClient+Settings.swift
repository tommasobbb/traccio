import Foundation

// Settings / tracking-start endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient {
    /// Fetch the current user's settings (ADR 0024, ADR 0029).
    ///
    /// Mirrors `GET /settings`: the tracking-start floor — the day the
    /// dashboard and Movimenti begin from, or `nil` for no floor — and
    /// whether the meal-vouchers dashboard breakout is on.
    public func settings() async throws -> SettingsResponse {
        try await get("settings")
    }

    /// Set or clear the tracking start date (ADR 0024).
    ///
    /// Mirrors `POST /settings`. `nil` clears the floor (show everything);
    /// either way nothing is deleted, only which movements are shown changes.
    /// Returns both settings, with the tracking-start floor now updated.
    ///
    /// Parameters
    /// ----------
    /// date:
    ///     The new floor, or `nil` to clear it.
    public func setTrackingStart(_ date: CalendarDate?) async throws -> SettingsResponse {
        try await post("settings", body: SetTrackingStartRequest(trackingStartDate: date))
    }

    /// Turn the meal-vouchers dashboard breakout on or off (ADR 0029).
    ///
    /// Mirrors `POST /settings/meal-vouchers`. Reversible: with the setting
    /// off, a voucher-kind account is counted like any other again. Returns
    /// both settings, with `meal_vouchers_enabled` now updated.
    ///
    /// Parameters
    /// ----------
    /// enabled:
    ///     The new state.
    public func setMealVouchersEnabled(_ enabled: Bool) async throws -> SettingsResponse {
        try await post("settings/meal-vouchers", body: SetMealVouchersRequest(enabled: enabled))
    }

    /// Fetch a suggested tracking start and the per-account first-movement
    /// dates it is derived from (ADR 0024).
    ///
    /// Mirrors `GET /settings/tracking-start/suggestion`.
    public func trackingStartSuggestion() async throws -> TrackingStartSuggestionResponse {
        try await get("settings/tracking-start/suggestion")
    }
}
