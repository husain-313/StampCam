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

All sources are flat in `Sources/`. `StampCamApp` registers defaults and shows `CameraScreen`. The photo library opens from the box next to the shutter while the set is empty (after that the box opens Review), and from Review → Add Photos → Add from Library; both use `CameraScreen.addFromLibrary()` (`LibraryPicker`). Since 4.3 there is no library button in the top bar. Every other screen (Review, Settings, Your PDFs, Rename, About, Arrange Pages) is a sheet or navigation destination opened from there.

**The photo set (session).** `CameraModel` (an `ObservableObject`) owns the AVCapture session and the current `[Shot]`. `Shot` (in `SessionStore.swift`) is Codable metadata: date, coordinates, place name, heading, note, and `imported`. The image bytes are stored separately, as `Application Support/Session/<uuid>.photo`. `SessionStore` saves the index to `session.json` after every change (`persist()`), so a session survives the app being killed. New fields on `Shot` must be optional so older saved sessions still decode.

**Stamping happens at PDF time, not capture time.** Saved photos are originals with no stamp. Stamp text (`StampText.lines`), style (`StampStyle.current()`) and quality are read from settings when Done is tapped, so a settings change applies to the whole set. Photos taken before the first location fix get their location and area name filled in later (`resolvePlaces`, and `makePDF` waits up to about 4 seconds). Library imports (`imported == true`) get **no stamp** and keep only their own EXIF date and location (`PhotoInfo`).

**PDF pipeline** (`CameraModel.makePDF` → `buildPDF` → `PDFBuilder.build` in `Processing.swift`):
- Each capture is matched to its date and place by `AVCapturePhotoSettings.uniqueID` (`pendingSlots: [Int64: Slot]`), never by order, so a failed or out-of-order capture can't shift metadata onto another photo.
- Shots are hidden from the camera right away (`hiddenIDs`) and rendered on `processQueue`.
- Each page is rendered through `ShotRenderer`/`ImageProcessor` and re-encoded as JPEG. Each stamped photo is also saved to Photos, optionally (`PhotoSaver`).
- `PDFBuilder.build` returns `Built(url:written:)`. Only the shots in `written` leave the set after the PDF is saved; a photo that couldn't be rendered stays in the camera and the user gets a toast (one combined message if the append also failed). If the whole build fails, all photos come back.
- Adding to an existing PDF (`FileStore.append`, which returns the old page count or nil) happens on `processQueue` inside `buildPDF`, not on the main thread. `makePDF` reports a `PDFOutcome` (url, leftOut, appendFailed) as soon as the PDF is saved.
- After reporting, still on `processQueue`, `buildPDF` OCRs the first 6 written originals and stores the text with `PDFText.fill`, then deletes the originals. The written shots are already out of `session.json`, so if the app dies first, `SessionStore.removeOrphans` cleans the files at next launch.

**Done is silent.** Since 3.5 there is no name or share sheet after Done, pages always fit the photo (`PageSize.photo`), and the stamp has no GPS coordinates or compass direction. `Defaults.register()` forces those old settings off; the code paths remain but are unused.

**Saved PDFs.** `FileStore` manages PDFs in the app's Documents folder, which is visible in the Files app. A new PDF is named after the time of its first photo (`h:mm a`, like "5:17 PM", with ` 2`, ` 3`… added if the name is taken). **Names never contain a dot** (some websites refuse "5.17 PM.pdf"): `FileStore.sanitize` turns dots into spaces and normalizes to NFC, and `FileStore.removeDotsFromNames()` renames older "5.17 PM" files to "5:17 PM" at every launch (`StampCamApp.init`). The first photo's time is stored as the file's **creation date** (set in `PDFBuilder.build`; rename, append and arrange keep it, since `replaceItemAt` keeps the original's creation date) and shown under each card as `PDFFile.takenAt`. The folder button in Select **saves copies** to the Files app (`FileExporter`, `UIDocumentPickerViewController(forExporting:asCopy: true)`); before 4.3 it moved them out of the app. Append and arrange use PDFKit and write to a temp file first, then `replaceItemAt`. `FilesView` shows them as a grid of covers, where page 1 is the cover. "Add from Library" opens the photo library with `LibraryPicker` (a UIKit `PHPickerViewController` presented on the topmost screen). If a menu or screen is still animating it retries every 0.1 s, because SwiftUI's `.photosPicker` silently fails when presented during a transition and then stays stuck. The picked photos (as `Data`) go to `CameraScreen.importPhotos`, which imports them and appends them to that PDF.

**Name suggestions.** `RenameSheet` combines several sources:
- Text read by on-device Vision OCR (`TextScanner`, `minimumTextHeight` 0.008 so small text counts). It runs two passes per image, English (`en-US`) and Arabic (`ar-SA`, keeping only Arabic results), because one combined pass reads English badly. Right after the PDF is saved, `buildPDF` reads the full-size originals (first 6, at most 2000 px). The result is stored privately in the app by `PDFText` (`Application Support/PDFText/<pdf name>.json`: ranked names plus lines per page, where a `nil` page means "not read yet"), **never inside the PDF**, so shared PDFs carry no hidden text. `TextScanner.read(_:)` (Rename screen) reads every `nil` page from the PDF (up to 30), merges the names, saves, and returns `Reading(names:lines:)`; if the stored page count doesn't match the PDF it starts fresh. Files saved by 4.1 have no `format` field; on load their empty pages count as unread. `FileStore` keeps the text in sync: rename moves it, append merges it (pages without text become `nil`), arrange reorders it and drops removed pages' text (and names no longer found), delete removes it, and `FilesView.reload` drops text for PDFs removed or renamed in the Files app (`PDFText.removeOrphans`). 3.9–4.0 PDFs had this text in their keywords/subject; it's stripped at launch until a run finishes cleanly (`cleanedPDFText42`). `RenameSheet` shows the names as Smart Suggestions (max 8) and all lines in a collapsed "All Text from Photos" list.
- Area and date names (`CameraModel.areaDateName`).
- It skips area names that were already stamped (`Keys.stampedPlaces`) and `PDFBuilder.coverMark`.

**Area name lookups.** `LocationModel.requestName` caches names; after a failed lookup it won't ask again for the same spot for 30 s (`failedAt`), so the retries in `makePDF` don't flood Apple's geocoder.

**Keep sheets responsive.** `DeviceOrientation` (level) and `LocationModel` publish many times a second and redraw `CameraScreen`; while any sheet is open (`sheet != nil`) `CameraScreen` stops both, and starts them again when the sheet closes. Otherwise menus and pickers in the open sheet close or need a second tap.

**Version.** `project.yml` maps `CFBundleShortVersionString`/`CFBundleVersion` to `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`; without them XcodeGen writes 1.0 and the updater always offers an update.

**Settings.** `Settings.swift` holds every `UserDefaults` key (`Keys`), the defaults and their migrations (`Defaults.register()`), and the setting enums (`Quality`, `StampPosition`, `StampColor`, `PageSize`). `StampColor` has 10 colors matching StampCam for Android, picked in Settings from `ColorCircles`; the stamp time is `hh:mm a` (two-digit hour) or `HH:mm`. Views read the settings with `@AppStorage(Keys.…)`. A new setting gets a key and a default registered here. Fresh-install defaults: time only (no date, no area name), top left, white, 100% size, Small quality, Save to Photos on, flash off (3.9 also switched existing users' flash to off once, `flashOffSince39`).

**Style.** `Style.swift` holds the shared look: `Haptics`, and the glass background and sheet modifiers. Comments and UI text are written in plain, short, user-facing language, and the code uses `// MARK:` sections. Match both.
