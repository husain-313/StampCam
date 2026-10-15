# Changelog

## 2.7.1
- **Fix: page numbers when adding photos to an existing PDF.** New pages carry on from the old ones (like 4 / 4 after 3 pages) instead of starting again at 1 / 1. This broke in 2.6.

## 2.7 — About & Updates
- **About page** (Settings → About StampCam): version and build date, a privacy note, what StampCam is built on, and Developed by Husain Helal.
- **Check for Updates:** finds the newest version on GitHub, shows what's new, and downloads it. Then open it with your signing app (like Signulous) to install.
- **Copy App Info:** copies the version and your iPhone model in one tap, for reporting a problem.

## 2.6.1
- **Fix: deleting a PDF from inside it now works.** The trash button on an open PDF asks "Delete this PDF?" in a clear alert and deletes it, then goes back to your list. Swipe and long-press delete use the same alert.

## 2.6 — Quiet and clean
- **Silent PDF:** tap Done and the camera is ready again at once. The PDF is made quietly in the background, with no "Creating PDF" or "Adding location" messages. The Name PDF screen appears when it's ready. Your photos are only deleted after the PDF is saved; if something goes wrong they come back.
- **Name PDF is simpler:** no photos or yellow boxes, just a clean list of smart suggestions.
- **Better suggestions:**
  - Reads all your photos, not just the first three.
  - Text that appears in several photos ranks higher.
  - Skips junk like "Made in…", websites, emails, phone numbers and prices.
  - New: the area and date, like *Jidhafs – 14 Oct*.
  - No repeats (even when the same words differ in capitals or Arabic letter forms).
  - Up to 8 suggestions.

## 2.5
- **Camera Control (iPhone 16 and newer):** press to take a photo, and now slide on it for **zoom** or **brightness**, like the built-in Camera app. The on-screen zoom and brightness follow along.
- **Camera tips:** a short card the first time you open the app explains the gestures (swipe for lens, hold for zoom dial, tap and slide for brightness, double-tap to switch cameras). Show it again from Settings.
- **Glass sheets:** Settings, Review, Your PDFs and Name PDF open on frosted glass over the camera.


## 2.4 — Pro camera look
- **Glass controls:** the top and bottom controls sit on glass (Apple's Liquid Glass on iOS 26, frosted glass on older iOS).
- **Haptics:** a light tap on every camera button, a click when changing lens, and a click when the phone is level (grid on).
- **Gestures:**
  - Swipe left or right on the picture to change lens (.5 / 1 / 2 / 5).
  - Press and hold the lens buttons, then slide, for a smooth zoom dial.
  - Double-tap the picture to switch between the back and front cameras.
- **Shutter:** bigger, with a little press animation.


## 2.3
Fixes found while testing 2.2:
- **Name PDF:** page numbers (like *2 / 3*) are no longer offered as tappable text, and overlapping boxes (e.g. on round logos) are cleaned up.
- **Smart suggestions** skip text that was probably misread.
- **Settings:** the stamp preview is bigger and zoomed in, so you can read it.
- **Compass:** steadier — it keeps the last good direction while the camera points at the floor or sky, and skips unsure readings.


## 2.2
- **Tap text in your photos to name the PDF.** The Name PDF screen now shows your photos with every piece of text highlighted. Tap any of it (a shop sign, a number, a name) and it becomes the file name. Swipe to see more photos.
- Smart suggestions and your note are still listed below.


## 2.1
- **Date and Time are separate switches.** Show both, only the date, or only the time. (Your old "Date & Time" choice is kept.)
- **Removed the cover page.** PDFs start straight with your photos. Page numbers and photo notes stay.


## 2.0
A cleaner, more focused StampCam: one great camera mode instead of three.

- **One mode.** Document and ID Photo modes are gone; the mode bar is removed.
- **Tap to focus.** Tap the picture to focus there; then slide up or down to make it brighter or darker. A chip under the picture shows the brightness — tap it to go back to automatic.
- **Richer stamp.**
  - Note line (like a project or client name) on every photo, set in Settings.
  - GPS coordinates.
  - Compass direction the camera faced (like *SW 225°*).
- **Better PDF.**
  - Cover page with the title (your note), date, places and a preview of all photos.
  - Page numbers.
  - Add a note to any photo in Review; it's printed under the photo.
- **Smarter names.** Your note is the first name suggestion; the cover page is skipped when reading text.
- **New look.** Rounded camera preview, round top-bar buttons, a yellow Done button, a bouncier thumbnail, a summary card and a big Create PDF button in Review.
- Unfinished sets from older versions still open (scanned pages and ID photos load as normal photos).


## 1.7 (not released — included in 2.0)
- **Removed Document mode.** StampCam now focuses on two modes: **Photo** and **ID Photo**.
  - The document scanner, the page filters (Magic, No Shadow, Enhanced, Grayscale, B&W) and the "Stamp Documents" setting are gone.
  - Pages scanned with an older version that are still in an unfinished set open as normal photos, so nothing is lost.
- Added this changelog.

## 1.6.1
- Smart file names: skip the stamp's own date, time and area name; ignore handwriting misread as text; join signs written on two lines.
- Document mode: Magic filter tuned on a real crumpled page.
