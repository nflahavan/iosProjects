import Foundation

enum ExerciseKind: String, Codable { case reps, bw, time, carry }

struct Learn {
    let why: String
    let setup: String
    let steps: [String]
    let feel: String
    let mistake: String
    let easier: String
}

struct ExerciseDef: Identifiable {
    let id: String
    let name: String
    let kind: ExerciseKind
    let lo: Int
    let hi: Int
    var inc: Double = 0
    var tag: String? = nil
    var wUnit: String = "lb"
    let hint: String
    let query: String
    var first: String? = nil
    var bwUp: String? = nil
    var upText: String? = nil
    let learn: Learn

    var countsReps: Bool { kind == .reps || kind == .bw }
    var hasWeight: Bool { kind == .reps || kind == .carry }
    var target: String { "\(lo)–\(hi) \(countsReps ? "reps" : "sec")" }
    var demoURL: URL {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return c.url!
    }
}

enum Workout: String, CaseIterable, Identifiable {
    case A, B
    var id: String { rawValue }
    var label: String { "Workout \(rawValue)" }
    var other: Workout { self == .A ? .B : .A }
    var items: [String] {
        switch self {
        case .A: ["legpress", "shoulder", "row", "legcurl", "plank", "carry", "calf"]
        case .B: ["legpress", "chestpress", "pulldown", "backext", "abduction", "carry", "calf"]
        }
    }
}

enum Exercises {
    static let maxSets = 5
    static let legs: Set<String> = ["legpress", "legcurl", "backext", "abduction", "calf", "goblet", "lunge", "rdl", "stepup"]

    /// Every exercise in either workout, in order, without repeats.
    static let order: [String] = {
        var seen = Set<String>()
        return (Workout.A.items + Workout.B.items).filter { seen.insert($0).inserted }
    }()

    static func def(_ key: String) -> ExerciseDef? { all[key] }

    static let all: [String: ExerciseDef] = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })

    static let list: [ExerciseDef] = [
        ExerciseDef(
            id: "legpress", name: "Leg press", kind: .reps, lo: 10, hi: 12, inc: 10,
            hint: "Feet flat and hip-width apart on the platform.", query: "seated leg press machine form",
            learn: Learn(
                why: "Strong legs for stairs, standing up from low seats, and lifting with your legs.",
                setup: "Adjust the seat so your knees are bent about 90° with your feet flat on the platform, hip-width apart. Hold the side handles.",
                steps: [
                    "Press through your whole foot to straighten your legs, stopping just short of locking your knees.",
                    "Bend your knees slowly to bring the weight back until they're at about 90°.",
                    "Keep your lower back against the pad the whole time.",
                ],
                feel: "Thighs and glutes.",
                mistake: "Locking your knees at the top, or lowering so far that your lower back lifts off the pad.",
                easier: "Less weight, stopping a little short of 90°.")),
        ExerciseDef(
            id: "chestpress", name: "Chest press", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Handles at mid-chest height.", query: "chest press machine form",
            learn: Learn(
                why: "Pushing strength for doors, heavy carts, and getting yourself up off the floor.",
                setup: "Set the seat so the handles line up with the middle of your chest. Sit with your back against the pad and your feet flat on the floor.",
                steps: [
                    "Push the handles forward until your arms are straight, without locking your elbows.",
                    "Bring them back slowly until your hands are close to your chest.",
                    "Keep your shoulder blades against the pad throughout.",
                ],
                feel: "Chest, shoulders and the backs of your arms.",
                mistake: "Shoulders rolling forward off the pad, or letting the weights clang down between reps.",
                easier: "Less weight, taking two or three seconds to bring the handles back.")),
        ExerciseDef(
            id: "row", name: "Seated cable row", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Sit tall and pull to your belly.", query: "seated cable row form",
            learn: Learn(
                why: "Pulling things toward you, and good posture.",
                setup: "Sit with your feet on the foot rests and your knees slightly bent. Hold the handle with your arms straight and your back tall.",
                steps: [
                    "Pull the handle to your belly, squeezing your shoulder blades together.",
                    "Keep your chest up and your body still.",
                    "Let your arms straighten slowly.",
                ],
                feel: "Upper back and the sides of your back.",
                mistake: "Rocking back and forth to move the weight. Your arms and back should do the work.",
                easier: "The seated row machine with a chest pad, which holds your body still.")),
        ExerciseDef(
            id: "legcurl", name: "Leg curl", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Knees lined up with the machine's pivot.", query: "seated leg curl machine form",
            learn: Learn(
                why: "Strong hamstrings that support your knees when you run, walk downhill, and bend to lift.",
                setup: "Sit so your knees line up with the machine's pivot point. Set the leg pad just above your heels and lower the thigh pad snugly onto your legs.",
                steps: [
                    "Curl your heels down and back as far as is comfortable.",
                    "Pause for a moment.",
                    "Let your legs straighten slowly.",
                ],
                feel: "The backs of your thighs.",
                mistake: "Lifting your hips or swinging the weight. Keep your thighs pinned under the pad.",
                easier: "Less weight, with a slower return.")),
        ExerciseDef(
            id: "backext", name: "Back extension", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Leave the weight blank for bodyweight.", query: "45 degree back extension form",
            first: "First time: bodyweight only, through a range that feels comfortable.", bwUp: "↑ Ready to hold a weight plate",
            learn: Learn(
                why: "A strong lower back and glutes for lifting and carrying.",
                setup: "Set the hip pad just below your hip bones so you can bend at the hips. Hook your heels under the foot pads and cross your arms over your chest.",
                steps: [
                    "Start with your body in a straight line.",
                    "Bend at your hips to lower your upper body as far as is comfortable, keeping your back flat.",
                    "Squeeze your glutes to come back up to a straight line, and no higher.",
                ],
                feel: "Glutes, hamstrings and lower back.",
                mistake: "Arching past a straight line at the top. Stop when your body lines up with your legs.",
                easier: "A smaller range of motion.")),
        ExerciseDef(
            id: "abduction", name: "Hip abduction", kind: .reps, lo: 12, hi: 15, inc: 10, tag: "Knees & feet",
            hint: "Pads on the outside of your knees.", query: "hip abduction machine form",
            learn: Learn(
                why: "Stronger outer hips, which keep your knees lined up when you run, climb stairs and step down.",
                setup: "Sit with your back against the pad and the pads against the outside of your knees. Set the starting position so your legs are close together.",
                steps: [
                    "Push your knees out against the pads as far as is comfortable.",
                    "Pause for a moment.",
                    "Bring them back together slowly, without letting the weights touch down.",
                ],
                feel: "The outsides of your hips and glutes.",
                mistake: "Rushing the return. Control the weight on the way back in.",
                easier: "Less weight and a smaller range.")),
        ExerciseDef(
            id: "plank", name: "Plank", kind: .time, lo: 20, hi: 30, inc: 5,
            hint: "Forearms down, body in one straight line.", query: "forearm plank proper form",
            learn: Learn(
                why: "A strong midsection that protects your back when you lift and carry.",
                setup: "Forearms on the floor with your elbows under your shoulders, legs straight behind you, up on your toes.",
                steps: [
                    "Make one straight line from your head to your heels.",
                    "Squeeze your glutes and tighten your stomach as if bracing for a poke.",
                    "Breathe steadily and hold for 20–30 seconds.",
                ],
                feel: "Stomach.",
                mistake: "Hips sagging, which strains your lower back, or piking up. Squeeze your glutes, and end the set when you lose the line.",
                easier: "Knees on the floor, or forearms on a bench.")),
        ExerciseDef(
            id: "calf", name: "Calf raises", kind: .reps, lo: 12, hi: 15, inc: 10, tag: "Knees & feet",
            hint: "Calf raise machine, or a step with your heels hanging off.", query: "standing calf raise machine form",
            first: "First time: start light and use your full range.",
            learn: Learn(
                why: "Walking, running and stairs. Stronger calves help your feet and ankles handle running.",
                setup: "On the calf raise machine, put your shoulders under the pads and the balls of your feet on the edge of the step. No machine free? Stand on a step and hold a rail.",
                steps: [
                    "Rise up onto your toes as high as you can.",
                    "Pause for a second at the top.",
                    "Lower slowly until your heels dip just below the step.",
                ],
                feel: "Calves.",
                mistake: "Bouncing fast. Take about a second up and two or three seconds down.",
                easier: "Do them on flat ground, or with both hands on a wall.")),
        ExerciseDef(
            id: "pulldown", name: "Lat pulldown", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Pull the bar to your upper chest.", query: "lat pulldown proper form",
            learn: Learn(
                why: "Pulling yourself up and pulling things down from overhead.",
                setup: "Sit with your thighs snug under the pad. Grab the bar a little wider than your shoulders.",
                steps: [
                    "Lean back slightly and lift your chest.",
                    "Pull the bar down to your upper chest, driving your elbows down toward your sides.",
                    "Let the bar rise slowly until your arms are straight.",
                ],
                feel: "The sides of your back and between your shoulder blades.",
                mistake: "Leaning way back and yanking the bar with your body. Use less weight and pull smoothly.",
                easier: "A lighter weight, with a one-second pause at your chest.")),
        ExerciseDef(
            id: "shoulder", name: "Shoulder press", kind: .reps, lo: 10, hi: 12, inc: 5,
            hint: "Machine. With dumbbells, the weight is per hand.", query: "shoulder press machine form",
            learn: Learn(
                why: "Lifting things overhead, like a bag into an overhead bin or a box onto a high shelf.",
                setup: "Set the seat so the handles start at about shoulder height. Sit with your back against the pad.",
                steps: [
                    "Press the handles up until your arms are straight, without locking your elbows.",
                    "Lower them slowly back to shoulder height.",
                    "Keep your back against the pad, without arching your lower back.",
                ],
                feel: "Shoulders and the backs of your arms.",
                mistake: "Arching your back off the pad to push the weight up. Use less weight.",
                easier: "Less weight, with a short pause at the bottom of each rep.")),
        ExerciseDef(
            id: "carry", name: "Farmer's carry", kind: .carry, lo: 30, hi: 40, inc: 5, wUnit: "lb/hand",
            hint: "Weight is per hand. Log how long you walked.", query: "farmers carry form",
            learn: Learn(
                why: "Carrying groceries and other heavy things without wearing out. Builds grip and posture.",
                setup: "Pick up a heavy dumbbell in each hand, squatting down with a flat back.",
                steps: [
                    "Stand tall with your shoulders back and down.",
                    "Walk with short, steady steps for 30–40 seconds.",
                    "Set the dumbbells down with control.",
                ],
                feel: "Grip, forearms, upper back and core.",
                mistake: "Shrugging or rounding forward. Keep your chest up and your shoulders away from your ears.",
                easier: "Lighter dumbbells or a shorter walk.")),
    ]
}
