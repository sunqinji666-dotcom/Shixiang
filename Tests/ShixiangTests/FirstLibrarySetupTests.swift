import Testing
@testable import Shixiang

struct FirstLibrarySetupTests {
    @Test func setupAppearsOnlyAfterAConfirmedEmptyLibrary() {
        #expect(FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: false,
            isInitialLoadComplete: true,
            isDeferredStartupLoading: false,
            packCount: 0
        ))

        #expect(!FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: false,
            isInitialLoadComplete: false,
            isDeferredStartupLoading: false,
            packCount: 0
        ))
        #expect(!FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: false,
            isInitialLoadComplete: true,
            isDeferredStartupLoading: true,
            packCount: 0
        ))
        #expect(!FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: false,
            isInitialLoadComplete: true,
            isDeferredStartupLoading: false,
            packCount: 1
        ))
        #expect(!FirstLibrarySetupPolicy.shouldPresent(
            hasPresented: true,
            isInitialLoadComplete: true,
            isDeferredStartupLoading: false,
            packCount: 0
        ))
    }
}
