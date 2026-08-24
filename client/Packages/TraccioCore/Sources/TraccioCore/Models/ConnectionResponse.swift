import Foundation

/// One bank connection as returned by `GET /connections`.
///
/// Mirrors the `ConnectionResponse` schema in `docs/api/openapi.json`. Carries
/// no secret material by construction — the consent secret and the anti-CSRF
/// `auth_state` never leave the backend (`.claude/rules/data-safety.md`); the
/// client has no notion that tokens exist (`client/CLAUDE.md`).
public struct ConnectionResponse: Codable, Sendable, Identifiable, Equatable {
    /// Stable connection identifier.
    public let id: UUID
    /// Adapter that produced the connection, e.g. `"enable_banking"`.
    public let provider: String
    /// Human-readable bank name for display.
    public let institutionName: String
    /// Consent lifecycle state, as last reported by the provider. Render
    /// `consentState` instead — this alone does not account for `expiresAt`
    /// elapsing.
    public let status: ConnectionStatus
    /// The actual, time-aware state — render this, never `status` alone.
    public let consentState: ConsentState
    /// Whole days until `expiresAt` (negative once lapsed), or `nil` when
    /// `expiresAt` is unset. A display figure; `consentState` is the
    /// authoritative expired/not-expired call.
    public let daysUntilExpiry: Int?
    /// Consent expiry, as reported by the provider; `nil` while pending.
    public let expiresAt: Date?
    /// When the connection was created.
    public let createdAt: Date
    /// When a sync last ran against this connection; `nil` until the first
    /// sync. A display figure only — nothing derives from it.
    public let lastSyncedAt: Date?
    /// Whether the background scheduler is running at all. When `false`,
    /// `syncBudgetRemaining` and `nextSyncAt` are both `nil` — they have
    /// nothing meaningful to say if nothing is scheduling syncs.
    public let backgroundSyncEnabled: Bool
    /// How many more background sync runs this connection may have in the
    /// current rolling 24h, or `nil` when `backgroundSyncEnabled` is
    /// `false`. Derived by the backend on every read, never stored — render
    /// it, never compute it (`client/CLAUDE.md`).
    public let syncBudgetRemaining: Int?
    /// When this connection is next expected to become eligible for a
    /// background sync, or `nil` when `backgroundSyncEnabled` is `false`,
    /// the connection is already due (the next tick will sync it), or its
    /// consent needs the user to re-authorize rather than time to pass.
    public let nextSyncAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case institutionName = "institution_name"
        case status
        case consentState = "consent_state"
        case daysUntilExpiry = "days_until_expiry"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case lastSyncedAt = "last_synced_at"
        case backgroundSyncEnabled = "background_sync_enabled"
        case syncBudgetRemaining = "sync_budget_remaining"
        case nextSyncAt = "next_sync_at"
    }

    public init(
        id: UUID,
        provider: String,
        institutionName: String,
        status: ConnectionStatus,
        consentState: ConsentState,
        daysUntilExpiry: Int?,
        expiresAt: Date?,
        createdAt: Date,
        lastSyncedAt: Date?,
        backgroundSyncEnabled: Bool,
        syncBudgetRemaining: Int?,
        nextSyncAt: Date?
    ) {
        self.id = id
        self.provider = provider
        self.institutionName = institutionName
        self.status = status
        self.consentState = consentState
        self.daysUntilExpiry = daysUntilExpiry
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
        self.backgroundSyncEnabled = backgroundSyncEnabled
        self.syncBudgetRemaining = syncBudgetRemaining
        self.nextSyncAt = nextSyncAt
    }
}
