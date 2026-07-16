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
local Qol -- forward-declared: ApplyFastLootCVar below is compiled before
          -- Qol's definition, and without this it resolved as a GLOBAL
          -- (nil) — erroring on login and on every fastLoot toggle

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
    fullMapWindow = true,  -- fullscreen map as a movable window (no blackout)
    hideErrorText = true,  -- hide red UI error text ("Ability is not ready yet")
    muteErrorSpeech = true,-- silence "I can't do that yet" voice errors
    -- Companion to the silent-sound client patch (loose files under the
    -- game root's Sound\ folder, see CLAUDE.md): with the patch the engine
    -- always plays silence for cast-deny sounds, and while this flag is OFF
    -- the addon replays bundled copies of the originals — so the checkbox
    -- reads as a mute: ticked = silence, unticked = sounds back. Defaults
    -- to muted, the state the patch exists to provide. Without the patch
    -- the engine sound still plays and unticking doubles it.
    muteDenySounds = true, -- silence fizzle/error sounds on denied casts
    -- Social auto-declines ship off: silently refusing invites/trades is a
    -- choice the player should make, not a surprise default.
    declineInvites = false,-- decline every party invite
    declineDuels = false,  -- cancel duel requests
    declineGuilds = false, -- decline guild invites
    declineTrades = false, -- close trades from non-friend/guild/group players
    autoResBG = false,     -- accept player resurrections inside battlegrounds
    quickInvite = false,   -- Alt + Right-Click: quick invite player
    leavePartyOnDungeon = false, -- also leave party when clicking Leave Dungeon
    -- Moves items and equips a bag on your behalf when your bag slots are
    -- full; on by default per user request.
    seamlessBagUpgrade = true, -- right-click a bag: auto-swap in the smallest equipped bag
}

local function ApplyFastLootCVar()
    -- Written both ways: only ever setting "1" left the engine
    -- auto-looting (shift-inverted) after the flag was unticked.
    SetCVar("autoLootDefault", Qol("fastLoot") and "1" or "0")
end

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
    ApplyFastLootCVar()
end

function Qol(key) -- assigns the forward-declared local above
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

-- Assigned by the world-map section at the bottom of this file; declared
-- here so Set can re-apply the flag while the map is open.
local ApplyFullMapWindow

-- Shared with RefactorUI.lua (the config window).
RefactorQoL = {
    Get = Qol,
    Set = function(key, value)
        InitQol()
        if qdb then qdb[key] = value and true or false end
        if key == "muteErrorSpeech" then ApplyErrorSpeech() end
        if key == "fullMapWindow" and ApplyFullMapWindow then ApplyFullMapWindow() end
        if key == "fastLoot" then ApplyFastLootCVar() end
    end,
}

local f = CreateFrame("Frame")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("PLAYER_ENTERING_WORLD")

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
                local appearanceID = C_Appearance.GetItemAppearanceID(itemID)
                if not appearanceID or c.IsAppearanceCollected(appearanceID) then
                    transmogDone[itemID] = true
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

f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        InitQol() -- saved variables (and RefactorCompare's init) are done by now
        ApplyErrorSpeech()
        -- The friends list is empty client-side until the server sends it;
        -- request it now so the trade-window whitelist can check it.
        ShowFriends()
        -- Don't fall through into the transmog debounce: login isn't a
        -- bag change, and the login flood of BAG_UPDATEs triggers the
        -- scan anyway while the flag is on.
        return
    end
    -- BAG_UPDATE fires whenever any bag's contents change, which covers
    -- looting, vendoring, mailing, etc. We don't rely on a more specific
    -- "loot" event since this custom client's event set isn't guaranteed.
    -- Auto-collect ships off; don't even run the debounce ticker for it.
    -- (Toggling it on mid-session picks up from the next bag change.)
    if not Qol("transmog") then return end
    timeSinceUpdate = 0
    self:SetScript("OnUpdate", TransmogDebounce)
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
    tooltip.refactorCursorX = nil -- force a repoint on the first frame
end)

local function PositionAtCursor(tooltip)
    local x, y = GetCursorPosition()
    -- Mouse hasn't moved since last frame: the point is already right;
    -- skip the per-frame ClearAllPoints/SetPoint churn.
    if tooltip.refactorCursorX == x and tooltip.refactorCursorY == y then
        return
    end
    tooltip.refactorCursorX, tooltip.refactorCursorY = x, y
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        x / scale + TOOLTIP_CURSOR_OFFSET_X, y / scale)
end

-- The lost-mouseover check below needs at most ~10 Hz to still read as
-- instant; unthrottled it was two C calls per frame for every tooltip,
-- item hovers included, for the whole session.
local UNIT_CHECK_INTERVAL = 0.1
local unitCheckElapsed = 0

GameTooltip:HookScript("OnUpdate", function(self, elapsed)
    if self.refactorCursorAnchor then
        PositionAtCursor(self) -- per-frame: the cursor follow must be smooth
    end
    -- The client fades unit tooltips out from C code (a Lua hook on FadeOut
    -- never fires), so detect the lost mouseover ourselves and hide instantly.
    unitCheckElapsed = unitCheckElapsed + elapsed
    if unitCheckElapsed < UNIT_CHECK_INTERVAL then return end
    unitCheckElapsed = 0
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

-- Attached only between LOOT_OPENED and its one check (or LOOT_CLOSED);
-- detaches itself so an idle frame costs nothing per frame. The engine's
-- autoLootDefault CVar does the actual looting — this only reveals the
-- window again if anything is left over (bags full, unique item).
local function FastLootCheck(self, elapsed)
    timeSinceLootPass = timeSinceLootPass + elapsed
    if timeSinceLootPass < FASTLOOT_CHECK_DELAY then return end
    self:SetScript("OnUpdate", nil)
    local remaining = 0
    for i = 1, GetNumLootItems() do
        if GetLootSlotInfo(i) then
            remaining = remaining + 1
        end
    end
    if remaining > 0 then
        -- Loot remains, show the window so the player can loot manually
        SetLootWindowVisible(true)
    end
end

fastLoot:SetScript("OnEvent", function(self, event)
    if event == "LOOT_OPENED" then
        if IsShiftKeyDown() or not Qol("fastLoot") then
            self:SetScript("OnUpdate", nil)
            SetLootWindowVisible(true)
            return
        end
        SetLootWindowVisible(false)
        timeSinceLootPass = 0
        self:SetScript("OnUpdate", FastLootCheck)
    elseif event == "LOOT_CLOSED" then
        self:SetScript("OnUpdate", nil)
        SetLootWindowVisible(true) -- restore for whatever opens it next
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
local function DebugOn()
    return type(RefactorCompareDB) == "table" and RefactorCompareDB.debug
end

local function SelectFromGossip()
    local numActive = GetNumGossipActiveQuests() or 0
    local numAvailable = GetNumGossipAvailableQuests() or 0
    if DebugOn() then
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99Refactor debug:|r GOSSIP_SHOW active=%d available=%d")
            :format(numActive, numAvailable))
    end
    if numActive > 0 then
        local returns = { GetGossipActiveQuests() }
        for i = 1, numActive do
            local title = GossipQuestTitle(returns, numActive, i)
            local complete = IsLogQuestComplete(title)
            if DebugOn() then
                DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99Refactor debug:|r  active #%d '%s' logComplete=%s")
                    :format(i, tostring(title), tostring(complete)))
            end
            if complete then
                SelectGossipActiveQuest(i)
                return true
            end
        end
    end
    if numAvailable > 0 then
        SelectGossipAvailableQuest(1)
        return true
    end
    -- A single quest embedded straight in the NPC's dialogue (as opposed to
    -- a multi-quest hub) never populates GetGossip{Active,Available}Quests,
    -- and its GetGossipOptions() type is plain "gossip" too — this server
    -- has no client-side type marker for it at all. Ascension's own
    -- convention is a literal "(Quest)" text prefix on the option title, so
    -- that's the only signal available; match on it rather than type.
    local options = { GetGossipOptions() }
    for i = 1, #options, 2 do
        local title = options[i]
        if DebugOn() then
            DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99Refactor debug:|r  option #%d '%s' type=%s")
                :format((i + 1) / 2, tostring(title), tostring(options[i + 1])))
        end
        if type(title) == "string" and title:find("(Quest)", 1, true) then
            SelectGossipOption((i + 1) / 2)
            return true
        end
    end
end

local function SelectFromGreeting()
    local numActive = GetNumActiveQuests() or 0
    local numAvailable = GetNumAvailableQuests() or 0
    if DebugOn() then
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99Refactor debug:|r QUEST_GREETING active=%d available=%d")
            :format(numActive, numAvailable))
    end
    for i = 1, numActive do
        if IsLogQuestComplete(GetActiveTitle(i)) then
            SelectActiveQuest(i)
            return true
        end
    end
    if numAvailable > 0 then
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
-- Social: Alt + Right-Click a player to quickly invite them
--------------------------------------------------------------------------

-- Post-hook, NOT a global replacement: swapping the UnitPopup_ShowMenu
-- global put addon code in the path of every unit right-click menu, and
-- on 3.3.5 dropdown taint blocks protected menu actions (Set Focus etc.)
-- — same lesson as the UseContainerItem hooks elsewhere in this addon.
-- The menu can't be preempted from a post-hook, so it's closed right
-- after opening instead; the one-frame flicker is the taint-free price.
hooksecurefunc("UnitPopup_ShowMenu", function(dropdownFrame, which, unit, name)
    if not Qol("quickInvite") or not IsAltKeyDown() then return end
    local targetName = name
    if unit then
        if not UnitIsPlayer(unit) then return end
        targetName = UnitName(unit)
    end
    if targetName and targetName ~= UnitName("player") then
        CloseDropDownMenus()
        InviteUnit(targetName)
    end
end)

-- World clicks: the binding system calls the TurnOrActionStart C command
-- directly, so a hooksecurefunc on the Lua global never fires from a real
-- right-click — WorldFrame's mouse script is the only path that does.
WorldFrame:HookScript("OnMouseDown", function(_, button)
    if button ~= "RightButton" then return end
    if Qol("quickInvite") and IsAltKeyDown() and UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        local name = UnitName("mouseover")
        if name and name ~= UnitName("player") then
            InviteUnit(name)
        end
    end
end)

--------------------------------------------------------------------------
-- Dungeons: leave party when clicking the Leave Dungeon button
--------------------------------------------------------------------------

if LFDLeaveFrameLeaveButton then
    LFDLeaveFrameLeaveButton:HookScript("OnClick", function()
        if Qol("leavePartyOnDungeon") then
            LeaveParty()
        end
    end)
end

--------------------------------------------------------------------------
-- Errors: hide the red UI error text ("Ability is not ready yet" etc.)
--------------------------------------------------------------------------

-- Cast-deny fizzles (on not-ready spam and on not-enough-resource — the
-- engine plays the spell school's fizzle for both) come from sound files —
-- the Lua API has no per-sound mute on this client, so they're silenced by
-- the client patch (silent loose files in the game root's Sound\ folder).
-- While muteDenySounds is off, the addon replays a bundled original on the
-- matching error events, giving an in-game mute toggle: patch installed +
-- flag on = silence, flag off = sound back, instantly, no restart. The
-- error text carries no spell school, so the replay is always the holy
-- variant rather than varying by school like the engine did.
local DENY_LINES = {}
local function AddDeny(s)
    if type(s) == "string" then DENY_LINES[s] = true end
end
AddDeny(SPELL_FAILED_NOT_READY)         -- "Ability is not ready yet"
AddDeny(SPELL_FAILED_SPELL_IN_PROGRESS) -- "Another action is in progress"
AddDeny(ERR_SPELL_COOLDOWN)             -- "Spell is not ready yet."
AddDeny(ERR_ABILITY_COOLDOWN)           -- "Ability is not ready yet."
AddDeny(ERR_ITEM_COOLDOWN)              -- "Item is not ready yet."
AddDeny(ERR_OUT_OF_MANA)                -- "Not enough mana"
AddDeny(ERR_OUT_OF_RAGE)                -- "Not enough rage"
AddDeny(ERR_OUT_OF_ENERGY)              -- "Not enough energy"
AddDeny(ERR_OUT_OF_FOCUS)               -- "Not enough focus"
AddDeny(ERR_OUT_OF_RUNIC_POWER)         -- "Not enough runic power"
AddDeny(ERR_OUT_OF_RUNES)               -- "Not enough runes"
AddDeny(ERR_OUT_OF_HEALTH)              -- "Not enough health"
AddDeny(SPELL_FAILED_NO_POWER)          -- "Not enough power"

local DENY_SOUND = "Interface\\AddOns\\Refactor\\sounds\\FizzleHolyA.wav"

-- UIErrorsFrame owns UI_ERROR_MESSAGE; take the event over so the flag is
-- read per message and toggling needs no /reload. Yellow UI_INFO_MESSAGE
-- lines (quest progress etc.) stay with the default frame.
UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")

local errText = CreateFrame("Frame")
errText:RegisterEvent("UI_ERROR_MESSAGE")
errText:SetScript("OnEvent", function(self, event, message)
    if message and DENY_LINES[message] and not Qol("muteDenySounds")
        and PlaySoundFile then
        PlaySoundFile(DENY_SOUND)
    end
    if Qol("hideErrorText") then return end
    -- Same color/hold values the default UI uses for error lines.
    UIErrorsFrame:AddMessage(message, 1.0, 0.1, 0.1, 1.0)
end)

--------------------------------------------------------------------------
-- World map: fullscreen map as a movable window
--
-- Everything on the fullscreen map (title, dropdowns, map, quest list and
-- detail/reward panes) is anchored inside WorldMapPositioningGuide, a
-- 1024x768 box centered in WorldMapFrame — the frame itself is just a
-- screen-covering shell: SetParent(nil) + SetAllPoints + EnableKeyboard
-- (that keyboard grab is why you can't move with WASD) + the BlackoutWorld
-- backdrop. Stock code already ships the counter-recipe in the advanced
-- windowed mode (WorldMapFrame_SetMiniMode): UIPanel area "center",
-- allowOtherPanels, SetMovable, own anchor. This applies that same
-- treatment to fullscreen mode: shrink the shell to the 1024x768 content
-- box, scale it down, hide the blackout, release the keyboard, and drag
-- via the title strip (mousewheel there resizes). While the flag is on
-- this window is the ONLY map mode: the size-down button is hidden and
-- anything that still lands in mini mode (the persisted miniWorldMap CVar
-- at login) is sized straight back up.
--------------------------------------------------------------------------

do
    if WorldMapFrame and BlackoutWorld and WorldMapPositioningGuide
        and WORLDMAP_SETTINGS and WORLDMAP_WINDOWED_SIZE then

        local FULLMAP_W, FULLMAP_H = 1024, 768 -- WorldMapPositioningGuide box
        local MIN_SCALE, MAX_SCALE = 0.5, 1.0
        local DEFAULT_SCALE = 0.85 -- most players land here; UI shows this as "1.0"

        -- Position/scale live outside qol (RefactorQoL.Set coerces values
        -- to booleans). Lazily created: saved variables don't exist yet
        -- when this file loads.
        local function FMDB()
            if type(RefactorCompareDB) ~= "table" then return nil end
            if type(RefactorCompareDB.fullmap) ~= "table" then
                RefactorCompareDB.fullmap = {}
            end
            return RefactorCompareDB.fullmap
        end

        local function Windowized()
            return Qol("fullMapWindow")
                and WORLDMAP_SETTINGS.size ~= WORLDMAP_WINDOWED_SIZE
        end

        -- SetPoint offsets are in the frame's own (scaled) coordinates, so
        -- the saved UIParent-space center offset is divided back out.
        local function ApplyPosition()
            local db = FMDB()
            local s = db and db.scale or DEFAULT_SCALE
            local x = db and db.x or 0
            local y = db and db.y or 0
            WorldMapFrame:ClearAllPoints()
            WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", x / s, y / s)
        end

        local function SavePosition()
            local db = FMDB()
            if not db then return end
            local s = WorldMapFrame:GetScale()
            local fx, fy = WorldMapFrame:GetCenter()
            local ux, uy = UIParent:GetCenter()
            if fx and ux then
                db.x = fx * s - ux
                db.y = fy * s - uy
            end
        end

        -- Quest blob mouseover hit-testing caches screen translations;
        -- invalidate after any move or rescale (stock does the same on its
        -- own drags and mode switches).
        local function RefreshBlob()
            if WorldMapBlobFrame then WorldMapBlobFrame.xRatio = nil end
            if type(WorldMapBlobFrame_CalculateHitTranslations) == "function"
                and WorldMapFrame:IsShown() then
                WorldMapBlobFrame_CalculateHitTranslations()
            end
        end

        -- The panel manager reads the UIPanelLayout-* attributes only once
        -- "UIPanelLayout-defined" is set — and setting it is the manager's
        -- own job: on the FIRST ShowUIPanel it copies the stock
        -- UIPanelWindows["WorldMapFrame"] table (area "full") over the
        -- attributes, clobbering any attribute written earlier. A "full"
        -- panel hides UIParent, which is why the first map-open after a
        -- load blanked the whole UI. Stock's advanced windowed mode has
        -- the same problem and ships the fix (WorldMapFrame_SetMiniMode):
        -- before "defined", mutate the table; after, write the attributes.
        local function SetPanelSlot(area, allow)
            if not WorldMapFrame:GetAttribute("UIPanelLayout-defined") then
                local w = UIPanelWindows and UIPanelWindows["WorldMapFrame"]
                if w then
                    w.area = area
                    w.allowOtherPanels = allow
                end
            else
                WorldMapFrame:SetAttribute("UIPanelLayout-area", area)
                WorldMapFrame:SetAttribute("UIPanelLayout-allowOtherPanels", allow)
            end
        end

        -- Drag/resize handle: the title strip above the dropdown row. The
        -- right edge stays clear of the close / size-down buttons.
        local drag = CreateFrame("Frame", nil, WorldMapFrame)
        drag:SetPoint("TOPLEFT", WorldMapPositioningGuide, "TOPLEFT", 0, 0)
        drag:SetPoint("TOPRIGHT", WorldMapPositioningGuide, "TOPRIGHT", -120, 0)
        drag:SetHeight(30)
        drag:EnableMouse(true)
        drag:EnableMouseWheel(true)
        drag:Hide()

        local function Apply()
            if Windowized() then
                local db = FMDB()
                local s = db and db.scale or DEFAULT_SCALE
                WorldMapFrame:SetParent(UIParent)
                WorldMapFrame:SetWidth(FULLMAP_W)
                WorldMapFrame:SetHeight(FULLMAP_H)
                WorldMapFrame:SetScale(s)
                ApplyPosition()
                WorldMapFrame:SetMovable(true)
                WorldMapFrame:EnableKeyboard(false) -- WASD stays live
                -- Same panel-slot switch stock's advanced windowed mode
                -- uses: managed as a centered panel that tolerates others,
                -- instead of the UIParent-hiding "full" slot.
                SetPanelSlot("center", true)
                BlackoutWorld:Hide()
                -- The window IS the only mode while the flag is on: the
                -- size-down button is hidden so the mini map is
                -- unreachable (ToggleSizeUp re-shows it every switch).
                if WorldMapFrameSizeDownButton then
                    WorldMapFrameSizeDownButton:Hide()
                end
                drag:Show()
                RefreshBlob()
            elseif WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
                drag:Hide()
                if Qol("fullMapWindow") then
                    -- Something still landed in mini mode (the persisted
                    -- miniWorldMap CVar at login, or the flag was turned
                    -- on while the mini map was active): clear the CVar
                    -- and size back up — that call re-enters Apply through
                    -- its hook and windowizes.
                    SetCVar("miniWorldMap", 0)
                    if type(WorldMap_ToggleSizeUp) == "function" then
                        WorldMap_ToggleSizeUp()
                    end
                end
            else
                -- Flag turned off while fullscreen: faithfully redo the
                -- shell bits of WorldMap_ToggleSizeUp.
                drag:Hide()
                WorldMapFrame:SetParent(nil)
                WorldMapFrame:ClearAllPoints()
                WorldMapFrame:SetAllPoints()
                WorldMapFrame:SetScale(1)
                if type(SetupFullscreenScale) == "function"
                    and WorldMapFrame:IsShown() then
                    SetupFullscreenScale(WorldMapFrame)
                end
                WorldMapFrame:SetMovable(false)
                WorldMapFrame:EnableKeyboard(true)
                SetPanelSlot("full", false)
                BlackoutWorld:Show()
                if WorldMapFrameSizeDownButton then
                    WorldMapFrameSizeDownButton:Show()
                end
                RefreshBlob()
            end
        end
        ApplyFullMapWindow = Apply

        drag:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" or not Windowized() then return end
            WorldMapFrame:StartMoving()
        end)
        drag:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" or not Windowized() then return end
            WorldMapFrame:StopMovingOrSizing()
            SavePosition()
            ApplyPosition() -- normalize back to the saved CENTER anchor
            RefreshBlob()
        end)
        -- Shared by the mousewheel handler and the settings-window field
        -- (RefactorUI): clamp, keep the window centered where it is, and
        -- re-scale in place. A no-op scale write while not windowized still
        -- saves so the value takes effect next time the window opens.
        local function SetScale(s)
            local db = FMDB()
            if not db then return end
            if s < MIN_SCALE then s = MIN_SCALE end
            if s > MAX_SCALE then s = MAX_SCALE end
            if Windowized() then
                SavePosition()
                db.scale = s
                WorldMapFrame:SetScale(s)
                ApplyPosition()
                RefreshBlob()
            else
                db.scale = s
            end
        end

        drag:SetScript("OnMouseWheel", function(self, delta)
            if not Windowized() then return end
            local db = FMDB()
            if not db then return end
            SetScale((db.scale or DEFAULT_SCALE) + delta * 0.05)
        end)

        RefactorFullMapShared = {
            GetScale = function()
                local db = FMDB()
                return (db and db.scale) or DEFAULT_SCALE
            end,
            SetScale = SetScale,
            MIN_SCALE = MIN_SCALE,
            MAX_SCALE = MAX_SCALE,
            -- The real WoW frame scale at the "1.0" mark shown in the UI —
            -- everything there is actual-scale / BASE_SCALE, so the default
            -- reads as a clean 1.0 instead of the raw 0.85.
            BASE_SCALE = DEFAULT_SCALE,
        }

        -- ToggleSizeUp rebuilds the fullscreen shell (and re-shows the
        -- blackout) on every size switch; OnShow covers plain opens plus
        -- the stock SetupFullscreenScale that runs just before this hook;
        -- ToggleSizeDown needs the scale cleanup above.
        hooksecurefunc("WorldMap_ToggleSizeUp", Apply)
        hooksecurefunc("WorldMap_ToggleSizeDown", Apply)
        WorldMapFrame:HookScript("OnShow", Apply)

        -- The panel slot must be right BEFORE the first ShowUIPanel, not
        -- fixed up during it (OnShow is too late — a "full" open has
        -- already hidden UIParent by then). Apply now with default flags,
        -- and again at PLAYER_ENTERING_WORLD once the saved flag is
        -- readable; the map can't be opened before that fires.
        Apply()
        local loader = CreateFrame("Frame")
        loader:RegisterEvent("PLAYER_ENTERING_WORLD")
        loader:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            Apply()
        end)
    end
end

--------------------------------------------------------------------------
-- Seamless bag upgrade. Right-clicking a bag while all 4 bag slots are
-- full normally just errors ("no free bag slot"). When the flag is on we
-- instead: find the equipped bag with the fewest slots, relocate its
-- contents into free slots elsewhere, equip the new bag in its place, and
-- park the now-empty old bag in the slot that was freed up.
--
-- Every step that touches an item slot (PickupContainerItem,
-- PickupInventoryItem) is a server round trip: the slots involved go
-- "locked" until the server confirms, and issuing the next pickup before
-- that resolves desyncs the cursor. So this runs as a single-item-at-a-time
-- queue driven by BAG_UPDATE/ITEM_LOCK_CHANGED, never more than one
-- in-flight swap.
--------------------------------------------------------------------------

do
    local bu = nil -- non-nil while a swap sequence is in flight
    local buFrame = CreateFrame("Frame")
    local BU_TIMEOUT = 8 -- seconds; a slot that never unlocks means the server rejected the move

    local function SlotLocked(bag, slot)
        return select(3, GetContainerItemInfo(bag, slot)) and true or false
    end

    local function SlotEmpty(bag, slot)
        return GetContainerItemLink(bag, slot) == nil
    end

    local function ItemFamily(link)
        return (link and GetItemFamily(link)) or 0
    end

    -- A destination slot in `bag` can take `itemFamily` if the bag is a
    -- plain bag (family 0, including the backpack) or the families overlap
    -- bitwise (soul bags, quivers, herb bags, etc).
    local function FamilyFits(bagFamily, itemFamily)
        return bagFamily == 0 or itemFamily == 0 or bit.band(bagFamily, itemFamily) ~= 0
    end

    local function StopBagUpgrade(errMsg)
        if errMsg then UIErrorsFrame:AddMessage(errMsg, 1, 0.1, 0.1) end
        bu = nil
        buFrame:UnregisterEvent("BAG_UPDATE")
        buFrame:UnregisterEvent("ITEM_LOCK_CHANGED")
        buFrame:SetScript("OnUpdate", nil)
    end

    local function StepBagUpgrade()
        if not bu then return end

        if bu.phase == "moving" then
            local mv = bu.moves[1]
            if not mv then
                bu.phase = "equip"
                return StepBagUpgrade()
            end
            if SlotEmpty(mv.fromBag, mv.fromSlot) then
                table.remove(bu.moves, 1) -- this move already landed
                return StepBagUpgrade()
            end
            if SlotLocked(mv.fromBag, mv.fromSlot) or SlotLocked(mv.toBag, mv.toSlot) then
                return -- still resolving the previous pickup, wait for the next event
            end
            PickupContainerItem(mv.fromBag, mv.fromSlot)
            PickupContainerItem(mv.toBag, mv.toSlot)
            return

        elseif bu.phase == "equip" then
            if GetInventoryItemLink("player", bu.targetInvSlot) ~= bu.oldBagLink then
                -- old bag link changed: the equip swap already landed
                bu.phase = "park"
                return StepBagUpgrade()
            end
            if CursorHasItem() then return end
            if SlotLocked(bu.newBag, bu.newSlot) then return end
            PickupContainerItem(bu.newBag, bu.newSlot) -- new bag onto cursor
            -- Bag-slot equips need the dedicated PutItemInBag, not the
            -- generic PickupInventoryItem swap Blizzard uses for gear slots
            -- (PickupInventoryItem left the old bag stuck on the cursor
            -- instead of swapping it back — it isn't the right API for bag
            -- slots specifically, only for stock equipment slots).
            PutItemInBag(bu.targetInvSlot) -- equips it; old (now-empty) bag replaces cursor
            return

        elseif bu.phase == "park" then
            if not CursorHasItem() then
                StopBagUpgrade() -- nothing left on cursor: the old bag already auto-stacked/placed
                return
            end
            if SlotLocked(0, bu.parkSlot) or not SlotEmpty(0, bu.parkSlot) then
                return
            end
            PickupContainerItem(0, bu.parkSlot)
            StopBagUpgrade()
        end
    end

    buFrame:SetScript("OnEvent", StepBagUpgrade)

    -- Fallback watchdog: if nothing resolves within BU_TIMEOUT, the server
    -- rejected a move (e.g. bag went missing mid-sequence). Bail instead of
    -- hanging silently; whatever already moved stays where it landed.
    local buElapsed = 0
    local function BuWatchdog(_, elapsed)
        buElapsed = buElapsed + elapsed
        if buElapsed > BU_TIMEOUT then
            buElapsed = 0
            StopBagUpgrade("Refactor: bag upgrade timed out, aborting.")
        end
    end

    local function StartBagUpgrade(state)
        bu = state
        buElapsed = 0
        buFrame:RegisterEvent("BAG_UPDATE")
        buFrame:RegisterEvent("ITEM_LOCK_CHANGED")
        buFrame:SetScript("OnUpdate", BuWatchdog)
        StepBagUpgrade()
    end

    -- Called from a hooksecurefunc after the real UseContainerItem already
    -- ran (see below) — the boolean return is only used internally, for the
    -- early-return guards below to short-circuit each other.
    local function TryBagUpgrade(bag, slot)
        if not Qol("seamlessBagUpgrade") then return false end
        if bu then return false end -- a sequence is already running
        -- Smart equip (RefactorCompare) may be mid-swap on its own
        -- PickupContainerItem sequence; two concurrent shuffles desync
        -- the cursor. Each side checks the other before arming.
        local cs = RefactorCompareShared
        if cs and cs.SmartEquipActive and cs.SmartEquipActive() then
            return false
        end
        if InCombatLockdown() then return false end
        if BankFrame and BankFrame:IsShown() then return false end -- right-click there means bank deposit/equip
        if MerchantFrame and MerchantFrame:IsShown() then return false end -- right-click there means sell to vendor

        local link = GetContainerItemLink(bag, slot)
        if not link then return false end
        local _, _, _, _, _, itemType, _, _, equipLoc = GetItemInfo(link)
        if itemType ~= "Container" or equipLoc ~= "INVTYPE_BAG" then return false end

        -- Only step in when Blizzard's own equip would fail (no free bag slot).
        for bagID = 1, NUM_BAG_SLOTS do
            if GetContainerNumSlots(bagID) == 0 then return false end
        end

        local newItemID = tonumber(link:match("item:(%d+)"))
        for bagID = 1, NUM_BAG_SLOTS do
            local invSlot = ContainerIDToInventoryID(bagID)
            if GetInventoryItemID("player", invSlot) == newItemID then
                UIErrorsFrame:AddMessage("You already have that bag equipped.", 1, 0.1, 0.1)
                return true
            end
        end

        -- Equipped bag with the fewest slots is the one being replaced.
        local targetBag, targetSlots
        for bagID = 1, NUM_BAG_SLOTS do
            local n = GetContainerNumSlots(bagID)
            if not targetSlots or n < targetSlots then
                targetBag, targetSlots = bagID, n
            end
        end
        if not targetBag then return false end

        -- Plan moves for every item in targetBag, dry-run first so a
        -- shortfall aborts before anything actually moves.
        local freeSlots = {} -- {bag, slot, family} for every empty slot outside targetBag
        for bagID = 0, NUM_BAG_SLOTS do
            if bagID ~= targetBag then
                local bagFamily = 0
                if bagID > 0 then
                    bagFamily = ItemFamily(GetInventoryItemLink("player", ContainerIDToInventoryID(bagID)))
                end
                for s = 1, GetContainerNumSlots(bagID) do
                    if SlotEmpty(bagID, s) then
                        table.insert(freeSlots, { bag = bagID, slot = s, family = bagFamily })
                    end
                end
            end
        end

        -- A bag can only be unequipped once it is completely empty, so the
        -- new bag itself must be moved out too if it's sitting inside the
        -- one being replaced — track where it lands so the equip step below
        -- picks it up from its new home instead of its original slot.
        local newBag, newSlot = bag, slot
        local moves, usedFree = {}, {}
        local ok = true
        for s = 1, targetSlots do
            local itemLink = GetContainerItemLink(targetBag, s)
            if itemLink then
                local family = ItemFamily(itemLink)
                local dest
                for i, free in ipairs(freeSlots) do
                    if not usedFree[i] and FamilyFits(free.family, family) then
                        dest, usedFree[i] = free, true
                        break
                    end
                end
                if not dest then ok = false break end
                table.insert(moves, { fromBag = targetBag, fromSlot = s, toBag = dest.bag, toSlot = dest.slot })
                if targetBag == bag and s == slot then
                    newBag, newSlot = dest.bag, dest.slot
                end
            end
        end

        -- Reserve one more free slot to park the old bag once it's emptied.
        local parkSlot
        if ok then
            for i, free in ipairs(freeSlots) do
                if not usedFree[i] and free.bag == 0 then
                    parkSlot, usedFree[i] = free.slot, true
                    break
                end
            end
            if not parkSlot then ok = false end
        end

        if not ok then
            UIErrorsFrame:AddMessage("Not enough free bag space to swap in that bag.", 1, 0.1, 0.1)
            return true
        end

        StartBagUpgrade({
            phase = "moving",
            moves = moves,
            targetBag = targetBag,
            targetInvSlot = ContainerIDToInventoryID(targetBag),
            oldBagLink = GetInventoryItemLink("player", ContainerIDToInventoryID(targetBag)),
            newBag = newBag,
            newSlot = newSlot,
            parkSlot = parkSlot,
        })
        return true
    end

    -- Smart equip (RefactorCompare) checks this before arming its own
    -- item shuffle — see the matching guard in TryBagUpgrade above.
    RefactorQoL.BagShuffleActive = function() return bu ~= nil end

    -- Reacting via hooksecurefunc (not replacing the global) keeps every
    -- other UseContainerItem call — eating food, opening lockboxes, using
    -- trinkets from bags — untainted. Replacing the global directly used to
    -- put an addon-defined function in the call path for ALL of those too,
    -- and Blizzard flags that as taint even for calls TryBagUpgrade itself
    -- ignores. The tradeoff: when Blizzard's own equip attempt can't work
    -- (no free bag slot), its failure message shows for an instant before
    -- this hook's shuffle-and-retry takes over, instead of being preempted.
    hooksecurefunc("UseContainerItem", function(bag, slot)
        TryBagUpgrade(bag, slot)
    end)
end

