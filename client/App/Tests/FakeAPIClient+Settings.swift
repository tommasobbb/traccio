import Foundation
import TraccioCore

/// `SettingsAPI` stub, mirroring `APIClient+Settings.swift`.
extension FakeAPIClient {
    func setSettings(_ response: SettingsResponse) {
        settingsToReturn = response
    }

    func setSettingsError(_ error: Error) {
        settingsError = error
    }

    func setTrackingStartSuggestion(_ response: TrackingStartSuggestionResponse) {
        trackingStartSuggestionToReturn = response
    }

    func setTrackingStartSuggestionError(_ error: Error) {
        trackingStartSuggestionError = error
    }

    func settings() async throws -> SettingsResponse {
        if let settingsError { throw settingsError }
        return settingsToReturn
    }

    func setTrackingStart(_ date: CalendarDate?) async throws -> SettingsResponse {
        if let settingsError { throw settingsError }
        setTrackingStartValues.append(date)
        settingsToReturn = SettingsResponse(
            trackingStartDate: date, mealVouchersEnabled: settingsToReturn.mealVouchersEnabled
        )
        return settingsToReturn
    }

    func setMealVouchersEnabled(_ enabled: Bool) async throws -> SettingsResponse {
        if let settingsError { throw settingsError }
        setMealVouchersEnabledValues.append(enabled)
        settingsToReturn = SettingsResponse(
            trackingStartDate: settingsToReturn.trackingStartDate, mealVouchersEnabled: enabled
        )
        return settingsToReturn
    }

    func trackingStartSuggestion() async throws -> TrackingStartSuggestionResponse {
        if let trackingStartSuggestionError { throw trackingStartSuggestionError }
        guard let trackingStartSuggestionToReturn else { throw NotConfigured() }
        return trackingStartSuggestionToReturn
    }
}
