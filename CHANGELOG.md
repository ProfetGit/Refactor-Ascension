# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.5.1]
- **New: CC alert can announce to party/raid chat** (`RefactorCC.lua`, off by default) — posts a chat line ("Silenced! (Interdict, 3s)") the moment you're stunned, feared, silenced, or otherwise unable to cast, so healers and other key roles get an immediate heads-up to use cooldowns or play defensively. Fires once per CC application (not spammed every tick), auto-picks RAID/PARTY based on your group, and skips rooted/frozen/disarmed since those don't stop a cast bar. Solo with `/rfc debug` on, it echoes locally instead of silently doing nothing, so the toggle can be checked without grouping up.
- **New: scale sliders for the loot toasts and the CC alert** — both the Loot page and the Tweaks page's Crowd control section now have a size slider, so either can be resized to taste independent of UI scale/resolution.
- **New: fullscreen map as a movable window** (`fullMapWindow`, on by default) — the full map becomes the only map mode: a scaled-down window with no black backdrop, draggable by its title strip (mousewheel there resizes), and keyboard movement keeps working instead of being grabbed by the fullscreen shell.
- **New: quick invite** (`quickInvite`, **off by default**) — Alt + Right-Click a player's unit frame, chat name, or model in the game world to invite them to your party. Off by default since it can invite by accident.
- **New: seamless bag upgrade** (`seamlessBagUpgrade`, on by default) — right-clicking a bag while all bag slots are full moves the smallest equipped bag's contents elsewhere and equips the new one in its place, instead of just erroring.
- **New: smart equip for rings, trinkets, and one-handers** (`smartEquip`, on by default, General page) — right-click equipping into a full pair now replaces the *weaker* of the two equipped items under current weights, instead of always the engine's fixed first slot. Implemented as a post-hoc fix-up after the engine's own swap (never by replacing `UseContainerItem`, which would taint every bag click); needs readable stats on both equipped items or it leaves the click alone. Shields/holdables in the off-hand now correctly restrict 1H weapon comparisons to the main hand only, since a 1H nearly always "wins" against a shield under weapon weights — that was pure noise. The tooltip verdict also now names the specific equipped item being beaten ("vs [Item]") when comparing against the weaker of two equipped slots.
- **New: item value on loot toasts** (`showValue`, on by default, Loot page) — the looted stack's auction-house worth is shown right-aligned on the toast's second line. Price source is configurable (`priceSource`): Auto (TSM market value → TSM minimum buyout → Auctionator), Auctionator only, or a specific whitelisted TSM source; sources are re-discovered every time the dropdown opens so installing/removing TSM or Auctionator needs no `/reload`. Vendor price is deliberately never shown — it would report the unscaled base item's price, contradicting the tooltip's own scaled Sell Price line.
- **New: ElvUI bag support** — bag upgrade arrows now also work with ElvUI's bag module (previously stock bags, Bagnon, DragonUI's Combuctor, and AdiBags).
- Gossip/greeting quest auto-selection now also recognizes single quests embedded directly in an NPC's dialogue (no multi-quest hub), which previously fell through both the active and available quest lists undetected. `/rfc debug` now logs each gossip/greeting decision for troubleshooting.
- Percent-based effects ("3% Increased Critical Damage" on meta gems, percent `Equip:` lines) now score as a custom `"<name> %"` stat instead of being silently dropped — weight it via `/rfc weight` or the UI's scanned-stats list, UNKNOWN weight until then.
- A 2H-vs-dual-wield comparison now discounts the offhand's weapon-DPS share by the same dual-wield penalty used elsewhere, instead of crediting it at full value — under-reported real 2H upgrades before.
- Every default class/spec profile now weights Armor slightly (tank specs already did; other specs get a small 0.01 tie-breaker weight instead of ignoring it entirely).
- Fixed quest-reward verdicts never showing on the fullscreen map's quest pane — hooking `QuestInfo_ShowRewards` never actually fired there since every quest-template `elements` table stores a bare reference to it (frozen at FrameXML load, before this addon exists to hook it); switched to hooking `QuestInfo_Display` instead, which every call site invokes by global name and so can actually be intercepted. Also hooked `WorldMapTooltip` directly so map reward tooltips get a verdict at all.
- Quest reward arrow moved to the icon's top-right corner (matches the bag-slot arrow); redundant rescans on every quest-pane redraw are now skipped via a reward-link fingerprint.
- Fixed stacked self-loot lines ("You receive loot: Foo x3.") not matching the loot-alert parser.
- Added profile rename (Stat Weights page) — renames a saved profile in place and remaps every character's remembered pick so alts don't lose it; refuses Default and class-spec profiles since those are found by exact name.
- Config window: reworked to a native-Blizzard three-column layout (stock dialog art, working search box, sticky detail pane) with profile switching, save-as, rename, and delete merged onto the top of the Stat Weights page.

## [1.5.0]
- **New: center-screen crowd-control alert** (`RefactorCC.lua`, on by default) — while you're stunned, feared, polymorphed, or otherwise CC'd, a large icon with a cooldown spiral, mechanic label ("Stunned", "Feared", ...) and countdown appears mid-screen; the 3.3.5 client has no native loss-of-control display. When several CCs overlap, the most severe (then longest) one shows.
- Detection is three layers deep, since this client's `UnitDebuff` exposes no mechanic: a spell-ID table scraped from db.ascension.gg across all 21 CoA classes (~125 CC abilities), a name fallback for charge-style trigger spells that apply their stun under a different ID, and a debuff-tooltip scan ("Stunned.", "Feared." at line start) that catches NPC/boss CC no list could.
- New "Crowd control" section on the Tweaks page: master toggle, "Include roots" and "Include silences and disarms" sub-toggles (both on), plus Move / Reset position / Test alert buttons. Roots show orange, silences gray, hard CC red.
- Bag upgrade arrows now also work with **AdiBags** (previously only stock bags, Bagnon, and DragonUI's Combuctor module).

## [1.4.4]
- **Retuned the default stat weights for every class and spec** — ported from current community theorycraft, replacing the old rough estimates (notable shifts: primary stats and weapon DPS weigh much more, flat hit/expertise weigh less). Also fixed spec-name typos so auto-detection matches the real talent tabs (Sanguine, Wildwalker, Geomancy, Archery, Domination, and friends). Existing saved profiles are untouched; the new defaults apply to newly seeded profiles and the new reset button below.
- New "Reset to defaults" button on the Stat Weights page: discards your edits and restores the active class-spec profile's default weights.
- The class auto-detection now also seeds sensible armor-type filters, and manually editing the armor checkboxes on the General page permanently takes them over for that character (`/rfc auto` hands them back, same as with profiles). (Fixed in the re-released 1.4.4 zip: the armor lookup used the display class name against a normalized-key table, so it silently never applied — neither at login nor from `/rfc auto`.)
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
