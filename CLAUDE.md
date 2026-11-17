# Working in this repo

**Risu** (`Risu/`) is a personal, local-only iPhone app for household money: import bank
CSVs, decide what each transaction is, see income against expenses. It was restarted from
nothing on 2026-10-18; the earlier app lives in git history. Its architecture, and the
decisions still open, are on the diagram at
<https://claude.ai/artifact/2SXaDR96NHULTf7TtaTbyi>.

`SyncDemo/` is a separate experiment from the earlier app's iCloud work, kept for reference.

**HalfMarathon** (`HalfMarathon/`, shown on the phone as "Half Build") is a personal iPhone
app for a 26-week half marathon plan with twice-weekly lifting: log workouts and runs, see
the plan as a calendar, track progress. It's a native port, made 2026-11-15, of the
"Half Marathon Build" artifact (<https://claude.ai/artifact/6xuWaWEFXdNuDfiBM3vS2q>). Data
lives on the phone in SwiftData. History ▸ ••• imports the artifact's JSON log and exports
a backup in the same shape. Bundle id `com.nikflahavan.halfmarathon`, same personal team,
same build settings as Risu. Run the tests with
`cd HalfMarathon && xcodebuild test -scheme HalfMarathon -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'`.
Debug builds take `-importLog <path>` and `-tab plan|history|moves|sources` as launch
arguments, for trying screens with real data in the simulator.

It has an Apple Watch app (`HalfMarathonWatch/`, watchOS 26 or later, bundle id
`com.nikflahavan.halfmarathon.watchkitapp`, embedded in the iPhone app, added 2026-11-15)
that offers this week's next run, times run/walk intervals with a tap on the wrist at each
change, and records runs and lifts as HealthKit workouts. `Shared/` (the plan tables and
week math, the interval schedule, the payloads) is compiled into both apps, and is tested
through the iPhone test target. The phone sends the race date, recent runs and last lift as
the WatchConnectivity application context (`PhoneLink`); the watch sends each saved run
back with `transferUserInfo`, and `WatchImporter` logs it as a cardio session. Lifts work
the same way: the context carries a hint per exercise (the weight, reps and set count the
phone's form would suggest), each set is entered on the watch on two wheels that start on
that hint, and the saved lift is logged as a Workout A/B session. Entitlements and the watch's
background mode are in `Config/`. The version and build number are set once, on the
project, so both apps always match.

```bash
cd HalfMarathon
xcodebuild build -scheme HalfMarathonWatch -destination 'generic/platform=watchOS Simulator'
```

No watchOS simulator runtime is installed on this Mac, so the watch app has been built but
never run here. `xcodebuild -downloadPlatform watchOS` gets one (an install: ask first).
Then pair a watch simulator to an iOS 27 iPhone one with `xcrun simctl pair`, install
`HalfMarathonWatch.app` and launch it. Debug builds take `-today 2026-11-17` to pretend
it's that day, and `-demoRun r1|r2|long|free|A|B` with `-demoElapsed <seconds>` to open
mid-workout with made-up heart rate and distance and no HealthKit.

## Rules

- **Personal project.** Sign with team `9K49YB68EN` only, bundle id `com.nikflahavan.risu`.
  Never sign, provision or publish under an employer's team.
- **Show primary-source docs and get approval before installing anything.** Every Xcode
  comes from `xcodes`, installed from homebrew-core (`brew install xcodes`), not the
  `xcodesorg/made` tap, which builds from source and fails on Swift 6.4
  ([xcodes#493](https://github.com/XcodesOrg/xcodes/issues/493)). `xcodes select`,
  Homebrew's installer and anything else needing a password run in Terminal.app, not `!`.
- **Bank data never goes in the repo.** Test fixtures use invented rows.
- **Amounts are whole cents**, never floating point.

## Running things

```bash
cd Risu
xcodebuild test -scheme Risu -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'   # ~10s
Scripts/testflight      # archive and upload a TestFlight build, as the Apple ID signed in to Xcode
```

Targets iOS 27.0, iPhone only, Swift 6 with the main actor as the default isolation.
Parallel testing is off in the scheme: it clones the simulator, which made a 0.1s suite
take minutes.

## Telemetry

The app logs screens, taps and choices (never descriptions or amounts) as JSON lines,
one file per launch, kept on the phone. Settings ▸ Export shares it; AirDrop it to this
Mac or save it to Files, and it can be read from there.
