# iosProjects

## HelloWorld

A minimal SwiftUI app in `HelloWorld/`. The Xcode project is generated from
`HelloWorld/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd HelloWorld && xcodegen generate && open HelloWorld.xcodeproj
```

CI (`.github/workflows/ios-build.yml`) builds it for the iOS Simulator on a
GitHub-hosted macOS runner and uploads the `.app` as a build artifact.
