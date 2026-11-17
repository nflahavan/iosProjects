import Foundation
import SwiftData

/// One logged set. Which fields are filled depends on the exercise kind:
/// reps = w × r, bw = r, time = s, carry = w × s. Same shape as the web log.
struct LoggedSet: Codable, Hashable {
    var w: Double?
    var r: Double?
    var s: Double?
}

struct LoggedExercise: Codable, Hashable {
    var key: String
    var name: String
    var kind: ExerciseKind
    var sets: [LoggedSet]
}

/// A saved workout (type "A" or "B") or cardio session (type "cardio").
@Model
final class Session {
    @Attribute(.unique) var id: String
    var date: DayKey
    var type: String
    var name: String
    var createdAt: Double
    var updatedAt: Double?
    var note: String
    // Lifts
    var exercises: [LoggedExercise]
    var finisherMin: Double?
    // Cardio
    var activity: String?
    var slot: String?
    var minutes: Double?
    var miles: Double?

    init(id: String, date: DayKey, type: String, name: String, createdAt: Double, updatedAt: Double? = nil,
         note: String = "", exercises: [LoggedExercise] = [], finisherMin: Double? = nil,
         activity: String? = nil, slot: String? = nil, minutes: Double? = nil, miles: Double? = nil) {
        self.id = id; self.date = date; self.type = type; self.name = name
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.note = note
        self.exercises = exercises; self.finisherMin = finisherMin
        self.activity = activity; self.slot = slot; self.minutes = minutes; self.miles = miles
    }

    var isLift: Bool { type == "A" || type == "B" }
    var isCardio: Bool { type == "cardio" }
    var liftExercises: [LoggedExercise] { isLift ? exercises.filter { !$0.sets.isEmpty } : [] }

    static func newID(date: DayKey, type: String) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "\(date)-\(type)-" + String((0..<6).map { _ in chars.randomElement()! })
    }

    static func newestFirst(_ a: Session, _ b: Session) -> Bool {
        a.date != b.date ? a.date > b.date : a.createdAt > b.createdAt
    }
}

/// The JSON the web log stored, used for importing it and for exporting a backup.
struct SessionRecord: Codable {
    var id: String
    var date: String
    var type: String
    var name: String?
    var createdAt: Double?
    var updatedAt: Double?
    var note: String?
    var unit: String?
    var exercises: [LoggedExercise]?
    var finisherMin: Double?
    var activity: String?
    var slot: String?
    var minutes: Double?
    var miles: Double?

    init(_ s: Session) {
        id = s.id; date = s.date; type = s.type; name = s.name; createdAt = s.createdAt; updatedAt = s.updatedAt
        note = s.note
        if s.isLift { unit = "lb"; exercises = s.exercises; finisherMin = s.finisherMin }
        else { activity = s.activity; slot = s.slot; minutes = s.minutes; miles = s.miles }
    }

    /// Nil when the record isn't something the app can show.
    func makeSession() -> Session? {
        guard Day.date(date) != nil, ["A", "B", "cardio"].contains(type) else { return nil }
        let fallback = type == "cardio" ? (Activity(rawValue: activity ?? "")?.label ?? "Cardio") : "Workout \(type)"
        return Session(id: id, date: date, type: type, name: name ?? fallback, createdAt: createdAt ?? 0,
                       updatedAt: updatedAt, note: note ?? "", exercises: exercises ?? [], finisherMin: finisherMin,
                       activity: activity, slot: slot, minutes: minutes, miles: miles)
    }
}

struct LogFile: Codable {
    var sessions: [SessionRecord]
    var raceDate: String?
}

enum Activity: String, CaseIterable, Identifiable {
    case run, bike, rower, walk, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .run: "Run"
        case .bike: "Bike"
        case .rower: "Rower"
        case .walk: "Walk"
        case .other: "Other"
        }
    }
}
