import Foundation

/// Result of `POST /imports/preview` (ADR 0023): every movement a file would
/// create, classified, with nothing written.
///
/// Mirrors the `ImportPreviewResponse` schema in `docs/api/openapi.json`.
public struct ImportPreviewResponse: Codable, Sendable, Equatable {
    /// Every movement or invalid row, in source order.
    public let rows: [ImportRowResponse]
    /// The counts across `rows`.
    public let summary: ImportPreviewSummaryResponse

    public init(rows: [ImportRowResponse], summary: ImportPreviewSummaryResponse) {
        self.rows = rows
        self.summary = summary
    }
}

/// One movement a file would create, or one row that cannot be imported.
///
/// A split source row (Satispay balance + meal voucher) appears twice, once
/// per leg, sharing `rowNumber`. An `invalid` row carries only `rowNumber`,
/// `status`, and `reason`.
public struct ImportRowResponse: Codable, Sendable, Equatable, Identifiable {
    /// How a preview row was classified.
    public enum Status: String, Codable, Sendable {
        /// Would be inserted.
        case new
        /// Its key is already stored (a re-import); skipped.
        case alreadyImported = "already_imported"
        /// The source row produced no movement.
        case invalid
    }

    /// Why an `invalid` row could not be turned into a movement — the
    /// backend's stable `REASON_*` codes
    /// (`domain/imports/models.py`). Like `Status`, an unrecognized wire
    /// value fails to decode rather than silently becoming `nil` — a real
    /// `nil` `reason` means "not an invalid row", a distinct case a
    /// mis-decoded unknown reason must never be confused with.
    public enum FailureReason: String, Codable, Sendable {
        case invalidAmount = "invalid_amount"
        case invalidDate = "invalid_date"
        case missingID = "missing_id"
        case unknownStatus = "unknown_status"
        case amountSplitMismatch = "amount_split_mismatch"
        case zeroAmount = "zero_amount"
    }

    /// 1-based position of the source row.
    public let rowNumber: Int
    /// `new`, `alreadyImported`, or `invalid`.
    public let status: Status
    /// Why an `invalid` row failed; `nil` otherwise.
    public let reason: FailureReason?
    /// Which account this movement would land on; `nil` for an `invalid` row.
    public let targetAccountID: UUID?
    /// Signed minor units; `nil` for an `invalid` row.
    public let amount: Int?
    /// ISO 4217 code; `nil` for an `invalid` row.
    public let currency: String?
    /// Timezone-aware UTC; `nil` for an `invalid` row.
    public let valueDate: Date?
    /// The row's description; `nil` for an `invalid` row.
    public let description: String?

    /// Stable identity for `ForEach`: the row number plus the target (or the
    /// reason, for an invalid row), so a split row's two legs do not collide.
    public var id: String { "\(rowNumber)-\(targetAccountID?.uuidString ?? reason?.rawValue ?? "?")" }

    private enum CodingKeys: String, CodingKey {
        case rowNumber = "row_number"
        case status
        case reason
        case targetAccountID = "target_account_id"
        case amount
        case currency
        case valueDate = "value_date"
        case description
    }

    public init(
        rowNumber: Int,
        status: Status,
        reason: FailureReason?,
        targetAccountID: UUID?,
        amount: Int?,
        currency: String?,
        valueDate: Date?,
        description: String?
    ) {
        self.rowNumber = rowNumber
        self.status = status
        self.reason = reason
        self.targetAccountID = targetAccountID
        self.amount = amount
        self.currency = currency
        self.valueDate = valueDate
        self.description = description
    }
}

/// Counts across a preview's rows.
///
/// Mirrors the `ImportPreviewSummaryResponse` schema.
public struct ImportPreviewSummaryResponse: Codable, Sendable, Equatable {
    /// Movements that would be inserted.
    public let new: Int
    /// Movements whose key is already stored; skipped.
    public let alreadyImported: Int
    /// Source rows that produced no movement.
    public let invalid: Int
    /// `new + alreadyImported + invalid`.
    public let total: Int

    private enum CodingKeys: String, CodingKey {
        case new
        case alreadyImported = "already_imported"
        case invalid
        case total
    }

    public init(new: Int, alreadyImported: Int, invalid: Int, total: Int) {
        self.new = new
        self.alreadyImported = alreadyImported
        self.invalid = invalid
        self.total = total
    }
}
