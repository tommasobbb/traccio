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
}
