-- Refactor: quest automation
-- Auto-accept, auto turn-in, auto-pick from gossip menus, and auto-pick the
-- best reward choice. Hold Shift while talking to an NPC for the normal
-- quest windows.

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

--------------------------------------------------------------------------
-- Reward auto-pick
--
-- Picking a quest reward is IRREVERSIBLE, so this is the strictest consumer
-- of the compare trust contract in the addon: it acts only when every
-- reward was scored from a live instance scan (SetQuestItem, the scaled
-- copy the server is actually offering), and stays out of the way — window
-- left open, nothing clicked — on any ambiguity at all: an unreadable
-- reward, a bare-link (approx) score, an exact tie, or a reward the
-- secondary profile wants. Holding Shift at any point during the wait
-- cancels it, and every pick prints what it took and why.
--
-- Ranking uses result.gain (absolute weighted-score difference), NOT pct:
-- percentages are relative to what's in that slot, so a +50% ring can be
-- worth far fewer stats than a +10% two-hander, and comparing DIFFERENT
-- items is exactly what this does.
--------------------------------------------------------------------------

local REWARD_TIMEOUT = 3.0  -- how long to wait for the client to render rewards
local REWARD_POLL = 0.15    -- seconds between attempts while waiting
local EPSILON = 1e-6

local rewardTip = CreateFrame("GameTooltip", "RefactorQuestRewardTip",
    UIParent, "GameTooltipTemplate")

-- Sell value of a reward choice, in copper, for the whole stack.
-- Preferred source is the reward tooltip's own money frame: SetQuestItem
-- renders the scaled instance, so that price is the real one (GetItemInfo's
-- 11th return is the BASE item's, which Ascension scaling detaches from the
-- copy on offer — see CLAUDE.md). The base price is kept only as a fallback
-- for tooltips that render no money line at all. Either way it's a per-item
-- price, so multiply by the reward's stack count.
local function RewardValue(index)
    local unit
    rewardTip:SetOwner(UIParent, "ANCHOR_NONE")
    rewardTip:ClearLines()
    if GameTooltip_ClearMoney then GameTooltip_ClearMoney(rewardTip) end
    rewardTip:SetQuestItem("choice", index)
    local money = _G["RefactorQuestRewardTipMoneyFrame1"]
    if money and money:IsShown() and type(money.staticMoney) == "number" then
        unit = money.staticMoney
    else
        local link = GetQuestItemLink and GetQuestItemLink("choice", index)
        unit = link and select(11, GetItemInfo(link)) or nil
    end
    if not unit then return 0 end
    local count = select(3, GetQuestItemInfo("choice", index)) or 1
    if count < 1 then count = 1 end
    return unit * count
end

-- Returns index, reason ("upgrade"/"gold") when a pick is safe;
-- nil, "wait" when reward data isn't rendered yet (caller retries);
-- nil when the choice belongs to the player.
-- Every abort path here is deliberately silent in normal play, which makes
-- "it did nothing" indistinguishable between six different reasons — so
-- each one says which it was under /rfc debug.
local function Dbg(fmt, ...)
    if not DebugOn() then return end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor debug:|r reward " ..
        (select("#", ...) > 0 and fmt:format(...) or fmt))
end

local function BestReward()
    local n = GetNumQuestChoices() or 0
    if n < 2 then Dbg("choices=%d, nothing to decide", n) return nil end
    -- Gear comparison lives in the separate Refactor Gear addon; read its
    -- shared table at use time, never at load (addon order isn't ours).
    local cmp = RefactorGearShared
    -- The gear half of the decision is the whole point; without the compare
    -- addon there's no upgrade test, and picking purely on gold would
    -- happily vendor an upgrade.
    if not cmp then Dbg("Refactor Gear addon not installed") return nil end
    if not cmp.IsEnabled() then Dbg("gear comparison is disabled") return nil end

    local bestIdx, bestGain, tiedUpgrade
    local secondaryWants, secondaryIdx = false, {}
    local values = {}

    for i = 1, n do
        local link = GetQuestItemLink and GetQuestItemLink("choice", i)
        if not link then Dbg("#%d: no item link yet", i) return nil, "wait" end
        local gear = cmp.IsGear(link) -- nil = item data not cached yet
        if gear == nil then Dbg("#%d: %s not cached yet", i, link) return nil, "wait" end
        if not gear then Dbg("#%d: %s is not gear", i, link) end
        if gear then
            local r = cmp.CompareItem(link, nil, nil, nil,
                { type = "choice", index = i })
            if not r then
                Dbg("#%d: %s unreadable (no verdict)", i, link)
                return nil, "wait" -- retry, never guess
            end
            Dbg("#%d: %s status=%s gain=%s pct=%s approx=%s", i, link,
                tostring(r.status), tostring(r.gain), tostring(r.pct),
                tostring(r.approx))
            if r.approx then
                Dbg("#%d: scored from a bare link, not actionable", i)
                return nil -- base-item score: not actionable
            end
            if (r.status == "upgrade" or r.status == "empty") and r.gain then
                if not bestGain or r.gain > bestGain + EPSILON then
                    bestIdx, bestGain, tiedUpgrade = i, r.gain, false
                elseif math.abs(r.gain - bestGain) <= EPSILON then
                    tiedUpgrade = true
                end
            end
            -- "The secondary profile wants this" has to mean a REAL upgrade
            -- for it: a plain pct upgrade, or a genuinely empty slot. NOT
            -- zeroBaseline "empty", which only says the secondary profile
            -- puts no value on what's currently worn (sparse profiles hit
            -- that constantly — see CLAUDE.md) and is no evidence at all
            -- about this item. Counting it made every gear quest ambiguous
            -- and the feature never fired.
            local sec = r.secondary
            if sec and (sec.status == "upgrade"
                or (sec.status == "empty" and not sec.zeroBaseline)) then
                secondaryWants = true
                secondaryIdx[i] = true
                Dbg("#%d: secondary profile rates this an upgrade", i)
            end
        end
        values[i] = RewardValue(i)
        Dbg("#%d: sell value %s copper", i, tostring(values[i]))
    end

    if bestIdx then
        -- Two rewards worth exactly the same: they're different items with
        -- the same score, and which one fits the player's plans isn't
        -- something weights can answer.
        if tiedUpgrade then Dbg("upgrades tied on gain, leaving it to you") return nil end
        return bestIdx, "upgrade"
    end

    local goldIdx, goldValue, goldTied
    for i = 1, n do
        local v = values[i] or 0
        if not goldValue or v > goldValue then
            goldIdx, goldValue, goldTied = i, v, false
        elseif v == goldValue then
            goldTied = true
        end
    end

    -- Nothing the active profile wants. A reward the SECONDARY profile wants
    -- is a real decision (off-spec set, different role), so hand it back
    -- rather than vendoring it for coin — unless the coin pick IS that
    -- reward, in which case taking it serves both and there's nothing to
    -- decide. (Checked after the gold winner is known, for exactly that.)
    if secondaryWants and not (goldIdx and secondaryIdx[goldIdx]) then
        Dbg("no upgrade for the active profile, but the secondary profile wants"
            .. " a different reward than the gold pick")
        return nil
    end

    if not goldIdx or goldValue <= 0 or goldTied then
        Dbg("no upgrade; gold pick declined (best=%s value=%s tied=%s)",
            tostring(goldIdx), tostring(goldValue), tostring(goldTied))
        return nil
    end
    return goldIdx, "gold"
end

local function RewardName(index)
    local link = GetQuestItemLink and GetQuestItemLink("choice", index)
    return (link and link:match("%[(.-)%]"))
        or select(1, GetQuestItemInfo("choice", index))
        or ("reward " .. index)
end

local resolver = CreateFrame("Frame")
resolver:Hide()
local waited, sincePoll, questTitle

local function TakeReward(index, reason)
    local name = RewardName(index)
    GetQuestReward(index)
    if reason == "gold" then
        local worth = RewardValue(index)
        local coin = GetCoinTextureString and worth > 0
            and GetCoinTextureString(worth) or nil
        Announce("took |cffffffff" .. name .. "|r — no upgrade among the rewards"
            .. (coin and (", highest sell value (" .. coin .. ")") or
                ", highest sell value") .. ".")
    else
        Announce("took |cffffffff" .. name .. "|r — best upgrade among the rewards.")
    end
end

resolver:SetScript("OnUpdate", function(self, elapsed)
    waited = waited + elapsed
    -- Shift is the manual override for every quest step, including this
    -- one: grabbing it mid-wait calls the whole thing off.
    local cancel
    if IsShiftKeyDown() then cancel = "Shift held"
    elseif not Qol("questAutoReward") then cancel = "flag off"
    elseif QuestFrame and not QuestFrame:IsShown() then cancel = "QuestFrame not shown"
    elseif GetTitleText and questTitle and GetTitleText() ~= questTitle then
        cancel = "quest changed ('" .. tostring(GetTitleText()) .. "' vs '"
            .. questTitle .. "')"
    end
    if cancel then
        Dbg("cancelled: %s", cancel)
        self:Hide()
        return
    end
    -- Quest-source scans are never memoized (they carry their own retry
    -- semantics), so each attempt re-renders every reward tooltip: poll,
    -- don't spin per frame.
    sincePoll = sincePoll + elapsed
    if sincePoll < REWARD_POLL then return end
    sincePoll = 0
    local index, reason = BestReward()
    if index then
        self:Hide()
        TakeReward(index, reason)
    elseif reason == "wait" and waited >= REWARD_TIMEOUT then
        Dbg("timed out after %.1fs waiting for reward data", waited)
        self:Hide()
    elseif reason ~= "wait" then
        -- Either the decision is the player's, or the client never rendered
        -- the rewards in time. Both mean: leave the window open, click nothing.
        self:Hide()
    end
end)

local function ArmRewardPick()
    waited, sincePoll = 0, REWARD_POLL
    questTitle = GetTitleText and GetTitleText() or nil
    Dbg("armed for '%s' (%d choices)", tostring(questTitle),
        GetNumQuestChoices() or 0)
    resolver:Show()
end

quest:RegisterEvent("QUEST_FINISHED")

quest:SetScript("OnEvent", function(self, event, arg1)
    if event == "QUEST_FINISHED" then
        resolver:Hide()
        return
    end

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
        resolver:Hide() -- a new completion window supersedes any pending pick
        local choices = GetNumQuestChoices() or 0
        if choices <= 1 then
            -- Zero or one reward choice: nothing to decide.
            if Qol("questTurnIn") then GetQuestReward(choices) end
        elseif not Qol("questAutoReward") then
            Dbg("QUEST_COMPLETE with %d choices, but auto-pick is off", choices)
        else
            -- Multiple choices: the reward picker decides, or leaves the
            -- window open. Deliberately independent of auto turn-in — it
            -- also applies to quests handed in by hand.
            ArmRewardPick()
        end
    end
end)
