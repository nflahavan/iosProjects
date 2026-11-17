import WatchKit

/// The taps on the wrist. Each kind of change has its own, so a run can be followed without
/// looking: `.start` to run, `.stop` to walk, `.notification` as the heads-up before either.
enum Haptics {
    static func play(_ cue: Cue.Kind) {
        let type: WKHapticType = switch cue {
        case .headsUp: .notification
        case .run: .start
        case .walk: .stop
        case .goalPace: .directionUp
        case .easy: .directionDown
        case .finish: .success
        }
        WKInterfaceDevice.current().play(type)
    }

    static func begin() { WKInterfaceDevice.current().play(.start) }
    static func click() { WKInterfaceDevice.current().play(.click) }
    /// Rest: enough at 60 s, time's up at 90 s.
    static func rest(over: Bool) { WKInterfaceDevice.current().play(over ? .start : .notification) }
}
