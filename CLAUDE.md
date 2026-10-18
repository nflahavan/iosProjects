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
xcodebuild -scheme Risu -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.1' build
Scripts/testflight      # archive and upload a TestFlight build, as the Apple ID signed in to Xcode
```

Targets iOS 27.0, iPhone only, Swift 6 with the main actor as the default isolation.
