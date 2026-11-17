import SwiftUI

@main
struct HalfMarathonWatchApp: App {
    @State private var model = WorkoutModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// One thing at a time: the start screen, a workout, or its summary. A workout isn't pushed
/// onto a navigation stack, so a stray swipe can't leave it.
struct RootView: View {
    @Environment(WorkoutModel.self) private var model

    var body: some View {
        if let summary = model.summary {
            SummaryView(summary: summary)
        } else if let run = model.run {
            RunView(run: run)
        } else if let lift = model.lift {
            LiftView(lift: lift)
        } else {
            StartView()
        }
    }
}

extension Color {
    /// Running: the phone app's "go" green.
    static let run = Color(red: 0x6B / 255, green: 0xD4 / 255, blue: 0x9A / 255)
    /// Walking, warming up and cooling down.
    static let walk = Color(red: 0x7F / 255, green: 0xA2 / 255, blue: 0xFF / 255)
    /// Goal pace and race day: the phone app's race red.
    static let race = Color(red: 0xFF / 255, green: 0x8B / 255, blue: 0x7F / 255)
    static let paused = Color.yellow
}

extension Font {
    /// Condensed labels, as on the phone.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}
