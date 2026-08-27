/// Body for `POST /connections`.
///
/// Mirrors the `StartConnectionRequest` schema in `docs/api/openapi.json`.
/// The institution the user picked (typically from
/// `GET /connections/institutions`), its country, and its logo URL — the
/// latter stored verbatim on the connection so Conti can show it without a
/// second provider call. `logo` is omitted from the payload when `nil`.
public struct StartConnectionRequest: Encodable, Sendable {
    public let institution: String
    public let country: String
    public let logo: String?

    public init(institution: String, country: String, logo: String? = nil) {
        self.institution = institution
        self.country = country
        self.logo = logo
    }
}
