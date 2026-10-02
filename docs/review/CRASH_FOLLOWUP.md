# Physical-device crash follow-up — 2 October 2026

The subsequent UI and scrolling overhaul is documented in [UI_SCROLL_REVIEW.md](UI_SCROLL_REVIEW.md).

The earlier tests did not establish that the user's installed build was fixed. Build 38 remained installed on the connected XS Max, and the supplied screenshots show the earlier three-poster Today layout. This follow-up uses physical-device crash reports and image-backed layout tests.

## Recorded failures

- **XR, 28 September, build 38:** `EXC_BREAKPOINT/SIGTRAP` on a background SwiftUI rendering thread. The stack enters `TrackerPalette.adaptive(light:dark:)` from `UIDynamicProviderColor`, then fails Swift's executor check / `_dispatch_assert_queue_fail`. The project defaults to MainActor isolation, so the dynamic color provider inherited an executor restriction that UIKit does not promise. The palette/provider is now explicitly nonisolated. A regression test resolves the actual provider on a detached executor in light and dark traits.
- **XR, 30 September, build 38:** SwiftData assertion while reading `VideoAsset.mimeType`, reached through `isVideo` and `TodayAccountRow.body`. This establishes the failing read, but does not by itself establish the full history that invalidated the object. Today now queries current media by account identity, checks removed records before rendering, and no longer builds its global completion count from retained relationship arrays. Shared folder scans introduced in the preceding fixes also avoid overlapping unique-record reconciliation.

Raw device reports and database snapshots are retained outside the repository in the private local diagnostics directory (`~/.codex/diagnostics/drive-tracker/2026-10-02`); personal media names, identifiers, and crash-report device identifiers are not included here.

## Additional fixes

- Opening a video previously downloaded the entire original before creating `AVPlayerItem`, leaving a temporary file outside the preview's cleanup ownership. Initial previews now construct an authenticated remote streaming asset. The owned local fallback retains download/cleanup behavior. Invalid/canceled download results clean up their temporary file.
- Thumbnail artwork now renders as an overlay within the proposed size. Landscape image aspect ratios cannot expand a narrow grid column. Tests include extreme landscape and portrait images at several widths; UI captures now contain image content rather than only placeholders.
- Disk reads/decodes now share the thumbnail concurrency limit. Canceled cache tasks cannot refill cleared memory after completing a decode.
- Google token refresh previously assigned unchanged `@Published` identity fields for every authorized request. Identity updates now publish only actual changes. A regression test checks 100 identical updates produce no notifications. A refresh from an account that has since switched is rejected.
- Thumbnail initial/cache lookup uses the modification-aware key consistently.
- AVFoundation KVO failure callbacks are created outside MainActor isolation and explicitly dispatch their UI handler to the main actor. A real invalid-file playback test checks failure delivery.

## Verification and installation

**63 native tests passed** with no failures. Signed build 39 succeeded using the existing OAuth configuration and was installed over the existing application on both the iPhone XR and iPhone XS Max. Both local database directories were copied to local temporary backups before installation. Settings now displays the version/build. Both devices report version 1.0 / build 39, launched successfully, and their Tracker processes remained running at the follow-up check. Their original store files remain in place. The image-backed UI capture test passed separately after explicitly preloading and asserting its fixtures. These launch checks do not exercise prolonged playback or prove every private Drive operation.

Synthetic captures: [light](build39-today-light.png), [dark](build39-today-dark.png), [accessibility text](build39-today-large-text.png). The available XS Max Jetsam reports did not name the Tracker. No specific freeze duration or zero-crash guarantee follows from passing unit tests. Continued physical-device use is necessary to establish whether either recorded failure or another crash remains.
