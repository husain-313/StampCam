# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Rule: keep this file up to date.** After every change to the app, small or large, review this CLAUDE.md and update anything that no longer matches the app. Do this automatically, without being asked, as part of the same change.

## What this is

StampCam is a SwiftUI iPhone app (iOS 17+, iPhone only, portrait UI, always dark mode). You take photos, tap Done, and get one PDF with the date, time and location stamped on each photo. There are no third-party dependencies, only Apple frameworks: AVFoundation, CoreLocation, Vision, PDFKit, Photos and ImageIO.

## Building

There is no local build. Development happens on Windows, and the `.xcodeproj` is not checked in; it is generated from `project.yml` by XcodeGen. There are no tests and no linter.

- Every push to `main` runs `.github/workflows/build.yml` on macOS. The workflow runs `xcodegen generate`, does an unsigned `xcodebuild` for `generic/platform=iOS`, zips `StampCam.ipa`, and **publishes a GitHub Release** tagged `v<STAMPCAM_RELEASE>`. Compile errors show up as annotations on that run.
- The release notes are the `## <version>` section of `CHANGELOG.md`, cut out with awk. The heading must start with exactly the version string (e.g. `## 3.4` or `## 2.7 — About & Updates`).
- A version containing `beta` is published as a prerelease.
- On macOS (if available): `xcodegen generate` and then open `StampCam.xcodeproj`.

Since pushing to `main` publishes a release that users' in-app updater will pick up, never push without being asked.

## Release convention

Each commit is one version, titled `X.Y: short description`. A release commit does all of the following:
1. Bumps `MARKETING_VERSION` and `STAMPCAM_RELEASE` in `project.yml`, and increments `CURRENT_PROJECT_VERSION` by 1.
2. Adds a `## X.Y` entry at the top of `CHANGELOG.md`. It is written for end users in plain, non-technical language with a bold lead phrase. `README.md` uses the same voice; update its feature list when the behavior it describes changes.

`Updater.swift` checks GitHub releases for `husain-313/StampCam`, so the tag and asset name (`StampCam.ipa`) must stay as they are.

## Architecture

All sources are flat in `Sources/`. `StampCamApp` registers defaults and shows `CameraScreen`. Every other screen (Review, Settings, Your PDFs, Rename, About, Arrange Pages) is a sheet or navigation destination opened from there.

**The photo set (session).** `CameraModel` (an `ObservableObject`) owns the AVCapture session and the current `[Shot]`. `Shot` (in `SessionStore.swift`) is Codable metadata: date, coordinates, place name, heading, note, and `imported`. The image bytes are stored separately, as `Application Support/Session/<uuid>.photo`. `SessionStore` saves the index to `session.json` after every change (`persist()`), so a session survives the app being killed. New fields on `Shot` must be optional so older saved sessions still decode.

**Stamping happens at PDF time, not capture time.** Saved photos are originals with no stamp. Stamp text (`StampText.lines`), style (`StampStyle.current()`) and quality are read from settings when Done is tapped, so a settings change applies to the whole set. Photos taken before the first location fix get their location and area name filled in later (`resolvePlaces`, and `makePDF` waits up to about 4 seconds). Library imports (`imported == true`) get **no stamp** and keep only their own EXIF date and location (`PhotoInfo`).

**PDF pipeline** (`CameraModel.makePDF` → `buildPDF` → `PDFBuilder.build` in `Processing.swift`):
- Shots are hidden from the camera right away (`hiddenIDs`) and rendered on `processQueue`.
- Each page is rendered through `ShotRenderer`/`ImageProcessor` and re-encoded as JPEG. Each stamped photo is also saved to Photos, optionally (`PhotoSaver`).
- Shots and their files are deleted only after the PDF is written. If the build fails, they come back.

**Done is silent.** Since 3.5 there is no name or share sheet after Done, pages always fit the photo (`PageSize.photo`), and the stamp has no GPS coordinates or compass direction. `Defaults.register()` forces those old settings off; the code paths remain but are unused.

**Saved PDFs.** `FileStore` manages PDFs in the app's Documents folder, which is visible in the Files app. A new PDF is named after the time of its first photo (`h.mm a`, with ` 2`, ` 3`… added if the name is taken). Append and arrange use PDFKit and write to a temp file first, then `replaceItemAt`. `FilesView` shows them as a grid of covers, where page 1 is the cover. "Add from Library" opens the photo picker right on top of Your PDFs (`FilesView` owns it), and the picked items are handed to `CameraScreen`, which imports them and appends them to that PDF. Don't open the picker from `CameraScreen` after closing the sheet: presenting while the sheet is still closing fails silently.

**Name suggestions.** `RenameSheet` combines several sources:
- Text read from the photos by on-device Vision OCR (`TextScanner`, Arabic and English).
- Area and date names (`CameraModel.areaDateName`).
- It skips area names that were already stamped (`Keys.stampedPlaces`) and `PDFBuilder.coverMark`.

**Settings.** `Settings.swift` holds every `UserDefaults` key (`Keys`), the defaults and their migrations (`Defaults.register()`), and the setting enums (`Quality`, `StampPosition`, `StampColor`, `PageSize`). Views read the settings with `@AppStorage(Keys.…)`. A new setting gets a key and a default registered here.

**Style.** `Style.swift` holds the shared look: `Haptics`, and the glass background and sheet modifiers. Comments and UI text are written in plain, short, user-facing language, and the code uses `// MARK:` sections. Match both.
