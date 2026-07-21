-- Refactor: quest automation
-- Auto-accept, auto turn-in, auto-pick from gossip menus. Hold Shift while
-- talking to an NPC for the normal quest windows.

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
