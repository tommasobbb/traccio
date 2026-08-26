/// How `GET /dashboard/summary`'s `by_bucket` groups transactions in time.
///
/// Mirrors the `BucketGranularity` schema in `docs/api/openapi.json`. Raw
/// values match the wire format exactly, same discipline as
/// `RuleMatchKind`. `.day` is the only case any screen sends today — `.week`
/// and `.month` exist for the period picker Task 6 adds (`docs/decisions/
/// 0007-dashboard-aggregation.md`'s third revision).
public enum BucketGranularity: String, Codable, Sendable, CaseIterable {
    case day
    case week
    case month
}
