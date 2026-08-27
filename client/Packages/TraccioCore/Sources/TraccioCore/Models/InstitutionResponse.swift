/// One bank the caller can authorize, as returned by
/// `GET /connections/institutions`.
///
/// Mirrors the `InstitutionResponse` schema in `docs/api/openapi.json`.
public struct InstitutionResponse: Codable, Sendable, Equatable {
    /// The provider-scoped institution identifier — pass this straight back
    /// as `StartConnectionRequest.institution`.
    public let name: String
    /// ISO 3166-1 alpha-2 country the institution is offered in.
    public let country: String
    /// The institution's logo URL, or `nil` when the provider has none. The
    /// client renders it with a lettermark fallback.
    public let logo: String?

    public init(name: String, country: String, logo: String? = nil) {
        self.name = name
        self.country = country
        self.logo = logo
    }
}

/// Envelope returned by `GET /connections/institutions`.
///
/// Mirrors the `InstitutionsResponse` schema in `docs/api/openapi.json`.
public struct InstitutionsResponse: Codable, Sendable, Equatable {
    /// The institutions offered in the requested country, in the provider's
    /// own order.
    public let institutions: [InstitutionResponse]

    public init(institutions: [InstitutionResponse]) {
        self.institutions = institutions
    }
}
