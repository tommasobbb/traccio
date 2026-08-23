import Foundation
import TraccioCore

extension APIClient {
    /// A client pointed at the local dev backend (`make run`).
    ///
    /// Hard-coded for M0/M3 local development only; there is no configuration
    /// UI yet and no secrets are involved (the client has no notion of
    /// tokens). Shared by every view model (`AccountsViewModel`,
    /// `DashboardViewModel`), so it lives in its own file rather than being
    /// attached to one of them.
    static let devDefault = APIClient(baseURL: URL(string: "http://localhost:8000")!)
}
