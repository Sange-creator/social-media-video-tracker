# Changelog

All notable changes to Social Media Video Tracker are documented here.

## Unreleased — 2026-08-17

### Backup and repository safety

- Added a confirmed visible video-backup flow that recreates
  `Backup Videos/<account>/<subfolder>` in the active Google Drive account.
- Added resumable Drive uploads and same-name replacement to avoid duplicate
  files on repeated backups.
- Added Photos export support for videos already saved by the tracker.
- Removed real OAuth and Apple signing identifiers from the repository and added
  ignore rules for local credentials, databases, build products, and signing files.

### Responsiveness

- Reduced scroll-time rendering cost by removing reusable blurred card shadows,
  thumbnail borders, and unnecessary layout animations.
- Kept download progress updates throttled and library filtering work shared per
  render.

## 1.0 (Build 35) — 2026-08-09

### Interface

- Reworked the visual system around native iOS typography, semantic colors,
  standard tab navigation, restrained cards, and system light/dark appearance.
- Simplified onboarding into one clear Google connection flow with compact setup
  progress and concise folder guidance.
- Improved Library video cards, download actions, completion states, scrolling,
  thumbnails, and video-preview audio controls.
- Validated authenticated Drive streams before presenting the player and added
  an automatic original-file fallback when AVPlayer rejects a ranged stream.
- Kept play/pause state synchronized with the real AVPlayer state and cleaned up
  temporary fallback previews after dismissal.
- Replaced blocking status dialogs with small temporary bottom messages.

### Performance

- Added persisted analytics snapshots that render immediately and refresh in a
  private SwiftData context instead of querying the full history on tab selection.
- Kept native tab contents prepared to avoid reconstructing sections after taps.
- Eliminated unchanged Drive metadata writes that previously invalidated the
  interface during routine synchronization.
- Reconciled large Drive folders in cooperative batches.
- Deduplicated thumbnail requests, reduced transfer size, cached results, and
  moved image decoding off the UI thread.
- Reduced repeated allocation and sorting when resolving video status.

### Downloads and synchronization

- Added immediate download-start, cancellation, success, and failure feedback.
- Reserved downloads synchronously to prevent accidental duplicate transfers.
- Preserved original Drive files without transcoding before saving to Photos.
- Added quiet foreground Drive polling so newly added files are discovered while
  the app is active.
- Kept automatic synchronization and Drive backup activity non-blocking and
  silent unless an actionable error occurs.

### Verification

- Installed and exercised the release line on an iPhone XR running iOS 18.7.9.
- Preserved the existing on-device SwiftData database during in-place updates.
- Profiled the preceding performance build on the physical device with Xcode
  Instruments and removed the detected main-thread synchronization hitch.
