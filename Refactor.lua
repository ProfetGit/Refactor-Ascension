-- Refactor
-- Optionally runs your bag-scan transmog collection logic whenever your
-- bags change (i.e. after looting), instead of you having to run the macro
-- by hand. Also anchors the default tooltip beside the cursor (right side),
-- hides the tooltip health bar, auto-accepts bind-on-pickup loot
-- confirmations, fast auto-loots everything, and automates quest NPC
-- interaction (accept, turn-in, gossip picks). Hold Shift for the normal
-- loot/quest windows.

--------------------------------------------------------------------------
-- QoL settings
-- Every tweak in this file is toggleable from the Refactor UI window.
-- Flags are read at use time (not install time), so switching one off
-- takes effect immediately without a /reload. Stored under
-- RefactorCompareDB.qol; initialized at PLAYER_ENTERING_WORLD because
-- this file loads before RefactorCompare.lua creates the saved variable.
--------------------------------------------------------------------------

local qdb -- RefactorCompareDB.qol once saved variables exist

local QOL_DEFAULTS = {
    -- Collecting an appearance soulbinds the item, so auto-collect ships
    -- OFF: silently destroying the sale value of a BoE is not an acceptable
    -- surprise default. transmogBoE additionally gates unbound items even
    -- when auto-collect is opted into.
    transmog = false,      -- auto-collect appearances from bags (bound items only)
    transmogBoE = false,   -- ...including unbound (BoE/tradeable) items
    transmogSkipConfirm = false, -- auto-accept the manual-learn confirm popup
    cursorTooltip = true,  -- anchor default tooltip beside the cursor
    hideHealthBar = true,  -- hide the unit tooltip health bar
    qualityBorder = true,  -- color tooltip border by item quality
    autoConfirmBoP = true, -- skip "will bind it to you" popups
    fastLoot = true,       -- instant loot, hidden loot window
    questAccept = true,    -- auto-accept quest offers and escort confirmations
    questTurnIn = true,    -- auto-complete quests (multi-choice rewards stay open)
    questGossip = true,    -- auto-pick quest entries from NPC gossip menus
    hideErrorText = true,  -- hide red UI error text ("Ability is not ready yet")
    muteErrorSpeech = true,-- silence "I can't do that yet" voice errors
    -- Social auto-declines ship off: silently refusing invites/trades is a
    -- choice the player should make, not a surprise default.
    declineInvites = false,-- decline every party invite
    declineDuels = false,  -- cancel duel requests
    declineGuilds = false, -- decline guild invites
    declineTrades = false, -- close trades from non-friend/guild/group players
    autoResBG = false,     -- accept player resurrections inside battlegrounds
}

local function InitQol()
    if qdb or type(RefactorCompareDB) ~= "table" then return end
    if type(RefactorCompareDB.qol) ~= "table" then RefactorCompareDB.qol = {} end
    qdb = RefactorCompareDB.qol
    for k, v in pairs(QOL_DEFAULTS) do
        if qdb[k] == nil then qdb[k] = v end
    end
    -- One-time migration: auto-collect used to default ON, and collecting
    -- soulbinds the item — players lost sellable BoEs to a default they
    -- never chose. Force it off once for saves from those versions; turning
    -- it back on is an explicit choice in /rfc -> Tweaks from now on.
    if not RefactorCompareDB.migratedTransmogOff then
        RefactorCompareDB.migratedTransmogOff = true
        if qdb.transmog then
            qdb.transmog = false
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r auto transmog" ..
                " collection is now OFF by default: collecting an appearance" ..
                " soulbinds the item, which destroys BoE sale value. Re-enable" ..
                " it in /rfc -> Tweaks (bound items only, unless you also allow" ..
                " tradeable items).")
        end
    end
end

local function Qol(key)
    if qdb and qdb[key] ~= nil then return qdb[key] end
    return QOL_DEFAULTS[key]
end

-- Voice errors ("I can't do that yet") are played by the sound engine, not
-- the UI, so there's nothing to intercept per-message — the only switch is
-- the Sound_EnableErrorSpeech CVar. Written at login and whenever the
-- checkbox changes (a CVar is client-wide, so it must track the flag).
local function ApplyErrorSpeech()
    SetCVar("Sound_EnableErrorSpeech", Qol("muteErrorSpeech") and 0 or 1)
end

-- Shared with RefactorUI.lua (the config window).
RefactorQoL = {
    Get = Qol,
    Set = function(key, value)
        InitQol()
        if qdb then qdb[key] = value and true or false end
        if key == "muteErrorSpeech" then ApplyErrorSpeech() end
    end,
}

local f = CreateFrame("Frame")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

local pendingScan = false
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
            if itemID then
                local appearanceID = C_Appearance.GetItemAppearanceID(itemID)
                if appearanceID and not c.IsAppearanceCollected(appearanceID)
                    and (includeUnbound or IsBagItemBound(b, s)) then
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

f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        InitQol() -- saved variables (and RefactorCompare's init) are done by now
        ApplyErrorSpeech()
        -- The friends list is empty client-side until the server sends it;
        -- request it now so the trade-window whitelist can check it.
        ShowFriends()
    end
    -- BAG_UPDATE fires whenever any bag's contents change, which covers
    -- looting, vendoring, mailing, etc. We don't rely on a more specific
    -- "loot" event since this custom client's event set isn't guaranteed.
    pendingScan = true
    timeSinceUpdate = 0
end)

-- Debounce with OnUpdate rather than C_Timer, since C_Timer's availability
-- on this client isn't guaranteed the way basic frame scripts are.
f:SetScript("OnUpdate", function(self, elapsed)
    if pendingScan then
        timeSinceUpdate = timeSinceUpdate + elapsed
        if timeSinceUpdate >= DEBOUNCE_DELAY then
            pendingScan = false
            ScanBagsForTransmog()
        end
    end
end)

--------------------------------------------------------------------------
-- Tooltip: anchor beside the cursor (right side) and follow it while shown
--------------------------------------------------------------------------

local TOOLTIP_CURSOR_OFFSET_X = 18 -- gap between cursor and tooltip's left edge

-- GameTooltip_SetDefaultAnchor is what the default UI calls for tooltips
-- that use the "default" position (world mouseover, bag items, unit frames,
-- etc.). Hooking it only affects those; tooltips a frame explicitly anchors
-- elsewhere are left alone.
hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip, parent)
    -- When disabled, the original function's default anchoring (which ran
    -- just before this post-hook) is left untouched.
    if not Qol("cursorTooltip") then return end
    -- ANCHOR_CURSOR on this client centers the tooltip on the cursor and
    -- doesn't follow it, so use ANCHOR_NONE and position it ourselves.
    tooltip:SetOwner(parent, "ANCHOR_NONE")
    tooltip.refactorCursorAnchor = true
end)

local function PositionAtCursor(tooltip)
    local x, y = GetCursorPosition()
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        x / scale + TOOLTIP_CURSOR_OFFSET_X, y / scale)
end

GameTooltip:HookScript("OnUpdate", function(self)
    if self.refactorCursorAnchor then
        PositionAtCursor(self)
    end
    -- The client fades unit tooltips out from C code (a Lua hook on FadeOut
    -- never fires), so detect the lost mouseover ourselves and hide instantly.
    if self:GetUnit() and not UnitExists("mouseover") then
        self:Hide()
    end
end)

GameTooltip:HookScript("OnHide", function(self)
    self.refactorCursorAnchor = nil
end)
--------------------------------------------------------------------------
-- Tooltip: remove the health bar shown under unit tooltips
--------------------------------------------------------------------------

if GameTooltipStatusBar then
    GameTooltipStatusBar:Hide()
    GameTooltipStatusBar:HookScript("OnShow", function(self)
        -- The client re-shows the bar for every unit tooltip, so letting
        -- this hook pass when disabled restores the bar immediately.
        if Qol("hideHealthBar") then self:Hide() end
    end)
end

--------------------------------------------------------------------------
-- Tooltip: color the border to match the item's quality
--------------------------------------------------------------------------

local defaultBorderR, defaultBorderG, defaultBorderB = GameTooltip:GetBackdropBorderColor()

GameTooltip:HookScript("OnTooltipSetItem", function(self)
    if not Qol("qualityBorder") then return end
    local _, link = self:GetItem()
    if not link then return end
    local quality = select(3, GetItemInfo(link))
    if quality then
        local r, g, b = GetItemQualityColor(quality)
        self:SetBackdropBorderColor(r, g, b)
    end
end)

GameTooltip:HookScript("OnTooltipCleared", function(self)
    self:SetBackdropBorderColor(defaultBorderR, defaultBorderG, defaultBorderB)
end)

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

local FASTLOOT_RETRY_DELAY = 0.25 -- seconds between passes, in case the server throttles loot
local FASTLOOT_MAX_PASSES = 4     -- initial pass + retries before giving up (bags full etc.)

local fastLoot = CreateFrame("Frame")
fastLoot:RegisterEvent("LOOT_OPENED")
fastLoot:RegisterEvent("LOOT_CLOSED")

local lootPassesLeft = 0
local timeSinceLootPass = 0

-- The window is hidden via alpha (not :Hide()) so the loot session stays
-- open and slots remain lootable while we work through them.
local function SetLootWindowVisible(visible)
    if LootFrame then
        LootFrame:SetAlpha(visible and 1 or 0)
    end
end

local function LootRemainingSlots()
    local remaining = 0
    for i = GetNumLootItems(), 1, -1 do
        -- Cleared slots keep their index until the window closes; a nil
        -- texture means the slot was already looted.
        if GetLootSlotInfo(i) then
            LootSlot(i)
            remaining = remaining + 1
        end
    end
    return remaining
end

fastLoot:SetScript("OnEvent", function(self, event)
    if event == "LOOT_OPENED" then
        if IsShiftKeyDown() or not Qol("fastLoot") then
            lootPassesLeft = 0
            SetLootWindowVisible(true)
            return
        end
        SetLootWindowVisible(false)
        lootPassesLeft = FASTLOOT_MAX_PASSES - 1
        timeSinceLootPass = 0
        LootRemainingSlots()
    elseif event == "LOOT_CLOSED" then
        lootPassesLeft = 0
        SetLootWindowVisible(true) -- restore for whatever opens it next
    end
end)

fastLoot:SetScript("OnUpdate", function(self, elapsed)
    if lootPassesLeft <= 0 then return end
    timeSinceLootPass = timeSinceLootPass + elapsed
    if timeSinceLootPass < FASTLOOT_RETRY_DELAY then return end
    timeSinceLootPass = 0
    lootPassesLeft = lootPassesLeft - 1
    if LootRemainingSlots() == 0 then
        lootPassesLeft = 0
    elseif lootPassesLeft == 0 then
        -- Something refused to loot (bags full, unique item already owned):
        -- reveal the window so the leftovers can be handled by hand.
        SetLootWindowVisible(true)
    end
end)

--------------------------------------------------------------------------
-- Quests: auto-accept, auto turn-in, auto-pick from gossip menus.
-- Hold Shift while talking to an NPC for the normal quest windows.
--------------------------------------------------------------------------

-- The gossip API doesn't say whether an active quest is completable on this
-- client generation, so check the quest log by title instead. A quest hidden
-- under a collapsed log header won't be found — that errs on the safe side
-- (we skip it and the gossip menu stays up).
local function IsLogQuestComplete(title)
    if type(title) ~= "string" then return false end
    for i = 1, GetNumQuestLogEntries() do
        local qTitle, _, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
        if not isHeader and qTitle == title then
            return isComplete == 1
        end
    end
    return false
end

-- GetGossipActiveQuests returns a flat list with an era-dependent number of
-- fields per quest (3.3.5 has three, later clients more), so derive the
-- stride from the count instead of hardcoding it. Title is always first.
local function GossipQuestTitle(returns, count, index)
    if count == 0 or #returns == 0 or #returns % count ~= 0 then return nil end
    return returns[(index - 1) * (#returns / count) + 1]
end

local quest = CreateFrame("Frame")
quest:RegisterEvent("GOSSIP_SHOW")
quest:RegisterEvent("QUEST_GREETING")
quest:RegisterEvent("QUEST_DETAIL")
quest:RegisterEvent("QUEST_ACCEPT_CONFIRM")
quest:RegisterEvent("QUEST_PROGRESS")
quest:RegisterEvent("QUEST_COMPLETE")

-- Picks one quest entry per GOSSIP_SHOW/QUEST_GREETING: selecting an entry
-- ends the menu, and if the NPC reopens it afterwards the event just fires
-- again for the next entry. Turn-ins go before pickups so a completed
-- chain step is handed in before its follow-up is offered.
local function SelectFromGossip()
    local numActive = GetNumGossipActiveQuests() or 0
    if numActive > 0 then
        local returns = { GetGossipActiveQuests() }
        for i = 1, numActive do
            if IsLogQuestComplete(GossipQuestTitle(returns, numActive, i)) then
                SelectGossipActiveQuest(i)
                return true
            end
        end
    end
    if (GetNumGossipAvailableQuests() or 0) > 0 then
        SelectGossipAvailableQuest(1)
        return true
    end
end

local function SelectFromGreeting()
    for i = 1, GetNumActiveQuests() or 0 do
        if IsLogQuestComplete(GetActiveTitle(i)) then
            SelectActiveQuest(i)
            return true
        end
    end
    if (GetNumAvailableQuests() or 0) > 0 then
        SelectAvailableQuest(1)
        return true
    end
end

quest:SetScript("OnEvent", function(self, event, arg1)
    if IsShiftKeyDown() then return end -- manual override for every step

    if event == "GOSSIP_SHOW" then
        if Qol("questGossip") then SelectFromGossip() end
    elseif event == "QUEST_GREETING" then
        if Qol("questGossip") then SelectFromGreeting() end
    elseif event == "QUEST_DETAIL" then
        if not Qol("questAccept") then return end
        if QuestGetAutoAccept and QuestGetAutoAccept() then
            -- Server already put it in the log; just dismiss the detail frame.
            if AcknowledgeAutoAcceptQuest then AcknowledgeAutoAcceptQuest() else CloseQuest() end
        else
            AcceptQuest()
        end
    elseif event == "QUEST_ACCEPT_CONFIRM" then
        -- Someone else started an escort/group quest nearby.
        if not Qol("questAccept") then return end
        ConfirmAcceptQuest()
        StaticPopup_Hide("QUEST_ACCEPT")
        StaticPopup_Hide("QUEST_ACCEPT_CONFIRM")
    elseif event == "QUEST_PROGRESS" then
        if Qol("questTurnIn") and IsQuestCompletable() then
            CompleteQuest()
        end
    elseif event == "QUEST_COMPLETE" then
        if not Qol("questTurnIn") then return end
        local choices = GetNumQuestChoices() or 0
        if choices <= 1 then
            -- Zero or one reward choice: nothing to decide. Multiple choices
            -- leave the window open for the player to pick.
            GetQuestReward(choices)
        end
    end
end)

--------------------------------------------------------------------------
-- Social: auto-decline party invites, duels, guild invites and stranger
-- trades; auto-accept player resurrections in battlegrounds.
-- Hold Shift as the request arrives to handle it manually.
--------------------------------------------------------------------------

-- Every auto-handled request gets one chat line so the player still knows
-- it happened — the popups are hidden the same frame they'd appear.
local function Announce(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r " .. msg)
end

local function IsFriend(name)
    if not name then return false end
    for i = 1, GetNumFriends() do
        if GetFriendInfo(i) == name then return true end
    end
    return false
end

local social = CreateFrame("Frame")
social:RegisterEvent("PARTY_INVITE_REQUEST")
social:RegisterEvent("DUEL_REQUESTED")
social:RegisterEvent("GUILD_INVITE_REQUEST")
social:RegisterEvent("TRADE_SHOW")
social:RegisterEvent("RESURRECT_REQUEST")

social:SetScript("OnEvent", function(self, event, arg1, arg2)
    if IsShiftKeyDown() then return end -- manual override for every request

    if event == "PARTY_INVITE_REQUEST" then
        if not Qol("declineInvites") then return end
        DeclineGroup()
        StaticPopup_Hide("PARTY_INVITE")
        Announce("declined group invite from " .. (arg1 or "someone"))
    elseif event == "DUEL_REQUESTED" then
        if not Qol("declineDuels") then return end
        CancelDuel()
        StaticPopup_Hide("DUEL_REQUESTED")
        Announce("declined duel from " .. (arg1 or "someone"))
    elseif event == "GUILD_INVITE_REQUEST" then
        -- arg1 = inviter, arg2 = guild name.
        if not Qol("declineGuilds") then return end
        DeclineGuild()
        StaticPopup_Hide("GUILD_INVITE")
        Announce("declined invite to <" .. (arg2 or "?") .. "> from " .. (arg1 or "someone"))
    elseif event == "TRADE_SHOW" then
        if not Qol("declineTrades") then return end
        -- "NPC" is the trade partner while the window is open. Friends,
        -- guildmates and groupmates trade freely; only strangers are blocked.
        local partner = UnitName("NPC")
        if IsFriend(partner) or UnitIsInMyGuild("NPC")
            or UnitInParty("NPC") or UnitInRaid("NPC") then return end
        CloseTrade()
        Announce("closed trade with " .. (partner or "someone"))
    elseif event == "RESURRECT_REQUEST" then
        -- arg1 = who's offering. Battlegrounds only — accepting a dungeon
        -- combat-res is a timing decision that stays with the player.
        if not Qol("autoResBG") then return end
        local _, instanceType = IsInInstance()
        if instanceType ~= "pvp" then return end
        AcceptResurrect()
        StaticPopup_Hide("RESURRECT")
        StaticPopup_Hide("RESURRECT_NO_SICKNESS")
        StaticPopup_Hide("RESURRECT_NO_TIMER")
        Announce("accepted resurrection from " .. (arg1 or "someone"))
    end
end)

--------------------------------------------------------------------------
-- Errors: hide the red UI error text ("Ability is not ready yet" etc.)
--------------------------------------------------------------------------

-- UIErrorsFrame owns UI_ERROR_MESSAGE; take the event over so the flag is
-- read per message and toggling needs no /reload. Yellow UI_INFO_MESSAGE
-- lines (quest progress etc.) stay with the default frame.
UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")

local errText = CreateFrame("Frame")
errText:RegisterEvent("UI_ERROR_MESSAGE")
errText:SetScript("OnEvent", function(self, event, message)
    if Qol("hideErrorText") then return end
    -- Same color/hold values the default UI uses for error lines.
    UIErrorsFrame:AddMessage(message, 1.0, 0.1, 0.1, 1.0)
end)
