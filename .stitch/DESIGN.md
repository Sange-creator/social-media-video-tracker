---
name: VideoTracker Pro
colors:
  surface: '#090a0f'
  surface-dim: '#090a0f'
  surface-bright: '#1f2433'
  surface-container-lowest: '#050608'
  surface-container-low: '#0d0f16'
  surface-container: '#131622'
  surface-container-high: '#1a1e2c'
  surface-container-highest: '#222739'
  on-surface: '#f8fafc'
  on-surface-variant: '#94a3b8'
  inverse-surface: '#f8fafc'
  inverse-on-surface: '#090a0f'
  outline: '#334155'
  outline-variant: '#1e293b'
  surface-tint: '#38bdf8'
  primary: '#38bdf8'
  on-primary: '#032136'
  primary-container: '#0c4a6e'
  on-primary-container: '#e0f2fe'
  secondary: '#818cf8'
  on-secondary: '#1e1b4b'
  secondary-container: '#312e81'
  on-secondary-container: '#e0e7ff'
  tertiary: '#34d399'
  on-tertiary: '#022c22'
  tertiary-container: '#064e3b'
  on-tertiary-container: '#d1fae5'
  error: '#f87171'
  on-error: '#450a0a'
  error-container: '#7f1d1d'
  on-error-container: '#fee2e2'
  background: '#090a0f'
  on-background: '#f8fafc'
  surface-variant: '#1a1e2c'
typography:
  display-lg:
    fontFamily: Outfit
    fontSize: 36px
    fontWeight: '700'
    lineHeight: 44px
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: Outfit
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 34px
    letterSpacing: -0.01em
  headline-md:
    fontFamily: Outfit
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 26px
  body-lg:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: '500'
    lineHeight: 18px
    letterSpacing: 0.01em
  label-sm:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.04em
rounded:
  sm: 0.375rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.25rem
  2xl: 1.5rem
  full: 9999px
spacing:
  container-margin: 16px
  gutter: 12px
  section-gap: 24px
  stack-sm: 8px
  stack-md: 14px
---

# Design System: Social Media Video Tracker Pro

## 1. Visual Atmosphere & Philosophy
A precision, tactile dark-mode studio designed for professional content creators managing multi-account video queues from Google Drive. The aesthetic balances high-density information architecture with luxurious obsidian glass surfaces, crisp micro-borders, and instant clarity. Every action communicates tactile responsiveness with purposeful spring feedback.

## 2. Color Palette & Roles
- **Obsidian Canvas** (`#090A0F`): Deep, ink-dark backdrop providing contrast for rich video thumbnails.
- **Glass Surface** (`#131622`): Primary card container with 1px hairline border (`#222739`).
- **Elevated Chamber** (`#1A1E2C`): Floating header cards, modal sheets, and active bento tiles.
- **Electric Cyan** (`#38BDF8`): Primary action accent, download progress fills, and active indicators.
- **Vibrant Emerald** (`#34D399`): Completed video status, quota achievements, and success validation.
- **Amber Sun** (`#FBBF24`): Quota deficit alerts, pending review tags, and carry-over indicators.
- **Slate Text** (`#F8FAFC`): Crisp high-contrast primary typography.
- **Muted Silver** (`#94A3B8`): Secondary metadata, folder paths, and timestamp labels.

## 3. Typographic Hierarchy
- **Display**: Outfit Bold (36px / 28px) with tight tracking for quota counters and hero figures.
- **Headlines**: Outfit SemiBold (20px) for account titles, section headers, and modal titles.
- **Body & Captions**: Inter Regular & Medium (14px / 13px) for folder paths, descriptions, and sheet text.
- **Monospace Numbers**: JetBrains Mono for durations, aspect ratios, file sizes, and timecodes.

## 4. Component Stylings
- **Bento Quota Card**: Asymmetric split card displaying today's progress circle, remaining quota count, and quick sync status.
- **Account Stream Row**: Horizontal thumbnail preview strip of today's suggested videos with quick-download action and carryover badge.
- **Video Card**: 9:16 vertical poster ratio with dark gradient scrim, duration pill top-right, status badge bottom-left, and quick preview tap zone.
- **Copy Queue Drawer**: Floating glass chip with one-tap clipboard copy for titles and hashtags with tactile haptic checkmark.
- **Bottom Navigation**: Floating pill dock with glass blur, minimal icons, and active cyan indicator.

## 5. Anti-Patterns (Banned)
- NO generic iOS system grouped gray backgrounds.
- NO purple neon button glows or oversaturated drop shadows.
- NO cluttered 3-column equal metric boxes.
- NO raw unformatted text blocks.
- NO emojis in system chrome.
- NO pure black `#000000` flat cutouts.
