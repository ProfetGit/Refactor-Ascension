local C = RefactorCompareInternal
local Print = C.Print
local CompareItem = C.CompareItem
local SLOTS_FOR_INVTYPE = C.SLOTS_FOR_INVTYPE
local STATS = C.STATS
local Weights = C.Weights
local ActiveProfile = C.ActiveProfile
local SetActiveProfile = C.SetActiveProfile
local CharKey = C.CharKey
local GetClassSpecs = C.GetClassSpecs
local SelectSpecProfile = C.SelectSpecProfile
local ResetActiveProfileWeights = C.ResetActiveProfileWeights
local SmartEquipActive = C.SmartEquipActive
local notGear = C.notGear
local MarkNotGear = C.MarkNotGear

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
    -- Shares the compare path's permanent "not gear" table, so a junk link
    -- already rejected by a bag redraw costs one lookup here and skips
    -- GetItemInfo entirely. Only the equipLoc half is cached — the quality
    -- cutoff below is a live user setting and must stay re-evaluated.
    if notGear[link] then return false end
    local name, _, quality, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if not name then return nil end
    if not equipLoc or not SLOTS_FOR_INVTYPE[equipLoc] then
        MarkNotGear(link)
        return false
    end
    if quality and quality < (RefactorCompareDB and RefactorCompareDB.minQuality or 0) then return false end
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
    IsEnabled = function() return RefactorCompareDB and RefactorCompareDB.enabled or false end,
    -- Everything below exists for RefactorUI.lua (the config window),
    -- which owns all settings UI. SaveProfileAs/DeleteProfile are added
    -- further down, after they're defined.
    GetDB = function() return RefactorCompareDB end,
    STATS = STATS,
    Weights = Weights,
    ActiveProfile = ActiveProfile,
    SetActiveProfile = SetActiveProfile,
    GetClassSpecs = GetClassSpecs,
    SelectSpecProfile = SelectSpecProfile,
    ResetActiveProfileWeights = ResetActiveProfileWeights,
    RefreshOpenBags = C.RefreshOpenBags,
    Print = Print,
    -- Armor-type checkboxes go through this (not raw DB().armorTypes[at] =
    -- v) so a manual edit is recorded and AutoApplyClassSpec stops
    -- overwriting it. /rfc auto clears the flag again.
    SetArmorType = function(armorType, value)
        RefactorCompareDB.armorTypes[armorType] = value
        RefactorCompareDB.charManualArmor[CharKey()] = true
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
    local wantAlert = RefactorCompareDB and RefactorCompareDB.enabled and RefactorCompareDB.lootAlert
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

C.OnLootMessage = OnLootMessage
