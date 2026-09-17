import Foundation
import TraccioCore

/// `ConnectionsAPI` stub, mirroring `APIClient+Connections.swift`.
extension FakeAPIClient {
    /// A recorded `startConnection(institution:country:logo:)` call.
    struct RecordedStartConnection: Equatable {
        let institution: String
        let country: String
        let logo: String?
    }

    func setConnectionsToReturn(_ connections: [ConnectionResponse]) {
        connectionsToReturn = connections
    }

    func setBackfillConnectionLogosResult(_ result: BackfillLogosResponse) {
        backfillConnectionLogosToReturn = result
    }

    func setBackfillConnectionLogosError(_ error: Error) {
        backfillConnectionLogosError = error
    }

    func setInstitutions(_ institutions: [InstitutionResponse]) {
        institutionsToReturn = institutions
    }

    func setInstitutionsError(_ error: Error) {
        institutionsError = error
    }

    func setStartConnectionResult(_ result: StartConnectionResponse) {
        startConnectionToReturn = result
    }

    func setStartConnectionError(_ error: Error) {
        startConnectionError = error
    }

    func connections() async throws -> [ConnectionResponse] {
        connectionsFetchCount += 1
        return connectionsToReturn
    }

    func institutions(country: String) async throws -> [InstitutionResponse] {
        receivedInstitutionsCountries.append(country)
        if let institutionsError { throw institutionsError }
        return institutionsToReturn
    }

    func startConnection(
        institution: String, country: String, logo: String?
    ) async throws -> StartConnectionResponse {
        startedConnections.append(
            RecordedStartConnection(institution: institution, country: country, logo: logo)
        )
        if let startConnectionError { throw startConnectionError }
        return startConnectionToReturn
    }

    func syncConnection(connectionID: UUID) async throws -> SyncResponse {
        syncConnectionToReturn
    }

    func reauthorizeConnection(connectionID: UUID) async throws -> StartConnectionResponse {
        reauthorizeConnectionToReturn
    }

    func backfillConnectionLogos() async throws -> BackfillLogosResponse {
        backfillConnectionLogosCallCount += 1
        if let backfillConnectionLogosError { throw backfillConnectionLogosError }
        return backfillConnectionLogosToReturn
    }
}
