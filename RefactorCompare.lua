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

--------------------------------------------------------------------------
-- Saved variables & defaults
--------------------------------------------------------------------------

local db -- becomes RefactorCompareDB after ADDON_LOADED

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
    -- charKey -> true once the player manually edits the General page's
    -- armor-type checkboxes. Stops AutoApplyClassSpec from overwriting
    -- their choice; cleared by /rfc auto like charManualProfile.
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
    local p = db.profiles[db.activeProfile]
    if not p then
        db.activeProfile = "Default"
        p = db.profiles.Default
    end
    return p
end

local function Weights()
    return ActiveProfile().weights
end

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

-- The profile supplying the second (blue) verdict, or nil: unset, pointing
-- at a deleted profile, or the same as the active profile (identical
-- verdicts would just be noise). Manual-only per character — see DEFAULTS.
local function SecondaryProfile()
    local name = db.charSecondaryProfile[CharKey()]
    if not name or name == db.activeProfile then return nil end
    return db.profiles[name]
end

-- Changes db.activeProfile and remembers the pick against this character,
-- so next login on THIS character re-applies it instead of inheriting
-- whatever the last-played alt left active. Internal: does NOT mark the
-- switch as a deliberate user choice — AutoApplyClassSpec uses this.
local function ActivateProfile(name)
    db.activeProfile = name
    db.charProfiles[CharKey()] = name
end

-- The user-facing switch (config window, slash command): additionally
-- records the pick as deliberate, which tells AutoApplyClassSpec to stop
-- managing this character's profile until the choice matches its own
-- suggestion again (or /rfc auto clears it).
local function SetActiveProfile(name)
    ActivateProfile(name)
    db.charManualProfile[CharKey()] = name
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor|r: " .. msg)
end

-- Forward-declared: defined near the bottom (needs RefactorUI), but
-- AutoApplyClassSpec above it wants to refresh an open config window.
-- RefreshOpenBags likewise (defined mid-file): the armor auto-apply
-- changes db.armorTypes, which moves verdicts, and with the generation-
-- counted memos a verdict-moving change MUST refresh or the memos serve
-- stale results until some unrelated refresh happens by.
local RefreshConfig
local RefreshOpenBags

--------------------------------------------------------------------------
-- Class/spec default weights
--------------------------------------------------------------------------

-- Per-class, per-spec default weights (Ascension's 22 classless "classes",
-- each with 3-4 talent-tree specs). Keyed by the non-localized class token
-- (UnitClass's 2nd return) -> ordered list of { name = spec name (talent
-- tab name, as returned by GetTalentTabInfo), weights = STATS-key weight
-- table }. These seed a per-class-spec profile the first time it's seen
-- (see AutoApplyClassSpec below); they never overwrite a profile that
-- already exists, so editing the weights or spinning off a custom profile
-- sticks. The first entry in each list also serves as the placeholder
-- default before level 10, when no spec has been chosen yet.
local CLASS_SPEC_WEIGHTS = {
    BARBARIAN = {
        { name = "Headhunting", weights = { AGI = 1.473, CRIT = 0.65, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brutality",   weights = { STR = 2.188, AGI = 1.537, CRIT = 0.761, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Ancestry",    weights = { STR = 1, AGI = 1.387, CRIT = 0.5, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.25, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    BLOODMAGE = {
        { name = "Fleshweaver", weights = { INT = 1, SPI = 0.621, CRIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Sanguine",    weights = { STA = 0.27, INT = 1, SPI = 0.27, CRIT = 0.9, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Accursed",    weights = { STR = 1.323, AGI = 1.866, INT = 0.119, CRIT = 0.653, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Eternal",     weights = { STR = 1.177, AGI = 2.967, STA = 1.08, INT = 0.067, CRIT = 0.364, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.25, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    CHRONOMANCER = {
        { name = "Time",      weights = { INT = 1, SPI = 0.575, CRIT = 0.5, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Infinite",  weights = { INT = 1, SPI = 0.46, CRIT = 0.75, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Artificer", weights = { AGI = 1.2, SPI = 1.6, CRIT = 0.828, HIT = 0.5, HASTE = 0.6, DPS = 7, AP = 0.5, SP = 0.25, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Duality",   weights = { SP = 1, INT = 0.8, HIT = 0.9, CRIT = 0.7, HASTE = 0.6, STA = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    CULTIST = {
        { name = "Godblade",    weights = { STR = 2.268, INT = 1.271, CRIT = 0.797, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Corruption",  weights = { INT = 1, CRIT = 0.9, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Heretic",     weights = { STR = 1, INT = 0.104, CRIT = 3, HASTE = 0.4, DPS = 14, AP = 1, SP = 0.4, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Dreadnought", weights = { STR = 2.531, STA = 1.12, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.5, ARP = 0.15, EXP = 0.5, ARMOR = 0.255, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 1.8, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    FELSWORN = {
        { name = "Infernal", weights = { INT = 1, SPI = 0.398, CRIT = 1.242, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Slayer",   weights = { STR = 1, AGI = 2.5, CRIT = 0.734, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Tyrant",   weights = { STR = 1.135, AGI = 2.817, STA = 2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.5, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    GUARDIAN = {
        { name = "Gladiator",   weights = { STR = 2.464, AGI = 0.592, CRIT = 0.764, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Vanguard",    weights = { STR = 2.354, AGI = 1.308, STA = 1.365, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.3, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Inspiration", weights = { STR = 2.16, AGI = 0.444, CRIT = 0.6, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.25, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    KNIGHT_OF_XOROTH = {
        { name = "Hellfire", weights = { STR = 2.2, INT = 1.163, CRIT = 0.831, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 0.75, SP = 1, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Defiance", weights = { STR = 2.549, AGI = 1.127, STA = 1.06, INT = 0, CRIT = 0.376, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.75, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "War",      weights = { STR = 2.398, AGI = 0.721, CRIT = 1.024, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    NECROMANCER = {
        { name = "Death",     weights = { INT = 1, CRIT = 0.63, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Animation", weights = { INT = 1, CRIT = 0.6, HIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Rime",      weights = { INT = 1, CRIT = 0.93, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    PRIMALIST = {
        { name = "Grovekeeper",   weights = { STR = 2.2, AGI = 0.374, CRIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.2, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Wildwalker",    weights = { STR = 2.2, AGI = 0.486, CRIT = 0.65, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Mountain_King", weights = { STR = 2.548, AGI = 1.503, STA = 1.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.3, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Geomancy",      weights = { INT = 1, CRIT = 0.654, HIT = 0.5, HASTE = 0.6, SP = 1, ARP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    PYROMANCER = {
        { name = "Incineration", weights = { INT = 1, CRIT = 1.242, HIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Draconic",     weights = { INT = 1, CRIT = 1.614, HIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Flameweaving", weights = { INT = 1, SPI = 2.182, CRIT = 0.9, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    RANGER = {
        { name = "Archery",    weights = { AGI = 1.445, INT = 0.054, CRIT = 0.631, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.15, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brigand",    weights = { STR = 1, AGI = 1.567, CRIT = 0.705, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Farstrider", weights = { AGI = 1.39, CRIT = 0.53, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.2, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    REAPER = {
        { name = "Harvest",    weights = { STR = 0.471, AGI = 2.347, CRIT = 0.67, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Soul",       weights = { STR = 2.2, AGI = 0.485, CRIT = 0.689, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Domination", weights = { STR = 2.596, AGI = 1.53, STA = 1.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 1.35, EXP = 0.5, ARMOR = 0.37, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    RUNEMASTER = {
        { name = "Glyphic",      weights = { INT = 1, SPI = 0.33, CRIT = 0.69, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Riftblade",    weights = { STR = 1, AGI = 1.643, INT = 0.144, CRIT = 0.772, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Engravement",  weights = { STR = 1.125, AGI = 1.429, INT = 0.109, CRIT = 0.641, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    STARCALLER = {
        { name = "Moon_Priest", weights = { INT = 1, SPI = 0.5, CRIT = 0.505, HASTE = 0.65, MP5 = 0.3, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Sentinel",    weights = { AGI = 1.366, INT = 2.1, CRIT = 0.778, HASTE = 0.1, SP = 0.25, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Warden",      weights = { STR = 0.55, AGI = 0.829, INT = 2, CRIT = 0.7, HASTE = 0.6, DPS = 14, AP = 0.5, SP = 1, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Moonguard",   weights = { STR = 2.04, AGI = 2.15, STA = 1.1, INT = 0.72, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 0.75, SP = 1, MP5 = 0.1, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    STORMBRINGER = {
        { name = "Lightning", weights = { INT = 1, CRIT = 1.563, HIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Wind",      weights = { INT = 1, CRIT = 0.5, HIT = 0.5, HASTE = 0.55, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Maelstrom", weights = { INT = 1, CRIT = 0.882, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    SUN_CLERIC = {
        { name = "Blessings", weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Seraphim", weights = { STR = 2.771, AGI = 1.32, STA = 1.15, CRIT = 0.363, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 0.5, SP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.256, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Valkyrie", weights = { STR = 2.4, AGI = 0.445, CRIT = 0.625, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Piety",    weights = { INT = 1, CRIT = 1.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    TEMPLAR = {
        { name = "Oathkeeper", weights = { STR = 1.333, AGI = 2.872, STA = 1.05, INT = 0.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.4, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Zealot",     weights = { STR = 1.365, AGI = 1.844, INT = 0.091, CRIT = 0.678, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Crusader",   weights = { STR = 1.05, AGI = 1.713, INT = 0.215, CRIT = 0.739, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    TINKER = {
        { name = "Demolition", weights = { AGI = 1.878, INT = 1.205, CRIT = 0.644, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Invention",  weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Mechanics",  weights = { AGI = 1.375, INT = 1.219, CRIT = 0.705, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.15, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    VENOMANCER = {
        { name = "Fortitude", weights = { STR = 0.8, AGI = 2.529, STA = 1, CRIT = 0.357, HASTE = 0.35, DPS = 14, AP = 0.5, SP = 1, ARP = 0.15, ARMOR = 0.34, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Stalking",  weights = { STR = 0.5, AGI = 0.935, INT = 0.389, CRIT = 0.813, HASTE = 0.6, DPS = 14, AP = 0.5, SP = 1, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Rotweaver", weights = { INT = 1, CRIT = 1.2, HIT = 0.5, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Vizier",    weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    WITCH_DOCTOR = {
        { name = "Shadowhunting", weights = { AGI = 2.037, INT = 1.194, CRIT = 0.672, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Voodoo",        weights = { INT = 1, SPI = 0.625, CRIT = 1.238, HASTE = 0.6, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brewing",       weights = { INT = 1, SPI = 0.3, CRIT = 0.5, HASTE = 0.65, SP = 1, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    WITCH_HUNTER = {
        { name = "Boltslinger",  weights = { AGI = 1.342, INT = 1.104, CRIT = 0.813, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Houndmaster",  weights = { AGI = 1.375, INT = 0.336, CRIT = 0.891, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Inquisition",  weights = { STR = 1, AGI = 1.745, INT = 1.082, CRIT = 0.644, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, EXP = 0.5, ARMOR = 0.01, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Black_Knight", weights = { STR = 1.225, AGI = 3.326, STA = 1, INT = 0.27, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.75, ARP = 0.15, EXP = 0.5, ARMOR = 0.4, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
}

-- Which armor types each class can wear (server-side rule, unrelated to
-- talent-spec stat weights — a class's DPS spec can favor Agility while
-- still only wearing leather). Same keys as CLASS_SPEC_WEIGHTS. Used by
-- AutoApplyClassSpec to auto-set the General page's armor-type filter so
-- e.g. Knight of Xoroth never shows Cloth as a viable upgrade.
local ARMOR_TYPES_BY_CLASS = {
    GUARDIAN          = { "Plate", "Mail" },
    KNIGHT_OF_XOROTH  = { "Plate", "Mail" },
    PRIMALIST         = { "Plate", "Mail" },
    REAPER            = { "Plate", "Mail" },
    STARCALLER        = { "Plate", "Mail" },
    TEMPLAR           = { "Mail", "Leather" },
    WITCH_HUNTER      = { "Mail", "Leather" },
    TINKER            = { "Mail", "Leather" },
    VENOMANCER        = { "Mail", "Leather" },
    BARBARIAN         = { "Leather", "Cloth" },
    BLOODMAGE         = { "Leather", "Cloth" },
    FELSWORN          = { "Leather", "Cloth" },
    RANGER            = { "Leather", "Cloth" },
    WITCH_DOCTOR      = { "Leather", "Cloth" },
    CHRONOMANCER      = { "Cloth" },
    NECROMANCER       = { "Cloth" },
    PYROMANCER        = { "Cloth" },
    RUNEMASTER        = { "Cloth" },
    STORMBRINGER      = { "Cloth" },
    CULTIST           = { "Plate", "Cloth" },
    SUN_CLERIC        = { "Plate", "Cloth" },
}

-- CLASS_SPEC_WEIGHTS is keyed by the non-localized class token (UnitClass's
-- 2nd return), guessed as the usual Blizzard convention (uppercase, spaces
-- as underscores). If Ascension's actual token differs, fall back to
-- deriving the same shape from the localized class name so lookups still
-- hit.
local function NormalizeClassKey(name)
    return name and name:upper():gsub(" ", "_")
end

-- Returns the spec list, the DISPLAY class name (for profile names shown
-- to the player), and the normalized weights-table key that matched (for
-- lookups into tables sharing CLASS_SPEC_WEIGHTS' key shape, like
-- ARMOR_TYPES_BY_CLASS — indexing those with the display name silently
-- misses, which is how armor auto-apply was broken for every class).
local function GetClassSpecList()
    local className, classToken = UnitClass("player")
    local key = classToken
    local list = key and CLASS_SPEC_WEIGHTS[key]
    if not list then
        key = NormalizeClassKey(className)
        list = key and CLASS_SPEC_WEIGHTS[key]
    end
    return list, className, key
end

-- Candidate names for the player's primary spec, in confidence order.
-- Ascension's CoA classes (the 21 classless "classes") don't live in the
-- stock 3.3.5 talent API — their talents sit in the custom
-- C_CharacterAdvancement system, and GetNumTalentTabs/GetTalentTabInfo
-- report nothing (or the wrong trees) for them. Relying on the stock API
-- alone made detection silently fall back to the class's first listed
-- spec for every CoA character (e.g. every Sun Cleric came out "Solar").
-- Three sources, all guarded since the custom APIs aren't guaranteed:
--
-- 1. GetSpecialization()/GetSpecializationInfo() — retail-style APIs the
--    Ascension client adds (stock 3.3.5 has neither); the returned name
--    is the chosen CoA spec.
-- 2. C_CharacterAdvancement — sum learned talent ranks per tree tab and
--    take the fullest tab (same "most points spent" rule as stock).
-- 3. Stock GetTalentTabInfo loop (vanilla classes / plain 3.3.5).
--
-- Ties keep whichever tab was checked first. The list is empty when
-- nothing has a spec or points yet (pre level 10).
local function DetectPrimarySpec()
    local candidates = {}

    -- 1: the client's own notion of the active spec.
    if type(GetSpecialization) == "function"
        and type(GetSpecializationInfo) == "function" then
        local ok, specName = pcall(function()
            local index = GetSpecialization()
            if not index or index == 0 then return nil end
            local _, name = GetSpecializationInfo(index)
            return name
        end)
        if ok and type(specName) == "string" and specName ~= "" then
            tinsert(candidates, specName)
        end
    end

    -- 2: Character Advancement talent trees (CoA classes).
    local ca = _G.C_CharacterAdvancement
    local cau = _G.CharacterAdvancementUtil
    if ca and cau and type(cau.GetClassDBCByFile) == "function"
        and type(ca.GetTalentsByClass) == "function"
        and type(ca.UnitTalentRankByID) == "function" then
        local ok, bestTab = pcall(function()
            local dbcClass = cau.GetClassDBCByFile(select(2, UnitClass("player")))
            if not dbcClass then return nil end
            -- Slot = the active spec/loadout slot (Ascension supports
            -- several); GetInspectInfo works on the player too.
            local slot = 1
            if type(ca.GetInspectInfo) == "function" then
                slot = ca.GetInspectInfo("player") or 1
            end
            local entries = ca.GetTalentsByClass(dbcClass, slot, false)
            if type(entries) ~= "table" then return nil end
            local points, best, bestPoints = {}, nil, 0
            for _, e in ipairs(entries) do
                if e.Tab and e.ID then
                    local rank = ca.UnitTalentRankByID("player", e.ID, slot)
                    if type(rank) == "number" and rank > 0 then
                        points[e.Tab] = (points[e.Tab] or 0) + rank
                        if points[e.Tab] > bestPoints then
                            best, bestPoints = e.Tab, points[e.Tab]
                        end
                    end
                end
            end
            return best
        end)
        if ok and type(bestTab) == "string" then
            tinsert(candidates, bestTab)
        end
    end

    -- 3: stock talent tabs (vanilla classes).
    local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 0
    local bestName, bestPoints = nil, 0
    for i = 1, numTabs do
        local name, _, pointsSpent = GetTalentTabInfo(i)
        if name and pointsSpent and pointsSpent > bestPoints then
            bestName, bestPoints = name, pointsSpent
        end
    end
    if bestName then tinsert(candidates, bestName) end

    return candidates
end

-- Creates the "<Class> - <Spec>" profile from a CLASS_SPEC_WEIGHTS entry if
-- it doesn't exist yet and returns its name. Never touches an existing
-- profile (whether auto-seeded earlier or hand-made), so editing the
-- weights sticks permanently.
local function EnsureSpecProfile(className, specEntry)
    local profileName = className .. " - " .. specEntry.name:gsub("_", " ")
    if not db.profiles[profileName] then
        local weights = {}
        for _, s in ipairs(STATS) do
            weights[s.key] = specEntry.weights[s.key] or 0
        end
        db.profiles[profileName] = { weights = weights, customWeights = {} }
    end
    return profileName
end

-- Every spec of the player's class with its display label and profile
-- name, for the UI's spec picker. All specs are offered, not just the
-- detected one — a player may gear a different role than they're specced
-- (a tank who still wants to collect DPS gear picks the DPS spec here).
local function GetClassSpecs()
    local specList, className = GetClassSpecList()
    if not specList then return nil end
    local out = {}
    for _, s in ipairs(specList) do
        local label = s.name:gsub("_", " ")
        tinsert(out, { label = label, profileName = className .. " - " .. label })
    end
    return out
end

-- Spec-picker click handler: seed that spec's profile if needed and switch
-- to it as a deliberate user choice — auto-selection then leaves it alone
-- (unless it happens to be the auto pick anyway; see AutoApplyClassSpec).
local function SelectSpecProfile(label)
    local specList, className = GetClassSpecList()
    if not specList then return end
    for _, s in ipairs(specList) do
        if s.name:gsub("_", " ") == label then
            SetActiveProfile(EnsureSpecProfile(className, s))
            return
        end
    end
end

-- Stat Weights page's "Reset to defaults" button. Only meaningful for a
-- class-spec profile (name format "<Class> - <Spec>", as EnsureSpecProfile/
-- GetClassSpecs build it) — finds the matching CLASS_SPEC_WEIGHTS entry by
-- name and overwrites the active profile's weights with it, discarding any
-- hand edits. Hand-made profiles (SaveProfileAs) have no default to revert
-- to, so those are left alone.
local function ResetActiveProfileWeights()
    local name = db.activeProfile
    -- Profile names carry the DISPLAY class name ("Knight of Xoroth -
    -- War", from GetClassSpecList's UnitClass return) while the weights
    -- table is keyed "KNIGHT_OF_XOROTH" — comparing against names built
    -- from the key never matched anything. Split the profile name and
    -- normalize its class half into key shape instead.
    local classPart, specPart = name:match("^(.-) %- (.+)$")
    local specList = classPart and CLASS_SPEC_WEIGHTS[NormalizeClassKey(classPart)]
    if specList then
        local wanted = specPart:lower():gsub(" ", "_")
        for _, specEntry in ipairs(specList) do
            if specEntry.name:lower() == wanted then
                local weights = {}
                for _, s in ipairs(STATS) do
                    weights[s.key] = specEntry.weights[s.key] or 0
                end
                ActiveProfile().weights = weights
                Print("reset '" .. name .. "' to its default weights.")
                RefreshConfig()
                return true
            end
        end
    end
    Print("'" .. name .. "' has no built-in defaults to reset to (it's a custom profile).")
    return false
end

-- Seeds a "<Class> - <Spec>" profile from CLASS_SPEC_WEIGHTS the first time
-- this character is seen in that spec, and switches to it (see
-- EnsureSpecProfile for the never-overwrite rule). Stops managing a
-- character once the player deliberately switches to some other profile
-- (charManualProfile — set only by the UI/slash switch, so a plain login
-- or the auto pick itself never counts as a choice); resumes if they later
-- pick the auto profile again, or after /rfc auto. Before level 10 (no
-- talent points yet) this falls back to the class's first listed spec as a
-- placeholder, so a fresh character still gets sane weights instead of the
-- flat generic defaults; it corrects itself to the real spec once talent
-- points exist.
local function AutoApplyClassSpec()
    if not db then return end
    local specList, className, classKey = GetClassSpecList()
    if not specList then
        if db.debug then
            Print("auto-profile: no weights for class '" .. tostring(UnitClass("player")) .. "'.")
        end
        return
    end

    -- Spec names come back as display text ("Moon Priest"); the table
    -- keeps Pawn-style underscored names ("Moon_Priest"). Normalize both
    -- sides before comparing. Candidates are tried in confidence order —
    -- the first one with a weights entry wins, so one source reporting a
    -- name the table doesn't know can't shadow a match from another.
    local candidates = DetectPrimarySpec()
    local specEntry
    for _, candidate in ipairs(candidates) do
        local wanted = candidate:lower():gsub(" ", "_")
        for _, s in ipairs(specList) do
            if s.name:lower() == wanted then specEntry = s break end
        end
        if specEntry then break end
    end
    if not specEntry and #candidates > 0 and db.debug then
        Print("auto-profile: no weights for spec '"
            .. table.concat(candidates, "' / '") .. "', using " .. specList[1].name .. ".")
    end
    specEntry = specEntry or specList[1]

    local charKey = CharKey()

    -- Armor-type filter is a hard proficiency rule, not a stat-weight
    -- preference, so it applies independently of whether the player picked
    -- a custom weight profile — unless they've edited the checkboxes
    -- themselves (charManualArmor, set by the UI setter below).
    local armorList = ARMOR_TYPES_BY_CLASS[classKey]
    if armorList and not db.charManualArmor[charKey] then
        local wanted = {}
        for _, t in ipairs(armorList) do wanted[t] = true end
        local changed = false
        for _, t in ipairs({ "Cloth", "Leather", "Mail", "Plate" }) do
            if (db.armorTypes[t] or false) ~= (wanted[t] or false) then changed = true end
        end
        if changed then
            for _, t in ipairs({ "Cloth", "Leather", "Mail", "Plate" }) do
                db.armorTypes[t] = wanted[t] or false
            end
            Print("auto-selected armor type(s) " .. table.concat(armorList, "/") .. " for your class.")
            RefreshConfig()
            if RefreshOpenBags then RefreshOpenBags() end
        end
    end

    local manual = db.charManualProfile[charKey]
    if manual and manual ~= db.charAutoProfile[charKey] then
        if db.debug then
            Print("auto-profile: keeping your chosen profile '" .. manual .. "' (/rfc auto to re-enable).")
        end
        return
    end

    local profileName = EnsureSpecProfile(className, specEntry)
    if db.activeProfile ~= profileName then
        ActivateProfile(profileName)
        Print("auto-selected weight profile '" .. profileName .. "' for your spec.")
        RefreshConfig()
    end
    db.charAutoProfile[charKey] = profileName
end

--------------------------------------------------------------------------
-- Slot mapping
--------------------------------------------------------------------------

-- Which equipment slot(s) an inventory type competes for.
local SLOTS_FOR_INVTYPE = {
    INVTYPE_HEAD = { 1 },  INVTYPE_NECK = { 2 },   INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },   INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },  INVTYPE_FEET = { 8 },   INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 }, INVTYPE_SHIELD = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local WEAPON_INVTYPES = {
    INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true,
}

-- Offhand weapons swing at half damage (WotLK's dual-wield penalty,
-- before talents), so when a 2H candidate is judged against MH+OH the
-- offhand's weapon-DPS share of the score only counts at this factor —
-- full credit made the dual-wield pair look ~stronger than it hits and
-- under-reported real 2H upgrades. Stats keep full value; only DPS is
-- discounted, and only in that one comparison (OH-vs-OH is symmetric,
-- the discount would cancel out).
local OFFHAND_DPS_FACTOR = 0.5

-- Slots the armor-type (cloth/leather/mail/plate) preference applies to.
-- Cloaks are always cloth and rings/trinkets are Miscellaneous, so only
-- the real body-armor slots are filtered.
local ARMOR_FILTERED_INVTYPES = {
    INVTYPE_HEAD = true, INVTYPE_SHOULDER = true, INVTYPE_CHEST = true,
    INVTYPE_ROBE = true, INVTYPE_WAIST = true, INVTYPE_LEGS = true,
    INVTYPE_FEET = true, INVTYPE_WRIST = true, INVTYPE_HAND = true,
}

--------------------------------------------------------------------------
-- Tooltip scanning (custom stats, weapon DPS, red "can't use" text)
--------------------------------------------------------------------------

local scanTip = CreateFrame("GameTooltip", "RefactorCompareScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

-- Ascension scales items (Worldforged etc.), and the base-item APIs —
-- GetItemStats(), SetHyperlink() — report the BASE item's stats, not the
-- scaled values on the copy you're actually holding. Scoring from them
-- turns obvious upgrades into "downgrades". So ALL stats come from
-- scanning the real tooltip: SetBagItem/SetInventoryItem render the
-- actual item instance with its scaled values (plus enchants and gems).
-- SetHyperlink remains only as a fallback when a bare link is all we
-- have (chat links, loot alerts for items not found in bags).

-- "Equip:" lines that grant a flat, scoreable stat, e.g.
-- "Equip: Increases your dodge rating by 2." First match wins;
-- captures are (stat name, amount).
local EQUIP_PATTERNS = {
    "^Equip: Increases your (.-) by ([%d,]+)%.?$",
    "^Equip: Increases (.-) by ([%d,]+)%.?$",
    "^Equip: Improves (.-) by ([%d,]+)%.?$",
}

-- The tables below port Pawn's tooltip-parsing algorithm (Pawn by Vger,
-- WotLK build) onto our instance scans.

-- A line matching one of these ends the scan: everything after it is the
-- set-item list / other addons' additions, not this item's own stats.
local KILL_LINE_PATTERNS = {
    " %(%d+/%d+%)$",         -- set header, e.g. "Netherwind Regalia (0/8)"
    "^|cff00e0ffDropped By", -- MobInfo-2 compatibility (from Pawn)
}

-- Compound stat lines — hybrid gems ("+10 Agility and +15 Stamina") and
-- multi-stat enchants ("+3 Stamina/+4 Critical Strike Rating") — are
-- split on these, in priority order, when the whole line doesn't parse.
-- Without the split, the generic "+N Name" pattern swallows the entire
-- tail as one unknown stat name and the extra stats score at the UNKNOWN
-- weight instead of their real ones.
local STAT_SEPARATORS = { ", ", "/", " & ", " and " }

-- Lines starting with these are prose, never separator-split (an
-- "Equip:" sentence with a comma is one effect, not two stats).
local NO_SPLIT_PREFIXES = { '"', "Equip:", "Use:", "Chance on hit:" }

-- Rewrites applied before matching, e.g. "Stamina +5" -> "+5 Stamina",
-- so reversed-order stat lines don't need their own patterns.
local NORMALIZE_PATTERNS = {
    { "^([%w%s%.]+) %+([%d,]+)$", "+%2 %1" },
}

-- Empty socket lines; each counts toward the SOCKET pseudo-stat.
local SOCKET_LINES = {
    ["Red Socket"] = true, ["Yellow Socket"] = true, ["Blue Socket"] = true,
    ["Meta Socket"] = true, ["Prismatic Socket"] = true,
}

-- Scanned tooltip stat names -> weight keys from STATS. Names not listed
-- here are treated as custom Ascension stats (customWeights / UNKNOWN).
local STAT_NAME_KEYS = {
    ["strength"] = "STR", ["agility"] = "AGI", ["stamina"] = "STA",
    ["intellect"] = "INT", ["spirit"] = "SPI",
    ["critical strike rating"] = "CRIT", ["crit rating"] = "CRIT",
    ["critical rating"] = "CRIT", ["critical strike"] = "CRIT",
    ["ranged critical strike"] = "CRIT",
    ["haste rating"] = "HASTE", ["hit rating"] = "HIT",
    ["expertise rating"] = "EXP", ["expertise"] = "EXP",
    ["armor penetration rating"] = "ARP",
    ["spell power"] = "SP",
    ["attack power"] = "AP", ["ranged attack power"] = "AP",
    ["mana per 5 sec"] = "MP5", ["mana per 5 seconds"] = "MP5",
    ["mana every 5 sec"] = "MP5", ["mana every 5 seconds"] = "MP5",
    ["mana restored per 5 seconds"] = "MP5", ["mana regen"] = "MP5",
    ["defense rating"] = "DEF", ["defense"] = "DEF",
    ["dodge rating"] = "DODGE",
    ["parry rating"] = "PARRY",
    ["shield block rating"] = "BLOCK", ["block rating"] = "BLOCK",
    ["resilience rating"] = "RESIL", ["resilience"] = "RESIL",
    ["armor"] = "ARMOR",
}

-- Scan results per item. Instance scans (bag or equipped) are keyed by
-- exact location — "b:"..bag..":"..slot / "e:"..invSlot plus the link —
-- because on Ascension two copies of one item can carry the same link
-- with different scaled stats; a shared key lets one copy's stats answer
-- for another and produces wildly wrong percentages. Instance entries
-- are invalidated event-driven: every path that can rescale an instance
-- raises an event this file handles (equip -> UNIT_INVENTORY_CHANGED,
-- bag changes -> BAG_UPDATE, level -> PLAYER_LEVEL_UP), and the debounced
-- refresh below wipes the affected entries. The TTL is only a safety net
-- for a rescale path that somehow has no event — it used to be the
-- primary mechanism at 0.5s, which forced a full hidden-tooltip render +
-- parse of both sides on nearly every hover and bag redraw. "h:"..link
-- base-item scans are static, so they live until level-up.
local scanCache = {}
local INSTANCE_SCAN_TTL = 10

-- "h:" base-link scans never expire, so a long session of hovering chat
-- links / AH listings piles them up; past the cap they're all dropped
-- and rebuild on demand.
local hScanCount = 0
local H_SCAN_CAP = 500

-- Everything derived from scans — equipped-slot scores, per-bag-slot
-- verdicts — is memoized against this generation counter. RefreshOpenBags
-- bumps it, and RefreshOpenBags is called on every state change that
-- moves verdicts globally (equip events via the debounced flush, weight
-- edits, profile switches, quality/armor filters, level-up), so a memo
-- hit is always computed from current weights AND current gear. Bag-only
-- changes don't bump it: the flush deletes just the dirty bags' verdict
-- entries instead, since a bag change can't move the equipped scores or
-- any other bag's verdicts.
local generation = 0

-- [invSlot] = { gen, link, score, dpsScore }. Only successful scores are
-- memoized — an unreadable equipped item must stay a per-call retry
-- (tooltip retries depend on it), never a cached failure.
local equippedCache = {}

-- ["bag:slot:link"] = { gen, result }. CompareItem results for bag slots:
-- the arrows path re-evaluates every slot of every open bag on each
-- redraw, and for unchanged slots this turns that into a table lookup.
-- Only non-nil results are cached; nil can mean "scan not ready yet" and
-- has to keep retrying.
local verdictCache = {}

local function WipeScanCache()
    for k in pairs(scanCache) do scanCache[k] = nil end
    hScanCount = 0
end

local function WipeInstanceScans()
    for k in pairs(scanCache) do
        if k:sub(1, 2) ~= "h:" then scanCache[k] = nil end
    end
end

local function IsRed(fontString)
    local r, g, b = fontString:GetTextColor()
    return r > 0.9 and g < 0.3 and b < 0.3
end

-- Red text alone isn't enough to call an item unequippable: Ascension adds
-- its own colored tooltip lines (loot-trade timers, scaling warnings) and
-- other addons append lines too. Only treat red text as a blocker when it
-- is an actual requirement line or the item's proficiency word (the client
-- renders the sub-type, e.g. "Mail", in red when you lack the skill).
--
-- Level requirement is split out from the rest: it's temporary (you'll
-- grow into the item), so it still gets a % score instead of a flat
-- "can't equip" — worth knowing whether to keep it for later. Proficiency/
-- class/race requirements are permanent for this character, so those stay
-- a hard block with no percentage.
local function IsLevelRequirement(text)
    return text:match("^Requires Level")
end

local function IsHardRequirementText(text, itemSubType)
    return (text:match("^Requires") and not IsLevelRequirement(text))
        or text:match("^Classes:")
        or text:match("^Races:")
        or text == itemSubType
end

--------------------------------------------------------------------------
-- Line parsing (hoisted out of ScanItem: defining these inline made every
-- scan allocate three fresh closures — a full bag refresh scans ~100 items,
-- hundreds of throwaway functions per redraw for this 2009-era client's GC
-- to chew. The scan's result table is threaded through explicitly instead.)
--------------------------------------------------------------------------

local function ScanAddStat(result, name, amount, sign)
    -- Normalize hard: scaled/suffix items have rendered stat names
    -- with color codes and stray whitespace, and any mismatch here
    -- silently reroutes a mapped stat (weight 0 included) into the
    -- UNKNOWN fallback weight — e.g. +5 Spirit scoring 2.5 on a
    -- Strength build.
    name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    name = name:lower():gsub("%.$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    local value = (tonumber((amount:gsub(",", ""))) or 0) * (sign or 1)
    -- "+4 All Stats" is five stats, not one unknown one.
    if name == "all stats" or name == "to all stats" then
        for _, n in ipairs({ "strength", "agility", "stamina",
            "intellect", "spirit" }) do
            result.stats[n] = (result.stats[n] or 0) + value
        end
        return
    end
    result.stats[name] = (result.stats[name] or 0) + value
end

-- Parses one stat line (already trimmed of surrounding whitespace).
-- Returns true when the line was understood — including understood-
-- and-worthless (flavor text stays false so the caller may try
-- splitting it).
local function ScanParseStatLine(result, line)
    line = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return true end
    for _, n in ipairs(NORMALIZE_PATTERNS) do
        line = line:gsub(n[1], n[2])
    end

    -- Weapon DPS, e.g. "(54.3 damage per second)".
    local dps = line:match("%(([%d,%.]+) damage per second%)")
    if dps then
        result.dps = tonumber((dps:gsub(",", "")))
        return true
    end
    -- "Adds N damage per second" (weapon enchants, Pawn's "Dps" stat).
    dps = line:match("^Adds ([%d,%.]+) damage per second$")
    if dps then
        result.bonusDps = (result.bonusDps or 0)
            + (tonumber((dps:gsub(",", ""))) or 0)
        return true
    end

    -- Damage range: "126 - 190 Damage", wands' "76 - 143 Frost
    -- Damage". Together with the right column's "Speed N" this
    -- reconstructs DPS when the printed DPS line is missing.
    local minD, maxD = line:match("^%+?([%d,]+) %- ([%d,]+) [%a ]-Damage$")
    if minD then
        result.minDamage = (result.minDamage or 0)
            + (tonumber((minD:gsub(",", ""))) or 0)
        result.maxDamage = (result.maxDamage or 0)
            + (tonumber((maxD:gsub(",", ""))) or 0)
        return true
    end

    if SOCKET_LINES[line] then
        result.emptySockets = (result.emptySockets or 0) + 1
        return true
    end

    -- "+N Name" / "-N Name": base stats, gems, enchants, custom
    -- Ascension stats alike (negative stats exist, e.g. Kreeg's Mug).
    -- Skipped when the line is compound — a separator followed by
    -- another signed number ("+10 Agility and +15 Stamina") or a bare
    -- number ("+21 Agility & 3% Increased Critical Damage": meta gems'
    -- percent halves carry no sign) — or the greedy name capture would
    -- swallow the whole tail as one bogus custom stat; the caller's
    -- splitter handles those instead.
    local compound = false
    for _, sep in ipairs(STAT_SEPARATORS) do
        if line:find(sep .. "+", 1, true)
            or line:find(sep .. "-", 1, true)
            or line:find(sep .. "%d") then
            compound = true
            break
        end
    end
    if not compound then
        local sign, amount, statName =
            line:match("^([%+%-])([%d,]+)%s+(.+)$")
        if amount then
            ScanAddStat(result, statName, amount, sign == "-" and -1 or 1)
            return true
        end
    end

    -- "N% Name" percent effects — meta gems ("3% Increased Critical
    -- Damage"), percent socket bonuses, custom Ascension lines. No
    -- rating conversion exists for these, so each scores as a custom
    -- "<name> %" stat: weight it via /rfc weight (or the UI's scanned-
    -- stats list), UNKNOWN weight until then. Dropping them entirely
    -- (the old behavior) undervalued every item carrying one.
    local pctAmount, pctName = line:match("^%+?([%d%.]+)%% (.+)$")
    if pctAmount then
        ScanAddStat(result, pctName .. " %", pctAmount)
        return true
    end

    local armor = line:match("^([%d,]+) Armor$")
    if armor then
        ScanAddStat(result, "armor", armor)
        return true
    end

    -- Not stats, but needed by the stale-armor-render check in ScanItem:
    -- the instance's scaled item level / required level, to tell a
    -- scaled copy apart from the base item.
    local ilvl = line:match("^Item Level ([%d,]+)$")
    if ilvl then
        result.itemLevel = tonumber((ilvl:gsub(",", "")))
        return true
    end
    local reqLvl = line:match("^Requires Level ([%d,]+)$")
    if reqLvl then
        result.reqLevel = tonumber((reqLvl:gsub(",", "")))
        return true
    end

    -- Specific "Equip:" shapes the generic patterns can't capture
    -- cleanly, checked first so they don't land as ugly custom names.
    local amt = line:match("^Equip: %+([%d,]+) Armor%.?$")
    if amt then
        ScanAddStat(result, "armor", amt)
        return true
    end
    amt = line:match("^Equip: Increases damage and healing done by magical spells and effects by up to ([%d,]+)%.?$")
    if amt then
        ScanAddStat(result, "spell power", amt)
        return true
    end
    local school
    school, amt = line:match("^Equip: Increases damage done by (.-) spells and effects by up to ([%d,]+)%.?$")
    if school then
        ScanAddStat(result, school .. " spell damage", amt)
        return true
    end
    amt = line:match("^Equip: Increases the block value of your shield by ([%d,]+)%.?$")
    if amt then
        ScanAddStat(result, "block value", amt)
        return true
    end
    -- "Equip: Restores N mana/health per (or every) 5 sec."
    local res
    amt, res = line:match("^Equip: Restores ([%d,]+) (%a+) per 5 sec")
    if not amt then
        amt, res = line:match("^Equip: Restores ([%d,]+) (%a+) every 5 sec")
    end
    if amt then
        ScanAddStat(result, res .. " per 5 sec", amt)
        return true
    end

    -- Percent-based "Equip:" effects ("Equip: Improves your chance to
    -- get a critical strike by 1%.") — the rating patterns below only
    -- accept plain integers, so these parsed as prose and scored zero.
    -- Same treatment as the bare "N% Name" lines above: a custom
    -- "<name> %" stat at its own /rfc weight or UNKNOWN.
    local pctEquipName, pctEquipAmount = line:match(
        "^Equip: Increases (.-) by ([%d%.]+)%%%.?$")
    if not pctEquipName then
        pctEquipName, pctEquipAmount = line:match(
            "^Equip: Improves (.-) by ([%d%.]+)%%%.?$")
    end
    if pctEquipName then
        ScanAddStat(result, (pctEquipName:gsub("^your ", "")) .. " %", pctEquipAmount)
        return true
    end

    -- Generic "Equip: Increases/Improves <stat> by N." rating lines.
    for _, pattern in ipairs(EQUIP_PATTERNS) do
        local name, a = line:match(pattern)
        if name then
            ScanAddStat(result, name, a)
            return true
        end
    end
    return false
end

-- Splits a compound line ("+10 Agility and +15 Stamina") on the
-- highest-priority separator present and parses each piece; pieces
-- may recursively split on lower-priority separators. (Pawn's
-- PawnSeparators pass.)
local function ScanSplitAndParse(result, text2, sepIndex)
    for si = sepIndex, #STAT_SEPARATORS do
        local sep = STAT_SEPARATORS[si]
        if text2:find(sep, 1, true) then
            local pos = 1
            while pos do
                local s, e = text2:find(sep, pos, true)
                local chunk = s and text2:sub(pos, s - 1) or text2:sub(pos)
                if not ScanParseStatLine(result, chunk) then
                    ScanSplitAndParse(result, chunk, si + 1)
                end
                pos = e and (e + 1) or nil
            end
            return true
        end
    end
    return false
end

-- Scans the item's tooltip and returns { stats, dps, unusable,
-- levelLocked }. Pass bag+slot (bag item) or invSlot (equipped) to scan
-- the real item instance. src scans other live sources the server
-- renders scaled — all count as instance scans:
--   { log, type, index } quest reward (SetQuestItem / SetQuestLogItem)
--   { roll = rollID }    group loot roll (SetLootRollItem)
--   { lootSlot = n }     open loot window (SetLootItem)
-- With only a link, falls back to the base item.
local function ScanItem(link, bag, slot, invSlot, src)
    local instance = (bag ~= nil and slot ~= nil) or invSlot ~= nil
        or src ~= nil
    local cacheKey
    if bag ~= nil and slot ~= nil then
        cacheKey = "b:" .. bag .. ":" .. slot .. ":" .. link
    elseif invSlot then
        cacheKey = "e:" .. invSlot .. ":" .. link
    elseif src and src.merchantSlot then
        cacheKey = "m:" .. src.merchantSlot .. ":" .. link
    elseif src and src.buybackSlot then
        cacheKey = "bb:" .. src.buybackSlot .. ":" .. link
    elseif src and src.roll then
        cacheKey = "r:" .. src.roll .. ":" .. link
    elseif src and src.lootSlot then
        cacheKey = "ls:" .. src.lootSlot .. ":" .. link
    elseif src then
        cacheKey = "q:" .. (src.log and "l" or "g") .. ":" .. src.type
            .. ":" .. src.index .. ":" .. link
    else
        cacheKey = "h:" .. link
    end
    local cached = scanCache[cacheKey]
    if cached and (not cached.expires or GetTime() < cached.expires)
        and not (db and db.debug) then
        return cached
    end

    local itemSubType = select(7, GetItemInfo(link))
    local result = { dps = nil, unusable = false, levelLocked = false,
        stats = {}, instance = instance }
    -- Re-own every scan: a tooltip that lost its owner renders nothing
    -- and would silently score everything as zero.
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
    -- Money lines don't reliably clear with ClearLines; a stale money
    -- frame from a previous scan would attribute the wrong sell price.
    if GameTooltip_ClearMoney then GameTooltip_ClearMoney(scanTip) end
    if bag ~= nil and slot ~= nil then
        scanTip:SetBagItem(bag, slot)
    elseif invSlot then
        scanTip:SetInventoryItem("player", invSlot)
    elseif src and src.merchantSlot then
        scanTip:SetMerchantItem(src.merchantSlot)
    elseif src and src.buybackSlot then
        scanTip:SetBuybackItem(src.buybackSlot)
    elseif src and src.roll then
        scanTip:SetLootRollItem(src.roll)
    elseif src and src.lootSlot then
        scanTip:SetLootItem(src.lootSlot)
    elseif src then
        if src.log then
            scanTip:SetQuestLogItem(src.type, src.index)
        else
            scanTip:SetQuestItem(src.type, src.index)
        end
    else
        scanTip:SetHyperlink(link)
    end

    local stopParsing = false
    for i = 2, scanTip:NumLines() do
        local left = _G["RefactorCompareScanTipTextLeft" .. i]
        local right = _G["RefactorCompareScanTipTextRight" .. i]
        local text = left and left:GetText()
        local rightText = right and right:IsShown() and right:GetText()
        if text then
            -- Raw-line dump: when a score looks impossible the fastest
            -- diagnosis is the literal text the hidden tooltip rendered
            -- (embedded \n bundles, unscaled lines), not the parsed stats.
            if db and db.debug then
                local lr, lg, lb = left:GetTextColor()
                Print(string.format("line %d [%.1f %.1f %.1f]: '%s'%s",
                    i, lr, lg, lb, (text:gsub("\n", "\\n")),
                    rightText and (" | R: '" .. rightText .. "'") or ""))
            end
            if IsRed(left) then
                if db and db.debug then
                    Print("red left line " .. i .. ": '" .. text .. "'")
                end
                if IsLevelRequirement(text) then
                    result.levelLocked = true
                elseif IsHardRequirementText(text, itemSubType) then
                    result.unusable = true
                    result.unusableReason = text
                end
            end
            -- Proficiency shows as the sub-type in the right column
            -- ("Mail", "Plate", "Sword"...), red when you can't use it.
            if rightText and IsRed(right) then
                if db and db.debug then
                    Print("red right line " .. i .. ": '" .. rightText .. "'")
                end
                if IsHardRequirementText(rightText, itemSubType) then
                    result.unusable = true
                    result.unusableReason = rightText
                end
            end

            -- Weapon speed lives in the right column ("Speed 2.60").
            if rightText then
                local speed = rightText:match("^Speed ([%d%.,]+)$")
                if speed then
                    result.speed = tonumber((speed:gsub(",", "")))
                end
            end

            -- Ascension sometimes bundles several "+N Stat" bonuses into a
            -- single tooltip row separated by embedded newlines instead of
            -- one stat per row (seen on scaled items, e.g. "of the
            -- Guardian" suffixes) — anchoring the patterns to the whole
            -- row would silently match nothing and drop every bonus but
            -- whichever plain line (like Armor) came separately. Splitting
            -- on newlines first makes the bundle behave like N ordinary
            -- lines.
            for line in text:gmatch("[^\n]+") do
                for _, kp in ipairs(KILL_LINE_PATTERNS) do
                    if line:find(kp) then
                        stopParsing = true
                        break
                    end
                end
                if stopParsing then break end

                local bonus = line:match("^%s*Socket Bonus: (.+)$")
                if bonus then
                    -- Count the socket bonus only while it's active: the
                    -- line renders green (red component ~0) when all
                    -- sockets match, grey when not.
                    local r, g = left:GetTextColor()
                    if r < 0.3 and g > 0.7 then
                        if not ScanParseStatLine(result, bonus) then
                            ScanSplitAndParse(result, bonus, 1)
                        end
                    end
                elseif not ScanParseStatLine(result, line) then
                    -- Whole line not understood: try splitting compound
                    -- gem/enchant lines — but never prose sentences.
                    local noSplit = false
                    for _, p in ipairs(NO_SPLIT_PREFIXES) do
                        if line:sub(1, #p) == p then
                            noSplit = true
                            break
                        end
                    end
                    if not noSplit then ScanSplitAndParse(result, line, 1) end
                end
            end
        end
        if stopParsing then break end
    end

    -- Pawn computes weapon DPS from the damage range and speed; use that
    -- whenever the printed "(x damage per second)" line didn't show, and
    -- fold in flat "Adds N damage per second" enchants either way.
    if not result.dps and result.minDamage and result.maxDamage
        and result.speed and result.speed > 0 then
        result.dps = (result.minDamage + result.maxDamage) / 2 / result.speed
    end
    if result.bonusDps then
        result.dps = (result.dps or 0) + result.bonusDps
    end

    -- Sell price: 3.3.5's GetItemInfo has no sellPrice return (added in
    -- 4.0), so the only source is the money line the client may render
    -- on the tooltip itself (SetTooltipMoney -> MoneyFrame_Update stores
    -- the copper amount on the money frame).
    local moneyFrame = scanTip.shownMoneyFrames and scanTip.shownMoneyFrames >= 1
        and _G["RefactorCompareScanTipMoneyFrame1"]
    result.sellPrice = moneyFrame and moneyFrame.staticMoney or nil

    -- A tooltip that never rendered (item not in the client cache yet,
    -- hyperlink the server won't answer) has no lines. Scoring it would
    -- fake a zero-stat item — "-100% downgrade" lies. Report failure and
    -- don't cache, so the next look retries.
    local numLines = scanTip:NumLines()
    result.failed = numLines < 2

    -- Stale armor render: the FIRST hidden-tooltip render of a scaled
    -- instance after the client's data for it goes cold shows the BASE
    -- item's armor line while everything else (stamina, required level,
    -- item level) is already scaled. Observed live: a scaled 115-armor
    -- bag chest scanning as 336 armor (the base item's famous value) with
    -- its scaled ilvl/req intact — which painted +21% on a real -13%
    -- downgrade, pinned for the whole hover because the 0.5s cache
    -- answered the client's own corrective re-render. Detection: on a
    -- scaled instance (scanned ilvl or req level differs from the base
    -- item's) the armor MUST differ from base too, since armor is
    -- computed from item level — so instance armor exactly equal to the
    -- base scan's armor is that stale first render. Report it as a failed
    -- scan (no cache, no verdict); the client's re-render or the next bag
    -- refresh supplies the real values a moment later.
    if not result.failed and instance
        and result.stats.armor and result.stats.armor > 0 then
        -- Base-link scan; recursing re-renders scanTip, safe because
        -- every read of this scan's lines is already done above. Scaled-
        -- ness is judged tooltip-vs-tooltip (this scan against the base
        -- render's own Item Level / Requires Level lines) — NOT against
        -- GetItemInfo, whose ilvl/req can disagree with even the base
        -- tooltip on this client (seen live: an unscaled drop rendering
        -- identical to its base render was still flagged "scaled" by the
        -- GetItemInfo comparison, killing its verdict entirely).
        local base = ScanItem(link)
        if not base.failed then
            local isScaled = (result.itemLevel and base.itemLevel
                    and result.itemLevel ~= base.itemLevel)
                or (result.reqLevel and base.reqLevel
                    and result.reqLevel ~= base.reqLevel)
            if isScaled and base.stats.armor == result.stats.armor then
                result.failed = true
                if db and db.debug then
                    Print("stale armor render (base armor "
                        .. base.stats.armor
                        .. " on a scaled instance) — scan discarded, will retry")
                end
            end
        end
    end

    -- Roll scans are never cached: while the roll's item data is still
    -- arriving the client can render a partial tooltip that passes the
    -- NumLines check, and a cached partial would pin a wrong % for the
    -- whole TTL. Hovers are rare enough that rescanning is free.
    if not result.failed and not (src and src.roll) then
        if instance then
            result.expires = GetTime() + INSTANCE_SCAN_TTL
        elseif scanCache[cacheKey] == nil then
            -- Count only genuinely new keys: /rfc debug bypasses the cache
            -- read and re-caches, and counting those overwrites inflated
            -- the counter into premature cap purges.
            hScanCount = hScanCount + 1
            if hScanCount > H_SCAN_CAP then
                for k in pairs(scanCache) do
                    if k:sub(1, 2) == "h:" then scanCache[k] = nil end
                end
                hScanCount = 1
            end
        end
        scanCache[cacheKey] = result
    end
    if db and db.debug then
        local parts = {}
        for statName, amt in pairs(result.stats) do
            tinsert(parts, statName .. "=" .. amt)
        end
        Print("scan [" .. cacheKey .. "] lines=" .. numLines
            .. " stats: " .. (next(parts) and table.concat(parts, ", ") or "(none)")
            .. (result.dps and (" dps=" .. string.format("%.1f", result.dps)) or "")
            .. (result.emptySockets and (" sockets=" .. result.emptySockets) or "")
            .. (result.failed and " FAILED" or ""))
    end
    return result
end

--------------------------------------------------------------------------
-- Scoring
--------------------------------------------------------------------------

-- Returns score plus the info needed to compare, or nil if the item isn't
-- in the client cache yet / isn't equippable gear. bag+slot or invSlot
-- select the real item instance (see ScanItem).
-- profile defaults to the active profile; the secondary-verdict path passes
-- its own so one tooltip scan feeds both weighted sums.
local function ScoreItem(link, bag, slot, invSlot, src, profile)
    local name, _, quality, _, reqLevel, itemType, itemSubType, _, equipLoc =
        GetItemInfo(link)
    if not name or not equipLoc or not SLOTS_FOR_INVTYPE[equipLoc] then
        return nil
    end

    profile = profile or ActiveProfile()
    local weights = profile.weights
    local customWeights = profile.customWeights
    local score = 0

    local scan = ScanItem(link, bag, slot, invSlot, src)
    if scan.failed then return nil end -- no data: no verdict, never a guess
    local hitAmount = 0 -- raw hit rating on the item, for the hit-cap correction
    for statName, amount in pairs(scan.stats) do
        local key = STAT_NAME_KEYS[statName]
        local w
        if key then
            w = weights[key] or 0
            if key == "HIT" then hitAmount = hitAmount + amount end
        else
            w = customWeights[statName]
            if w == nil then w = weights.UNKNOWN or 0 end
        end
        score = score + amount * w
    end

    -- Empty sockets score at the SOCKET weight (0 by default): Pawn-style
    -- credit for the gem you could put there, opt-in because the green
    -- arrow promises actual stats, not potential ones.
    if scan.emptySockets then
        score = score + scan.emptySockets * (weights.SOCKET or 0)
    end

    -- Weapons: DPS is the dominant term, weighted separately from stats.
    -- Kept as its own component too, so the 2H-vs-dual-wield comparison
    -- can discount the offhand's share (see OFFHAND_DPS_FACTOR).
    local dpsScore
    if WEAPON_INVTYPES[equipLoc] and scan.dps then
        dpsScore = scan.dps * (weights.DPS or 0)
        score = score + dpsScore
    end

    if db and db.debug then
        Print("score [" .. (name or link) .. "] = " .. string.format("%.2f", score))
    end

    return {
        score = score,
        dpsScore = dpsScore, -- weapon-DPS share of score (nil for non-weapons)
        hit = hitAmount, -- raw hit rating on the item (hit-cap correction)
        quality = quality,
        reqLevel = reqLevel,
        itemType = itemType,
        itemSubType = itemSubType,
        equipLoc = equipLoc,
        unusable = scan.unusable,
        unusableReason = scan.unusableReason,
        levelLocked = scan.levelLocked,
        -- Scored from a bare link = base item, not the scaled copy in
        -- hand. Ascension scaling makes that an estimate at best.
        approx = not scan.instance,
    }
end

-- Score of what's equipped in a slot: a number, nil when the slot is
-- truly empty, or false when there IS an item but it can't be read
-- (tooltip scan failed). Callers must treat false as "unknown" and stay
-- silent — never as an empty slot begging to be filled. Second return is
-- the weapon-DPS share of the score (nil unless the slot holds a weapon),
-- for the offhand discount in the 2H comparison. Third return is the item's
-- raw hit rating (for the hit-cap correction in VerdictForProfile). profile
-- defaults to the active profile; the secondary verdict passes its own and
-- gets its own memo fields (score2/dpsScore2/hit2) so the two never poison
-- each other.
local function ScoreEquipped(slot, profile)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local secondary = profile ~= nil
    profile = profile or ActiveProfile()
    -- Memoized per generation: equipped gear only changes on events that
    -- bump the generation (equip, level, weight/profile edits), so one
    -- score serves every bag slot of a whole redraw — and every hover in
    -- between — instead of re-rendering the worn item's tooltip each time.
    local c = equippedCache[slot]
    local memoHit = c and c.gen == generation and c.link == link
    if memoHit then
        if not secondary and c.score then
            return c.score, c.dpsScore, c.hitAmt
        elseif secondary and c.score2 then
            return c.score2, c.dpsScore2, c.hitAmt2
        end
        -- This profile's half isn't memoized yet: fall through and score it.
    end
    local info = ScoreItem(link, nil, nil, slot, nil, profile)
    if not info then return false end -- unreadable: retry next call, never memoized
    if memoHit then
        if secondary then
            c.score2, c.dpsScore2, c.hitAmt2 = info.score, info.dpsScore, info.hit
        else
            c.score, c.dpsScore, c.hitAmt = info.score, info.dpsScore, info.hit
        end
    elseif secondary then
        equippedCache[slot] = { gen = generation, link = link,
            score2 = info.score, dpsScore2 = info.dpsScore, hitAmt2 = info.hit }
    else
        equippedCache[slot] = { gen = generation, link = link,
            score = info.score, dpsScore = info.dpsScore, hitAmt = info.hit }
    end
    return info.score, info.dpsScore, info.hit
end

local function MainHandIs2H()
    local link = GetInventoryItemLink("player", 16)
    if not link then return false end
    local equipLoc = select(9, GetItemInfo(link))
    return equipLoc == "INVTYPE_2HWEAPON"
end

-- Dual Wield is a learnable ability on Ascension; if the character
-- doesn't know it, a one-hander only competes for the main hand.
local function CanDualWield()
    return IsSpellKnown and IsSpellKnown(674) or false
end

-- A shield (or held-in-off-hand frill) is a deliberate role choice, not a
-- weapon competing for its slot: a one-hander scored against it nearly
-- always "wins" under weapon weights, painting a misleading upgrade arrow
-- on every 1H in the bag. While one is equipped, 1H weapons only compete
-- for the main hand.
local function OffhandIsShield()
    local link = GetInventoryItemLink("player", 17)
    if not link then return false end
    local equipLoc = select(9, GetItemInfo(link))
    return equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE"
end

--------------------------------------------------------------------------
-- Hit cap
--------------------------------------------------------------------------
-- Hit rating past the cap is worthless; below it, valuable. The linear
-- score can't express that, so an opt-in per-profile "hit cap" mode re-scores
-- the HIT term as a marginal value: full weight up to the cap given the hit
-- you ALREADY wear, ~zero past it. Everything works in rating-space, matching
-- the game's own "7/22" (current rating / rating-for-cap) sheet display —
-- talent/racial flat-% hit is deliberately out of scope (v1 limitation).
local HITCAP_INDEX    = { melee = 6, ranged = 7, spell = 8 } -- CR_HIT_MELEE/RANGED/SPELL
local HITCAP_PCT       = { melee = 8, ranged = 8, spell = 17 } -- % vs a raid boss (PvE)
local HITCAP_PCT_PVP   = { melee = 5, ranged = 5, spell = 4 }  -- % vs a player (PvP)

local function HitCapMode(profile)
    local hc = profile and profile.hitCap
    local mode = hc and hc.mode
    if mode == "melee" or mode == "ranged" or mode == "spell" then return mode end
    return "off"
end

local function HitCapPvP(profile)
    local hc = profile and profile.hitCap
    return hc and hc.pvp or false
end

-- Rating needed for 1% hit of this type, read LIVE from the game so it tracks
-- Ascension's own scaling and the player's level (same source as the "7/22"
-- display). GetCombatRatingBonus is 0 when current rating is 0, so the ratio
-- is only derivable with some hit on; cache the last-good value per type and
-- fall back to it. Returns nil when never seen — caller then treats the item
-- as fully under-cap (a player with no hit is far under any cap anyway).
local function HitRatingPerPct(mode)
    local idx = HITCAP_INDEX[mode]
    if not idx or not GetCombatRating or not GetCombatRatingBonus then return nil end
    local rating = GetCombatRating(idx)
    local pct = GetCombatRatingBonus(idx)
    if rating and pct and pct > 0 then
        local ratio = rating / pct
        db.hitCapRatio = db.hitCapRatio or {}
        db.hitCapRatio[mode] = ratio
        return ratio
    end
    return db.hitCapRatio and db.hitCapRatio[mode] or nil
end

-- Cap rating for this profile's hit mode, or nil (mode off / ratio unknown).
-- Targets the PvE cap by default; with hitCap.pvp = true, targets the lower
-- PvP cap instead (the other cap is shown in the readout for reference).
local function HitCapRating(profile)
    local mode = HitCapMode(profile)
    if mode == "off" then return nil end
    local ratio = HitRatingPerPct(mode)
    if not ratio then return nil end
    local pctTable = HitCapPvP(profile) and HITCAP_PCT_PVP or HITCAP_PCT
    return pctTable[mode] * ratio, mode
end

-- Current total hit rating of the profile's mode (from all worn gear).
local function CurrentHitRating(mode)
    local idx = HITCAP_INDEX[mode]
    if not idx or not GetCombatRating then return 0 end
    return GetCombatRating(idx) or 0
end

-- Cap-corrects a (new item, equipped item) score pair for one slot. Replaces
-- the flat linear hit term (wUnder * hit, already baked into both scores) with
-- the item's MARGINAL cap value given the hit worn on OTHER slots. wOver = 0:
-- hit past the cap is worth nothing. Returns the two corrected scores.
local function ApplyHitCap(profile, newScore, newHit, equippedScore, equippedHit)
    local cap, mode = HitCapRating(profile)
    if not cap then return newScore, equippedScore end
    local wUnder = (profile.weights and profile.weights.HIT) or 0
    if wUnder == 0 then return newScore, equippedScore end
    newHit = newHit or 0
    equippedHit = equippedHit or 0
    local hitOther = CurrentHitRating(mode) - equippedHit
    if hitOther < 0 then hitOther = 0 end
    local function capVal(h)
        if h <= cap then return wUnder * h end
        return wUnder * cap -- wOver = 0: nothing past the cap
    end
    local base = capVal(hitOther)
    newScore = newScore - wUnder * newHit + (capVal(hitOther + newHit) - base)
    equippedScore = equippedScore - wUnder * equippedHit + (capVal(hitOther + equippedHit) - base)
    return newScore, equippedScore
end

-- One profile's verdict for an already-scored item. Returns nil (nothing to
-- show — including any side we couldn't actually read) or a result table:
--   status  = "upgrade" | "downgrade" | "even" | "empty"
--   pct     = signed % difference (for upgrade/downgrade/even)
--   gain    = absolute score difference (new - equipped; the new item's own
--             score when the slot is empty or scores zero). Percentages are
--             not comparable across slots — a +50% ring can be worth less
--             than a +10% two-hander — so anything ranking DIFFERENT items
--             against each other (quest reward auto-pick) must use this.
--   context = optional extra text, e.g. "vs main + off hand"
-- profile nil = the active profile (ScoreEquipped's primary memo fields);
-- the secondary verdict passes its own profile. The slot logic below is
-- weight-independent — only the scores differ between profiles.
local function VerdictForProfile(info, profile)
    local equippedScore, equippedHit, context
    -- profile may be nil (primary verdict = active profile); resolve it for
    -- the hit-cap correction, which needs the real weights/hitCap table.
    local capProfile = profile or ActiveProfile()
    -- New item's own cap-corrected score, for the empty/zero-baseline gains
    -- (quest auto-pick ranks by gain, so hit over cap must not inflate it).
    local function emptyNewScore()
        local ns = ApplyHitCap(capProfile, info.score, info.hit, 0, 0)
        return ns
    end

    if info.equipLoc == "INVTYPE_2HWEAPON" then
        -- A two-hander replaces everything you're holding: compare against
        -- main hand + off hand combined, the offhand's weapon DPS at the
        -- dual-wield penalty factor (shields/holdables have no DPS share
        -- and keep full value).
        local mh, _, mhHit = ScoreEquipped(16, profile)
        local oh, ohDps, ohHit = ScoreEquipped(17, profile)
        if mh == false or oh == false then return nil end
        if not mh and not oh then
            return { status = "empty", gain = emptyNewScore(),
                levelLocked = info.levelLocked, approx = info.approx }
        end
        equippedScore = (mh or 0) + (oh or 0)
        equippedHit = (mhHit or 0) + (ohHit or 0)
        if oh and ohDps then
            equippedScore = equippedScore - ohDps * (1 - OFFHAND_DPS_FACTOR)
        end
        if oh then context = "vs main + off hand" end
    elseif MainHandIs2H()
        and (info.equipLoc == "INVTYPE_WEAPON"
            or info.equipLoc == "INVTYPE_WEAPONMAINHAND"
            or info.equipLoc == "INVTYPE_WEAPONOFFHAND"
            or info.equipLoc == "INVTYPE_HOLDABLE"
            or info.equipLoc == "INVTYPE_SHIELD") then
        -- Anything held while a 2H is equipped means giving up the 2H, so
        -- that's what it has to beat.
        equippedScore, _, equippedHit = ScoreEquipped(16, profile)
        if equippedScore == false then return nil end
        context = "vs equipped 2H"
    else
        local slots = SLOTS_FOR_INVTYPE[info.equipLoc]
        if info.equipLoc == "INVTYPE_WEAPON"
            and (not CanDualWield() or OffhandIsShield()) then
            slots = { 16 }
        end
        -- Multi-slot gear (rings, trinkets, 1H weapons): compare against
        -- the weaker of the equipped items, since that's what you'd replace.
        local weakerSlot
        for _, slot in ipairs(slots) do
            local s, _, sHit = ScoreEquipped(slot, profile)
            if s == false then return nil end
            if not s then
                return { status = "empty", gain = emptyNewScore(),
                    levelLocked = info.levelLocked, approx = info.approx }
            end
            if not equippedScore or s < equippedScore then
                equippedScore, equippedHit, weakerSlot = s, sHit, slot
            end
        end
        -- When two slots competed, name the loser so the verdict says
        -- what it's actually beating (and what smart equip will replace).
        if weakerSlot and #slots > 1 then
            local elink = GetInventoryItemLink("player", weakerSlot)
            local name = elink and elink:match("%[(.-)%]")
            if name then context = "vs " .. name end
        end
    end

    if not equippedScore then
        return { status = "empty", gain = emptyNewScore(),
            levelLocked = info.levelLocked, approx = info.approx }
    end

    -- Both sides readable: re-score the HIT term against the cap before
    -- comparing (no-op when the profile's hit-cap mode is off). newScore is
    -- info.score with the cap correction; the linear info.score is untouched.
    local newScore
    newScore, equippedScore = ApplyHitCap(capProfile, info.score, info.hit,
        equippedScore, equippedHit)

    if equippedScore <= 0 then
        -- Equipped item scores zero or negative under these weights; a
        -- percentage against that is meaningless, treat as free upgrade
        -- if the new item scores anything at all. zeroBaseline marks this
        -- so renderers don't claim the slot is EMPTY (the "empty" status
        -- only earns the upgrade arrow here — the slot is occupied): sparse
        -- profiles (e.g. a healer secondary profile looking at a Strength
        -- belt) score worn gear at 0 all the time.
        if newScore > 0 then
            return { status = "empty", zeroBaseline = true, context = context,
                gain = newScore,
                levelLocked = info.levelLocked, approx = info.approx }
        end
        -- BOTH sides score nothing: not parity — this profile simply has no
        -- weights for anything on either item. zeroAll marks it so renderers
        -- say "No value" instead of a misleading "0%".
        return { status = "even", pct = 0, zeroAll = true, context = context,
            gain = 0,
            levelLocked = info.levelLocked, approx = info.approx }
    end

    local pct = (newScore - equippedScore) / equippedScore * 100
    -- Clamp absurd percentages (tiny denominators) so the display stays sane.
    if pct > 999 then pct = 999 elseif pct < -999 then pct = -999 end

    local status
    if pct > 0.5 then status = "upgrade"
    elseif pct < -0.5 then status = "downgrade"
    else status = "even" end

    return { status = status, pct = pct, context = context,
        gain = newScore - equippedScore,
        levelLocked = info.levelLocked, approx = info.approx }
end

-- Core comparison. Returns nil (nothing to show — including any side we
-- couldn't actually read) or the active profile's result table:
--   status  = "upgrade" | "downgrade" | "even" | "empty" | "unusable" | "wrongarmor"
--   pct     = signed % difference (for upgrade/downgrade/even)
--   context = optional extra text, e.g. "vs main + off hand"
--   approx  = true when scored from a bare link (base item, not the
--             scaled instance): display as estimate, never as bag arrow
--   secondary = the secondary profile's verdict table (same shape), when a
--             secondary profile is configured. Never attached for the
--             profile-independent statuses (unusable/wrongarmor); a side
--             that can't be read kills only the secondary verdict, never
--             the primary one.
-- (Wrapped by CompareItem below, which memoizes bag-slot results.)
local function CompareItemUncached(link, bag, slot, invSlot, src)
    local info = ScoreItem(link, bag, slot, invSlot, src)
    if not info then return nil end
    if info.quality < (db.minQuality or 0) then return nil end

    -- Level requirement is deliberately NOT checked via GetItemInfo():
    -- Ascension scales items, and GetItemInfo() reports the base item's
    -- required level, not the scaled one on your actual copy. The tooltip
    -- scan handles it instead — the client renders any requirement you
    -- don't meet (level, proficiency, class) in red.
    if info.unusable then
        return { status = "unusable", context = info.unusableReason }
    end

    if ARMOR_FILTERED_INVTYPES[info.equipLoc]
        and info.itemType == "Armor"
        and db.armorTypes[info.itemSubType] == false then
        return { status = "wrongarmor", context = info.itemSubType }
    end

    local result = VerdictForProfile(info)
    if not result then return nil end

    -- Secondary (blue) verdict: same tooltip scan, second weighted sum —
    -- ScanItem is weight-independent and cached, so this costs one
    -- re-scoring, not one re-scan.
    local secondary = SecondaryProfile()
    if secondary then
        local info2 = ScoreItem(link, bag, slot, invSlot, src, secondary)
        if info2 then
            result.secondary = VerdictForProfile(info2, secondary)
        end
    end

    return result
end

-- Bag-slot lookups are the hot path: every open bag re-evaluates every
-- slot on each redraw (ContainerFrame_Update / Bagnon hooks), so those
-- results are memoized per location+link until the generation moves.
-- Other sources (equipped invSlot, quest/roll/loot src) stay live — they
-- carry their own retry semantics. nil results are never cached: nil can
-- mean "scan not ready yet" and must keep retrying until it resolves.
local function CompareItem(link, bag, slot, invSlot, src)
    if bag ~= nil and slot ~= nil and invSlot == nil and src == nil then
        local key = bag .. ":" .. slot .. ":" .. link
        local hit = verdictCache[key]
        if hit and hit.gen == generation then return hit.result end
        local result = CompareItemUncached(link, bag, slot)
        -- Only cache fully-resolved results: with a secondary profile set,
        -- a missing .secondary half means its equipped side wasn't readable
        -- yet — caching that would pin the verdict half-drawn until the
        -- next generation bump instead of retrying like a nil result does.
        if result and (result.secondary or not SecondaryProfile()) then
            verdictCache[key] = { gen = generation, result = result }
        end
        return result
    end
    return CompareItemUncached(link, bag, slot, invSlot, src)
end

--------------------------------------------------------------------------
-- Smart equip
--
-- Right-clicking a ring/trinket/1H weapon into a full pair should replace
-- the WEAKER of the two equipped items under current weights, not the
-- engine's fixed pick (always the first slot). The click can't be
-- preempted: replacing the UseContainerItem global puts addon code in the
-- path of every bag click and Blizzard flags that as taint (see the
-- bag-upgrade hook in Refactor.lua for the war story), so this reacts
-- after the engine's own equip instead. The engine swaps the displaced
-- item into the clicked bag slot; once it lands there unlocked, it gets
-- equipped over the weaker slot — both better items stay equipped, the
-- weaker one ends up in the bag. Scores are snapshotted at click time
-- (both items still equipped — the swap is a server round trip) under the
-- usual trust rules: either side unreadable means hands off, and a failed
-- or blocked equip (level requirement, rings in combat) never settles, so
-- the watchdog just times the fix-up out.
--------------------------------------------------------------------------

local SMART_EQUIP_SLOTS = {
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_WEAPON = { 16, 17 },
}

-- Exported via RefactorCompareShared: Refactor.lua's seamless bag upgrade
-- checks it before starting its own item shuffle (and vice versa, via
-- RefactorQoL.BagShuffleActive) — two concurrent PickupContainerItem
-- sequences desync the cursor.
local SmartEquipActive

do
    local seFrame = CreateFrame("Frame")
    local se -- pending fix-up, nil when idle
    local seElapsed = 0

    SmartEquipActive = function() return se ~= nil end

    local function StopSmartEquip()
        se = nil
        seFrame:UnregisterAllEvents()
        seFrame:SetScript("OnUpdate", nil)
    end

    seFrame:SetScript("OnEvent", function()
        if not se then return end
        -- Which slot did the engine put the new item in?
        local landed
        for i = 1, 2 do
            if GetInventoryItemLink("player", se.slots[i]) ~= se.links[i] then
                landed = i
                break
            end
        end
        if not landed then return end -- swap not visible yet
        if se.slots[landed] == se.weakerSlot then
            StopSmartEquip() -- engine already replaced the weaker one
            return
        end
        -- The displaced (stronger) item should be sitting in the clicked
        -- bag slot; wait until it's there and unlocked.
        if GetContainerItemLink(se.bag, se.slot) ~= se.links[landed] then return end
        local _, _, locked = GetContainerItemInfo(se.bag, se.slot)
        if locked then return end
        if CursorHasItem() then
            StopSmartEquip()
            return
        end
        local bag, slot, target = se.bag, se.slot, se.weakerSlot
        StopSmartEquip()
        PickupContainerItem(bag, slot)
        EquipCursorItem(target)
    end)

    local function SeWatchdog(_, elapsed)
        seElapsed = seElapsed + elapsed
        if seElapsed > 2 then StopSmartEquip() end
    end

    hooksecurefunc("UseContainerItem", function(bag, slot)
        if not db or not db.enabled or db.smartEquip == false then return end
        if se then return end -- a fix-up is already in flight
        -- Seamless bag upgrade (Refactor.lua) mid-shuffle: its queue is
        -- moving items through the same events; hands off until it's done.
        if RefactorQoL and RefactorQoL.BagShuffleActive
            and RefactorQoL.BagShuffleActive() then
            return
        end
        -- Right-click means sell/deposit/attach/trade while these are open.
        if (MerchantFrame and MerchantFrame:IsShown())
            or (BankFrame and BankFrame:IsShown())
            or (MailFrame and MailFrame:IsShown())
            or (TradeFrame and TradeFrame:IsShown())
            or (AuctionFrame and AuctionFrame:IsShown())
            or (GuildBankFrame and GuildBankFrame:IsShown()) then
            return
        end
        if CursorHasItem() then return end
        local link = GetContainerItemLink(bag, slot)
        if not link then return end
        local equipLoc = select(9, GetItemInfo(link))
        local slots = SMART_EQUIP_SLOTS[equipLoc]
        if not slots then return end
        if equipLoc == "INVTYPE_WEAPON"
            and (not CanDualWield() or MainHandIs2H() or OffhandIsShield()) then
            return -- only one candidate slot; the engine default is right
        end
        local linkA = GetInventoryItemLink("player", slots[1])
        local linkB = GetInventoryItemLink("player", slots[2])
        if not linkA or not linkB then return end -- empty slot: engine fills it
        local sa = ScoreEquipped(slots[1])
        local sb = ScoreEquipped(slots[2])
        if type(sa) ~= "number" or type(sb) ~= "number" then return end
        if sa == sb then return end -- either is fine, leave the engine to it
        se = {
            bag = bag, slot = slot, slots = slots,
            links = { linkA, linkB },
            weakerSlot = sa < sb and slots[1] or slots[2],
        }
        seElapsed = 0
        seFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
        seFrame:RegisterEvent("ITEM_LOCK_CHANGED")
        seFrame:RegisterEvent("BAG_UPDATE")
        seFrame:SetScript("OnUpdate", SeWatchdog)
    end)
end

--------------------------------------------------------------------------
-- Tooltip line
--------------------------------------------------------------------------

-- The verdict used to be a floating overlay pinned to the tooltip's
-- top-right corner, tinted via SetVertexColor/SetTextColor. On a long
-- item name that overlay sits on top of the title text: the corner
-- position is fixed while the title (left-anchored, natural width) can
-- reach all the way to the frame edge. The fix isn't "make the frame
-- wider" — tooltip:SetWidth() after OnTooltipSetItem doesn't stick, the
-- client recomputes width from its own lines and discards it. The only
-- resize that's reliable is adding a genuine line via AddLine/
-- AddDoubleLine, since that's native content the client sizes for. So
-- the verdict is now its own tooltip line instead of an overlay:
-- guaranteed to never collide with anything else, at the cost of the
-- compact corner-badge look. Direction is still unambiguous — sign on
-- the percentage plus red/green — even without the arrow icon.
local ARROW_TEXTURE = "Interface\\AddOns\\Refactor\\arrow" -- fallback texture asset
local LOOT_TOAST_ATLAS = "Interface\\LootFrame\\LootToastAtlas"

local ATLAS_COORDS = {
    ["loottoast-arrow-green"] = { left = 0.858398, right = 0.878906, top = 0.158203, bottom = 0.207031 },
    ["loottoast-arrow-blue"]  = { left = 0.835938, right = 0.856445, top = 0.158203, bottom = 0.207031 },
    ["loottoast-arrow-red"]   = { left = 0.878906, right = 0.899414, top = 0.158203, bottom = 0.207031 },
}

local function SetArrowAtlas(arrow, atlasName, fallbackR, fallbackG, fallbackB, flipY)
    local coords = ATLAS_COORDS[atlasName] or ATLAS_COORDS["loottoast-arrow-green"]
    if coords then
        if arrow:SetTexture(LOOT_TOAST_ATLAS) then
            local top = flipY and coords.bottom or coords.top
            local bottom = flipY and coords.top or coords.bottom
            arrow:SetTexCoord(coords.left, coords.right, top, bottom)
            if arrow.SetDesaturated then arrow:SetDesaturated(false) end
            if fallbackR and fallbackG and fallbackB then
                arrow:SetVertexColor(fallbackR, fallbackG, fallbackB)
            else
                arrow:SetVertexColor(1, 1, 1)
            end
            return true
        end
    end
    if arrow.SetAtlas then
        local ok = pcall(arrow.SetAtlas, arrow, atlasName)
        if ok then
            if arrow.SetDesaturated then arrow:SetDesaturated(false) end
            if fallbackR and fallbackG and fallbackB then
                arrow:SetVertexColor(fallbackR, fallbackG, fallbackB)
            else
                arrow:SetVertexColor(1, 1, 1)
            end
            arrow:SetTexCoord(0, 1, flipY and 1 or 0, flipY and 0 or 1)
            return true
        end
    end
    if arrow:SetTexture(ARROW_TEXTURE) then
        if arrow.SetDesaturated then arrow:SetDesaturated(false) end
        arrow:SetTexCoord(0, 1, flipY and 1 or 0, flipY and 0 or 1)
        arrow:SetVertexColor(fallbackR or 0, fallbackG or 1, fallbackB or 0)
        return true
    else
        arrow:SetTexture(fallbackR or 0, fallbackG or 1, fallbackB or 0, 0.9)
        return false
    end
end

-- Secondary-profile verdict color: one hue for everything secondary (text,
-- tooltip arrow, bag arrow, up and down) — color identifies the PROFILE,
-- arrow direction carries the verdict. Blue stays clear of the primary
-- green/red, the gold "even" text, and the quest-reward gold coin.
local SEC_R, SEC_G, SEC_B = 0.35, 0.65, 1

-- Anchors a tinted arrow texture just left of the given fontstring. Anchored
-- to that specific text (not the tooltip frame corner, as the old overlay
-- was) so it can never collide with a long item title above it. `down`
-- flips the (up-pointing) source art vertically for the downgrade case —
-- there's only the one arrow.tga asset, no separate down/red variant.
-- field picks which tooltip texture slot to use (the secondary verdict gets
-- its own so both can be visible at once).
local function ShowLineArrow(tooltip, fontString, r, g, b, down, field, offset)
    if not fontString then return end
    field = field or "refactorLineArrow"
    local arrow = tooltip[field]
    if not arrow then
        arrow = tooltip:CreateTexture(nil, "OVERLAY")
        tooltip[field] = arrow
    end
    arrow:ClearAllPoints()

    if not down and b > 0.5 and r < 0.5 then
        SetArrowAtlas(arrow, "loottoast-arrow-blue", nil, nil, nil, false)
    elseif not down and g > 0.5 and r < 0.5 then
        SetArrowAtlas(arrow, "loottoast-arrow-green", nil, nil, nil, false)
    elseif down then
        -- Red downgrade arrow using LootToastAtlas sprite flipped vertically with red vertex tinting
        SetArrowAtlas(arrow, "loottoast-arrow-red", r, g, b, true)
    else
        SetArrowAtlas(arrow, "loottoast-arrow-green", r, g, b, false)
    end

    arrow:SetWidth(12)
    arrow:SetHeight(14)
    if offset then
        -- Negative inset from the fontstring's RIGHT edge: parks the arrow
        -- just left of the trailing % when a label leads the text ("Warden
        -- <arrow> +66%"). Measured from the right edge so the label/gap
        -- widths never have to be known.
        arrow:SetPoint("RIGHT", fontString, "RIGHT", offset, 0)
    else
        -- -2px clearance so the primary arrow aligns perfectly with the
        -- secondary arrow on the line below.
        arrow:SetPoint("RIGHT", fontString, "LEFT", -2, 0)
    end
    arrow:Show()
end

local function HideLineArrow(tooltip)
    if tooltip.refactorLineArrow then tooltip.refactorLineArrow:Hide() end
    if tooltip.refactorLineArrow2 then tooltip.refactorLineArrow2:Hide() end
end

-- Rows whose right column is reliably blank, tried in order so the verdict
-- lands in roughly the same place regardless of item type: Durability
-- covers weapons/armor, but plenty of gear (rings, trinkets, necks) has
-- none of those and only ever shows "Requires Level N" — which every
-- piece of equipment prints (even at level 1, per Blizzard's own tooltip
-- code), so it's the reliable second choice.
local ROW_PATTERNS = { "^Durability", "^Requires Level" }

-- Rides one of the rows above instead of adding a whole new line, so the
-- verdict sits in a consistent spot (mirrors how Blizzard already puts
-- weapon Speed in the right column of its own row). Returns the
-- right-column fontstring on success so the caller can anchor the arrow.
local function SetCompareRowText(tooltip, text, r, g, b)
    local name = tooltip:GetName()
    for _, pattern in ipairs(ROW_PATTERNS) do
        for i = 2, tooltip:NumLines() do
            local left = _G[name .. "TextLeft" .. i]
            local leftText = left and left:GetText()
            if leftText and leftText:match(pattern) then
                local right = _G[name .. "TextRight" .. i]
                if not right then return nil end
                right:SetText(text)
                right:SetTextColor(r, g, b)
                right:Show()
                return right, i
            end
        end
    end
    return nil
end

-- Places text in the right column of an EXISTING tooltip line, used to sit
-- the secondary verdict directly under the primary's row. Returns the
-- right-column fontstring, or nil when that line is absent or its right
-- column is already occupied (leave it be — caller falls back to AddLine).
local function SetRowRightTextAt(tooltip, i, text, r, g, b)
    if not i or i < 2 or i > tooltip:NumLines() then return nil end
    local right = _G[tooltip:GetName() .. "TextRight" .. i]
    if not right then return nil end
    local existing = right:GetText()
    if existing and existing ~= "" then return nil end
    right:SetText(text)
    right:SetTextColor(r, g, b)
    right:Show()
    return right
end

local function AddCompareLine(tooltip, link, bag, slot, invSlot, src)
    if not db or not db.enabled then return end
    local result = CompareItem(link, bag, slot, invSlot, src)
    if not result then return end

    HideLineArrow(tooltip)

    -- result.approx (scored from the base-item link, not the scaled copy)
    -- deliberately gets no visual marker — per user preference the verdict
    -- line looks the same either way. The flag still gates bag arrows and
    -- loot alerts, which estimates never earn.
    --
    -- No "Compare:" label anywhere (per user preference) — the up/down
    -- arrow carries that meaning instead, matching the bag/quest arrows.
    local text, r, g, b, arrowDir
    if result.status == "unusable" then
        local suffix = result.context and (" (" .. result.context .. ")") or ""
        text, r, g, b = "Can't equip" .. suffix, 1, 0.4, 0.4
    elseif result.status == "wrongarmor" then
        text, r, g, b = "Filtered armor type", 0.6, 0.6, 0.6
    elseif result.status == "empty" then
        text = result.zeroBaseline and "Equipped scores 0" or "Fills empty slot"
        r, g, b, arrowDir = 0, 1, 0, "up"
    elseif result.status == "even" then
        if result.zeroAll then
            -- Neither item scores under this profile: not parity, just
            -- irrelevance — quiet gray like the armor-filter notice.
            text, r, g, b = "No value", 0.6, 0.6, 0.6
        else
            text, r, g, b = "0%", 1, 0.82, 0
        end
    elseif result.status == "upgrade" then
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 0, 1, 0, "up"
    else
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 1, 0.25, 0.25, "down"
    end

    local w1, w2 = 0, 0
    if arrowDir or sec then
        if not tooltip.refactorMeasure then
            tooltip.refactorMeasure = tooltip:CreateFontString(nil, "OVERLAY", "GameTooltipText")
        end
        local measure = tooltip.refactorMeasure
        if arrowDir then
            measure:SetText(text)
            w1 = measure:GetStringWidth() or 0
        end
    end

    local fontString, primaryLine = SetCompareRowText(tooltip, text, r, g, b)
    if not fontString then
        tooltip:AddLine(text, r, g, b)
        primaryLine = tooltip:NumLines()
        fontString = _G[tooltip:GetName() .. "TextLeft" .. primaryLine]
    end

    -- Secondary profile's verdict: rides the right column of the row
    -- directly under the primary's row, the spec-name label folded into
    -- that right-column text so the whole group right-aligns as
    -- "Requires Level 17   Warden <arrow> +24%" (the label hugs the arrow —
    -- it does NOT go to the tooltip's left edge, and no new line is added).
    local sec = result.secondary
    local arrowDir2, fs2
    local r2, g2, b2 = SEC_R, SEC_G, SEC_B
    if sec then
        local text2
        if sec.status == "empty" then
            text2 = sec.zeroBaseline and "Equipped scores 0" or "Fills empty slot"
            arrowDir2 = "up"
        elseif sec.status == "even" then
            if sec.zeroAll then
                text2, r2, g2, b2 = "No value", 0.6, 0.6, 0.6
            else
                text2 = "0%"
            end
        else
            text2 = string.format("%+.0f%%", sec.pct)
            arrowDir2 = sec.status == "upgrade" and "up" or "down"
            if arrowDir2 == "down" then
                r2, g2, b2 = 1, 0.25, 0.25
            end
        end

        local secName = db.charSecondaryProfile[CharKey()]
        local label = secName and (secName:match("%- (.+)$") or secName)
        local display = text2
        if label then
            local measure = tooltip.refactorMeasure
            if arrowDir2 then
                measure:SetText("00")
                local pair = measure:GetStringWidth() or 6
                measure:SetText("0 0")
                local spaceW = (measure:GetStringWidth() or (pair + 3)) - pair
                if spaceW < 1 then spaceW = 3 end
                display = label .. string.rep(" ", math.ceil(16 / spaceW)) .. text2
                measure:SetText(text2)
                w2 = measure:GetStringWidth() or 0
            else
                display = label .. " " .. text2
            end
        end

        fs2 = primaryLine and SetRowRightTextAt(tooltip, primaryLine + 1, display, r2, g2, b2)
        if not fs2 then
            tooltip:AddLine(display, r2, g2, b2)
            fs2 = _G[tooltip:GetName() .. "TextLeft" .. tooltip:NumLines()]
        end
    end

    -- Align both arrows to the maximum text width so they form a 100% straight vertical column
    local maxW = math.max(w1, w2)
    local sharedOffset = (maxW > 0) and -(maxW + 2) or nil

    if arrowDir then
        ShowLineArrow(tooltip, fontString, r, g, b, arrowDir == "down", "refactorLineArrow", sharedOffset)
    end
    if arrowDir2 and fs2 then
        ShowLineArrow(tooltip, fs2, r2, g2, b2, arrowDir2 == "down", "refactorLineArrow2", sharedOffset)
    end

    tooltip:Show()
    return true -- a verdict was drawn (callers retry while this is falsy)
end

-- Figure out which real item the tooltip is showing, so the scaled
-- instance gets scanned instead of the base item. Bag buttons (stock and
-- Bagnon alike) satisfy button:GetParent():GetID() == bag and
-- button:GetID() == slot; character paperdoll slots carry the inventory
-- slot as their ID. The link check guards against unrelated owners whose
-- IDs happen to point at some other item.
--
-- src = false is a hard block: the owner is a frame with a live scaled
-- source (roll window, loot window, quest reward) that couldn't be
-- confirmed yet — falling back to a bare-link scan there scores the BASE
-- item and flashes a wrong % until the client re-renders with real data.
-- Better to show nothing for that frame.
local function GetTooltipSource(tooltip, link)
    local owner = tooltip:GetOwner()
    if not (owner and owner.GetID) then return end

    -- Group loot roll windows: the hovered icon's parent (GroupLootFrame)
    -- carries rollID. SetLootRollItem renders the scaled item being
    -- rolled, so the verdict matches what lands in the winner's bags —
    -- a bare-link scan reads the BASE item and shifts the % afterwards.
    -- Checked before the ID guard below: the icon frame's own ID is 0.
    local rollParent = owner:GetParent()
    local rollID = rollParent and rollParent.rollID
    if rollID and GetLootRollItemLink then
        -- Match by item ID, not whole link: while the roll data is still
        -- arriving GetLootRollItemLink can be nil or carry volatile link
        -- fields that differ from the tooltip's own. The rollID on the
        -- hovered frame is authoritative enough once the IDs agree.
        local rollLink = GetLootRollItemLink(rollID)
        if not rollLink
            or rollLink:match("item:(%d+)") == link:match("item:(%d+)") then
            return nil, nil, nil, { roll = rollID }
        end
        return nil, nil, nil, false
    end

    -- Corpse/chest loot window buttons: SetLootItem for the same reason.
    local ownerName = owner.GetName and owner:GetName()
    if ownerName and ownerName:match("^LootButton%d+$") and owner.slot then
        if GetLootSlotLink(owner.slot) == link then
            return nil, nil, nil, { lootSlot = owner.slot }
        end
        return nil, nil, nil, false
    end

    -- Vendor/merchant item buttons: SetMerchantItem / SetBuybackItem for scaled items.
    if ownerName and ownerName:match("^MerchantItem%d+ItemButton$") then
        local id = owner:GetID()
        if id and id > 0 then
            local isBuyback = MerchantFrame and MerchantFrame.selectedTab == 2
            local mlink = isBuyback and (GetBuybackItemLink and GetBuybackItemLink(id))
                or (GetMerchantItemLink and GetMerchantItemLink(id))
            if mlink == link then
                return nil, nil, nil, isBuyback and { buybackSlot = id } or { merchantSlot = id }
            end
        end
        return nil, nil, nil, false
    end

    local id = owner:GetID()
    if not id or id <= 0 then return end

    -- Bagnon-style item buttons know their bag directly; cached buttons
    -- show another character's (or offline) data, where the live bag
    -- APIs would read the wrong item — no live source for those.
    if owner.GetBag then
        if not (owner.IsCached and owner:IsCached()) then
            local bag = owner:GetBag()
            if type(bag) == "number" and GetContainerItemLink(bag, id) == link then
                return bag, id, nil
            end
        end
        return
    end

    -- Paperdoll slots (CharacterHeadSlot...) before the generic bag
    -- guess: their parent's ID is 0 = backpack, so a backpack item with
    -- the same link at the same slot number would shadow them.
    local name = owner.GetName and owner:GetName()
    if name and name:match("^Character.*Slot$") then
        if GetInventoryItemLink("player", id) == link then
            return nil, nil, id
        end
        return
    end

    -- Quest reward buttons (QuestInfoItem1..N, shared by the quest-giver
    -- frame and the quest log): scanning via SetQuestItem/SetQuestLogItem
    -- renders the scaled copy the server would hand over, so the verdict
    -- matches what the item scores once it's in the bags. Scoring the
    -- bare link here reads the BASE item and flips verdicts on scaled
    -- rewards.
    if name and name:match("^QuestInfoItem%d+$")
        and (owner.type == "choice" or owner.type == "reward") then
        local qlog = QuestInfoFrame and QuestInfoFrame.questLog and true or false
        local qlink
        if qlog then
            qlink = GetQuestLogItemLink(owner.type, id)
        else
            qlink = GetQuestItemLink(owner.type, id)
        end
        if qlink == link then
            return nil, nil, nil, { log = qlog, type = owner.type, index = id }
        end
        return nil, nil, nil, false
    end

    local parent = owner:GetParent()
    local bag = parent and parent.GetID and parent:GetID()
    if bag and GetContainerItemLink(bag, id) == link then
        return bag, id, nil
    end
    if GetInventoryItemLink("player", id) == link then
        return nil, nil, id
    end
end

-- True if `link` matches something already worn. Blizzard's own shift-compare
-- "Currently Equipped" panel reuses a hooked tooltip template to redisplay
-- your own gear; when that fires OnTooltipSetItem, GetTooltipSource can't map
-- it to a real bag/paperdoll button (it isn't one), so without this guard it
-- fell through to a bare-hyperlink scan of the BASE item and printed a bogus
-- second "Compare:" line for gear you already have on — the flicker between
-- two different percentages on the same item.
local function LinkIsEquipped(link)
    for slot = 1, 18 do
        if GetInventoryItemLink("player", slot) == link then return true end
    end
    return false
end

-- Verdict retry: some live sources start out unreadable — a loot-roll
-- tooltip's first render can carry the stale base armor (see the
-- stale-armor check in ScanItem) or its item data hasn't arrived yet —
-- and unlike bag tooltips, the client doesn't always re-set those once
-- the real data lands, so a verdict discarded at hover time would stay
-- missing for the whole roll. While the same tooltip keeps showing the
-- same link, re-run the pipeline every 0.25s until a verdict draws (or
-- correctly stays absent: equipped-gear re-renders count as settled) or
-- the attempts run out. Verdicts that are legitimately never shown
-- (non-gear, quality-filtered) just let the retries expire silently.
local tipRetryFrame = CreateFrame("Frame")
tipRetryFrame:Hide()
local tipRetryTip, tipRetryLink, tipRetryElapsed, tipRetryTries

local function StartTipRetry(tip, link)
    tipRetryTip, tipRetryLink = tip, link
    tipRetryElapsed, tipRetryTries = 0, 8
    tipRetryFrame:Show()
end

tipRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    tipRetryElapsed = tipRetryElapsed + elapsed
    if tipRetryElapsed < 0.25 then return end
    tipRetryElapsed = 0
    local tip = tipRetryTip
    local link = tip and tip:IsShown() and select(2, tip:GetItem())
    if not link or link ~= tipRetryLink then
        self:Hide()
        return
    end
    tipRetryTries = tipRetryTries - 1
    local done = false
    local bag, slot, invSlot, src = GetTooltipSource(tip, link)
    if src ~= false then
        if not (bag or slot or invSlot or src) and LinkIsEquipped(link) then
            done = true -- correctly verdict-free, stop retrying
        else
            done = AddCompareLine(tip, link, bag, slot, invSlot, src)
        end
    end
    if done or tipRetryTries <= 0 then self:Hide() end
end)

local function HookTooltip(tip)
    tip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        -- Dupe guard keyed on the link (not a plain boolean): the same
        -- render pass can fire this twice, but a genuine re-set — the
        -- client refreshing a loot-roll/quest tooltip once the real item
        -- data arrives — goes through OnTooltipCleared below, which
        -- resets the key so the verdict is recomputed from live data.
        if not link or self.refactorCompareDone == link then return end
        self.refactorCompareDone = link
        local bag, slot, invSlot, src = GetTooltipSource(self, link)
        if src == false then
            StartTipRetry(self, link) -- live source pending: no guessing, but keep watching
            return
        end
        if not (bag or slot or invSlot or src) and LinkIsEquipped(link) then
            return
        end
        if not AddCompareLine(self, link, bag, slot, invSlot, src) then
            StartTipRetry(self, link)
        end
    end)
    tip:HookScript("OnTooltipCleared", function(self)
        self.refactorCompareDone = nil
        HideLineArrow(self)
    end)
    tip:HookScript("OnHide", function(self)
        self.refactorCompareDone = nil
        HideLineArrow(self)
    end)
end

HookTooltip(GameTooltip)
HookTooltip(ItemRefTooltip)
-- The fullscreen map's quest pane shows rewards through QuestInfo's
-- QUEST_TEMPLATE_MAP2, whose item buttons write to WorldMapTooltip — a
-- separate GameTooltipTemplate instance — so without this hook a reward
-- hovered on the map got no verdict while the same reward in the quest
-- log (QUEST_TEMPLATE_LOG, GameTooltip) did.
if WorldMapTooltip then HookTooltip(WorldMapTooltip) end

--------------------------------------------------------------------------
-- Bag slot upgrade arrow
--------------------------------------------------------------------------

-- Same shipped arrow texture as the tooltip overlay, tinted green. (A
-- font glyph was tried first but FRIZQT__.TTF has no ▲ in this client;
-- stock arrow textures proved unreliable too — the red variant is
-- missing from this build.) If the file somehow fails to load, fall
-- back to a plain green marker so something still shows.
local function GetBagArrow(button)
    local arrow = button.refactorArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        button.refactorArrow = arrow
    end
    return arrow
end

-- Secondary profile's bag arrow: loottoast-arrow-blue texture, opposite corner. Only
-- ever an UPGRADE marker (upgrades/empty slots) — downgrades get no arrow
-- for either profile.
local function GetBagArrow2(button)
    local arrow = button.refactorArrow2
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        SetArrowAtlas(arrow, "loottoast-arrow-blue", SEC_R, SEC_G, SEC_B)
        button.refactorArrow2 = arrow
    end
    return arrow
end

local function UpdateArrowForLink(button, link, bag, slot)
    local show, show2 = false, false
    if link and db and db.enabled and db.bagIcons then
        local result = CompareItem(link, bag, slot)
        -- The arrow is a promise, not a hint: estimates (base-item link
        -- scans, cached other-character slots) never earn it — and the
        -- secondary (blue) arrow plays by the exact same rule.
        show = result ~= nil
            and not result.approx
            and (result.status == "upgrade" or result.status == "empty")
        local sec = result and result.secondary
        show2 = db.secondaryBagArrow
            and sec ~= nil
            and not result.approx
            and (sec.status == "upgrade" or sec.status == "empty")
    end
    if show then
        GetBagArrow(button):Show()
    elseif button.refactorArrow then
        button.refactorArrow:Hide()
    end
    if show2 then
        GetBagArrow2(button):Show()
    elseif button.refactorArrow2 then
        button.refactorArrow2:Hide()
    end
end

local function UpdateBagButton(button, bag, slot)
    UpdateArrowForLink(button, GetContainerItemLink(bag, slot), bag, slot)
end

local function UpdateContainerArrows(frame)
    local bag = frame:GetID()
    local frameName = frame:GetName()
    local shown = 0
    for i = 1, frame.size do
        local button = _G[frameName .. "Item" .. i]
        if button then
            UpdateBagButton(button, bag, button:GetID())
            if button.refactorArrow and button.refactorArrow:IsShown() then
                shown = shown + 1
            end
        end
    end
    if db and db.debug then
        Print("bag " .. bag .. " updated, " .. shown .. " upgrade arrow(s).")
    end
end

-- 3.3.5 has no per-button update function to hook; ContainerFrame_Update
-- is what redraws a whole bag frame (on open and on BAG_UPDATE while
-- open). Guarded in case this custom client renames it — losing the bag
-- arrows should not take the rest of the addon down with it.
if type(ContainerFrame_Update) == "function" then
    hooksecurefunc("ContainerFrame_Update", UpdateContainerArrows)
end

-- Bagnon replaces the stock bag frames entirely, so ContainerFrame_Update
-- never fires while it's enabled. Its item buttons all share the
-- Bagnon.ItemSlot class; post-hooking its Update method covers every
-- slot redraw. DragonUI's bundled Combuctor bag module is the same
-- design (a KPack Combuctor port, itself Bagnon-family) with the same
-- ItemSlot surface (Update/GetBag/GetID/GetItem/IsCached), exposed as
-- DragonUI.CombuctorItemSlot. Buttons are remembered (weak-keyed, mapped
-- to the updater matching their addon's button surface) so equipment
-- changes can re-evaluate them without waiting for the bag addon's own
-- updates.
local hookedSlotButtons = setmetatable({}, { __mode = "k" })

local function UpdateBagnonSlot(self)
    -- Cached slots show another character's (or offline) data; the
    -- live bag APIs would read the wrong item, so fall back to the
    -- link-only scan for those.
    local bag, slot
    if not self:IsCached() then
        bag, slot = self:GetBag(), self:GetID()
    end
    UpdateArrowForLink(self, self:GetItem(), bag, slot)
end

local function HookItemSlotClass(itemSlot)
    hooksecurefunc(itemSlot, "Update", function(self)
        hookedSlotButtons[self] = UpdateBagnonSlot
        UpdateBagnonSlot(self)
    end)
end

local bagnonHooked = false
local function TryHookBagnon()
    if bagnonHooked then return end
    local ace = LibStub and LibStub.GetLibrary
        and LibStub:GetLibrary("AceAddon-3.0", true)
    local bagnon = ace and ace:GetAddon("Bagnon", true)
    local itemSlot = bagnon and bagnon.ItemSlot
    if not itemSlot or type(itemSlot.Update) ~= "function" then return end
    HookItemSlotClass(itemSlot)
    bagnonHooked = true
end

local dragonUIHooked = false
local function TryHookDragonUI()
    if dragonUIHooked then return end
    local itemSlot = _G.DragonUI and _G.DragonUI.CombuctorItemSlot
    if not itemSlot or type(itemSlot.Update) ~= "function" then return end
    HookItemSlotClass(itemSlot)
    dragonUIHooked = true
end

-- AdiBags replaces the stock bags too, but its buttons aren't
-- Bagnon-family: no GetBag/GetItem/IsCached, just .bag/.slot fields and
-- a per-button Update on the "ItemButton" class prototype (fetched via
-- its OO layer's GetClass). The bank sub-class inherits Update through
-- __index, so one post-hook covers backpack, bags and bank alike.
-- AdiBags has no offline-character cache — visible buttons always show
-- the live player bags, so the container APIs are always the right
-- source (its own cached .itemLink can lag behind on equip-triggered
-- refreshes).
local function UpdateAdiBagsSlot(self)
    local bag, slot = self.bag, self.slot
    if bag == nil or slot == nil then return end
    UpdateArrowForLink(self, GetContainerItemLink(bag, slot), bag, slot)
end

local adiBagsHooked = false
local function TryHookAdiBags()
    if adiBagsHooked then return end
    local ace = LibStub and LibStub.GetLibrary
        and LibStub:GetLibrary("AceAddon-3.0", true)
    local adibags = ace and ace:GetAddon("AdiBags", true)
    local class = adibags and adibags.GetClass
        and adibags:GetClass("ItemButton")
    local proto = class and class.prototype
    if not proto or type(proto.Update) ~= "function" then return end
    hooksecurefunc(proto, "Update", function(self)
        hookedSlotButtons[self] = UpdateAdiBagsSlot
        UpdateAdiBagsSlot(self)
    end)
    adiBagsHooked = true
end

-- ElvUI's bag module replaces the stock frames too, but isn't Bagnon- or
-- AdiBags-family: one shared module method (Bags:UpdateSlot(frame, bagID,
-- slotID)) redraws every slot button, rather than a per-button class.
-- Post-hooking that method covers backpack + bags; the button itself is
-- frame.Bags[bagID][slotID] and carries no bag/slot fields of its own, so
-- they're stashed on the button for RefreshOpenBags to reuse later.
local function UpdateElvUISlot(button, bagID, slotID)
    button.refactorBag, button.refactorSlot = bagID, slotID
    UpdateArrowForLink(button, GetContainerItemLink(bagID, slotID), bagID, slotID)
end

local function RefreshElvUISlot(button)
    if button.refactorBag == nil then return end
    UpdateArrowForLink(button, GetContainerItemLink(button.refactorBag, button.refactorSlot),
        button.refactorBag, button.refactorSlot)
end

local elvUIHooked = false
local function TryHookElvUI()
    if elvUIHooked then return end
    local ace = LibStub and LibStub.GetLibrary
        and LibStub:GetLibrary("AceAddon-3.0", true)
    local elvui = ace and ace.GetAddon and ace:GetAddon("ElvUI", true)
    local bagsModule = elvui and elvui.GetModule and elvui:GetModule("Bags", true)
    if not bagsModule or type(bagsModule.UpdateSlot) ~= "function" then return end
    hooksecurefunc(bagsModule, "UpdateSlot", function(self, frame, bagID, slotID)
        local button = frame and frame.Bags and frame.Bags[bagID] and frame.Bags[bagID][slotID]
        if not button then return end
        hookedSlotButtons[button] = RefreshElvUISlot
        UpdateElvUISlot(button, bagID, slotID)
    end)
    elvUIHooked = true
end

local UpdateQuestRewards -- defined in the quest-reward section below
local StartRollUpdates -- defined in the loot-roll marker section below
local UpdateMerchantArrows -- defined in the vendor marker section below

-- Redraws every verdict-driven marker (stock and bag-addon slot buttons,
-- quest reward markers, roll-frame arrows, vendor item buttons) against the current memo
-- state. Invalidation is the caller's job: RefreshOpenBags for
-- verdict-moving state changes, the bag-only flush below for single-bag
-- churn.
local function RedrawBags()
    for i = 1, NUM_CONTAINER_FRAMES do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsShown() then
            UpdateContainerArrows(frame)
        end
    end
    for button, updateSlot in pairs(hookedSlotButtons) do
        if button:IsVisible() then
            updateSlot(button)
        end
    end
    if UpdateQuestRewards then UpdateQuestRewards() end
    if StartRollUpdates then StartRollUpdates() end
    if UpdateMerchantArrows then UpdateMerchantArrows() end
end

-- Re-evaluate arrows on open bags when equipped gear changes (equipping
-- an upgrade makes the remaining bag copies stop being upgrades).
-- Assigns the forward-declared local near the top of the file.
function RefreshOpenBags()
    -- Every caller is a state change that moves verdicts globally (equip
    -- events via the debounced flush, weight/profile/filter edits,
    -- level-up) or an explicit "re-evaluate everything": invalidate the
    -- score and verdict memos so this pass — and hovers after it —
    -- recompute fresh. Bag-only changes deliberately do NOT come through
    -- here (the flush takes the cheaper targeted path): they can't move
    -- the equipped scores or other bags' verdicts.
    generation = generation + 1
    for k in pairs(verdictCache) do verdictCache[k] = nil end
    RedrawBags()
end

--------------------------------------------------------------------------
-- Quest reward markers
--------------------------------------------------------------------------

-- Green arrow on reward items that are upgrades, gold coin on the choice
-- reward worth the most vendor money. Rewards are scored through the
-- quest-item tooltip scan (see ScanItem), never the bare link, so the
-- verdict here is the same one the item gets once it reaches the bags.

local MAX_QUEST_ITEMS = MAX_NUM_ITEMS or 10

local function QuestItemIcon(button)
    local name = button:GetName()
    return (name and _G[name .. "IconTexture"]) or button
end

-- Arrow sits on the icon's top-right corner (matches the bag-slot arrow);
-- the coin marker below stays top-left, clear of it.
local function GetQuestArrow(button)
    local arrow = button.refactorQuestArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", QuestItemIcon(button), "TOPRIGHT", 2, 2)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        button.refactorQuestArrow = arrow
    end
    return arrow
end

local function GetQuestCoin(button)
    local coin = button.refactorQuestCoin
    if not coin then
        coin = button:CreateTexture(nil, "OVERLAY")
        coin:SetWidth(14)
        coin:SetHeight(14)
        coin:SetPoint("TOPLEFT", QuestItemIcon(button), "TOPLEFT", -2, 2)
        coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
        button.refactorQuestCoin = coin
    end
    return coin
end

local function HideQuestMarkers(button)
    if button.refactorQuestArrow then button.refactorQuestArrow:Hide() end
    if button.refactorQuestCoin then button.refactorQuestCoin:Hide() end
end

-- QuestInfo_Display fires on every quest-pane redraw, not just when
-- rewards actually change (accept/decline/gossip clicks re-run it too).
-- Cheaply fingerprint the shown reward/choice links first; if unchanged
-- since the last COMPLETE pass, skip the scan loop entirely. Reset to
-- force a rebuild whenever markers get hidden outright (disabled, or no
-- quest frame) so re-enabling always redraws instead of trusting a stale
-- fingerprint from before the hide.
local lastQuestSig, lastQuestComplete = "", false

local function QuestRewardSig(qlog)
    local parts = {}
    for i = 1, MAX_QUEST_ITEMS do
        local button = _G["QuestInfoItem" .. i]
        if button and button:IsShown()
            and (button.type == "choice" or button.type == "reward") then
            local idx = button:GetID()
            local link = qlog and GetQuestLogItemLink(button.type, idx)
                or GetQuestItemLink(button.type, idx)
            parts[#parts + 1] = button.type .. idx .. ":" .. tostring(link)
        end
    end
    return table.concat(parts, "|")
end

-- Recomputes every visible reward button. Returns false when some item
-- wasn't ready yet (not in the client cache / tooltip scan failed) so the
-- caller schedules a retry — reward data often trails the frame opening.
local function UpdateQuestRewardsNow()
    if not (db and db.enabled and QuestInfoFrame) then
        for i = 1, MAX_QUEST_ITEMS do
            local button = _G["QuestInfoItem" .. i]
            if button then HideQuestMarkers(button) end
        end
        lastQuestSig, lastQuestComplete = "", false
        return true
    end

    local qlog = QuestInfoFrame.questLog and true or false

    -- A retry (scan/CompareItem still pending) must always re-run even
    -- though the links themselves haven't changed, so the skip only
    -- applies once a prior pass has fully resolved.
    local sig = QuestRewardSig(qlog)
    if lastQuestComplete and sig == lastQuestSig then
        return true
    end

    local complete = true
    local choiceCount = 0
    local bestValue, bestButton = 0, nil
    local arrowFor = {}

    for i = 1, MAX_QUEST_ITEMS do
        local button = _G["QuestInfoItem" .. i]
        if button and button:IsShown()
            and (button.type == "choice" or button.type == "reward") then
            local idx = button:GetID()
            local link
            if qlog then
                link = GetQuestLogItemLink(button.type, idx)
            else
                link = GetQuestItemLink(button.type, idx)
            end
            -- One GetItemInfo call per button (this runs inside a retry
            -- loop): name gates readiness, equipLoc routes the verdict,
            -- sellPrice feeds the coin marker (nil on stock 3.3.5 — the
            -- 11th return is 4.0+, kept in case Ascension backported it).
            local name, equipLoc, sellPrice
            if link then
                local n, _, _, _, _, _, _, _, e, _, sp = GetItemInfo(link)
                name, equipLoc, sellPrice = n, e, sp
            end
            if not name then
                complete = false
            else
                if equipLoc and SLOTS_FOR_INVTYPE[equipLoc] then
                    local result = CompareItem(link, nil, nil, nil,
                        { log = qlog, type = button.type, index = idx })
                    if not result then
                        -- Gear without a verdict: usually a scan that
                        -- hasn't succeeded yet — retry. (Quality-filtered
                        -- items land here too; the retry cap keeps that
                        -- harmless.)
                        complete = false
                    elseif not result.approx
                        and (result.status == "upgrade" or result.status == "empty") then
                        arrowFor[button] = true
                    end
                end
                if button.type == "choice" then
                    choiceCount = choiceCount + 1
                    -- No sellPrice from GetItemInfo: fall back to the money
                    -- line scanned off the reward tooltip itself.
                    if not sellPrice then
                        local scan = ScanItem(link, nil, nil, nil,
                            { log = qlog, type = button.type, index = idx })
                        if not scan.failed then sellPrice = scan.sellPrice end
                    end
                    local num
                    if qlog then
                        num = select(3, GetQuestLogChoiceInfo(idx)) or 1
                    else
                        num = select(3, GetQuestItemInfo("choice", idx)) or 1
                    end
                    local value = (sellPrice or 0) * num
                    if value > bestValue then
                        bestValue, bestButton = value, button
                    end
                end
            end
        end
    end

    for i = 1, MAX_QUEST_ITEMS do
        local button = _G["QuestInfoItem" .. i]
        if button then
            if arrowFor[button] then
                GetQuestArrow(button):Show()
            elseif button.refactorQuestArrow then
                button.refactorQuestArrow:Hide()
            end
            -- Coin marks the most vendor-valuable choice, but the arrow
            -- outranks it: an upgrade beats vendor gold.
            local showCoin = button == bestButton and bestValue > 0
                and choiceCount >= 2 and not arrowFor[button]
            if showCoin then
                GetQuestCoin(button):Show()
            elseif button.refactorQuestCoin then
                button.refactorQuestCoin:Hide()
            end
        end
    end

    if db.debug then
        Print("quest rewards updated (log=" .. tostring(qlog)
            .. ", choices=" .. choiceCount
            .. ", bestValue=" .. bestValue
            .. (complete and ")" or ", retrying)"))
    end
    lastQuestSig, lastQuestComplete = sig, complete
    return complete
end

local questRetryFrame = CreateFrame("Frame")
questRetryFrame:Hide()
local questRetryElapsed, questRetriesLeft = 0, 0
questRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    questRetryElapsed = questRetryElapsed + elapsed
    if questRetryElapsed < 0.25 then return end
    questRetryElapsed = 0
    questRetriesLeft = questRetriesLeft - 1
    if UpdateQuestRewardsNow() or questRetriesLeft <= 0 then
        self:Hide()
    end
end)

-- QuestInfo_ShowRewards runs INSIDE QuestInfo_Display's element loop, and
-- the display code reparents the shared rewards frame to the calling pane
-- only AFTER the element function returns — so at hook time a check on the
-- rewards CONTAINER's IsVisible() still walks up through the PREVIOUS
-- pane's parent chain, usually a hidden one (this is why the world map's
-- reward pane never got markers: the container looked invisible from here
-- every time). UpdateQuestRewardsNow sidesteps that by never asking the
-- container anything — it reads each QuestInfoItemN button's own IsShown()
-- flag instead, which stock code sets directly (Show/Hide per button in
-- QuestInfo_ShowRewards) and which isn't affected by the pane's SetParent
-- happening later in the same call.
function UpdateQuestRewards()
    if UpdateQuestRewardsNow() then
        questRetryFrame:Hide()
    else
        questRetriesLeft = 8
        questRetryElapsed = 0
        questRetryFrame:Show()
    end
end

-- Hooking QuestInfo_ShowRewards directly doesn't work: every
-- QUEST_TEMPLATE_*.elements table stores a bare reference to that
-- function, frozen when QuestInfo.lua's templates were built (core
-- FrameXML, long before this addon loads). hooksecurefunc only rebinds
-- the global NAME to a wrapper — it can't reach into those already-built
-- tables and swap the value they hold, so QuestInfo_Display's element
-- loop keeps calling the untouched original and our hook never fires
-- (confirmed live: no debug print, no marker, on quest log/map alike).
-- QuestInfo_Display itself is safe to hook because every real call site
-- invokes it by bare global name, which Lua re-resolves through the
-- global table each time — that's what hooksecurefunc can actually
-- intercept. It runs for every quest pane (detail dialog, quest log,
-- map), reward elements or not, so re-scanning after each call is cheap
-- and always reflects the current button state.
if type(QuestInfo_Display) == "function" then
    hooksecurefunc("QuestInfo_Display", UpdateQuestRewards)
end

--------------------------------------------------------------------------
-- Loot-roll upgrade markers
--------------------------------------------------------------------------

-- Green arrow on a group-loot roll frame's item icon when the rolled item
-- is an upgrade — same promise as the bag/quest arrows, same trust rules
-- (live SetLootRollItem scan via CompareItem's roll src, never approx).
-- Roll item data trails the frame opening (and the first scans can be
-- stale-armor discards), so this retries on a timer like the quest-reward
-- markers do; roll frames stay up for the whole roll window, so the retry
-- budget is generous.

local NUM_ROLL_FRAMES = NUM_GROUP_LOOT_FRAMES or 4

local function GetRollArrow(frame)
    local arrow = frame.refactorRollArrow
    if not arrow then
        local anchor = _G[frame:GetName() .. "IconFrame"] or frame
        arrow = anchor:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 2, 2)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        frame.refactorRollArrow = arrow
    end
    return arrow
end

-- Recomputes every visible roll frame. Returns false when some roll's
-- item wasn't readable yet so the caller keeps retrying.
local function UpdateRollFramesNow()
    local complete = true
    for i = 1, NUM_ROLL_FRAMES do
        local frame = _G["GroupLootFrame" .. i]
        if frame then
            local show = false
            if frame:IsShown() and frame.rollID and db and db.enabled then
                local link = GetLootRollItemLink
                    and GetLootRollItemLink(frame.rollID)
                -- One GetItemInfo call per frame per retry tick, not two.
                local name, equipLoc
                if link then
                    local n, _, _, _, _, _, _, _, e = GetItemInfo(link)
                    name, equipLoc = n, e
                end
                if not name then
                    complete = false
                else
                    if equipLoc and SLOTS_FOR_INVTYPE[equipLoc] then
                        local result = CompareItem(link, nil, nil, nil,
                            { roll = frame.rollID })
                        if not result then
                            -- Scan pending / stale-armor discard: retry.
                            -- (Quality-filtered gear lands here too; the
                            -- retry cap keeps that harmless.)
                            complete = false
                        elseif not result.approx
                            and (result.status == "upgrade"
                                or result.status == "empty") then
                            show = true
                        end
                    end
                end
            end
            if show then
                GetRollArrow(frame):Show()
            elseif frame.refactorRollArrow then
                frame.refactorRollArrow:Hide()
            end
        end
    end
    return complete
end

local rollRetryFrame = CreateFrame("Frame")
rollRetryFrame:Hide()
local rollRetryElapsed, rollRetriesLeft = 0, 0
rollRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    rollRetryElapsed = rollRetryElapsed + elapsed
    if rollRetryElapsed < 0.25 then return end
    rollRetryElapsed = 0
    rollRetriesLeft = rollRetriesLeft - 1
    if UpdateRollFramesNow() or rollRetriesLeft <= 0 then
        self:Hide()
    end
end)

function StartRollUpdates()
    if UpdateRollFramesNow() then
        rollRetryFrame:Hide()
    else
        rollRetriesLeft = 20 -- 5s of retries; rolls stay up far longer
        rollRetryElapsed = 0
        rollRetryFrame:Show()
    end
end

--------------------------------------------------------------------------
-- Vendor/Merchant item upgrade markers
--------------------------------------------------------------------------

-- Green arrow on a vendor item button when the item is an upgrade —
-- same promise as the bag/quest/roll arrows, same trust rules
-- (live SetMerchantItem/SetBuybackItem scan via CompareItem's src, never approx).

local function GetMerchantArrow(button)
    local arrow = button.refactorMerchantArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        button.refactorMerchantArrow = arrow
    end
    return arrow
end

local function UpdateMerchantArrowsNow()
    local maxItems = MERCHANT_ITEMS_PER_PAGE or 10
    if not (db and db.enabled and db.bagIcons and MerchantFrame and MerchantFrame:IsShown()) then
        for i = 1, maxItems do
            local button = _G["MerchantItem" .. i .. "ItemButton"]
            if button and button.refactorMerchantArrow then
                button.refactorMerchantArrow:Hide()
            end
        end
        return true
    end

    local complete = true
    local isBuyback = MerchantFrame.selectedTab == 2
    local page = MerchantFrame.page or 1

    for i = 1, maxItems do
        local button = _G["MerchantItem" .. i .. "ItemButton"]
        if button then
            local show = false
            local index = ((page - 1) * maxItems) + i
            local link
            if isBuyback then
                link = GetBuybackItemLink and GetBuybackItemLink(index)
            else
                link = GetMerchantItemLink and GetMerchantItemLink(index)
            end

            if link then
                local name, equipLoc
                local n, _, _, _, _, _, _, _, e = GetItemInfo(link)
                name, equipLoc = n, e
                if not name then
                    complete = false
                elseif equipLoc and SLOTS_FOR_INVTYPE[equipLoc] then
                    local src = isBuyback and { buybackSlot = index } or { merchantSlot = index }
                    local result = CompareItem(link, nil, nil, nil, src)
                    if not result then
                        complete = false
                    elseif not result.approx
                        and (result.status == "upgrade" or result.status == "empty") then
                        show = true
                    end
                end
            end

            if show then
                GetMerchantArrow(button):Show()
            elseif button.refactorMerchantArrow then
                button.refactorMerchantArrow:Hide()
            end
        end
    end

    return complete
end

local merchantRetryFrame = CreateFrame("Frame")
merchantRetryFrame:Hide()
local merchantRetryElapsed, merchantRetriesLeft = 0, 0
merchantRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    merchantRetryElapsed = merchantRetryElapsed + elapsed
    if merchantRetryElapsed < 0.25 then return end
    merchantRetryElapsed = 0
    merchantRetriesLeft = merchantRetriesLeft - 1
    if UpdateMerchantArrowsNow() or merchantRetriesLeft <= 0 then
        self:Hide()
    end
end)

function UpdateMerchantArrows()
    if UpdateMerchantArrowsNow() then
        merchantRetryFrame:Hide()
    else
        merchantRetriesLeft = 8
        merchantRetryElapsed = 0
        merchantRetryFrame:Show()
    end
end

if type(MerchantFrame_Update) == "function" then
    hooksecurefunc("MerchantFrame_Update", UpdateMerchantArrows)
end

--------------------------------------------------------------------------
-- Loot-moment alert
--------------------------------------------------------------------------

-- Turn a format string like "You receive loot: %sx%d." into a match
-- pattern. Multi-stack formats go first so the "x3" suffix lands in the
-- %d capture instead of being swallowed by the greedy %s capture. The
-- link is re-extracted from the %s capture by item-link shape either way.
local function PatternFromFormat(fmt)
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("%%s", "(.+)")
    fmt = fmt:gsub("%%d", "(%%d+)")
    return "^" .. fmt .. "$"
end

local LOOT_SELF_PATTERNS = {
    { pattern = PatternFromFormat(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_SELF or "You receive loot: %s."), counted = false },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF or "You receive item: %s."), counted = false },
}

-- Self-loot lines are parsed exactly once for the whole addon, here, and
-- fanned out as (link, count) — RefactorToast used to run its own
-- identical CHAT_MSG_LOOT pattern pass for every loot line.
local lootListeners = {}

-- Items sometimes aren't in the client cache the instant the loot message
-- arrives; retry once shortly after.
local pendingAlerts = {} -- link -> retries left
local alertFrame = CreateFrame("Frame")
local alertElapsed = 0

-- Cheap pre-filter for the loot paths: is this link even gear we would
-- evaluate? Most loot is junk, materials and quest items — walking the
-- bags and running the compare pipeline for those was pure waste.
-- Three-state: nil = GetItemInfo has no data yet (caller should retry),
-- false = known non-gear or below the quality cutoff (skip everything),
-- true = evaluatable gear.
local function GearFilter(link)
    local name, _, quality, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if not name then return nil end
    if not equipLoc or not SLOTS_FOR_INVTYPE[equipLoc] then return false end
    if quality and quality < (db and db.minQuality or 0) then return false end
    return true
end

-- Locate a looted item in the bags so the scaled copy gets scanned; a
-- bare link would score the base item.
local function FindBagItem(link)
    -- GetItemCount answers "not in the bags at all" from C code; skip the
    -- per-slot Lua walk entirely for items we don't hold (guarded — this
    -- custom client's API surface isn't taken for granted).
    if type(GetItemCount) == "function" and GetItemCount(link) == 0 then
        return
    end
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, GetContainerNumSlots(bag) do
            if GetContainerItemLink(bag, slot) == link then
                return bag, slot
            end
        end
    end
end

-- Shared with RefactorToast.lua: the loot toast shows the same green
-- upgrade arrow the bag slots do, so it needs the same verdict. Consumers
-- must honor the trust rules — arrow only from a live instance scan
-- (result present, not approx, status upgrade/empty).
RefactorCompareShared = {
    CompareItem = CompareItem,
    FindBagItem = FindBagItem,
    -- One CHAT_MSG_LOOT parse for the whole addon: fn(link, count) fires
    -- for every self-loot line (RefactorToast subscribes here instead of
    -- re-matching every loot line itself).
    RegisterLootListener = function(fn) tinsert(lootListeners, fn) end,
    -- True while the smart-equip fix-up is mid-swap (see the guard pair
    -- with RefactorQoL.BagShuffleActive).
    SmartEquipActive = SmartEquipActive,
    -- Pre-filter (see GearFilter): lets the toast skip the bag walk and
    -- compare pipeline for loot that could never earn an arrow.
    IsGear = GearFilter,
    IsEnabled = function() return db and db.enabled or false end,
    -- Everything below exists for RefactorUI.lua (the config window),
    -- which owns all settings UI. SaveProfileAs/DeleteProfile are added
    -- further down, after they're defined.
    GetDB = function() return db end,
    STATS = STATS,
    Weights = Weights,
    ActiveProfile = ActiveProfile,
    SetActiveProfile = SetActiveProfile,
    GetClassSpecs = GetClassSpecs,
    SelectSpecProfile = SelectSpecProfile,
    ResetActiveProfileWeights = ResetActiveProfileWeights,
    RefreshOpenBags = RefreshOpenBags,
    Print = Print,
    -- Armor-type checkboxes go through this (not raw DB().armorTypes[at] =
    -- v) so a manual edit is recorded and AutoApplyClassSpec stops
    -- overwriting it. /rfc auto clears the flag again.
    SetArmorType = function(armorType, value)
        db.armorTypes[armorType] = value
        db.charManualArmor[CharKey()] = true
    end,
}

local function TryAlert(link)
    -- Junk/materials can never alert: done immediately, no bag walk, no
    -- compare. (The old code retried those for the full budget.) nil =
    -- item data not client-cached yet — that's what the retries are for.
    local gear = GearFilter(link)
    if gear == false then return true end
    if gear == nil then return false end
    local bag, slot = FindBagItem(link)
    local result = CompareItem(link, bag, slot)
    if not (bag and slot) and (result == nil or result.approx) then
        return false -- not in bags / not cached yet, worth retrying
    end
    -- Alert only from a real instance scan: a base-link estimate isn't
    -- worth telling the player to keep something.
    if result and not result.approx
        and (result.status == "upgrade" or result.status == "empty") then
        local lockNote = result.levelLocked and " (once you're high enough level)" or ""
        if result.status == "empty" then
            if result.zeroBaseline then
                Print(link .. " beats your equipped item (it scores 0 under your weights)"
                    .. lockNote .. " — worth keeping!")
            else
                Print(link .. " fills an empty slot" .. lockNote .. " — worth keeping!")
            end
        else
            Print(string.format("%s looks like a |cff00ff00+%.1f%%|r upgrade%s!",
                link, result.pct, lockNote))
        end
    end
    return true
end

alertFrame:Hide()
alertFrame:SetScript("OnUpdate", function(self, elapsed)
    alertElapsed = alertElapsed + elapsed
    if alertElapsed < 1 then return end
    alertElapsed = 0
    local remaining = 0
    for link, retries in pairs(pendingAlerts) do
        if TryAlert(link) or retries <= 1 then
            pendingAlerts[link] = nil
        else
            pendingAlerts[link] = retries - 1
            remaining = remaining + 1
        end
    end
    if remaining == 0 then self:Hide() end
end)

local function OnLootMessage(msg)
    local wantAlert = db and db.enabled and db.lootAlert
    if not wantAlert and #lootListeners == 0 then return end
    for _, p in ipairs(LOOT_SELF_PATTERNS) do
        local itemString, count = msg:match(p.pattern)
        if itemString then
            local link = itemString:match("|Hitem:.-|h%[.-%]|h")
            if link then
                if wantAlert and not TryAlert(link) then
                    pendingAlerts[link] = 3
                    alertElapsed = 0
                    alertFrame:Show()
                end
                count = p.counted and tonumber(count) or 1
                for _, fn in ipairs(lootListeners) do
                    fn(link, count)
                end
            end
            return
        end
    end
end

--------------------------------------------------------------------------
-- Config panel — the window itself lives in RefactorUI.lua
--------------------------------------------------------------------------

function RefreshConfig()
    if RefactorUI and RefactorUI.Refresh then RefactorUI.Refresh() end
end

local function SaveProfileAs(name)
    db.profiles[name] = CopyTable(ActiveProfile())
    SetActiveProfile(name)
    Print("Saved profile '" .. name .. "'.")
    RefreshConfig()
end

-- User-facing setter for the secondary (blue) verdict profile — config
-- window and /rfc secondary. nil/false turns the feature off for this
-- character. RefreshOpenBags bumps the memo generation: every cached
-- verdict's .secondary field goes stale the moment this changes.
local function SetSecondaryProfile(name)
    if name and not db.profiles[name] then
        Print("no profile named '" .. name .. "'.")
        return
    end
    db.charSecondaryProfile[CharKey()] = name or nil
    RefreshOpenBags()
    RefreshConfig()
    if name then
        Print("secondary verdict profile set to '" .. name .. "'.")
    else
        Print("secondary verdict profile off.")
    end
end

local function DeleteProfile(name)
    if name == "Default" then
        Print("Can't delete the Default profile.")
    elseif db.profiles[name] then
        db.profiles[name] = nil
        if db.activeProfile == name then SetActiveProfile("Default") end
        -- Characters showing it as their secondary verdict lose that too.
        for k, v in pairs(db.charSecondaryProfile) do
            if v == name then db.charSecondaryProfile[k] = nil end
        end
        Print("Deleted profile '" .. name .. "'.")
        RefreshOpenBags()
        RefreshConfig()
    end
end

-- Hit-cap mode setter for the config window / slash: "off" | "melee" |
-- "ranged" | "spell", stored per profile. Bumps the memo generation so
-- open tooltips and bag arrows re-score against the cap immediately.
local function SetHitCapMode(mode)
    if mode ~= "melee" and mode ~= "ranged" and mode ~= "spell" then mode = "off" end
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.mode = mode
    RefreshOpenBags()
    RefreshConfig()
    return mode
end

local function SetHitCapPvP(enabled)
    local p = ActiveProfile()
    p.hitCap = p.hitCap or {}
    p.hitCap.pvp = enabled and true or nil
    RefreshOpenBags()
    RefreshConfig()
end

RefactorCompareShared.SaveProfileAs = SaveProfileAs
RefactorCompareShared.DeleteProfile = DeleteProfile
RefactorCompareShared.SetSecondaryProfile = SetSecondaryProfile
RefactorCompareShared.SetHitCapMode = SetHitCapMode
RefactorCompareShared.GetHitCapMode = function()
    return HitCapMode(ActiveProfile())
end
RefactorCompareShared.SetHitCapPvP = SetHitCapPvP
RefactorCompareShared.GetHitCapPvP = function()
    return HitCapPvP(ActiveProfile())
end
-- Live readout for the config window: current hit rating, the cap rating, and
-- the target %. cap is nil when the rating→% ratio isn't derivable yet (no hit
-- worn and none cached) — the UI shows "—" then.
RefactorCompareShared.HitCapInfo = function()
    local p = ActiveProfile()
    local mode = HitCapMode(p)
    if mode == "off" then return { mode = "off" } end
    local pvp = HitCapPvP(p)
    local cap = HitCapRating(p)
    local ratio = HitRatingPerPct(mode)
    local activePct = pvp and HITCAP_PCT_PVP[mode] or HITCAP_PCT[mode]
    local refPct = pvp and HITCAP_PCT[mode] or HITCAP_PCT_PVP[mode]
    local refCap = ratio and (refPct * ratio) or nil
    return { mode = mode, pvp = pvp, current = CurrentHitRating(mode),
        cap = cap, pct = activePct,
        refCap = refCap, refPct = refPct }
end
-- Raw saved pick (name or nil) for the config window's dropdown display;
-- unlike SecondaryProfile() this reports the setting even while it names
-- the active profile or a deleted one.
RefactorCompareShared.SecondaryProfileName = function()
    return db.charSecondaryProfile[CharKey()]
end

-- Renames a hand-made profile in place and points every character's
-- remembered pick (last-active, auto-applied, deliberate choice) at the
-- new name, so alts don't lose it. Two names refuse: Default anchors the
-- fallback path, and class-spec profiles are found BY NAME by
-- auto-selection and the spec picker — renaming one would only make it
-- regenerate from defaults under the old name.
RefactorCompareShared.RenameProfile = function(old, new)
    new = new and new:match("^%s*(.-)%s*$") or ""
    if new == "" or new == old or not db.profiles[old] then return end
    if old == "Default" then
        Print("Can't rename the Default profile.")
        return
    end
    local classPart, specPart = old:match("^(.-) %- (.+)$")
    local specList = classPart and CLASS_SPEC_WEIGHTS[NormalizeClassKey(classPart)]
    if specList then
        local wanted = specPart:lower():gsub(" ", "_")
        for _, specEntry in ipairs(specList) do
            if specEntry.name:lower() == wanted then
                Print("'" .. old .. "' is a class-spec profile — auto-selection finds "
                    .. "it by this exact name. Use 'Save as' to make a copy you can "
                    .. "name freely.")
                return
            end
        end
    end
    if db.profiles[new] then
        Print("A profile named '" .. new .. "' already exists.")
        return
    end
    db.profiles[new] = db.profiles[old]
    db.profiles[old] = nil
    if db.activeProfile == old then db.activeProfile = new end
    for _, map in ipairs({ db.charProfiles, db.charAutoProfile, db.charManualProfile,
        db.charSecondaryProfile }) do
        for k, v in pairs(map) do
            if v == old then map[k] = new end
        end
    end
    Print("Renamed profile '" .. old .. "' to '" .. new .. "'.")
    RefreshConfig()
end

-- Opens/closes the RefactorUI window (RefactorUI.lua, loaded after this
-- file). The guard only matters if that file failed to load.
local function ToggleConfig()
    if RefactorUI and RefactorUI.Toggle then
        RefactorUI.Toggle()
    else
        Print("config window failed to load — check RefactorUI.lua.")
    end
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_REFACTORCOMPARE1 = "/rfc"
SLASH_REFACTORCOMPARE2 = "/refactorcompare"
SLASH_REFACTORCOMPARE3 = "/refactor"
SlashCmdList.REFACTORCOMPARE = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" then
        ToggleConfig()
    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        RefreshOpenBags()
        Print("gear compare " .. (db.enabled and "|cff00ff00enabled|r" or "|cffff4040disabled|r") .. ".")
    elseif cmd == "alert" then
        db.lootAlert = not db.lootAlert
        Print("loot alerts " .. (db.lootAlert and "on" or "off") .. ".")
    elseif cmd == "bagicons" then
        db.bagIcons = not db.bagIcons
        RefreshOpenBags()
        Print("bag upgrade icons " .. (db.bagIcons and "on" or "off") .. ".")
    elseif cmd == "auto" then
        -- Forget this character's manual profile/armor choices and hand
        -- control back to class/spec auto-selection.
        db.charManualProfile[CharKey()] = nil
        db.charManualArmor[CharKey()] = nil
        AutoApplyClassSpec()
        RefreshOpenBags()
        RefreshConfig()
        Print("profile auto-selection re-enabled (now: '" .. db.activeProfile .. "').")
    elseif cmd == "debug" then
        db.debug = not db.debug
        Print("debug " .. (db.debug and "on — hover an item to see red-line detection" or "off") .. ".")
    elseif cmd == "quality" then
        local q = tonumber(rest)
        if q then
            db.minQuality = math.max(0, math.min(5, math.floor(q)))
            RefreshOpenBags()
            RefreshConfig()
            Print("minimum quality set to " .. db.minQuality .. ".")
        else
            Print("usage: /rfc quality <0-5>")
        end
    elseif cmd == "weight" then
        -- Last token is the value, everything before it is the stat name
        -- (custom stat names can contain spaces).
        local name, value = rest:match("^(.-)%s+([%d%.%-]+)$")
        value = tonumber(value)
        if not name or name == "" or not value then
            Print("usage: /rfc weight <stat> <value>")
            return
        end
        local lname = name:lower()
        for _, s in ipairs(STATS) do
            if s.key:lower() == lname or s.label:lower() == lname then
                Weights()[s.key] = value
                RefreshOpenBags()
                RefreshConfig()
                Print(s.label .. " weight set to " .. value .. ".")
                return
            end
        end
        ActiveProfile().customWeights[lname] = value
        -- Verdicts move with the weight: refresh (and bump the memo
        -- generation) like the standard-stat branch above does — without
        -- this the verdict/equipped memos keep serving old-weight scores.
        RefreshOpenBags()
        RefreshConfig()
        Print("custom stat '" .. lname .. "' weight set to " .. value .. ".")
    elseif cmd == "secondary" then
        local name = rest:match("^%s*(.-)%s*$")
        if name == "" then
            local cur = db.charSecondaryProfile[CharKey()]
            Print(cur and ("secondary verdict profile: '" .. cur .. "'.")
                or "no secondary verdict profile set. /rfc secondary <name> to set one.")
        elseif name:lower() == "off" or name:lower() == "none" then
            SetSecondaryProfile(nil)
        else
            SetSecondaryProfile(name)
        end
    elseif cmd == "hitcap" then
        local mode = rest:match("^%s*(%S*)"):lower()
        if mode == "pvp" then
            local p = ActiveProfile()
            SetHitCapPvP(not HitCapPvP(p))
            local pvp = HitCapPvP(ActiveProfile())
            Print("hit cap target: " .. (pvp and "PvP (never miss a player)"
                or "PvE (never miss a raid boss)") .. ".")
        elseif mode == "off" or mode == "melee" or mode == "ranged" or mode == "spell" then
            SetHitCapMode(mode)
            if mode == "off" then
                Print("hit cap off for profile '" .. db.activeProfile .. "'.")
            else
                local info = RefactorCompareShared.HitCapInfo()
                local target = info.pvp and "PvP" or "PvE"
                Print("hit cap set to " .. mode .. " " .. target .. " (" .. (info.pct or "?") .. "%) for profile '"
                    .. db.activeProfile .. "'"
                    .. (info.cap and (": " .. info.current .. "/" .. math.floor(info.cap + 0.5) .. " rating")
                        or " (cap unknown until you have some hit)") .. ".")
            end
        else
            Print("usage: /rfc hitcap <off|melee|ranged|spell|pvp>")
        end
    elseif cmd == "profile" then
        local sub, name = rest:match("^(%S*)%s*(.-)$")
        local subl = sub:lower()
        if subl == "list" then
            local names = {}
            for n in pairs(db.profiles) do tinsert(names, n) end
            table.sort(names)
            Print("profiles: " .. table.concat(names, ", ")
                .. " (active: " .. db.activeProfile .. ")")
        elseif subl == "save" and name ~= "" then
            SaveProfileAs(name)
        elseif subl == "delete" and name ~= "" then
            if db.profiles[name] then
                DeleteProfile(name)
            else
                Print("no profile named '" .. name .. "'.")
            end
        elseif sub ~= "" and name == "" then
            if db.profiles[sub] then
                SetActiveProfile(sub)
                RefreshOpenBags()
                RefreshConfig()
                Print("switched to profile '" .. sub .. "'.")
            else
                Print("no profile named '" .. sub .. "'. /rfc profile save " .. sub .. " to create it.")
            end
        else
            Print("usage: /rfc profile <name> | save <name> | delete <name> | list")
        end
    else
        Print("commands: /rfc (config), toggle, alert, bagicons, auto, debug, quality <n>, weight <stat> <n>, hitcap <off|melee|ranged|spell|pvp>, profile ..., secondary <name|off>")
    end
end

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

-- UNIT_INVENTORY_CHANGED and BAG_UPDATE fire in bursts (one equip raises
-- several of each). Wiping the scan cache and re-evaluating every open
-- bag once PER EVENT was the addon's biggest frame-time spike — with a
-- Bagnon wall of 100+ slots, each event cost 100+ hidden-tooltip renders.
-- Instead: mark what went stale, flush once shortly after the burst ends.
-- (Smart equip keeps its own immediate event frame — it must react the
-- moment the engine's swap settles, and it does no scanning of its own.)
local refreshFrame = CreateFrame("Frame")
refreshFrame:Hide()
local refreshElapsed = 0
local invDirty = false -- equipped gear changed: every instance scan is suspect
local dirtyBags = {}   -- [bagID] = true: that bag's instance scans are stale
local REFRESH_DEBOUNCE = 0.15

refreshFrame:SetScript("OnUpdate", function(self, elapsed)
    refreshElapsed = refreshElapsed + elapsed
    if refreshElapsed < REFRESH_DEBOUNCE then return end
    self:Hide()
    if invDirty then
        -- Equipping can rescale items; drop all live scans so the refresh
        -- compares against what's actually worn now.
        WipeInstanceScans()
    else
        -- Bag-only change: a same-link different-instance copy can land in
        -- a slot whose scan is still cached, so drop just those bags' scans.
        for bagID in pairs(dirtyBags) do
            local prefix = "b:" .. bagID .. ":"
            for k in pairs(scanCache) do
                if k:sub(1, #prefix) == prefix then scanCache[k] = nil end
            end
        end
    end
    -- Expired instance scans (quest-reward "q:" and loot-window "ls:" keys
    -- especially) have no event that deletes them — without this sweep
    -- they'd sit as dead weight until the next equip or level-up wiped
    -- everything. Piggybacks on the iteration this flush already does.
    local now = GetTime()
    for k, v in pairs(scanCache) do
        if v.expires and v.expires < now then scanCache[k] = nil end
    end
    if invDirty then
        invDirty = false
        for k in pairs(dirtyBags) do dirtyBags[k] = nil end
        RefreshOpenBags()
    else
        -- Bag-only: equipped gear and weights are unchanged, so the
        -- equipped-score memos and every untouched bag's verdicts are
        -- still exact. Drop only the dirty bags' verdict entries and
        -- redraw — clean slots answer from the warm memos instead of
        -- re-running the whole scan pipeline (a one-slot loot into a
        -- 100-slot bag wall used to recompute all 100).
        for bagID in pairs(dirtyBags) do
            local prefix = bagID .. ":"
            for k in pairs(verdictCache) do
                if k:sub(1, #prefix) == prefix then verdictCache[k] = nil end
            end
            dirtyBags[bagID] = nil
        end
        RedrawBags()
    end
end)

local function QueueRefresh()
    refreshElapsed = 0 -- true debounce: the burst's last event restarts the clock
    refreshFrame:Show()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_UPDATE")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        -- Bagnon/DragonUI/AdiBags/ElvUI can load before or after this
        -- addon; try the hooks on every load until they stick (no-op once
        -- hooked or if absent).
        TryHookBagnon()
        TryHookDragonUI()
        TryHookAdiBags()
        TryHookElvUI()
        if arg1 ~= "Refactor" then return end
        local firstRun = type(RefactorCompareDB) ~= "table"
        if firstRun then RefactorCompareDB = {} end
        db = RefactorCompareDB
        if firstRun then
            Print("gear compare loaded — weights are auto-picked from your class and spec, type |cffffff00/rfc|r to fine-tune.")
        end
        MergeDefaults(db, DEFAULTS)
        for _, profile in pairs(db.profiles) do
            if type(profile.weights) ~= "table" then profile.weights = {} end
            if type(profile.customWeights) ~= "table" then profile.customWeights = {} end
            MergeDefaults(profile.weights, DEFAULT_WEIGHTS)
        end
        -- Recall this character's own last profile choice rather than
        -- inheriting whatever the last-played alt left active. Falls
        -- through to whatever's already active (or Default) the first
        -- time a character is seen, and records it so it sticks from
        -- here on.
        local remembered = db.charProfiles[CharKey()]
        if remembered and db.profiles[remembered] then
            db.activeProfile = remembered
        end
    elseif event == "CHAT_MSG_LOOT" then
        OnLootMessage(arg1)
    elseif event == "START_LOOT_ROLL" then
        -- FrameXML's own handler opened the roll frame before this one
        -- runs (it registered first); mark the icon if it's an upgrade.
        StartRollUpdates()
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        UpdateMerchantArrows()
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            invDirty = true
            QueueRefresh()
        end
    elseif event == "BAG_UPDATE" then
        -- Player bags only; bank (-1, 5+) has no arrows or live scans.
        if type(arg1) == "number" and arg1 >= 0 and arg1 <= NUM_BAG_SLOTS then
            dirtyBags[arg1] = true
            QueueRefresh()
        end
    elseif event == "PLAYER_LEVEL_UP" then
        -- Scaled item stats change with level; cached scans are stale.
        WipeScanCache()
        RefreshOpenBags()
        -- Spec unlocks at level 10 — re-detect in case the placeholder
        -- default (the class's first spec) needs correcting now.
        AutoApplyClassSpec()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_TALENT_UPDATE"
        or event == "ASCENSION_KNOWN_ENTRIES_UPDATED"
        or event == "ASCENSION_KNOWN_ENTRIES_CHANGED" then
        local before = db and db.activeProfile
        AutoApplyClassSpec()
        if db and db.activeProfile ~= before then RefreshOpenBags() end
    end
end)
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
-- Ascension custom events: fire when Character Advancement entries
-- (CoA talents/abilities) change — the CA system doesn't reliably raise
-- PLAYER_TALENT_UPDATE. Unknown event names are a harmless no-op on
-- clients that lack them.
pcall(eventFrame.RegisterEvent, eventFrame, "ASCENSION_KNOWN_ENTRIES_UPDATED")
pcall(eventFrame.RegisterEvent, eventFrame, "ASCENSION_KNOWN_ENTRIES_CHANGED")
