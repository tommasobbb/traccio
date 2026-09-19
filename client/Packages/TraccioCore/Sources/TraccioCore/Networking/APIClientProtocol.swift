import Foundation

/// The seam a view model depends on instead of the concrete `APIClient`.
///
/// Per `docs/engineering.md` ("Protocols at real seams, not everywhere"):
/// the API client is the one place a caller must not know the concrete type,
/// so a view model can be tested against a fake without a network stub.
///
/// Composed from one protocol per domain — `AccountsAPI`, `HealthAPI`, and so
/// on, each declared alongside its `APIClient+<Domain>.swift` implementation
/// — rather than one flat list of 64 requirements, mirroring the split
/// `APIClient` itself already has. A view model that only needs one or two
/// domains can depend on that narrower protocol directly instead of the full
/// union; most depend on `APIClientProtocol` because they touch several.
public protocol APIClientProtocol:
    AccountsAPI, HealthAPI, DashboardAPI, TransactionsAPI, ImportsAPI, SettingsAPI, CategoriesAPI,
    RulesAPI, AdvancesAPI, ConnectionsAPI, TransfersAPI, EventsAPI
{}

extension APIClient: APIClientProtocol {}
