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
-- exactly what Ascension scaling breaks.
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
local RefreshConfig

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
        { name = "Headhunting", weights = { AGI = 1.473, CRIT = 0.65, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brutality",   weights = { STR = 2.188, AGI = 1.537, CRIT = 0.761, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Ancestry",    weights = { STR = 1, AGI = 1.387, CRIT = 0.5, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.25, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    BLOODMAGE = {
        { name = "Fleshweaver", weights = { INT = 1, SPI = 0.621, CRIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Sanguine",    weights = { STA = 0.27, INT = 1, SPI = 0.27, CRIT = 0.9, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Accursed",    weights = { STR = 1.323, AGI = 1.866, INT = 0.119, CRIT = 0.653, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Eternal",     weights = { STR = 1.177, AGI = 2.967, STA = 1.08, INT = 0.067, CRIT = 0.364, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.25, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    CHRONOMANCER = {
        { name = "Time",      weights = { INT = 1, SPI = 0.575, CRIT = 0.5, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Infinite",  weights = { INT = 1, SPI = 0.46, CRIT = 0.75, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Artificer", weights = { AGI = 1.2, SPI = 1.6, CRIT = 0.828, HIT = 0.5, HASTE = 0.6, DPS = 7, AP = 0.5, SP = 0.25, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Duality",   weights = { SP = 1, INT = 0.8, HIT = 0.9, CRIT = 0.7, HASTE = 0.6, STA = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    CULTIST = {
        { name = "Godblade",    weights = { STR = 2.268, INT = 1.271, CRIT = 0.797, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Corruption",  weights = { INT = 1, CRIT = 0.9, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Heretic",     weights = { STR = 1, INT = 0.104, CRIT = 3, HASTE = 0.4, DPS = 14, AP = 1, SP = 0.4, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Dreadnought", weights = { STR = 2.531, STA = 1.12, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.5, ARP = 0.15, EXP = 0.5, ARMOR = 0.255, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 1.8, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    FELSWORN = {
        { name = "Infernal", weights = { INT = 1, SPI = 0.398, CRIT = 1.242, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Slayer",   weights = { STR = 1, AGI = 2.5, CRIT = 0.734, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Tyrant",   weights = { STR = 1.135, AGI = 2.817, STA = 2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.5, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    GUARDIAN = {
        { name = "Gladiator",   weights = { STR = 2.464, AGI = 0.592, CRIT = 0.764, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Vanguard",    weights = { STR = 2.354, AGI = 1.308, STA = 1.365, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.3, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Inspiration", weights = { STR = 2.16, AGI = 0.444, CRIT = 0.6, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.25, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    KNIGHT_OF_XOROTH = {
        { name = "Hellfire", weights = { STR = 2.2, INT = 1.163, CRIT = 0.831, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 0.75, SP = 1, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Defiance", weights = { STR = 2.549, AGI = 1.127, STA = 1.06, INT = 0, CRIT = 0.376, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 0.75, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "War",      weights = { STR = 2.398, AGI = 0.721, CRIT = 1.024, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    NECROMANCER = {
        { name = "Death",     weights = { INT = 1, CRIT = 0.63, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Animation", weights = { INT = 1, CRIT = 0.6, HIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Rime",      weights = { INT = 1, CRIT = 0.93, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    PRIMALIST = {
        { name = "Grovekeeper",   weights = { STR = 2.2, AGI = 0.374, CRIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.2, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Wildwalker",    weights = { STR = 2.2, AGI = 0.486, CRIT = 0.65, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Mountain_King", weights = { STR = 2.548, AGI = 1.503, STA = 1.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, SP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.3, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Geomancy",      weights = { INT = 1, CRIT = 0.654, HIT = 0.5, HASTE = 0.6, SP = 1, ARP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    PYROMANCER = {
        { name = "Incineration", weights = { INT = 1, CRIT = 1.242, HIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Draconic",     weights = { INT = 1, CRIT = 1.614, HIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Flameweaving", weights = { INT = 1, SPI = 2.182, CRIT = 0.9, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    RANGER = {
        { name = "Archery",    weights = { AGI = 1.445, INT = 0.054, CRIT = 0.631, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.15, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brigand",    weights = { STR = 1, AGI = 1.567, CRIT = 0.705, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Farstrider", weights = { AGI = 1.39, CRIT = 0.53, HIT = 0.5, HASTE = 0.55, DPS = 14, AP = 1, ARP = 0.2, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    REAPER = {
        { name = "Harvest",    weights = { STR = 2.347, AGI = 0.471, CRIT = 0.67, HIT = 0.5, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Soul",       weights = { STR = 2.2, AGI = 0.485, CRIT = 0.689, HASTE = 0.6, DPS = 14, AP = 1, ARP = 0.45, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Domination", weights = { STR = 2.596, AGI = 1.53, STA = 1.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 1.35, EXP = 0.5, ARMOR = 0.37, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    RUNEMASTER = {
        { name = "Glyphic",      weights = { INT = 1, SPI = 0.33, CRIT = 0.69, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Riftblade",    weights = { STR = 1, AGI = 1.643, INT = 0.144, CRIT = 0.772, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Engravement",  weights = { STR = 1.125, AGI = 1.429, INT = 0.109, CRIT = 0.641, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    STARCALLER = {
        { name = "Moon_Priest", weights = { INT = 1, SPI = 0.5, CRIT = 0.505, HASTE = 0.65, MP5 = 0.3, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Sentinel",    weights = { AGI = 1.366, INT = 2.1, CRIT = 0.778, HASTE = 0.1, SP = 0.25, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Warden",      weights = { STR = 0.55, AGI = 0.829, INT = 2, CRIT = 0.7, HASTE = 0.6, DPS = 14, AP = 0.5, SP = 1, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Moonguard",   weights = { STR = 2.041, AGI = 2.147, STA = 1.1, INT = 0.721, CRIT = 0.354, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 0.75, SP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.2, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    STORMBRINGER = {
        { name = "Lightning", weights = { INT = 1, CRIT = 1.563, HIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Wind",      weights = { INT = 1, CRIT = 0.5, HIT = 0.5, HASTE = 0.55, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Maelstrom", weights = { INT = 1, CRIT = 0.882, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    SUN_CLERIC = {
        { name = "Blessings", weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Seraphim", weights = { STR = 2.771, AGI = 1.32, STA = 1.15, CRIT = 0.363, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 0.5, SP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.256, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, BLOCK = 0.75, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Valkyrie", weights = { STR = 2.4, AGI = 0.445, CRIT = 0.625, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.25, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Piety",    weights = { INT = 1, CRIT = 1.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    TEMPLAR = {
        { name = "Oathkeeper", weights = { STR = 1.333, AGI = 2.872, STA = 1.05, INT = 0.2, CRIT = 0.35, HIT = 0.5, HASTE = 0.35, DPS = 14, AP = 1, ARP = 0.15, EXP = 0.5, ARMOR = 0.4, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Zealot",     weights = { STR = 1.365, AGI = 1.844, INT = 0.091, CRIT = 0.678, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Crusader",   weights = { STR = 1.05, AGI = 1.713, INT = 0.215, CRIT = 0.739, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    TINKER = {
        { name = "Demolition", weights = { AGI = 1.878, INT = 1.205, CRIT = 0.644, HASTE = 0.6, DPS = 14, AP = 1, SP = 1, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Invention",  weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Mechanics",  weights = { AGI = 1.375, INT = 1.219, CRIT = 0.705, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.15, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    VENOMANCER = {
        { name = "Fortitude", weights = { STR = 0.8, AGI = 2.529, STA = 1, CRIT = 0.357, HASTE = 0.35, DPS = 14, AP = 0.5, SP = 1, ARP = 0.15, ARMOR = 0.34, DEF = 1.05, DODGE = 0.9, PARRY = 0.9, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Stalking",  weights = { STR = 0.5, AGI = 0.935, INT = 0.389, CRIT = 0.813, HASTE = 0.6, DPS = 14, AP = 0.5, SP = 1, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Rotweaver", weights = { INT = 1, CRIT = 1.2, HIT = 0.5, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Vizier",    weights = { INT = 1, CRIT = 0.5, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    WITCH_DOCTOR = {
        { name = "Shadowhunting", weights = { AGI = 2.037, INT = 1.194, CRIT = 0.672, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Voodoo",        weights = { INT = 1, SPI = 0.625, CRIT = 1.238, HASTE = 0.6, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Brewing",       weights = { INT = 1, SPI = 0.3, CRIT = 0.5, HASTE = 0.65, SP = 1, SOCKET = 20, UNKNOWN = 0.1 } },
    },
    WITCH_HUNTER = {
        { name = "Boltslinger",  weights = { AGI = 1.342, INT = 1.104, CRIT = 0.813, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Houndmaster",  weights = { AGI = 1.375, INT = 0.336, CRIT = 0.891, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.5, ARP = 0.3, SOCKET = 20, UNKNOWN = 0.1 } },
        { name = "Inquisition",  weights = { STR = 1, AGI = 1.745, INT = 1.082, CRIT = 0.644, HASTE = 0.6, DPS = 14, AP = 1, SP = 0.75, ARP = 0.3, EXP = 0.5, SOCKET = 20, UNKNOWN = 0.1 } },
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

local function GetClassSpecList()
    local className, classToken = UnitClass("player")
    local list = classToken and CLASS_SPEC_WEIGHTS[classToken]
    if not list then list = CLASS_SPEC_WEIGHTS[NormalizeClassKey(className)] end
    return list, className
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
    local specList, className = GetClassSpecList()
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
    local armorList = ARMOR_TYPES_BY_CLASS[className]
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
-- also expire after half a second: scaled stats can change outside
-- level-ups (rescale on equip etc.), so a scan is only trusted long
-- enough to dedupe one bag-redraw burst. "h:"..link base-item scans are
-- static, so they live until level-up.
local scanCache = {}
local INSTANCE_SCAN_TTL = 0.5

local function WipeScanCache()
    for k in pairs(scanCache) do scanCache[k] = nil end
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

    local function AddStat(name, amount, sign)
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
    local function ParseStatLine(line)
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
        -- another signed number ("+10 Agility and +15 Stamina") — or the
        -- greedy name capture would swallow the whole tail as one bogus
        -- custom stat; the caller's splitter handles those instead.
        local compound = false
        for _, sep in ipairs(STAT_SEPARATORS) do
            if line:find(sep .. "+", 1, true)
                or line:find(sep .. "-", 1, true) then
                compound = true
                break
            end
        end
        if not compound then
            local sign, amount, statName =
                line:match("^([%+%-])([%d,]+)%s+(.+)$")
            if amount then
                AddStat(statName, amount, sign == "-" and -1 or 1)
                return true
            end
        end

        local armor = line:match("^([%d,]+) Armor$")
        if armor then
            AddStat("armor", armor)
            return true
        end

        -- Specific "Equip:" shapes the generic patterns can't capture
        -- cleanly, checked first so they don't land as ugly custom names.
        local amt = line:match("^Equip: %+([%d,]+) Armor%.?$")
        if amt then
            AddStat("armor", amt)
            return true
        end
        amt = line:match("^Equip: Increases damage and healing done by magical spells and effects by up to ([%d,]+)%.?$")
        if amt then
            AddStat("spell power", amt)
            return true
        end
        local school
        school, amt = line:match("^Equip: Increases damage done by (.-) spells and effects by up to ([%d,]+)%.?$")
        if school then
            AddStat(school .. " spell damage", amt)
            return true
        end
        amt = line:match("^Equip: Increases the block value of your shield by ([%d,]+)%.?$")
        if amt then
            AddStat("block value", amt)
            return true
        end
        -- "Equip: Restores N mana/health per (or every) 5 sec."
        local res
        amt, res = line:match("^Equip: Restores ([%d,]+) (%a+) per 5 sec")
        if not amt then
            amt, res = line:match("^Equip: Restores ([%d,]+) (%a+) every 5 sec")
        end
        if amt then
            AddStat(res .. " per 5 sec", amt)
            return true
        end

        -- Generic "Equip: Increases/Improves <stat> by N." rating lines.
        for _, pattern in ipairs(EQUIP_PATTERNS) do
            local name, a = line:match(pattern)
            if name then
                AddStat(name, a)
                return true
            end
        end
        return false
    end

    -- Splits a compound line ("+10 Agility and +15 Stamina") on the
    -- highest-priority separator present and parses each piece; pieces
    -- may recursively split on lower-priority separators. (Pawn's
    -- PawnSeparators pass.)
    local function SplitAndParse(text2, sepIndex)
        for si = sepIndex, #STAT_SEPARATORS do
            local sep = STAT_SEPARATORS[si]
            if text2:find(sep, 1, true) then
                local pos = 1
                while pos do
                    local s, e = text2:find(sep, pos, true)
                    local chunk = s and text2:sub(pos, s - 1) or text2:sub(pos)
                    if not ParseStatLine(chunk) then
                        SplitAndParse(chunk, si + 1)
                    end
                    pos = e and (e + 1) or nil
                end
                return true
            end
        end
        return false
    end

    local stopParsing = false
    for i = 2, scanTip:NumLines() do
        local left = _G["RefactorCompareScanTipTextLeft" .. i]
        local right = _G["RefactorCompareScanTipTextRight" .. i]
        local text = left and left:GetText()
        local rightText = right and right:IsShown() and right:GetText()
        if text then
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
                        if not ParseStatLine(bonus) then
                            SplitAndParse(bonus, 1)
                        end
                    end
                elseif not ParseStatLine(line) then
                    -- Whole line not understood: try splitting compound
                    -- gem/enchant lines — but never prose sentences.
                    local noSplit = false
                    for _, p in ipairs(NO_SPLIT_PREFIXES) do
                        if line:sub(1, #p) == p then
                            noSplit = true
                            break
                        end
                    end
                    if not noSplit then SplitAndParse(line, 1) end
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
    result.failed = scanTip:NumLines() < 2
    -- Roll scans are never cached: while the roll's item data is still
    -- arriving the client can render a partial tooltip that passes the
    -- NumLines check, and a cached partial would pin a wrong % for the
    -- whole TTL. Hovers are rare enough that rescanning is free.
    if not result.failed and not (src and src.roll) then
        if instance then result.expires = GetTime() + INSTANCE_SCAN_TTL end
        scanCache[cacheKey] = result
    end
    if db and db.debug then
        local parts = {}
        for statName, amt in pairs(result.stats) do
            tinsert(parts, statName .. "=" .. amt)
        end
        Print("scan [" .. cacheKey .. "] lines=" .. scanTip:NumLines()
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
local function ScoreItem(link, bag, slot, invSlot, src)
    local name, _, quality, _, reqLevel, itemType, itemSubType, _, equipLoc =
        GetItemInfo(link)
    if not name or not equipLoc or not SLOTS_FOR_INVTYPE[equipLoc] then
        return nil
    end

    local weights = Weights()
    local customWeights = ActiveProfile().customWeights
    local score = 0

    local scan = ScanItem(link, bag, slot, invSlot, src)
    if scan.failed then return nil end -- no data: no verdict, never a guess
    for statName, amount in pairs(scan.stats) do
        local key = STAT_NAME_KEYS[statName]
        local w
        if key then
            w = weights[key] or 0
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
    if WEAPON_INVTYPES[equipLoc] and scan.dps then
        score = score + scan.dps * (weights.DPS or 0)
    end

    if db and db.debug then
        Print("score [" .. (name or link) .. "] = " .. string.format("%.2f", score))
    end

    return {
        score = score,
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
-- silent — never as an empty slot begging to be filled.
local function ScoreEquipped(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local info = ScoreItem(link, nil, nil, slot)
    if not info then return false end
    return info.score
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

-- Core comparison. Returns nil (nothing to show — including any side we
-- couldn't actually read) or a result table:
--   status  = "upgrade" | "downgrade" | "even" | "empty" | "unusable" | "wrongarmor"
--   pct     = signed % difference (for upgrade/downgrade/even)
--   context = optional extra text, e.g. "vs main + off hand"
--   approx  = true when scored from a bare link (base item, not the
--             scaled instance): display as estimate, never as bag arrow
local function CompareItem(link, bag, slot, invSlot, src)
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

    local equippedScore, context

    if info.equipLoc == "INVTYPE_2HWEAPON" then
        -- A two-hander replaces everything you're holding: compare against
        -- main hand + off hand combined.
        local mh = ScoreEquipped(16)
        local oh = ScoreEquipped(17)
        if mh == false or oh == false then return nil end
        if not mh and not oh then
            return { status = "empty", levelLocked = info.levelLocked, approx = info.approx }
        end
        equippedScore = (mh or 0) + (oh or 0)
        if oh then context = "vs main + off hand" end
    elseif MainHandIs2H()
        and (info.equipLoc == "INVTYPE_WEAPON"
            or info.equipLoc == "INVTYPE_WEAPONMAINHAND"
            or info.equipLoc == "INVTYPE_WEAPONOFFHAND"
            or info.equipLoc == "INVTYPE_HOLDABLE"
            or info.equipLoc == "INVTYPE_SHIELD") then
        -- Anything held while a 2H is equipped means giving up the 2H, so
        -- that's what it has to beat.
        equippedScore = ScoreEquipped(16)
        if equippedScore == false then return nil end
        context = "vs equipped 2H"
    else
        local slots = SLOTS_FOR_INVTYPE[info.equipLoc]
        if info.equipLoc == "INVTYPE_WEAPON" and not CanDualWield() then
            slots = { 16 }
        end
        -- Multi-slot gear (rings, trinkets, 1H weapons): compare against
        -- the weaker of the equipped items, since that's what you'd replace.
        for _, slot in ipairs(slots) do
            local s = ScoreEquipped(slot)
            if s == false then return nil end
            if not s then
                return { status = "empty", levelLocked = info.levelLocked, approx = info.approx }
            end
            if not equippedScore or s < equippedScore then
                equippedScore = s
            end
        end
    end

    if not equippedScore then
        return { status = "empty", levelLocked = info.levelLocked, approx = info.approx }
    end
    if equippedScore <= 0 then
        -- Equipped item scores zero or negative under these weights; a
        -- percentage against that is meaningless, treat as free upgrade
        -- if the new item scores anything at all.
        if info.score > 0 then
            return { status = "empty", context = context, levelLocked = info.levelLocked, approx = info.approx }
        end
        return { status = "even", pct = 0, context = context, levelLocked = info.levelLocked, approx = info.approx }
    end

    local pct = (info.score - equippedScore) / equippedScore * 100
    -- Clamp absurd percentages (tiny denominators) so the display stays sane.
    if pct > 999 then pct = 999 elseif pct < -999 then pct = -999 end

    local status
    if pct > 0.5 then status = "upgrade"
    elseif pct < -0.5 then status = "downgrade"
    else status = "even" end

    return { status = status, pct = pct, context = context,
        levelLocked = info.levelLocked, approx = info.approx }
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
local ARROW_TEXTURE = "Interface\\AddOns\\Refactor\\arrow" -- still used by bag-slot arrows below

-- Anchors a tinted arrow texture just left of the given fontstring. Anchored
-- to that specific text (not the tooltip frame corner, as the old overlay
-- was) so it can never collide with a long item title above it. `down`
-- flips the (up-pointing) source art vertically for the downgrade case —
-- there's only the one arrow.tga asset, no separate down/red variant.
local function ShowLineArrow(tooltip, fontString, r, g, b, down)
    if not fontString then return end
    local arrow = tooltip.refactorLineArrow
    if not arrow then
        arrow = tooltip:CreateTexture(nil, "OVERLAY")
        tooltip.refactorLineArrow = arrow
    end
    arrow:ClearAllPoints()
    if arrow:SetTexture(ARROW_TEXTURE) then
        arrow:SetVertexColor(r, g, b)
    else
        arrow:SetTexture(r, g, b, 0.9)
    end
    if down then
        arrow:SetTexCoord(0, 1, 1, 0)
    else
        arrow:SetTexCoord(0, 1, 0, 1)
    end
    arrow:SetWidth(12)
    arrow:SetHeight(12)
    arrow:SetPoint("RIGHT", fontString, "LEFT", -2, 0)
    arrow:Show()
end

local function HideLineArrow(tooltip)
    if tooltip.refactorLineArrow then tooltip.refactorLineArrow:Hide() end
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
                return right
            end
        end
    end
    return nil
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
        text, r, g, b, arrowDir = "Fills empty slot", 0, 1, 0, "up"
    elseif result.status == "even" then
        text, r, g, b = "0%", 1, 0.82, 0
    elseif result.status == "upgrade" then
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 0, 1, 0, "up"
    else
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 1, 0.25, 0.25, "down"
    end

    local fontString = SetCompareRowText(tooltip, text, r, g, b)
    if not fontString then
        tooltip:AddLine(text, r, g, b)
        fontString = _G[tooltip:GetName() .. "TextLeft" .. tooltip:NumLines()]
    end
    if arrowDir then
        ShowLineArrow(tooltip, fontString, r, g, b, arrowDir == "down")
    end
    tooltip:Show()
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
        if src == false then return end -- live source pending: no guessing
        if not (bag or slot or invSlot or src) and LinkIsEquipped(link) then
            return
        end
        AddCompareLine(self, link, bag, slot, invSlot, src)
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
        arrow:SetHeight(14)
        arrow:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
        if arrow:SetTexture(ARROW_TEXTURE) then
            arrow:SetVertexColor(0, 1, 0)
        else
            arrow:SetTexture(0, 1, 0, 0.9)
            arrow:SetWidth(10)
            arrow:SetHeight(10)
        end
        button.refactorArrow = arrow
    end
    return arrow
end

local function UpdateArrowForLink(button, link, bag, slot)
    local show = false
    if link and db and db.enabled and db.bagIcons then
        local result = CompareItem(link, bag, slot)
        -- The arrow is a promise, not a hint: estimates (base-item link
        -- scans, cached other-character slots) never earn it.
        show = result ~= nil
            and not result.approx
            and (result.status == "upgrade" or result.status == "empty")
    end
    if show then
        GetBagArrow(button):Show()
    elseif button.refactorArrow then
        button.refactorArrow:Hide()
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
-- DragonUI.CombuctorItemSlot. Buttons are remembered (weak-keyed) so
-- equipment changes can re-evaluate them without waiting for the bag
-- addon's own updates.
local hookedSlotButtons = setmetatable({}, { __mode = "k" })

local function HookItemSlotClass(itemSlot)
    hooksecurefunc(itemSlot, "Update", function(self)
        hookedSlotButtons[self] = true
        -- Cached slots show another character's (or offline) data; the
        -- live bag APIs would read the wrong item, so fall back to the
        -- link-only scan for those.
        local bag, slot
        if not self:IsCached() then
            bag, slot = self:GetBag(), self:GetID()
        end
        UpdateArrowForLink(self, self:GetItem(), bag, slot)
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

local UpdateQuestRewards -- defined in the quest-reward section below

-- Re-evaluate arrows on open bags when equipped gear changes (equipping
-- an upgrade makes the remaining bag copies stop being upgrades).
local function RefreshOpenBags()
    for i = 1, NUM_CONTAINER_FRAMES do
        local frame = _G["ContainerFrame" .. i]
        if frame and frame:IsShown() then
            UpdateContainerArrows(frame)
        end
    end
    for button in pairs(hookedSlotButtons) do
        if button:IsVisible() then
            local bag, slot
            if not button:IsCached() then
                bag, slot = button:GetBag(), button:GetID()
            end
            UpdateArrowForLink(button, button:GetItem(), bag, slot)
        end
    end
    if UpdateQuestRewards then UpdateQuestRewards() end
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

-- Markers sit on the icon's top-left corner: the top-right holds the
-- stack count and the button's right half is the item name text.
local function GetQuestArrow(button)
    local arrow = button.refactorQuestArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(14)
        arrow:SetPoint("TOPLEFT", QuestItemIcon(button), "TOPLEFT", -2, 2)
        if arrow:SetTexture(ARROW_TEXTURE) then
            arrow:SetVertexColor(0, 1, 0)
        else
            arrow:SetTexture(0, 1, 0, 0.9)
            arrow:SetWidth(10)
            arrow:SetHeight(10)
        end
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

-- Recomputes every visible reward button. Returns false when some item
-- wasn't ready yet (not in the client cache / tooltip scan failed) so the
-- caller schedules a retry — reward data often trails the frame opening.
local function UpdateQuestRewardsNow()
    -- QuestInfoFrame.rewardsFrame is a retail-era field; on 3.3.5 the
    -- rewards container is the global QuestInfoRewardsFrame.
    local rewardsFrame = QuestInfoRewardsFrame
        or (QuestInfoFrame and QuestInfoFrame.rewardsFrame)
    if not (rewardsFrame and rewardsFrame:IsVisible() and db and db.enabled) then
        for i = 1, MAX_QUEST_ITEMS do
            local button = _G["QuestInfoItem" .. i]
            if button then HideQuestMarkers(button) end
        end
        return true
    end

    local qlog = QuestInfoFrame.questLog and true or false
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
            if not link or not GetItemInfo(link) then
                complete = false
            else
                local equipLoc = select(9, GetItemInfo(link))
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
                    -- 3.3.5's GetItemInfo has no sellPrice return (that's
                    -- 4.0+; try anyway in case Ascension backported it),
                    -- so fall back to the money line scanned off the
                    -- reward tooltip itself.
                    local sellPrice = select(11, GetItemInfo(link))
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

function UpdateQuestRewards()
    if UpdateQuestRewardsNow() then
        questRetryFrame:Hide()
    else
        questRetriesLeft = 8
        questRetryElapsed = 0
        questRetryFrame:Show()
    end
end

-- QuestInfo_ShowRewards redraws the reward buttons for both the
-- quest-giver frame and the quest log. Guarded in case this custom
-- client renames it.
if type(QuestInfo_ShowRewards) == "function" then
    hooksecurefunc("QuestInfo_ShowRewards", UpdateQuestRewards)
end

--------------------------------------------------------------------------
-- Loot-moment alert
--------------------------------------------------------------------------

-- Turn a format string like "You receive loot: %s." into a match pattern.
local function PatternFromFormat(fmt)
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("%%s", "(.+)")
    return "^" .. fmt .. "$"
end

local LOOT_SELF_PATTERNS = {
    PatternFromFormat(LOOT_ITEM_SELF or "You receive loot: %s."),
    PatternFromFormat(LOOT_ITEM_PUSHED_SELF or "You receive item: %s."),
}

-- Items sometimes aren't in the client cache the instant the loot message
-- arrives; retry once shortly after.
local pendingAlerts = {} -- link -> retries left
local alertFrame = CreateFrame("Frame")
local alertElapsed = 0

-- Locate a looted item in the bags so the scaled copy gets scanned; a
-- bare link would score the base item.
local function FindBagItem(link)
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
            Print(link .. " fills an empty slot" .. lockNote .. " — worth keeping!")
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
    if not db or not db.enabled or not db.lootAlert then return end
    for _, pattern in ipairs(LOOT_SELF_PATTERNS) do
        local itemString = msg:match(pattern)
        if itemString then
            local link = itemString:match("|Hitem:.-|h%[.-%]|h")
            if link and not TryAlert(link) then
                pendingAlerts[link] = 3
                alertElapsed = 0
                alertFrame:Show()
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

local function DeleteProfile(name)
    if name == "Default" then
        Print("Can't delete the Default profile.")
    elseif db.profiles[name] then
        db.profiles[name] = nil
        if db.activeProfile == name then SetActiveProfile("Default") end
        Print("Deleted profile '" .. name .. "'.")
        RefreshOpenBags()
        RefreshConfig()
    end
end

-- Confirmation for the delete button on the UI's Profiles page —
-- destructive, so it stays a popup.
StaticPopupDialogs["REFACTORCOMPARE_DELETE_PROFILE"] = {
    text = "Delete profile '%s'?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data) DeleteProfile(data or self.data) end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

RefactorCompareShared.SaveProfileAs = SaveProfileAs
RefactorCompareShared.DeleteProfile = DeleteProfile

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
        Print("custom stat '" .. lname .. "' weight set to " .. value .. ".")
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
        Print("commands: /rfc (config), toggle, alert, bagicons, auto, debug, quality <n>, weight <stat> <n>, profile ...")
    end
end

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        -- Bagnon/DragonUI can load before or after this addon; try the
        -- hooks on every load until they stick (no-op once hooked or if
        -- absent).
        TryHookBagnon()
        TryHookDragonUI()
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
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then
            -- Equipping can rescale the item; drop instance scans so the
            -- refresh below compares against what's actually worn now.
            WipeInstanceScans()
            RefreshOpenBags()
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
