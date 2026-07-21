-- Refactor: loot automation
-- Auto-accepts "will bind it to you" confirmations and fast auto-loots
-- everything the instant the loot window opens. Hold Shift while looting
-- for the normal window instead.

--------------------------------------------------------------------------
-- Loot: auto-accept "Looting X will bind it to you" confirmations
--------------------------------------------------------------------------

local lootConfirm = CreateFrame("Frame")
lootConfirm:RegisterEvent("LOOT_BIND_CONFIRM")
lootConfirm:RegisterEvent("CONFIRM_LOOT_ROLL")

lootConfirm:SetScript("OnEvent", function(self, event, arg1, arg2)
    if not Qol("autoConfirmBoP") then return end
    if event == "LOOT_BIND_CONFIRM" then
        -- arg1 = loot slot. Fires when looting a BoP item directly.
        ConfirmLootSlot(arg1)
        StaticPopup_Hide("LOOT_BIND")
    elseif event == "CONFIRM_LOOT_ROLL" then
        -- arg1 = rollID, arg2 = roll type. Fires when a need/greed roll on a
        -- BoP item asks for the same bind confirmation.
        ConfirmLootRoll(arg1, arg2)
        StaticPopup_Hide("CONFIRM_LOOT_ROLL")
    end
    -- UIParent registered these events before this addon loaded, so its
    -- handler has already shown the popup by the time we run — hiding here
    -- removes it the same frame, before it's ever drawn.
end)

--------------------------------------------------------------------------
-- Loot: fast auto-loot — grab everything the instant the window opens.
-- Hold Shift while looting to get the normal window instead.
--------------------------------------------------------------------------

local FASTLOOT_CHECK_DELAY = 0.5 -- seconds before checking whether loot remains

local fastLoot = CreateFrame("Frame")
fastLoot:RegisterEvent("LOOT_OPENED")
fastLoot:RegisterEvent("LOOT_CLOSED")

local timeSinceLootPass = 0

-- The window is hidden via alpha (not :Hide()) so the loot session stays
-- open and slots remain lootable while we work through them.
local function SetLootWindowVisible(visible)
    if LootFrame then
        LootFrame:SetAlpha(visible and 1 or 0)
    end
end

-- Attached only between LOOT_OPENED and its checks (or LOOT_CLOSED);
-- detaches itself so an idle frame costs nothing per frame. The engine's
-- autoLootDefault CVar does the actual looting — but on Ascension it
-- stops at anything needing a bind confirmation (BoP world-quest items
-- from objects stay in the window). With autoConfirmBoP on, the first
-- check loots those leftovers itself (the LOOT_BIND_CONFIRM handler above
-- accepts the popup), and only if a second check still finds loot left
-- (bags full, unique item) is the window revealed for manual looting.
local fastLootRetry -- set after the one LootSlot pass on leftovers
local function FastLootCheck(self, elapsed)
    timeSinceLootPass = timeSinceLootPass + elapsed
    if timeSinceLootPass < FASTLOOT_CHECK_DELAY then return end
    timeSinceLootPass = 0
    local remaining = 0
    for i = 1, GetNumLootItems() do
        if GetLootSlotInfo(i) then
            remaining = remaining + 1
        end
    end
    if remaining == 0 then
        self:SetScript("OnUpdate", nil)
        return
    end
    if not fastLootRetry and Qol("autoConfirmBoP") then
        fastLootRetry = true
        for i = 1, GetNumLootItems() do
            if GetLootSlotInfo(i) then LootSlot(i) end
        end
        return -- OnUpdate stays attached for the confirm round trip
    end
    self:SetScript("OnUpdate", nil)
    -- Loot remains, show the window so the player can loot manually
    SetLootWindowVisible(true)
end

fastLoot:SetScript("OnEvent", function(self, event)
    if event == "LOOT_OPENED" then
        -- The CVar check is a safety net: if engine auto-loot is off by
        -- any path the reconciler didn't see, never hide the window — the
        -- items wouldn't be looted and the player would stare at nothing.
        if IsShiftKeyDown() or not Qol("fastLoot")
            or not GetCVarBool("autoLootDefault") then
            self:SetScript("OnUpdate", nil)
            SetLootWindowVisible(true)
            return
        end
        SetLootWindowVisible(false)
        timeSinceLootPass = 0
        fastLootRetry = nil
        self:SetScript("OnUpdate", FastLootCheck)
    elseif event == "LOOT_CLOSED" then
        self:SetScript("OnUpdate", nil)
        SetLootWindowVisible(true) -- restore for whatever opens it next
    end
end)
