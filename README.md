# StampCam

A personal iPhone camera app: take photos, tap **Done**, and get one PDF with the time and area name on every photo.

## Features

- Camera with flash (Off / Auto / On) and zoom by pinch or lens buttons (.5 / 1 / 2 / 5).
- Volume buttons and Camera Control also take photos.
- Time (24-hour) and area name on each photo: bold text with no background, plus a soft shadow for readability.
- Settings: show/hide time and location, corner position, text size, text color, photo quality, PDF page size (photo size or A4), and share after Done.
- Review before the PDF: delete any photo, retake a photo in the same spot, or add more photos.
- Saved PDFs list inside the app: open, rename, share, delete.
- Smart file names: suggestions read from the text in your photos (like a shop sign), on-device with Apple Vision, Arabic and English.

## Build without a Mac

1. Push this folder to a GitHub repository (`main` branch).
2. GitHub Actions builds the app automatically (about 3–5 minutes).
3. Open **Actions** → latest run → **Artifacts** and download `StampCam-ipa`.
4. Upload `StampCam.ipa` to **Signulous**, sign it and install it.

## Files

| File | Contents |
|---|---|
| `Sources/StampCamApp.swift` | App entry point |
| `Sources/CameraScreen.swift` | Camera screen |
| `Sources/CameraModel.swift` | Camera, flash, zoom, capture |
| `Sources/ReviewView.swift` | Review, delete, retake |
| `Sources/FilesView.swift` | Saved PDFs |
| `Sources/SettingsView.swift` | Settings screen |
| `Sources/Settings.swift` | Settings and defaults |
| `Sources/Processing.swift` | Photo stamp, compression, PDF |
| `Sources/LocationModel.swift` | Area name |
| `Sources/TextScanner.swift` | Reads text in photos for name suggestions |
| `Sources/RenameSheet.swift` | Rename screen with suggestions |
| `project.yml` | Project settings and permissions |
| `.github/workflows/build.yml` | Cloud build |
