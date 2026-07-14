# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.3]
- **Auto transmog collection is now OFF by default** — collecting an appearance soulbinds the item, so the old always-on default silently turned sellable BoEs into BoP. A one-time migration disables it on existing installs too (with a chat notice); re-enable it on the Tweaks page.
- When auto-collect is enabled it now only learns from items that are already bound (Soulbound / quest / account-bound tooltip line). A new "Include tradeable items (BoE)" sub-option restores the old fully-automatic behavior for players who want it. Items whose tooltip can't be read yet are skipped and retried on the next bag update — never bound on a guess.
- New "Skip the learn confirmation popup" option (off by default): auto-accepts the "item will become soulbound" confirmation when manually learning an appearance with Ctrl+Shift-click.
- Fixed the wrong compare % flashing on group-loot roll tooltips: while the rolled item's data is still arriving from the server, the verdict fell back to scoring the BASE item from its link, then jumped to the real scaled value when the client re-rendered the tooltip. Roll, loot-window, and quest-reward tooltips now show nothing until the live scaled item can be read (no more false hope), and the verdict recomputes automatically the moment the tooltip re-renders with real data.
- Roll-item scans are no longer cached, so a partially rendered tooltip can't pin a stale % for the cache lifetime.

## [1.4.2]
- Added a Social section to the Tweaks page (all off by default): auto-decline group invites, duels, and guild invites; auto-close trades from players who aren't friends, guildmates, or groupmates; auto-accept player resurrections in battlegrounds. Holding Shift when a request arrives handles it manually, and every auto-handled request prints a chat line naming who it came from.

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
