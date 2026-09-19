import Testing

@testable import TraccioCore

struct LoadStateTests {
    @Test func tagCollapsesIdleAndLoadingToTheSameValue() {
        let idle = LoadState<Int>.idle
        let loading = LoadState<Int>.loading
        #expect(idle.tag == "loading")
        #expect(loading.tag == "loading")
        #expect(idle.tag == loading.tag)
    }

    @Test func tagIsLoadedRegardlessOfTheCarriedValue() {
        #expect(LoadState.loaded(1).tag == "loaded")
        #expect(LoadState.loaded("anything").tag == "loaded")
    }

    @Test func tagIsFailed() {
        #expect(LoadState<Int>.failed.tag == "failed")
    }

    @Test func equatableWhenValueIsEquatable() {
        #expect(LoadState.loaded(42) == LoadState.loaded(42))
        #expect(LoadState<Int>.loaded(1) != LoadState<Int>.loaded(2))
        #expect(LoadState<Int>.idle == LoadState<Int>.idle)
        #expect(LoadState<Int>.idle != LoadState<Int>.loading)
    }

    @Test func beginLoadingEntersLoadingFromIdleOrFailed() {
        var idle = LoadState<Int>.idle
        idle.beginLoading()
        #expect(idle == .loading)

        var failed = LoadState<Int>.failed
        failed.beginLoading()
        #expect(failed == .loading)
    }

    @Test func beginLoadingKeepsLoadedContentVisible() {
        // The whole point: a refetch of an already-`.loaded` screen (a
        // pull-to-refresh, a filter change) must not drop back to `.loading`
        // and discard what's on screen.
        var loaded = LoadState.loaded(42)
        loaded.beginLoading()
        #expect(loaded == .loaded(42))
    }

    @Test func beginLoadingIsANoOpWhenAlreadyLoading() {
        var loading = LoadState<Int>.loading
        loading.beginLoading()
        #expect(loading == .loading)
    }
}
