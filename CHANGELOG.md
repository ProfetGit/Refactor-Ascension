# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.1]
- Moved the default loot toast position from mid-screen center to the lower right, clear of the right action bars, the first bag column, and the bottom bars. Dragged anchor positions are unaffected.
- Fixed stale docs: CLAUDE.md no longer claims a `/rfct` slash command (toast controls live on the config window's Loot page); class count corrected to 21; README no longer says screenshots are "coming soon" now that `docs/images/` has them.
- Set a real `Author` in `Refactor.toc`.

## [1.4]
- Reworked the tooltip verdict line and loot toast visuals (borderless classic-style banner, quality-colored hairlines, pulsing upgrade arrow).
- Added README and `docs/` screenshots.
- Untracked `CLAUDE.md` from version control; added `.gitignore`.
- Added MIT license and GitHub issue templates.

## [1.0] – [1.3]
- Initial addon: weighted stat gear comparison, class/spec default weight profiles, bag upgrade arrows, loot toasts, and quality-of-life tweaks (fast auto-loot, quest automation, transmog auto-collect, tooltip tweaks).
- In-game config window (`/rfc`) covering General, Stat Weights, Profiles, Loot, and Tweaks pages, plus a minimap button.
