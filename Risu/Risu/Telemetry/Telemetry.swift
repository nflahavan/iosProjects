import Foundation
import UIKit

/// A log of how the app is used, for talking through the UX afterwards.
///
/// One JSON object per line: when, which screen, what happened. It records
/// structure only — screens, buttons, which chip, how long a card took, where a
/// finger landed — never a transaction's description or amount, so bank data
/// stays out of it. Category and source names are in it; you made those up.
///
/// Each launch writes its own file in the app's Documents. Settings ▸ Export
/// hands it to the share sheet; nothing leaves the phone otherwise.
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    /// What the screen in front of you is called, for every event and tap.
    private(set) var screen = "launch"
    let fileURL: URL
    private let session = UUID().uuidString.prefix(8)
    private var lines: [String] = []
    private let started = Date()

    private init() {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateTimeSeparator(.standard).timeSeparator(.omitted))
        let folder = URL.documentsDirectory.appending(path: "Telemetry")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appending(path: "risu-\(stamp)-\(session).jsonl")
    }

    func start() {
        let info = Bundle.main.infoDictionary
        log("launch", ["build": "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))",
                       "device": UIDevice.current.model,
                       "os": UIDevice.current.systemVersion])
    }

    func entered(_ name: String) {
        screen = name
        log("screen")
    }

    func log(_ event: String, _ fields: [String: String] = [:]) {
        var object: [String: String] = fields
        object["t"] = Date.now.formatted(.iso8601)
        object["s"] = String(Date.now.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1))))
        object["session"] = String(session)
        object["screen"] = screen
        object["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        let all = Data((lines.joined(separator: "\n") + "\n").utf8)
        try? all.write(to: fileURL, options: .atomic)
    }

    /// A touch on the screen, as a fraction of its width and height, so it
    /// can be placed on a screenshot afterwards.
    func tap(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        log("tap", ["x": String(format: "%.3f", point.x / size.width),
                    "y": String(format: "%.3f", point.y / size.height)])
    }
}

/// Watches every touch in the app's windows without getting in its way: the
/// recogniser never claims a touch, so buttons, scrolling and swipes behave
/// exactly as they would without it.
final class TapRecorder: NSObject, UIGestureRecognizerDelegate {
    static let shared = TapRecorder()

    func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === self }) {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
            }
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }
        Telemetry.shared.tap(at: recognizer.location(in: view), in: view.bounds.size)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

import SwiftUI

extension View {
    /// Names the screen for the telemetry log while it's on screen.
    func screen(_ name: String) -> some View {
        onAppear { Telemetry.shared.entered(name) }
    }
}
