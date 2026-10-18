import CloudKit
import CoreData
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// One entity, one CloudKit container, and a log of everything that happens.
///
/// This exists to watch sync rather than to be a good app. Every save, every
/// CloudKit setup/import/export event, every remote-change notification and
/// every persistent-history transaction is written to `log`, with who made
/// the change — this device, or CloudKit's importer bringing it from another.
@MainActor
@Observable
final class SyncStore {

    static let containerID = "iCloud.com.nikflahavan.syncdemo"

    struct Row: Identifiable, Equatable {
        var id: UUID
        var text: String
        var updatedAt: Date
        var author: String
    }

    struct LogLine: Identifiable {
        enum Kind { case local, event, eventFailed, remote, history, info, error }
        let id = UUID()
        let time = Date()
        let kind: Kind
        let message: String
    }

    private(set) var rows: [Row] = []
    private(set) var log: [LogLine] = []
    private(set) var accountStatus = "checking…"
    private(set) var storeURL: URL?
    private(set) var inFlight: [String: Date] = [:]   // event type → started

    let device: String
    private let container: NSPersistentCloudKitContainer
    private var historyToken: NSPersistentHistoryToken?
    private var observers: [NSObjectProtocol] = []

    /// The text everyone should be seeing: the most recently edited record.
    var current: Row? { rows.max { $0.updatedAt < $1.updatedAt } }

    var environment: String {
        #if DEBUG
        return "development (debug build)"
        #else
        return "production"
        #endif
    }

    init() {
        #if os(macOS)
        device = "Mac – " + (Host.current().localizedName ?? "unknown")
        #else
        device = "iPhone – " + UIDevice.current.name
        #endif

        container = NSPersistentCloudKitContainer(name: "SyncDemo", managedObjectModel: Self.model)
        let description = container.persistentStoreDescriptions.first!
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerID)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        storeURL = description.url

        add(.info, "device: \(device)")
        add(.info, "container: \(Self.containerID) · \(environment)")

        container.loadPersistentStores { [weak self] desc, error in
            MainActor.assumeIsolated {
                if let error { self?.add(.error, "store failed to load: \(error.localizedDescription)") }
                else { self?.add(.info, "store loaded: \(desc.url?.lastPathComponent ?? "?")") }
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        // Tags this device's writes in persistent history, so the log can tell
        // "I wrote this" from "CloudKit's importer wrote this".
        container.viewContext.transactionAuthor = "app on \(device)"

        historyToken = loadToken()
        observe()
        refresh(reason: "launch")
        Task { await checkAccount() }
    }

    // MARK: Actions

    /// Edit "the" string. With nothing there yet it creates a record — which
    /// is exactly how two devices end up with two of them.
    func save(_ text: String) {
        let context = container.viewContext
        let object: NSManagedObject
        if let latest = current, let existing = fetchObject(id: latest.id) {
            object = existing
            add(.local, "editing record \(short(latest.id))")
        } else {
            object = NSEntityDescription.insertNewObject(forEntityName: "Note", into: context)
            let id = UUID()
            object.setValue(id, forKey: "id")
            add(.local, "no record yet — creating \(short(id))")
        }
        object.setValue(text, forKey: "text")
        object.setValue(Date(), forKey: "updatedAt")
        object.setValue(device, forKey: "author")
        commit("save “\(text)”")
    }

    /// A second record on purpose, to see what duplicates look like.
    func addRecord(_ text: String) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Note", into: container.viewContext)
        let id = UUID()
        object.setValue(id, forKey: "id")
        object.setValue(text, forKey: "text")
        object.setValue(Date(), forKey: "updatedAt")
        object.setValue(device, forKey: "author")
        commit("insert extra record \(short(id))")
    }

    func delete(_ row: Row) {
        guard let object = fetchObject(id: row.id) else { return }
        container.viewContext.delete(object)
        commit("delete \(short(row.id))")
    }

    func clearLog() { log.removeAll() }

    func refresh(reason: String) {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        let objects = (try? container.viewContext.fetch(request)) ?? []
        let new = objects.compactMap { o -> Row? in
            guard let id = o.value(forKey: "id") as? UUID else { return nil }
            return Row(id: id, text: o.value(forKey: "text") as? String ?? "",
                       updatedAt: o.value(forKey: "updatedAt") as? Date ?? .distantPast,
                       author: o.value(forKey: "author") as? String ?? "")
        }
        if new != rows {
            add(.info, "records now \(new.count) (after \(reason))")
        }
        rows = new
    }

    func checkAccount() async {
        do {
            let status = try await CKContainer(identifier: Self.containerID).accountStatus()
            accountStatus = switch status {
            case .available: "available"
            case .noAccount: "no iCloud account"
            case .restricted: "restricted"
            case .couldNotDetermine: "could not determine"
            case .temporarilyUnavailable: "temporarily unavailable"
            @unknown default: "unknown"
            }
        } catch {
            accountStatus = "error: \(error.localizedDescription)"
        }
        add(.info, "iCloud account: \(accountStatus)")
    }

    // MARK: Watching

    private func observe() {
        let center = NotificationCenter.default

        // CloudKit's own report: setup, import, export — start and end.
        observers.append(center.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.record(event) }
        })

        // Something changed the store from outside this context — in practice,
        // CloudKit's importer writing what another device sent.
        observers.append(center.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.add(.remote, "remote-change notification")
                self?.readHistory()
                self?.refresh(reason: "remote change")
            }
        })
    }

    private func record(_ event: NSPersistentCloudKitContainer.Event) {
        let kind = switch event.type {
        case .setup: "setup"
        case .import: "import"
        case .export: "export"
        @unknown default: "event"
        }
        if event.endDate == nil {
            inFlight[kind] = event.startDate
            add(.event, "▶ \(kind) started")
        } else {
            inFlight[kind] = nil
            let seconds = event.endDate!.timeIntervalSince(event.startDate)
            if event.succeeded {
                add(.event, "✓ \(kind) finished in \(String(format: "%.1f", seconds))s")
            } else {
                let message = (event.error as NSError?).map { "\($0.domain) \($0.code): \($0.localizedDescription)" } ?? "unknown"
                add(.eventFailed, "✗ \(kind) failed: \(message)")
            }
            if kind == "import" { refresh(reason: "import") }
        }
    }

    /// Persistent history: every transaction since the last one we read, with
    /// its author and what it touched. This is where "who changed what" lives.
    private func readHistory() {
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: historyToken)
        guard let result = try? container.viewContext.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else { return }
        for transaction in transactions {
            let changes = transaction.changes ?? []
            let inserts = changes.filter { $0.changeType == .insert }.count
            let updates = changes.filter { $0.changeType == .update }.count
            let deletes = changes.filter { $0.changeType == .delete }.count
            let who = transaction.author ?? transaction.contextName ?? "unknown author"
            add(.history, "history: \(who) — +\(inserts) ~\(updates) −\(deletes)")
            historyToken = transaction.token
        }
        saveToken()
    }

    // MARK: Plumbing

    private func commit(_ what: String) {
        do {
            try container.viewContext.save()
            add(.local, "saved locally: \(what)")
        } catch {
            add(.error, "save failed: \(error.localizedDescription)")
        }
        readHistory()
        refresh(reason: "local save")
    }

    private func fetchObject(id: UUID) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Note")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try? container.viewContext.fetch(request).first
    }

    private func add(_ kind: LogLine.Kind, _ message: String) {
        log.insert(LogLine(kind: kind, message: message), at: 0)
        if log.count > 400 { log.removeLast(log.count - 400) }
    }

    func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    private var tokenURL: URL {
        URL.applicationSupportDirectory.appending(path: "history-token.data")
    }

    private func loadToken() -> NSPersistentHistoryToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private func saveToken() {
        guard let historyToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: historyToken, requiringSecureCoding: true)
        else { return }
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: tokenURL)
    }

    /// One entity, every attribute optional — CloudKit's rule.
    static let model: NSManagedObjectModel = {
        let note = NSEntityDescription()
        note.name = "Note"
        note.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = true
            return a
        }
        note.properties = [
            attribute("id", .UUIDAttributeType),
            attribute("text", .stringAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("author", .stringAttributeType),
        ]
        let model = NSManagedObjectModel()
        model.entities = [note]
        return model
    }()
}
