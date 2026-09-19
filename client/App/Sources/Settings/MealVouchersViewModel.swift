import Foundation
import Observation
import TraccioCore

/// Drives the "Buoni pasto" toggle row on `SettingsView` (ADR 0029): loads
/// the current `meal_vouchers_enabled` setting and flips it.
///
/// All it does is call `APIClient` and hold the result — no derivation
/// (`docs/engineering.md`). A simpler shape than `TrackingStartViewModel`
/// (a flat `Bool`, not a loaded/failed enum with a payload) since there is
/// nothing else to show alongside the toggle.
@MainActor
@Observable
final class MealVouchersViewModel {
    /// The current value, or `nil` before the first load / after a failed
    /// one — the row disables the toggle rather than showing a stale value.
    private(set) var isEnabled: Bool?
    /// Set while the initial load or a flip is in flight.
    private(set) var isSaving = false
    /// The last load or flip failed — the row shows a retry-able message.
    private(set) var loadFailed = false

    private let client: any APIClientProtocol
    /// Invoked after a successful flip so the caller can mark the dashboard
    /// stale — the setting changes what "Speso questo periodo" counts. A
    /// mutable `var`, not an `init` parameter: `SettingsView` holds this
    /// view model in `@State`, whose initial value is built before
    /// `@Environment(DataFreshness.self)` is guaranteed available, so the
    /// view sets this property in `.task` instead of capturing `freshness`
    /// at construction time.
    var onChanged: () -> Void = {}

    /// Create the view model.
    ///
    /// Parameters
    /// ----------
    /// client:
    ///     The API client to reach the backend through. Defaults to a client
    ///     pointed at the local dev backend.
    init(client: any APIClientProtocol = APIClient.current) {
        self.client = client
    }

    /// Load the current value.
    func load() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let settings = try await client.settings()
            isEnabled = settings.mealVouchersEnabled
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Turn the setting on or off. A no-op while another call is in flight.
    func setEnabled(_ enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await client.setMealVouchersEnabled(enabled)
            isEnabled = updated.mealVouchersEnabled
            loadFailed = false
            onChanged()
        } catch {
            loadFailed = true
        }
    }
}
