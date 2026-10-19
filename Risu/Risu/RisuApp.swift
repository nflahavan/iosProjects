import SwiftData
import SwiftUI

@main
struct RisuApp: App {
    let container: ModelContainer
    /// A CSV handed over by "Open in Risu", waiting for the import screen.
    @State private var incoming: IncomingFile?

    init() {
        // Unit tests run inside this app; they get a store that vanishes.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            container = try RisuStore.container(inMemory: testing)
        } catch {
            fatalError("Could not open the store: \(error)")
        }
        if !testing { Telemetry.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootView(incoming: $incoming, container: container)
                .onOpenURL { url in incoming = IncomingFile(url: url) }
                .onAppear { TapRecorder.shared.install() }
        }
        .modelContainer(container)
    }
}

/// A file to import, read into memory while the app still has permission.
struct IncomingFile: Identifiable {
    let id = UUID()
    let name: String
    let contents: Data?

    init(url: URL) {
        name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        contents = try? Data(contentsOf: url)
    }
}

struct RootView: View {
    @Binding var incoming: IncomingFile?
    /// Shared with the tab's badge, so neither holds every waiting row.
    @State private var review: ReviewState
    @State private var tab = Tab.review

    init(incoming: Binding<IncomingFile?>, container: ModelContainer) {
        _incoming = incoming
        _review = State(initialValue: ReviewState(container: container))
    }

    enum Tab: String { case review, transactions, categories, overview }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("Review", systemImage: "rectangle.stack", value: Tab.review) {
                ReviewScreen(importFile: $incoming, review: review)
            }
            .badge(review.snapshot?.waiting.count ?? 0)
            SwiftUI.Tab("Transactions", systemImage: "list.bullet", value: Tab.transactions) {
                TransactionsScreen()
            }
            SwiftUI.Tab("Categories", systemImage: "square.grid.2x2", value: Tab.categories) {
                CategoriesScreen()
            }
            SwiftUI.Tab("Overview", systemImage: "chart.bar", value: Tab.overview) {
                OverviewScreen()
            }
        }
        .onChange(of: tab) { _, new in Telemetry.shared.log("tab", ["to": new.rawValue]) }
        .sheet(item: $incoming, onDismiss: { review.refresh(after: .elsewhere) }) { file in
            ImportFlow(file: file) { tab = .review }
        }
    }
}
