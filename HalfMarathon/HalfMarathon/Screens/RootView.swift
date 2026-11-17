import SwiftData
import SwiftUI

enum AppTab: Hashable { case log, plan, history, moves, sources }

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query private var stored: [Session]
    @AppStorage("raceDate") private var raceDate: String = Plan.defaultRace
    @State private var log = LogModel()
    @State private var tab: AppTab = .log
    @State private var today = Day.today()
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private var plan: Plan {
        Plan(raceDate: Day.date(raceDate) != nil ? raceDate : Plan.defaultRace,
             sessions: stored.sorted(by: Session.newestFirst), today: today)
    }

    var body: some View {
        let plan = plan
        TabView(selection: $tab) {
            Tab("Log", systemImage: "square.and.pencil", value: .log) {
                LogScreen(plan: plan, log: log, showToast: show)
            }
            Tab("Plan", systemImage: "calendar", value: .plan) {
                PlanScreen(plan: plan, raceDate: $raceDate) { day in
                    log.logDay(day, plan: plan)
                    tab = .log
                }
            }
            Tab("History", systemImage: "chart.line.uptrend.xyaxis", value: .history) {
                HistoryScreen(plan: plan, raceDate: $raceDate, showToast: show) { s in
                    log.startEdit(s)
                    tab = .log
                }
            }
            Tab("Moves", systemImage: "figure.strengthtraining.functional", value: .moves) {
                MovesScreen()
            }
            Tab("Sources", systemImage: "books.vertical", value: .sources) {
                SourcesScreen()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(.systemBackground))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(.label), in: .rect(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 130)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        #if DEBUG
        .task { debugImport() }
        #endif
        .onChange(of: WatchImporter.context(for: plan), initial: true) { _, context in
            PhoneLink.shared.push(context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                today = Day.today()
                log.rollToToday()
            } else {
                log.persist()
            }
        }
    }

    #if DEBUG
    @Environment(\.modelContext) private var context

    /// `-importLog <path>` on launch imports a log file, for trying screens with real data in the simulator.
    private func debugImport() {
        let args = ProcessInfo.processInfo.arguments
        if let t = args.firstIndex(of: "-tab"), args.indices.contains(t + 1) {
            tab = ["plan": .plan, "history": .history, "moves": .moves, "sources": .sources][args[t + 1]] ?? .log
        }
        guard let i = args.firstIndex(of: "-importLog"), args.indices.contains(i + 1),
              let data = FileManager.default.contents(atPath: args[i + 1]),
              let report = try? LogImporter.importLog(data, into: context) else { return }
        if let r = report.raceDate { raceDate = r }
        show(report.message)
    }
    #endif

    private func show(_ message: String) {
        toastTask?.cancel()
        withAnimation { toast = message }
        AccessibilityNotification.Announcement(message).post()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }
}
