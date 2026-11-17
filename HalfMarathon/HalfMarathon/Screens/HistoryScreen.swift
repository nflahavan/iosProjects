import Charts
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HistoryScreen: View {
    let plan: Plan
    @Binding var raceDate: String
    let showToast: (String) -> Void
    let edit: (Session) -> Void
    @Environment(\.modelContext) private var context
    @State private var open: Set<String> = []
    @State private var confirmDelete: Session?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    progress
                    sessions
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import log…", systemImage: "square.and.arrow.down") { importing = true }
                        ShareLink(item: ExportFile(plan: plan), preview: SharePreview("Half marathon log"))
                    } label: {
                        Label("Import or export", systemImage: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                doImport(result)
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog("Delete this session for good?", isPresented: Binding(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let s = confirmDelete {
                        context.delete(s)
                        try? context.save()
                        showToast("Session deleted.")
                    }
                }
                Button("Keep it", role: .cancel) {}
            }
        }
    }

    // MARK: Progress

    @ViewBuilder private var progress: some View {
        let chron = Array(plan.sessions.reversed())
        let rows = Exercises.order.compactMap { k -> (ExerciseDef, [Double], String)? in
            guard let def = Exercises.def(k) else { return nil }
            let pts = chron.compactMap { s in s.liftExercises.first { $0.key == k }.flatMap { Plan.metric(def.kind, $0.sets) } }
            guard let unit = pts.last?.unit else { return nil }
            return (def, Array(pts.filter { $0.unit == unit }.suffix(30).map(\.v)), unit)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Progress").font(.display(22)).textCase(.uppercase)
            if rows.isEmpty {
                empty("Each exercise gets a line here once you save a workout, tracking your working weight from session to session.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        let (def, vals, unit) = row
                        HStack(spacing: 12) {
                            Text(def.name).fontWeight(.semibold).lineLimit(1)
                            Spacer()
                            Group {
                                if vals.count > 1 {
                                    Text("\(fmtNum(vals.first)) → ") + Text(fmtNum(vals.last)).bold().foregroundStyle(.primary) + Text(" \(unit)")
                                } else {
                                    Text(fmtNum(vals.last)).bold().foregroundStyle(.primary) + Text(" \(unit)")
                                }
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                            Sparkline(values: vals).frame(width: 84, height: 28)
                        }
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                        if i < rows.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 2)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder private var sessions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sessions").font(.display(22)).textCase(.uppercase)
            if plan.sessions.isEmpty {
                empty("No sessions yet. Save a workout or a cardio session from the Log tab and it shows up here. Coming from the web page? Use Import log in the ••• menu.")
            }
            let groups = Dictionary(grouping: plan.sessions) { Day.weekStart($0.date) }
            ForEach(groups.keys.sorted(by: >), id: \.self) { key in
                let list = groups[key]!.sorted(by: Session.newestFirst)
                let lifts = list.filter(\.isLift).count
                let mins = list.reduce(0.0) { $0 + ($1.isLift ? ($1.finisherMin ?? 0) : ($1.minutes ?? 0)) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Week of \(Day.short(key))")
                        Spacer()
                        Text("\(plural(lifts, "lift", "lifts")) · \(fmtNum(mins.rounded())) min cardio")
                    }
                    .font(.footnote.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(list) { s in
                            row(s)
                            if s.id != list.last?.id { Divider() }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
            }
        }
    }

    private func row(_ s: Session) -> some View {
        let isOpen = open.contains(s.id)
        let exs = s.liftExercises
        let sets = exs.reduce(0) { $0 + $1.sets.count }
        let fin = s.finisherMin ?? 0
        let summary: String = s.isLift
            ? "\(plural(exs.count, "exercise", "exercises")) · \(plural(sets, "set", "sets"))\(fin > 0 ? " · \(fmtNum(fin)) min cardio" : "")"
            : "\(RunSlot(rawValue: s.slot ?? "").map { $0 != .extra ? "\(plan.runName(s)) · " : "" } ?? "")\(Plan.loggedText(s))"
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { if isOpen { open.remove(s.id) } else { open.insert(s.id) } }
            } label: {
                HStack(spacing: 10) {
                    Text(Day.long(s.date)).fontWeight(.semibold).frame(width: 96, alignment: .leading)
                    Text(s.isLift ? s.type : (Activity(rawValue: s.activity ?? "")?.label ?? "Cardio"))
                        .font(.display(16)).padding(.horizontal, 8).padding(.vertical, 1)
                        .foregroundStyle(s.isLift ? Color.accentColor : Color.go)
                        .background((s.isLift ? Color.accentColor : Color.go).opacity(0.15), in: .rect(cornerRadius: 6))
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isOpen {
                ForEach(Array(exs.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top) {
                        Text(Exercises.def(e.key)?.name ?? e.name)
                        Spacer()
                        Text(Plan.fmtSets(Exercises.def(e.key)?.kind ?? e.kind, e.sets)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                }
                if s.isLift && fin > 0 {
                    HStack { Text("Cardio after"); Spacer(); Text("\(fmtNum(fin)) min").foregroundStyle(.secondary) }.font(.subheadline)
                }
                if !s.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(s.note).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 20) {
                    Button("Edit session") { edit(s) }
                    Button("Delete session", role: .destructive) { confirmDelete = s }.foregroundStyle(Color.race)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Color(.separator)))
    }

    // MARK: Import

    private func doImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let report = try LogImporter.importLog(Data(contentsOf: url), into: context)
            if let race = report.raceDate { raceDate = race }
            showToast(report.message)
        } catch {
            importError = "That file isn't a half marathon log. (\(error.localizedDescription))"
        }
    }
}

enum LogImporter {
    struct Report { var added: Int; var skipped: Int; var raceDate: String?
        var message: String {
            "Imported \(plural(added, "session", "sessions"))." + (skipped > 0 ? " \(skipped) already here." : "")
        }
    }

    /// Adds sessions from a log file, skipping ones already in the app.
    /// Takes either `{ "sessions": [...], "raceDate": "…" }` or a bare array of sessions.
    static func importLog(_ data: Data, into context: ModelContext) throws -> Report {
        let file: LogFile
        if let f = try? JSONDecoder().decode(LogFile.self, from: data) { file = f }
        else { file = LogFile(sessions: try JSONDecoder().decode([SessionRecord].self, from: data)) }
        let existing = Set(try context.fetch(FetchDescriptor<Session>()).map(\.id))
        var added = 0, skipped = 0
        for r in file.sessions {
            if existing.contains(r.id) { skipped += 1; continue }
            guard let s = r.makeSession() else { skipped += 1; continue }
            context.insert(s)
            added += 1
        }
        try context.save()
        let race = file.raceDate.flatMap { Day.date($0) != nil ? $0 : nil }
        return Report(added: added, skipped: skipped, raceDate: race)
    }
}

/// The whole log as JSON, in the web page's shape, for the share sheet.
nonisolated struct ExportFile: Transferable, Sendable {
    let data: Data

    @MainActor init(plan: Plan) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? enc.encode(LogFile(sessions: plan.sessions.map(SessionRecord.init), raceDate: plan.raceDate))) ?? Data()
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("half-marathon-log.json")
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        if values.count < 2 {
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            let lo = values.min()!, hi = values.max()!
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Session", i), yStart: .value("Base", lo), yEnd: .value("Value", v))
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                LineMark(x: .value("Session", i), y: .value("Value", v))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if i == values.count - 1 {
                    PointMark(x: .value("Session", i), y: .value("Value", v)).symbolSize(30).foregroundStyle(Color.accentColor)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: lo == hi ? (lo - 1)...(hi + 1) : lo...hi)
            .accessibilityHidden(true)
        }
    }
}
