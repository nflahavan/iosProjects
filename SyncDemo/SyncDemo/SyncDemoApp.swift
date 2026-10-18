import SwiftUI

/// A throwaway app for watching iCloud sync happen, with its own container so
/// nothing it does can touch Risu's data.
///
/// State lives at the outermost lifetime that needs it:
/// - **App** (this struct, created once per process): the store and its sync
///   engine. One container per process, however many windows are open — and
///   still running when none are.
/// - **Scene / view**: what's on screen and what's being typed, in the views.
///
/// Nothing longer-lived is created by something shorter-lived. Before this,
/// the store was `@State` in ContentView, so every ContentView — a second Mac
/// window, say — made its own container on the same file.
@main
struct SyncDemoApp: App {
    @State private var store = SyncStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 820)
        #endif
    }
}
