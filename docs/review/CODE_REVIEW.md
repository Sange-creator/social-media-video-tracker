# Code review and reliability fixes — 1 October 2026

The subsequent UI and scrolling overhaul is documented in [UI_SCROLL_REVIEW.md](UI_SCROLL_REVIEW.md).

This review covers the native SwiftUI/SwiftData app, its Drive and workspace synchronization, media playback and thumbnail lifecycle, daily assignments, and the Next.js dashboard/API/database. Changes are implemented in this checkout. The backend changes have not been deployed. Following the [physical-device crash investigation on 2 October](CRASH_FOLLOWUP.md), native build 39 was installed on both iPhones; that follow-up records the newer 63-test result, crash evidence, and launch checks.

## Findings and fixes

| Priority | Finding | Implemented change |
|---|---|---|
| High | Startup maintenance did not actually scan Drive; foreground monitoring could start before Google authentication restored. | Start maintenance and monitor after authentication is available; resume checks in the foreground. |
| High | Capturing the change token after a folder scan could skip uploads made during that scan. Failed scans could lose the cursor needed to retry. | Capture the baseline before reconciliation; advance only after success. Preserve cursors on network/permission failure; reset only expired cursors. |
| High | Sync shared the general work flag, allowing nested operations to wait on themselves. Concurrent direct folder scans could reconcile the same files twice. | Separate sync state from other work, coalesce requests, and share an in-flight folder scan. |
| High | Scanning a sole account's source root could include sibling folders outside the configured account. | Always scan the account's explicit folder reference. Reject results after account deletion, reassociation, or Google identity changes. |
| High | The dashboard read only one Drive page and only updated on manual refresh. | Read every page; refresh while visible every 10 seconds and on focus. Reject partial listings and ignore stale responses from previous navigation. |
| High | Backend connections did not queue their first scan. Discovered media lacked access paths, making it invisible under permissions. | Queue the initial scan; atomically reconcile metadata and grant access paths, including nested folders. |
| High | Notifications during an active backend scan could disappear; abandoned jobs could stay running forever. | Coalesce jobs while retaining the latest requested timestamp; repair stale jobs and periodically reconcile connections. |
| High | Assignment deltas lacked timestamps and sync could return truncated/partial results with an advanced cursor. | Add update triggers and keyset pagination by timestamp and ID. Fail the response if any page fails. |
| High | Missing database policies broke authenticated caption/assignment operations. Assignment routes bypassed member permissions using the service role. | Use the caller's token; add member policies, confine assignment writes to the account's grant, and deny foreign/viewer writes. |
| High | A public default admin password/signing key and missing worker secret exposed privileged paths. Fake database responses concealed configuration failures. | Remove defaults and simulated success; optional admin login requires explicit configuration. Worker invocation requires `CRON_SECRET`; missing backend configuration fails visibly. |
| High | Workspace tokens, cursors, and pending operations could outlive a Google account switch. One forbidden queued operation blocked all remaining edits. | Scope tokens/cursors/outbox operations to the identity, validate the account after async work, deduplicate retries, and skip per-record authorization/conflict failures while preserving the pending edit. |
| High | Playback could install an old player after dismissal; observer cleanup and fallback transitions were unsafe. Invalid media times could trap integer conversion. | Cancel owned tasks, detach player/observers before deleting temporary files, discard late results, validate local playback, recover initial stream failures, and guard time/seek values. |
| Medium | Repeated unchanged saves invalidated SwiftData views during scrolling. Full-resolution thumbnail fallback and a large memory cache increased pressure. | Save only changed metadata/workflow state, batch large reconciliation cooperatively, reduce cache size, decode thumbnails away from the UI thread, and correct canceled request-slot accounting. |
| Medium | Fixed tiny poster columns hid items beyond slot three and made labels/actions difficult to read. Download progress observed the wrong object. | Replace Today posters with aligned rows that show the quota, use semantic fonts and larger controls, observe download state, and adapt clock/grid layout to accessibility text. |
| Medium | Photo completions consumed the daily video quota; the shuffle button only refilled assignments. Missing files remained active suggestions. | Count videos for video quotas, call the actual shuffle operation, and retire untouched missing-file suggestions while preserving history. |
| Medium | Polling could overwrite caption drafts; failed saves/deletes displayed successful local changes. Starred/Trash queried the wrong collection. | Preserve drafts, apply mutations after remote success, show failures, query the actual collections, and allow restoring trashed files. |
| Medium | Native scans did not read Drive descriptions, so dashboard captions were absent in newly discovered native media. | Fetch descriptions and import them without overwriting workspace-managed or unsynchronized local edits. |
| Medium | Persistent-store failure silently selected another store or an in-memory store. | Show a recoverable startup error and retry the original persistent store, preserving existing data. |

## Verification

- Native automated tests cover cursor ordering/retries/account switches, a 2,000-file reconciliation, unchanged-write behavior, overlapping scans, assignments, workspace ownership, invalid playback times, and existing app workflows.
- Native UI renders are captured and inspected in light mode, dark mode, and accessibility text size. These use synthetic data, not a live account. Render tests are smoke checks, not pixel baselines or scrolling frame-rate benchmarks.
- Dashboard tests import production TypeScript, exercise multi-page Drive and delta reads, failure behavior, backend scans, and collection queries. Database tests execute both migrations in embedded PostgreSQL with RLS enabled, including caption permissions, cross-grant assignment rejection, missing-file retention, and notification coalescing.
- TypeScript checking, ESLint, and the Next.js production build are checked separately.
- Browser QA uses a production server and mocked Drive responses: a new upload appears without pressing Sync, a draft survives polling, and a denied caption save displays an error without fake success.

Final result: **58 native tests passed, 22 dashboard tests passed**, no failures. Type checking, lint, and production build passed. Browser checks confirmed automatic discovery, draft preservation, and denied-save behavior.

Synthetic UI captures: [Today light](today-light.png), [Today dark](today-dark.png), [Today accessibility text](today-large-text.png), [Dashboard automatic refresh and save failure](dashboard-qa.png).

## Release requirements

1. Apply `dashboard/supabase/migrations/002_sync_reliability.sql` after migration 001 **before** deploying these API changes. It adds the functions, columns, indexes, triggers, and policies required by the new worker and delta API.
2. Configure the real Supabase and Google OAuth settings, token encryption key, public app URL, and server-only `CRON_SECRET`. Schedule an authenticated **POST** to `/api/v1/internal/sync` (for example every minute). Webhooks enqueue work; a scheduler must execute it. No production scheduler was created in this review.
3. Deploy the dashboard/backend and rebuild/install the native app using the existing production signing/OAuth setup.
4. Verify with the real account: upload, rename, remove, and move files in a nested granted folder; keep the app open; verify automatic discovery without repeated reloads. Repeat after account switching and reconnecting.
5. On a physical device, play a long video, scrub repeatedly, dismiss/reopen the player, interrupt connectivity, and profile scrolling while a large folder sync runs. Collect an actual crash report if the reported mid-video crash recurs.

## Remaining limits and review follow-ups

- This work cannot establish zero latency or prove the absence of crashes. Foreground native checks run approximately every five seconds **plus request/scan time**; the dashboard polls approximately every ten seconds. iOS background scheduling and network availability remain external constraints.
- The reported mid-video crash was not reproduced from a supplied crash log. The identified lifecycle/time-conversion failure paths are hardened and unit checks pass; long-duration physical-device playback remains unverified.
- No authenticated private Drive or deployed Supabase end-to-end test was possible in this checkout. Mocked responses and embedded database tests do not validate production OAuth credentials, webhook delivery, hosted RLS configuration, or quotas.
- Backend scans still walk complete granted folder trees. They do not yet apply individual Drive changes or follow Drive shortcuts; native scans support shortcuts. Very large libraries need live timing and memory measurements before setting a responsiveness target.
- Concurrent server-side daily assignment generation is not a single transactional quota allocation; database uniqueness prevents duplicate media/day assignments, but parallel generators can still race slot allocation. This needs a separate transactional design if multiple devices generate at the same time.
- Workspace-managed captions and direct Drive-description edits remain separate authorities after initial import. The browser's direct Drive editing does not automatically create a workspace caption revision for existing workspace-managed records.
- Legacy pending workspace operations without an identity are retained locally but are not replayed into an arbitrary signed-in account. Their drafts require explicit recovery under the correct account.
- Optional local admin login is a separately configured privileged mode; workspace collaboration should use verified Supabase identities. Broad privileged-route design and production authorization require a dedicated security audit.
