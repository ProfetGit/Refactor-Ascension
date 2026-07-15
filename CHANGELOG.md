# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.4]
- **Retuned the default stat weights for every class and spec** — ported from current community theorycraft, replacing the old rough estimates (notable shifts: primary stats and weapon DPS weigh much more, flat hit/expertise weigh less). Also fixed spec-name typos so auto-detection matches the real talent tabs (Sanguine, Wildwalker, Geomancy, Archery, Domination, and friends). Existing saved profiles are untouched; the new defaults apply to newly seeded profiles and the new reset button below.
- New "Reset to defaults" button on the Stat Weights page: discards your edits and restores the active class-spec profile's default weights.
- The class auto-detection now also seeds sensible armor-type filters, and manually editing the armor checkboxes on the General page permanently takes them over for that character (`/rfc auto` hands them back, same as with profiles).
- New `client-patch/` folder with one-click `install-silent-fizzles.cmd` / `uninstall-silent-fizzles.cmd` scripts (plus the five silent `.wav` files they copy into the game root) so anyone can install the fizzle mute without hand-editing game folders.
- New "Mute cast-deny sounds" option on the Tweaks page (on by default). Companion to the silent-sound client patch: the engine plays a spell-school fizzle when a cast is denied (cooldown spam, not enough resource), and it can't be muted per-sound from Lua, so the patch replaces the five fizzle files with silent loose copies under the game root's `Sound\` folder. With the patch installed the engine always plays silence; while this option is unticked the addon replays a bundled original (`sounds\FizzleHolyA.wav` — the error text carries no spell school, so the replay doesn't vary by school) on the matching error events. The checkbox therefore works as an instant in-game mute, no restart. Without the patch the engine sound still plays and unticking doubles it.

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
