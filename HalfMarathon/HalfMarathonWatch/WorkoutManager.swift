import Foundation
import HealthKit
import Observation

/// The HealthKit side of a workout. An `HKWorkoutSession` is what keeps the app running with
/// the wrist down, and the live builder collects heart rate and distance into the workout
/// saved to Health. Timing never depends on it: if Health says no, the timers still run.
@Observable
final class WorkoutManager: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    var heartRate: Double?
    var avgHeartRate: Double?
    var meters: Double = 0
    var kcal: Double = 0
    /// Why nothing is being recorded to Health, when it isn't.
    var problem: String?

    /// The system paused or resumed the session (both buttons pressed, say).
    @ObservationIgnored var onPause: ((_ paused: Bool, _ date: Date) -> Void)?
    /// New readings arrived.
    @ObservationIgnored var onStats: (() -> Void)?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?

    var miles: Double { meters / 1609.344 }

    func reset() {
        heartRate = nil; avgHeartRate = nil; meters = 0; kcal = 0; problem = nil
        session = nil; builder = nil
    }

    private static let shared: Set<HKSampleType> = [
        HKQuantityType.workoutType(),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.heartRate),
    ]
    private static let read: Set<HKObjectType> = [
        HKQuantityType(.heartRate),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.activeEnergyBurned),
        HKObjectType.activitySummaryType(),
    ]

    /// Starts the session. Asks for Health access the first time.
    func begin(_ activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType, at date: Date) {
        reset()
        guard HKHealthStore.isHealthDataAvailable() else {
            problem = "Health isn't available"
            return
        }
        store.requestAuthorization(toShare: Self.shared, read: Self.read) { ok, _ in
            Task { @MainActor in
                if ok { self.startSession(activity, location: location, at: date) } else { self.problem = "No Health access" }
            }
        }
    }

    private func startSession(_ activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType, at date: Date) {
        let config = HKWorkoutConfiguration()
        config.activityType = activity
        config.locationType = location
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            session.startActivity(with: date)
            builder.beginCollection(withStart: date) { ok, _ in
                if !ok { Task { @MainActor in self.problem = "Not recording to Health" } }
            }
        } catch {
            problem = "Not recording to Health"
        }
    }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    /// Ends the session and stops collecting. The workout isn't saved or thrown away until
    /// `finish(save:)`.
    func end(at date: Date) async {
        guard let session, let builder else { return }
        session.end()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            builder.endCollection(withEnd: date) { _, _ in c.resume() }
        }
    }

    /// Saves the workout to Health, or discards it. True when a workout was saved.
    @discardableResult
    func finish(save: Bool) async -> Bool {
        guard let builder else { return false }
        session = nil
        self.builder = nil
        guard save else {
            builder.discardWorkout()
            return false
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            builder.finishWorkout { workout, _ in c.resume(returning: workout != nil) }
        }
    }

    private func apply(heartRate: Double?, avg: Double?, meters: Double?, kcal: Double?) {
        if let heartRate { self.heartRate = heartRate }
        if let avg { avgHeartRate = avg }
        if let meters { self.meters = meters }
        if let kcal { self.kcal = kcal }
        onStats?()
    }

    // MARK: HealthKit callbacks, off the main actor

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hr = workoutBuilder.statistics(for: HKQuantityType(.heartRate))
        let now = hr?.mostRecentQuantity()?.doubleValue(for: bpm)
        let avg = hr?.averageQuantity()?.doubleValue(for: bpm)
        let meters = workoutBuilder.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter())
        let kcal = workoutBuilder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        Task { @MainActor in self.apply(heartRate: now, avg: avg, meters: meters, kcal: kcal) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .paused || (toState == .running && fromState == .paused) else { return }
        let paused = toState == .paused
        Task { @MainActor in self.onPause?(paused, date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.problem = "Not recording to Health" }
    }
}
