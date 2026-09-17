/// The four-state shape a screen's data load goes through: not started yet,
/// in flight, done with a value, or failed.
///
/// Before this type existed, eight view models each declared their own
/// `enum State { case idle, loading, loaded(T), failed }` — identical except
/// for `T` — and six views each declared the same `stateTag` switch over it
/// to drive a SwiftUI `.animation(_:value:)` trigger. One generic type
/// replaces both: `Value` supplies the `T`, and `tag` replaces the repeated
/// switch.
///
/// Not every load shape fits this: `TrackingStartViewModel.State` has no
/// `.idle` (the screen has nothing to show before its first load completes)
/// and `PersonDetailViewModel.State`/`TransactionDetailViewModel
/// .ReimbursementsState` have no `.idle`/no `.loading` respectively — real
/// differences in what each screen can display, not copies of this shape,
/// so they stay their own enums.
public enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed

    /// A cheap discriminator for `.animation(_:value:)`: keys off which case
    /// is current, not the loaded value's content, so `Value` never needs to
    /// be `Equatable` just to drive an animation trigger.
    public var tag: String {
        switch self {
        case .idle, .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
    }
}

extension LoadState: Equatable where Value: Equatable {}
