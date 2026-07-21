-- Refactor: transmog auto-collect
-- Optionally runs your bag-scan transmog collection logic whenever your
-- bags change (i.e. after looting), instead of you having to run the macro
-- by hand. See core.lua's QOL_DEFAULTS for the transmog/transmogBoE/
-- transmogSkipConfirm flag comments.

local timeSinceUpdate = 0
local DEBOUNCE_DELAY = 0.5 -- seconds to wait after the last bag change before scanning

-- Collecting an appearance soulbinds the item, so unless the player opted
-- into transmogBoE, only items that are ALREADY bound may be auto-collected.
-- Bind state isn't in the item link — only the instance tooltip knows — so
-- scan the bag slot and look for a bound-item line. An unreadable tooltip
-- (item not cached yet) means "unknown": skip it, never guess; the next
-- BAG_UPDATE retries it.
local bindTip = CreateFrame("GameTooltip", "RefactorBindScanTip", nil,
    "GameTooltipTemplate")

local BOUND_LINES = {}
local function AddBoundLine(s)
    if type(s) == "string" then BOUND_LINES[s] = true end
end
AddBoundLine(ITEM_SOULBOUND)         -- "Soulbound"
AddBoundLine(ITEM_BIND_QUEST)        -- "Quest Item" (untradeable)
AddBoundLine(ITEM_ACCOUNTBOUND)      -- account-bound variants: any of these
AddBoundLine(ITEM_BNETACCOUNTBOUND)  -- may or may not exist on this client,
AddBoundLine(ITEM_BIND_TO_ACCOUNT)   -- AddBoundLine skips the nils

local function IsBagItemBound(bag, slot)
    bindTip:SetOwner(UIParent, "ANCHOR_NONE")
    bindTip:ClearLines()
    bindTip:SetBagItem(bag, slot)
    local numLines = bindTip:NumLines()
    if numLines < 2 then return nil end -- failed scan: bind state unknown
    -- The bind line sits right under the name, but Ascension can inject its
    -- own lines (scaling notes, loot timers), so check the first few.
    for i = 2, math.min(numLines, 6) do
        local line = _G["RefactorBindScanTipTextLeft" .. i]
        local text = line and line:GetText()
        if text and BOUND_LINES[text] then return true end
    end
    return false
end

-- Session memo: itemIDs that can never need collecting again (no
-- appearance, or the appearance is already collected). BAG_UPDATE fires
-- constantly while playing and every scan used to re-query C_Appearance
-- for the whole bag contents; with the memo only new/uncollected items
-- pay. Deliberately NOT set after CollectItemAppearance — the confirm-
-- popup path may not complete — so a collect is memoized on the next
-- scan, once IsAppearanceCollected actually reports it.
local transmogDone = {}
local transmogDoneCount = 0
local TRANSMOG_DONE_CAP = 500 -- distinct itemIDs memoized this session; wipe wholesale past this rather than grow forever

-- Same logic as your manual macro, just wrapped in a function so it can be
-- triggered automatically instead of typed in.
local function ScanBagsForTransmog()
    if not Qol("transmog") then return end
    local c = C_AppearanceCollection
    if not c or not C_Appearance then
        return -- defensive: bail out quietly if these APIs aren't available
    end
    local includeUnbound = Qol("transmogBoE")

    for b = 0, 4 do
        local numSlots = GetContainerNumSlots(b)
        for s = 1, numSlots do
            local itemID = GetContainerItemID(b, s)
            if itemID and not transmogDone[itemID] then
                if transmogDoneCount >= TRANSMOG_DONE_CAP then
                    transmogDone = {}
                    transmogDoneCount = 0
                end
                local appearanceID = C_Appearance.GetItemAppearanceID(itemID)
                if not appearanceID or c.IsAppearanceCollected(appearanceID) then
                    transmogDone[itemID] = true
                    transmogDoneCount = transmogDoneCount + 1
                elseif includeUnbound or IsBagItemBound(b, s) then
                    local itemGUID = GetContainerItemGUID(b, s)
                    if itemGUID then
                        c.CollectItemAppearance(itemGUID)
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- Transmog: optionally skip the "item will become soulbound" confirmation
-- shown when manually learning an appearance (Ctrl+Shift-click). The
-- dialog's name is unknown (it lives in Ascension's packed FrameXML), so
-- match on the dialog TEXT instead and accept it in the same frame it was
-- shown — before it's ever drawn. If Ascension's confirm isn't a
-- StaticPopup this hook simply never fires.
--------------------------------------------------------------------------

local function IsCollectConfirmDialog(which)
    local dialog = StaticPopupDialogs and StaticPopupDialogs[which]
    local text = dialog and dialog.text
    if type(text) ~= "string" then return false end
    text = string.lower(text)
    return (string.find(text, "collect the appearance", 1, true)
        or string.find(text, "become soulbound", 1, true)) and true or false
end

hooksecurefunc("StaticPopup_Show", function(which)
    if not Qol("transmogSkipConfirm") then return end
    if not IsCollectConfirmDialog(which) then return end
    for i = 1, 4 do
        local frame = _G["StaticPopup" .. i]
        if frame and frame:IsShown() and frame.which == which then
            local accept = _G["StaticPopup" .. i .. "Button1"]
            if accept and accept:IsEnabled() then
                accept:Click() -- runs OnAccept and hides the popup
            end
            return
        end
    end
end)

-- Debounce with OnUpdate rather than C_Timer, since C_Timer's availability
-- on this client isn't guaranteed the way basic frame scripts are. The
-- handler detaches itself once it fires, so an idle frame costs nothing
-- per frame — it only ticks between a BAG_UPDATE burst and its scan.
local function TransmogDebounce(self, elapsed)
    timeSinceUpdate = timeSinceUpdate + elapsed
    if timeSinceUpdate >= DEBOUNCE_DELAY then
        self:SetScript("OnUpdate", nil)
        ScanBagsForTransmog()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("BAG_UPDATE")
f:SetScript("OnEvent", function(self, event)
    -- BAG_UPDATE fires whenever any bag's contents change, which covers
    -- looting, vendoring, mailing, etc. We don't rely on a more specific
    -- "loot" event since this custom client's event set isn't guaranteed.
    -- Auto-collect ships off; don't even run the debounce ticker for it.
    -- (Toggling it on mid-session picks up from the next bag change.)
    if not Qol("transmog") then return end
    timeSinceUpdate = 0
    self:SetScript("OnUpdate", TransmogDebounce)
end)
