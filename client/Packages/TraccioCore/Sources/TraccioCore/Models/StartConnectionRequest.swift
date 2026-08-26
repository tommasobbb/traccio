/// Body for `POST /connections`.
///
/// Mirrors the `StartConnectionRequest` schema in `docs/api/openapi.json`.
/// Both fields are always present — the institution the user picked
/// (typically from `GET /connections/institutions`) and its country.
public struct StartConnectionRequest: Encodable, Sendable {
    public let institution: String
    public let country: String

    public init(institution: String, country: String) {
        self.institution = institution
        self.country = country
    }
}
