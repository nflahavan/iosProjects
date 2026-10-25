# Working in this repo

**Risu** (`Risu/`) is a personal, local-only iPhone app for household money: import bank
CSVs, decide what each transaction is, see income against expenses. It was restarted from
nothing on 2026-10-18; the earlier app lives in git history. Its architecture, and the
decisions still open, are on the diagram at
<https://claude.ai/artifact/2SXaDR96NHULTf7TtaTbyi>.

`SyncDemo/` is a separate experiment from the earlier app's iCloud work, kept for reference.

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
xcodebuild test -scheme Risu -destination 'platform=iOS Simulator,name=iPhone Duo,OS=27.1'   # ~10s
Scripts/testflight      # archive and upload a TestFlight build, as the Apple ID signed in to Xcode
```

Targets iOS 27.1, iPhone only (the 27.1 simulator runtime runs only the iPhone Duo), Swift 6 with the main actor as the default isolation.
Parallel testing is off in the scheme: it clones the simulator, which made a 0.1s suite
take minutes.

## Telemetry

The app logs screens, taps and choices (never descriptions or amounts) as JSON lines,
one file per launch, kept on the phone. Settings ▸ Export shares it; AirDrop it to this
Mac or save it to Files, and it can be read from there.
