import SwiftData
import SwiftUI

@main
struct HalfMarathonApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Session.self)
        } catch {
            fatalError("Couldn't open the log: \(error)")
        }
        // Up before the first screen, so a run the watch sent while the app was closed is
        // logged as soon as the system hands it over.
        PhoneLink.shared.start(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

extension Color {
    /// 10 kg plate green: done, and weight going up.
    static let go = Color(light: UIColor(hex: 0x146C3B), dark: UIColor(hex: 0x6BD49A))
    /// 25 kg plate red: race day.
    static let race = Color(light: UIColor(hex: 0xB42318), dark: UIColor(hex: 0xFF8B7F))

    init(light: UIColor, dark: UIColor) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension UIColor {
    convenience init(hex: Int) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Font {
    /// Condensed uppercase labels, standing in for the web page's Barlow Condensed.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}
