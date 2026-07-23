local C = RefactorCompareInternal
local STATS = C.STATS
local ActiveProfile = C.ActiveProfile
local CharKey = C.CharKey
local SetActiveProfile = C.SetActiveProfile
local ActivateProfile = C.ActivateProfile
local Print = C.Print

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

-- There is deliberately no per-class armor table here any more. One used
-- to drive the General page's armor-type filter on every login, and it was
-- wrong twice over (issue #26): it wrote an account-wide setting from a
-- per-character rule, so logging a Cloth alt stripped Plate/Mail off a
-- Starcaller for good, and its hardcoded class -> armor lists can't know
-- about proficiencies learned on a classless server, so a Witch Doctor who
-- had earned Mail kept having Mail switched back off. Neither is worth
-- fixing, because the table never added information: the client renders an
-- item's sub-type in red when you lack the proficiency, ScanItem reads that
-- (IsHardRequirementText in 03_scan.lua) and CompareItem blocks the item as
-- unusable before the armor filter is consulted at all. The filter is now
-- purely a player preference, per character, set only from the checkboxes.

-- CLASS_SPEC_WEIGHTS is keyed by the non-localized class token (UnitClass's
-- 2nd return), guessed as the usual Blizzard convention (uppercase, spaces
-- as underscores). If Ascension's actual token differs, fall back to
-- deriving the same shape from the localized class name so lookups still
-- hit.
local function NormalizeClassKey(name)
    return name and name:upper():gsub(" ", "_")
end

-- Returns the spec list, the DISPLAY class name (for profile names shown
-- to the player), and the normalized weights-table key that matched — any
-- further table keyed like CLASS_SPEC_WEIGHTS must be indexed with that
-- key, never the display name, which silently misses.
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
    if not RefactorCompareDB.profiles[profileName] then
        local weights = {}
        for _, s in ipairs(STATS) do
            weights[s.key] = specEntry.weights[s.key] or 0
        end
        RefactorCompareDB.profiles[profileName] = { weights = weights, customWeights = {} }
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
    local name = RefactorCompareDB.activeProfile
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
                C.RefreshConfig()
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
    if not RefactorCompareDB then return end
    local specList, className = GetClassSpecList()
    if not specList then
        if RefactorCompareDB.debug then
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
    if not specEntry and #candidates > 0 and RefactorCompareDB.debug then
        Print("auto-profile: no weights for spec '"
            .. table.concat(candidates, "' / '") .. "', using " .. specList[1].name .. ".")
    end
    specEntry = specEntry or specList[1]

    local charKey = CharKey()

    local manual = RefactorCompareDB.charManualProfile[charKey]
    if manual and manual ~= RefactorCompareDB.charAutoProfile[charKey] then
        if RefactorCompareDB.debug then
            Print("auto-profile: keeping your chosen profile '" .. manual .. "' (/rfc auto to re-enable).")
        end
        return
    end

    local profileName = EnsureSpecProfile(className, specEntry)
    if RefactorCompareDB.activeProfile ~= profileName then
        ActivateProfile(profileName)
        Print("auto-selected weight profile '" .. profileName .. "' for your spec.")
        C.RefreshConfig()
    end
    RefactorCompareDB.charAutoProfile[charKey] = profileName
end

C.CLASS_SPEC_WEIGHTS = CLASS_SPEC_WEIGHTS
C.NormalizeClassKey = NormalizeClassKey
C.GetClassSpecs = GetClassSpecs
C.SelectSpecProfile = SelectSpecProfile
C.ResetActiveProfileWeights = ResetActiveProfileWeights
C.AutoApplyClassSpec = AutoApplyClassSpec
