import Foundation

/// Body for `POST /imports/preview` and `POST /imports/commit` (ADR 0023).
///
/// Mirrors the `ImportPreviewRequest` schema in `docs/api/openapi.json`. The
/// file travels as base64 in a JSON body — the client is JSON-only and this
/// avoids a multipart path.
public struct ImportPreviewRequest: Encodable, Sendable {
    /// The manual account the primary movements land on.
    public let accountID: UUID
    /// The manual account a split profile's voucher leg lands on. Required by
    /// the backend (`422 voucher_account_required`) when the file has non-zero
    /// voucher amounts; must differ from `accountID`.
    public let voucherAccountID: UUID?
    /// An import profile key (`"satispay"`, `"generic"`).
    public let profile: String
    /// The original file name — a format hint only.
    public let filename: String
    /// The raw file, base64-encoded.
    public let contentBase64: String

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case voucherAccountID = "voucher_account_id"
        case profile
        case filename
        case contentBase64 = "content_base64"
    }

    public init(
        accountID: UUID,
        voucherAccountID: UUID?,
        profile: String,
        filename: String,
        contentBase64: String
    ) {
        self.accountID = accountID
        self.voucherAccountID = voucherAccountID
        self.profile = profile
        self.filename = filename
        self.contentBase64 = contentBase64
    }
}
