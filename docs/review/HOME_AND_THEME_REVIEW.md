# Home, theme, and incremental sync — build 41

Consolidation note (22 October 2026): the carousel and ordering UI now includes TikTok/Facebook streams and document captions. Foreground file events use incremental reconciliation; complete catch-up scans retain the newer off-time policy (at most once every 12 hours), rather than the historical per-activation repair described below.

## Home

Each account is one reusable List row with a full, wrapping account name, a quota summary, and a horizontal carousel. Three thumbnail cards fit normal phone widths. Accounts with more than three videos scroll horizontally; accessibility text uses wider cards and horizontal scrolling. Tapping a thumbnail opens the streaming preview. Per-video downloads and action menus remain available, alongside Download all and Shuffle.

Tap Reorder, then drag the native handle to move an account. The list scrolls during dragging. Account order is persisted in sortOrder. Move to top is also available from the account context menu. Hidden/paused accounts retain their position, and video assignment slots are unchanged.

## Shared theme and rendering

Clipboard, Settings, Analytics, Library, account editors, account details, setup, and media details use the shared adaptive palette and semantic system fonts. Clipboard now recycles individual rows. Settings and Analytics use native lists. Library grid mode recycles two-card rows instead of putting an entire grid in one list item. Filenames sit below Library grid thumbnails, rather than over video artwork.

Removed unused GlobalCopyQueueCard, its private duplicate sheet, RowClipboardCard, CopyQueueSetupCard, RadialQuotaProgress, and the onboarding masthead. Their only references were internal to unused components. Removed whole-account thumbnail prefetch from Library: visible cells now own requests, and cancelled cells release them. This prevents a visit to Library from queuing every thumbnail.

## Sync

The previous change monitor reconciled every tracked account for any Drive event and ran another full scan every five minutes. Ordinary file events now use DriveDeltaService to update metadata directly, including nested uploads, moves, removal, and duplicate events. Folder ancestry is cached from scans and resolved for previously unknown parents. Folder changes reconcile the affected account, not all accounts.

DriveChangeTracker commits the cursor only after metadata and assignments succeed. Failures retain it for retry; only HTTP 410 resets it. Foreground change checks run approximately once per second without publishing an activity spinner on every check. Network failures back off to 30 seconds. Checks stop in the background. Optional workspace metadata checks are throttled to once per minute. Full repair is limited to two attempts per foreground activation, after ten and twenty minutes, and only when idle with no active downloads. Initial setup and manual refresh still perform authoritative scans.

Google Drive push notifications require an HTTPS callback server. The current native app has no configured server-to-device event connection. This implementation therefore uses lightweight foreground polling; it cannot promise an upload will appear within exactly one second, particularly while the app is suspended or before Drive publishes the change. A deployed Drive watch receiver plus a foreground signal connection and APNs background notifications is needed for server-triggered refresh. Apple also does not guarantee background notification delivery.

- [Google Drive push notification requirements](https://developers.google.com/workspace/drive/api/guides/push)
- [Apple background update delivery](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## Verification

The full native suite passed: 75 tests, zero failures (`/tmp/Tracker41ShipQA.xcresult`). This includes direct upload processing with zero folder-list calls, idempotent duplicate events, nested uploads, file moves preserving completed history, folder removal, failed ancestry requests retaining cursors, persisted reordering of 20 accounts without changing slots, narrow carousel widths, and repeated vertical/horizontal scrolling through 20 accounts and 100 previews. Twelve additional screens are rendered in theme checks; Home is rendered in light, dark, and accessibility text modes.

These tests establish rendering, reuse, and model correctness. They do not measure physical scrolling FPS or real Google Drive propagation latency. Device installation and final small layout checks are recorded below when complete.

Final small layout checks passed: 8 targeted rendering/ordering tests, zero failures (`/tmp/Tracker41LayoutFinal.xcresult`). Signed Release build 41 compiled successfully, and git diff --check passed.

Build 41 was installed on both iPhone XR and iPhone XS Max; device app inventories independently confirmed bundle version 41. XR launched successfully and remained present in the running-process inventory. XS Max launch verification was blocked by the device lock. Both pre-install data backups passed SQLite quick_check. Installation did not uninstall the app or erase its data container. Physical scrolling frame rates and live Drive upload latency remain unmeasured.
