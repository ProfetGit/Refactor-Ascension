local C = RefactorCompareInternal
local Print = C.Print
local strfind = string.find

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
--
-- scanCache/equippedCache/verdictCache/generation cross file boundaries
-- (bag icons and the debounced refresh in 06/10 clear entries scored
-- here), so they live on the shared RefactorCompareInternal table rather
-- than as bare locals.
C.scanCache = {}
local scanCache = C.scanCache
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
C.generation = 0

-- [invSlot] = { gen, link, score, dpsScore }. Only successful scores are
-- memoized — an unreadable equipped item must stay a per-call retry
-- (tooltip retries depend on it), never a cached failure.
C.equippedCache = {}

-- ["bag:slot:link"] = { gen, result }. CompareItem results for bag slots:
-- the arrows path re-evaluates every slot of every open bag on each
-- redraw, and for unchanged slots this turns that into a table lookup.
-- Only non-nil results are cached; nil can mean "scan not ready yet" and
-- has to keep retrying.
C.verdictCache = {}

local function WipeScanCache()
    for k in pairs(scanCache) do scanCache[k] = nil end
    hScanCount = 0
end

local function WipeInstanceScans()
    for k in pairs(scanCache) do
        -- strfind-plain rather than sub(): this walks the whole cache and
        -- sub() allocated a throwaway two-char string for every key.
        if strfind(k, "h:", 1, true) ~= 1 then scanCache[k] = nil end
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
        and not (RefactorCompareDB and RefactorCompareDB.debug) then
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
            if RefactorCompareDB and RefactorCompareDB.debug then
                local lr, lg, lb = left:GetTextColor()
                Print(string.format("line %d [%.1f %.1f %.1f]: '%s'%s",
                    i, lr, lg, lb, (text:gsub("\n", "\\n")),
                    rightText and (" | R: '" .. rightText .. "'") or ""))
            end
            if IsRed(left) then
                if RefactorCompareDB and RefactorCompareDB.debug then
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
                if RefactorCompareDB and RefactorCompareDB.debug then
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
                if RefactorCompareDB and RefactorCompareDB.debug then
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
            -- Arm the expiry backstop (10_config.lua). The debounced bag/equip
            -- flush does most of the reclaiming, but merchant, quest-reward and
            -- loot-window scans raise no bag event, so without this they had
            -- nothing to clean them up while the player only browsed.
            if C.QueueScanSweep then C.QueueScanSweep() end
        elseif scanCache[cacheKey] == nil then
            -- Count only genuinely new keys: /rfc debug bypasses the cache
            -- read and re-caches, and counting those overwrites inflated
            -- the counter into premature cap purges.
            hScanCount = hScanCount + 1
            if hScanCount > H_SCAN_CAP then
                for k in pairs(scanCache) do
                    if strfind(k, "h:", 1, true) == 1 then scanCache[k] = nil end
                end
                hScanCount = 1
            end
        end
        scanCache[cacheKey] = result
    end
    if RefactorCompareDB and RefactorCompareDB.debug then
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

C.SLOTS_FOR_INVTYPE = SLOTS_FOR_INVTYPE
C.WEAPON_INVTYPES = WEAPON_INVTYPES
C.OFFHAND_DPS_FACTOR = OFFHAND_DPS_FACTOR
C.ARMOR_FILTERED_INVTYPES = ARMOR_FILTERED_INVTYPES
C.STAT_NAME_KEYS = STAT_NAME_KEYS
C.WipeScanCache = WipeScanCache
C.WipeInstanceScans = WipeInstanceScans
C.ScanItem = ScanItem
