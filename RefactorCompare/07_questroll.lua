local C = RefactorCompareInternal
local Print = C.Print
local CompareItem = C.CompareItem
local ScanItem = C.ScanItem
local SLOTS_FOR_INVTYPE = C.SLOTS_FOR_INVTYPE
local SetArrowAtlas = C.SetArrowAtlas

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

-- Arrow sits on the icon's top-right corner (matches the bag-slot arrow);
-- the coin marker below stays top-left, clear of it.
local function GetQuestArrow(button)
    local arrow = button.refactorQuestArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", QuestItemIcon(button), "TOPRIGHT", 2, 2)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
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

-- QuestInfo_Display fires on every quest-pane redraw, not just when
-- rewards actually change (accept/decline/gossip clicks re-run it too).
-- Cheaply fingerprint the shown reward/choice links first; if unchanged
-- since the last COMPLETE pass, skip the scan loop entirely. Reset to
-- force a rebuild whenever markers get hidden outright (disabled, or no
-- quest frame) so re-enabling always redraws instead of trusting a stale
-- fingerprint from before the hide.
local lastQuestSig, lastQuestComplete = "", false

local function QuestRewardSig(qlog)
    local parts = {}
    for i = 1, MAX_QUEST_ITEMS do
        local button = _G["QuestInfoItem" .. i]
        if button and button:IsShown()
            and (button.type == "choice" or button.type == "reward") then
            local idx = button:GetID()
            local link = qlog and GetQuestLogItemLink(button.type, idx)
                or GetQuestItemLink(button.type, idx)
            parts[#parts + 1] = button.type .. idx .. ":" .. tostring(link)
        end
    end
    return table.concat(parts, "|")
end

-- Recomputes every visible reward button. Returns false when some item
-- wasn't ready yet (not in the client cache / tooltip scan failed) so the
-- caller schedules a retry — reward data often trails the frame opening.
local function UpdateQuestRewardsNow()
    if not (RefactorCompareDB and RefactorCompareDB.enabled and QuestInfoFrame) then
        for i = 1, MAX_QUEST_ITEMS do
            local button = _G["QuestInfoItem" .. i]
            if button then HideQuestMarkers(button) end
        end
        lastQuestSig, lastQuestComplete = "", false
        return true
    end

    local qlog = QuestInfoFrame.questLog and true or false

    -- A retry (scan/CompareItem still pending) must always re-run even
    -- though the links themselves haven't changed, so the skip only
    -- applies once a prior pass has fully resolved.
    local sig = QuestRewardSig(qlog)
    if lastQuestComplete and sig == lastQuestSig then
        return true
    end

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
            -- One GetItemInfo call per button (this runs inside a retry
            -- loop): name gates readiness, equipLoc routes the verdict,
            -- sellPrice feeds the coin marker (nil on stock 3.3.5 — the
            -- 11th return is 4.0+, kept in case Ascension backported it).
            local name, equipLoc, sellPrice
            if link then
                local n, _, _, _, _, _, _, _, e, _, sp = GetItemInfo(link)
                name, equipLoc, sellPrice = n, e, sp
            end
            if not name then
                complete = false
            else
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
                    -- No sellPrice from GetItemInfo: fall back to the money
                    -- line scanned off the reward tooltip itself.
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

    if RefactorCompareDB.debug then
        Print("quest rewards updated (log=" .. tostring(qlog)
            .. ", choices=" .. choiceCount
            .. ", bestValue=" .. bestValue
            .. (complete and ")" or ", retrying)"))
    end
    lastQuestSig, lastQuestComplete = sig, complete
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

-- QuestInfo_ShowRewards runs INSIDE QuestInfo_Display's element loop, and
-- the display code reparents the shared rewards frame to the calling pane
-- only AFTER the element function returns — so at hook time a check on the
-- rewards CONTAINER's IsVisible() still walks up through the PREVIOUS
-- pane's parent chain, usually a hidden one (this is why the world map's
-- reward pane never got markers: the container looked invisible from here
-- every time). UpdateQuestRewardsNow sidesteps that by never asking the
-- container anything — it reads each QuestInfoItemN button's own IsShown()
-- flag instead, which stock code sets directly (Show/Hide per button in
-- QuestInfo_ShowRewards) and which isn't affected by the pane's SetParent
-- happening later in the same call.
function C.UpdateQuestRewards()
    if UpdateQuestRewardsNow() then
        questRetryFrame:Hide()
    else
        questRetriesLeft = 8
        questRetryElapsed = 0
        questRetryFrame:Show()
    end
end

-- Hooking QuestInfo_ShowRewards directly doesn't work: every
-- QUEST_TEMPLATE_*.elements table stores a bare reference to that
-- function, frozen when QuestInfo.lua's templates were built (core
-- FrameXML, long before this addon loads). hooksecurefunc only rebinds
-- the global NAME to a wrapper — it can't reach into those already-built
-- tables and swap the value they hold, so QuestInfo_Display's element
-- loop keeps calling the untouched original and our hook never fires
-- (confirmed live: no debug print, no marker, on quest log/map alike).
-- QuestInfo_Display itself is safe to hook because every real call site
-- invokes it by bare global name, which Lua re-resolves through the
-- global table each time — that's what hooksecurefunc can actually
-- intercept. It runs for every quest pane (detail dialog, quest log,
-- map), reward elements or not, so re-scanning after each call is cheap
-- and always reflects the current button state.
if type(QuestInfo_Display) == "function" then
    hooksecurefunc("QuestInfo_Display", C.UpdateQuestRewards)
end

--------------------------------------------------------------------------
-- Loot-roll upgrade markers
--------------------------------------------------------------------------

-- Green arrow on a group-loot roll frame's item icon when the rolled item
-- is an upgrade — same promise as the bag/quest arrows, same trust rules
-- (live SetLootRollItem scan via CompareItem's roll src, never approx).
-- Roll item data trails the frame opening (and the first scans can be
-- stale-armor discards), so this retries on a timer like the quest-reward
-- markers do; roll frames stay up for the whole roll window, so the retry
-- budget is generous.

local NUM_ROLL_FRAMES = NUM_GROUP_LOOT_FRAMES or 4

local function GetRollArrow(frame)
    local arrow = frame.refactorRollArrow
    if not arrow then
        local anchor = _G[frame:GetName() .. "IconFrame"] or frame
        arrow = anchor:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 2, 2)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        frame.refactorRollArrow = arrow
    end
    return arrow
end

-- Recomputes every visible roll frame. Returns false when some roll's
-- item wasn't readable yet so the caller keeps retrying.
local function UpdateRollFramesNow()
    local complete = true
    for i = 1, NUM_ROLL_FRAMES do
        local frame = _G["GroupLootFrame" .. i]
        if frame then
            local show = false
            if frame:IsShown() and frame.rollID and RefactorCompareDB and RefactorCompareDB.enabled then
                local link = GetLootRollItemLink
                    and GetLootRollItemLink(frame.rollID)
                -- One GetItemInfo call per frame per retry tick, not two.
                local name, equipLoc
                if link then
                    local n, _, _, _, _, _, _, _, e = GetItemInfo(link)
                    name, equipLoc = n, e
                end
                if not name then
                    complete = false
                else
                    if equipLoc and SLOTS_FOR_INVTYPE[equipLoc] then
                        local result = CompareItem(link, nil, nil, nil,
                            { roll = frame.rollID })
                        if not result then
                            -- Scan pending / stale-armor discard: retry.
                            -- (Quality-filtered gear lands here too; the
                            -- retry cap keeps that harmless.)
                            complete = false
                        elseif not result.approx
                            and (result.status == "upgrade"
                                or result.status == "empty") then
                            show = true
                        end
                    end
                end
            end
            if show then
                GetRollArrow(frame):Show()
            elseif frame.refactorRollArrow then
                frame.refactorRollArrow:Hide()
            end
        end
    end
    return complete
end

local rollRetryFrame = CreateFrame("Frame")
rollRetryFrame:Hide()
local rollRetryElapsed, rollRetriesLeft = 0, 0
rollRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    rollRetryElapsed = rollRetryElapsed + elapsed
    if rollRetryElapsed < 0.25 then return end
    rollRetryElapsed = 0
    rollRetriesLeft = rollRetriesLeft - 1
    if UpdateRollFramesNow() or rollRetriesLeft <= 0 then
        self:Hide()
    end
end)

function C.StartRollUpdates()
    if UpdateRollFramesNow() then
        rollRetryFrame:Hide()
    else
        rollRetriesLeft = 20 -- 5s of retries; rolls stay up far longer
        rollRetryElapsed = 0
        rollRetryFrame:Show()
    end
end
