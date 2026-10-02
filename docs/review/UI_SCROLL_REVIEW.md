# Native UI and scrolling review — build 40

The Today screen, account detail, and default Library view now use native List rows. System typography, standard navigation titles, restrained spacing, bounded thumbnails, and visible action menus replace the oversized nested poster cards. Large accessibility text changes the media row to a vertical layout.

## Findings and corrections

| Finding | Correction |
| --- | --- |
| Nested lazy stacks made an entire account, including its media, the unit of scrolling work. | Each video is a separate recycled list row; account detail and the default Library view follow the same pattern. |
| Wide thumbnail content escaped narrow cards; filenames competed with status and download buttons. | Today uses fixed 56 × 72 thumbnails, readable filenames, separate status text, and consistent 44-point controls. |
| Today repeated filtering of all media for every account. | One media pass builds an account index; regressions cover foreign users, paused accounts, photos, and completed items removed from Drive. |
| Thumbnail network work continued after cells disappeared. | Reference-counted consumers cancel a request when its last consumer disappears. Shared requests survive cancellation of one consumer. Disk/network/decode concurrency remains bounded. |
| Several screens repeated giant custom titles and inconsistent typography. | Standard navigation titles and semantic system fonts across Today, Library, Accounts, Analytics, and Settings. |
| Previous physical installs were Debug builds. | Build 40 is compiled with Release optimization for both physical phones. |

## Validation

The final native suite passed: **67 tests, 0 failures** (`/tmp/TrackerUI40Verified.xcresult`). The signed Release build succeeded. **Release build 40 is installed on both the iPhone XR and iPhone XS Max.** Both successfully launched, and their existing database files remain present. The initial XR wireless timeout and XS Max lock-screen launch block were resolved on retry. Screenshots below are rendered with actual image fixtures in the simulator, rather than empty placeholders. The feed benchmark uses 40 accounts, 2,000 media items, and 120 queued videos; it averaged approximately 16 ms across ten measurements in the simulator (first sample 31 ms; subsequent samples approximately 14 ms). This measures feed construction, not scrolling frame rate.

- [Light appearance](build40-today-light.png)
- [Dark appearance](build40-today-dark.png)
- [Accessibility text](build40-today-large-text.png)

## Limits

Automated layout and model tests cannot establish physical scrolling FPS or guarantee that all freezes are eliminated. Live Drive propagation depends on network availability and Drive API polling; iOS background execution is scheduled by the system. The optional Library grid remains available, while the default list uses individual reusable rows.

The earlier crash investigation and synchronization fixes remain documented in [CRASH_FOLLOWUP.md](CRASH_FOLLOWUP.md) and [CODE_REVIEW.md](CODE_REVIEW.md).

## Design and performance references

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/foundations): native hierarchy, readability, adaptable typography.
- [Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks/): lazy construction and scrolling work.
- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance): view dependencies and measurement.
