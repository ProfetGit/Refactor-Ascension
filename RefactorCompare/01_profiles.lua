-- RefactorCompare
-- Weighted stat gear comparison for Ascension's classless 3.3.5 client.
--
-- Scores every item as: sum of (stat amount x your chosen weight), then
-- compares that score against what you currently have equipped in the
-- matching slot(s) and shows the % difference on the tooltip (green =
-- upgrade, red = downgrade). Weapons additionally count DPS (parsed from
-- the tooltip) as a weighted pseudo-stat, since raw stat totals don't
-- capture weapon value.
--
-- Stats are read by scanning the item's real tooltip (SetBagItem /
-- SetInventoryItem): Ascension scales items, and the base-item APIs
-- (GetItemStats, SetHyperlink) report unscaled values that make scaled
-- gear compare wrong. The same scan also picks up custom Ascension
-- stats ("+N Something") and flat "Equip:" rating lines.
--
-- The line parser ports Pawn's algorithm (kill lines that stop at set
-- lists, "Stamina +5" normalization, separator-splitting of compound
-- gem/enchant lines, All Stats expansion, active-only socket bonuses,
-- empty-socket credit, DPS reconstructed from damage range x speed) on
-- top of our instance scanning — Pawn itself reads base links, which is
-- exactly what Ascension scaling breaks. Percent effects ("3% Increased
-- Critical Damage", percent "Equip:" lines) score as custom "<name> %"
-- stats since no rating conversion exists for them.
--
-- Trust rules: a verdict is only shown when BOTH sides were read from
-- live scaled instances just now. If either tooltip can't be read, show
-- nothing rather than guess. Scores derived from a bare link (chat
-- links, cached other-character bags) are estimates: shown like any
-- other verdict, but they never produce a bag arrow or loot alert.
--
-- Settings (weights, armor-type filter, profiles, thresholds) persist in
-- the RefactorCompareDB saved variable. Profiles are account-wide (so an
-- alt can reuse one), but each character remembers which profile it last
-- switched to and that's what's active when it logs back in — picking a
-- profile on one alt doesn't silently change what another alt sees.
--
-- Slash commands (/rfc and /refactor are interchangeable):
--   /rfc                     open/close the config panel
--   /rfc toggle              enable/disable the whole feature
--   /rfc bagicons            toggle the green upgrade arrow on bag item slots
--   /rfc alert               toggle loot-moment upgrade alerts
--   /rfc quality <0-5>       minimum item quality to evaluate
--   /rfc weight <stat> <n>   set a weight (works for scanned custom stats too)
--   /rfc hitcap <off|melee|ranged|spell>  value hit only until the cap (per profile)
--   /rfc hitcap pvp                       toggle PvP cap target (lower %)
--   /rfc auto                forget the manual profile pick, resume class/spec auto-selection
--   /rfc profile <name>      switch to a saved profile
--   /rfc profile save <name> save current weights as a profile
--   /rfc profile delete <name>
--   /rfc profile list
--
-- This feature is split across RefactorCompare/01..10 (loaded in that
-- order by Refactor.toc — every file is its own Lua chunk, so state that
-- needs to cross file boundaries lives on the RefactorCompareInternal
-- table instead of as a bare `local`, which is invisible outside the
-- chunk that declares it. `RefactorCompareDB` (the saved variable) is a
-- real global already, so it's used directly everywhere instead of the
-- monolithic file's old `local db` alias.

--------------------------------------------------------------------------
-- Saved variables & defaults
--------------------------------------------------------------------------

RefactorCompareInternal = RefactorCompareInternal or {}
local C = RefactorCompareInternal

-- Stats the config panel exposes; values are matched from tooltip text
-- via STAT_NAME_KEYS below. DPS and UNKNOWN are pseudo-stats: DPS is
-- parsed from weapon tooltips, UNKNOWN is the default weight applied to
-- any scanned custom stat that doesn't have its own weight set.
local STATS = {
    { key = "STR",    label = "Strength",
      tip = "Attack power and block value. Core stat for Strength melee builds." },
    { key = "AGI",    label = "Agility",
      tip = "Crit, armor and attack power for Agility builds; dodge for tanks." },
    { key = "STA",    label = "Stamina",
      tip = "Health. Worth a little to everyone, a lot to tanks." },
    { key = "INT",    label = "Intellect",
      tip = "Mana pool and spell crit. Core caster stat." },
    { key = "SPI",    label = "Spirit",
      tip = "Health and mana regeneration. Mostly matters for healers." },
    { key = "CRIT",   label = "Crit Rating",
      tip = "Increases critical strike chance (melee, ranged and spells)." },
    { key = "HASTE",  label = "Haste Rating",
      tip = "Faster attacks and casts." },
    { key = "HIT",    label = "Hit Rating",
      tip = "Reduces your chance to miss. Very valuable until you're hit-capped, near worthless after." },
    { key = "EXP",    label = "Expertise",
      tip = "Reduces the target's chance to dodge or parry your melee attacks." },
    { key = "ARP",    label = "Armor Pen",
      tip = "Your physical attacks ignore part of the target's armor." },
    { key = "SP",     label = "Spell Power",
      tip = "Increases spell damage and healing." },
    { key = "AP",     label = "Attack Power",
      tip = "Raw melee/ranged power. Roughly half as valuable as a point of your primary stat." },
    { key = "MP5",    label = "Mana per 5",
      tip = "Mana regenerated every 5 seconds, even while casting." },
    { key = "DEF",    label = "Defense",
      tip = "Avoidance and crit reduction for tanks." },
    { key = "DODGE",  label = "Dodge Rating",
      tip = "Chance to dodge attacks entirely. Tank stat." },
    { key = "PARRY",  label = "Parry Rating",
      tip = "Chance to parry melee attacks. Tank stat." },
    { key = "BLOCK",  label = "Block Rating",
      tip = "Chance to block with a shield. Only matters with a shield equipped." },
    { key = "RESIL",  label = "Resilience",
      tip = "Reduces damage and crit chance taken from players. PvP stat." },
    { key = "ARMOR",  label = "Armor",
      tip = "Physical damage reduction. Items carry big armor numbers, so keep this weight tiny (~0.02)." },
    { key = "SOCKET", label = "Empty Socket",
      tip = "Score credit per empty gem socket. 0 (default) counts only stats actually on the item — the strict 'never worse' promise. If you always gem your gear, set this to roughly what a typical gem scores (gem stat × its weight)." },
    { key = "DPS",    label = "Weapon DPS",
      tip = "Damage per second read from the weapon tooltip. One point of DPS beats many raw stat points — default weight 8." },
    { key = "UNKNOWN", label = "Unknown (scanned)",
      tip = "Fallback weight for scanned custom Ascension stats that have no weight of their own. Give one its own value with /rfc weight <stat name> <value>." },
}

local DEFAULT_WEIGHTS = {
    STR = 1.0, AGI = 1.0, STA = 0.6, INT = 1.0, SPI = 0.4,
    CRIT = 0.9, HASTE = 0.9, HIT = 0.9, EXP = 0.9, ARP = 0.9,
    SP = 0.85, AP = 0.45, MP5 = 1.0,
    DEF = 0.3, DODGE = 0.6, PARRY = 0.6, BLOCK = 0.3, RESIL = 0.5,
    ARMOR = 0.02,
    SOCKET = 0,     -- empty sockets promise nothing until a gem goes in
    DPS = 8.0,      -- one point of weapon DPS is worth a lot of raw stats
    UNKNOWN = 0.5,  -- default for tooltip-scanned custom stats
}

local DEFAULTS = {
    enabled = true,
    lootAlert = true,
    bagIcons = true,
    secondaryBagArrow = false, -- off by default: blue secondary-verdict arrow on bag icons
    smartEquip = true, -- right-click equip replaces the weaker of a slot pair
    minQuality = 2, -- ignore items below Uncommon so junk doesn't clutter tooltips
    -- Legacy account-wide armor filter. Kept only as the migration source
    -- for charArmorTypes below — nothing reads it for filtering any more.
    armorTypes = { Cloth = true, Leather = true, Mail = true, Plate = true },
    activeProfile = "Default",
    profiles = {
        Default = { weights = {}, customWeights = {} },
    },
    -- charKey -> last profile name active on that character (however it
    -- got selected). Profiles themselves stay account-wide (shared/
    -- reusable across alts), but each character remembers which one it
    -- last had so login doesn't silently keep whatever the last-played
    -- character left active.
    charProfiles = {},
    -- charKey -> profile name AutoApplyClassSpec last picked for that
    -- character.
    charAutoProfile = {},
    -- charKey -> profile name the player deliberately switched to (config
    -- window / slash command). Only these count as "user has chosen" —
    -- charProfiles can't be used for that, since it records auto picks and
    -- plain logins too. Cleared back to auto-managed by /rfc auto.
    charManualProfile = {},
    -- charKey -> { Cloth = bool, Leather = bool, Mail = bool, Plate = bool }.
    -- Which armor types this character wants considered for upgrades. Per
    -- character, because it's a preference about one character's gearing:
    -- when this was one account-wide table, logging an alt rewrote it for
    -- everybody (issue #26 — a Cloth alt stripped Plate/Mail off a
    -- Starcaller). Nothing sets it automatically; armor the character
    -- genuinely can't wear is already blocked by the red proficiency line
    -- in the tooltip scan (03_scan.lua), which — unlike a hardcoded
    -- per-class table — tracks proficiencies learned on Ascension.
    charArmorTypes = {},
    -- Dead since the auto armor override was removed (see charArmorTypes).
    -- Left in defaults so old saves keep merging cleanly.
    charManualArmor = {},
    -- charKey -> profile name shown as a SECOND verdict (blue) alongside
    -- the active profile's on tooltips and bag arrows, for hybrid builds
    -- gearing two roles at once. Manual-only — auto-selection never picks
    -- one. nil entry = feature off for that character.
    charSecondaryProfile = {},
}

local function CopyTable(src)
    local t = {}
    for k, v in pairs(src) do
        t[k] = type(v) == "table" and CopyTable(v) or v
    end
    return t
end

-- Fill missing keys in dst from src, recursing into subtables. Never
-- overwrites values the user already has, so new defaults added in later
-- versions merge in cleanly.
local function MergeDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            MergeDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function ActiveProfile()
    local p = RefactorCompareDB.profiles[RefactorCompareDB.activeProfile]
    if not p then
        RefactorCompareDB.activeProfile = "Default"
        p = RefactorCompareDB.profiles.Default
    end
    return p
end

local function Weights()
    return ActiveProfile().weights
end

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

local ARMOR_TYPE_NAMES = { "Cloth", "Leather", "Mail", "Plate" }

-- This character's armor-type filter, created on first access. The
-- account-wide table it replaces is inherited exactly ONCE, by whichever
-- character is logged in when the upgraded addon first runs
-- (migratedArmorPerChar, on the DB root like the other migration flags),
-- so that character keeps what it had. Everyone after that starts from
-- all four types on — the honest default, since armor a character truly
-- can't wear is already blocked by the red proficiency line in the
-- tooltip scan. Inheriting the old table for every new character would
-- just re-import the account-wide bug it exists to fix.
local function ArmorTypes()
    local key = CharKey()
    local t = RefactorCompareDB.charArmorTypes[key]
    if not t then
        t = {}
        local legacy = not RefactorCompareDB.migratedArmorPerChar
            and RefactorCompareDB.armorTypes
        for _, at in ipairs(ARMOR_TYPE_NAMES) do
            t[at] = not legacy or legacy[at] ~= false
        end
        RefactorCompareDB.charArmorTypes[key] = t
        RefactorCompareDB.migratedArmorPerChar = true
    end
    return t
end

-- The profile supplying the second (blue) verdict, or nil: unset, pointing
-- at a deleted profile, or the same as the active profile (identical
-- verdicts would just be noise). Manual-only per character — see DEFAULTS.
local function SecondaryProfile()
    local name = RefactorCompareDB.charSecondaryProfile[CharKey()]
    if not name or name == RefactorCompareDB.activeProfile then return nil end
    return RefactorCompareDB.profiles[name]
end

-- Changes RefactorCompareDB.activeProfile and remembers the pick against
-- this character, so next login on THIS character re-applies it instead
-- of inheriting whatever the last-played alt left active. Internal: does
-- NOT mark the switch as a deliberate user choice — AutoApplyClassSpec
-- uses this.
local function ActivateProfile(name)
    RefactorCompareDB.activeProfile = name
    RefactorCompareDB.charProfiles[CharKey()] = name
end

-- The user-facing switch (config window, slash command): additionally
-- records the pick as deliberate, which tells AutoApplyClassSpec to stop
-- managing this character's profile until the choice matches its own
-- suggestion again (or /rfc auto clears it).
local function SetActiveProfile(name)
    ActivateProfile(name)
    RefactorCompareDB.charManualProfile[CharKey()] = name
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor|r: " .. msg)
end

C.STATS = STATS
C.DEFAULT_WEIGHTS = DEFAULT_WEIGHTS
C.DEFAULTS = DEFAULTS
C.CopyTable = CopyTable
C.MergeDefaults = MergeDefaults
C.ActiveProfile = ActiveProfile
C.Weights = Weights
C.CharKey = CharKey
C.ARMOR_TYPE_NAMES = ARMOR_TYPE_NAMES
C.ArmorTypes = ArmorTypes
C.SecondaryProfile = SecondaryProfile
C.ActivateProfile = ActivateProfile
C.SetActiveProfile = SetActiveProfile
C.Print = Print
