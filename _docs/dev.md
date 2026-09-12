# Development Guide

## Requirements

- Xcode with license accepted (`sudo xcodebuild -license accept`)
- XcodeGen (`brew install xcodegen`)
- Homebrew

## Project layout

- `project.yml` — XcodeGen project definition (app target `FocusTracker`, test target `FocusTrackerTests`, Yams SPM dependency, macOS 14+, ad-hoc signing)
- `Sources/FocusTracker/` — app source
- `Tests/FocusTrackerTests/` — unit tests
- `_docs/` — PRD, process docs, acceptance records

## Regenerate the Xcode project

`FocusTracker.xcodeproj` is generated from `project.yml`. After editing `project.yml` run:

```sh
xcodegen generate
```

## Build and test (CLI)

```sh
xcodegen generate
xcodebuild -project FocusTracker.xcodeproj -scheme FocusTracker -destination 'platform=macOS' build
xcodebuild -project FocusTracker.xcodeproj -scheme FocusTracker -destination 'platform=macOS' test
```

A clean-checkout acceptance run is: `xcodegen generate && xcodebuild test` (all test targets must pass).

## Run the app

Open `FocusTracker.xcodeproj` in Xcode and press Cmd+R, or build via CLI and launch the product from DerivedData.

## Notes

- Git: canonical backlog is GitHub issues (`gh issue list -R rileycong/focus-tracker-app`); close issues only after verification passes.
- Data store scope: the app reads/writes only `Tasks/` and `Logs/` inside the user's Obsidian vault. Health and Lifebot are separate projects.