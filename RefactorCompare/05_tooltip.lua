local C = RefactorCompareInternal
local CompareItem = C.CompareItem
local CharKey = C.CharKey

--------------------------------------------------------------------------
-- Tooltip line
--------------------------------------------------------------------------

-- The verdict used to be a floating overlay pinned to the tooltip's
-- top-right corner, tinted via SetVertexColor/SetTextColor. On a long
-- item name that overlay sits on top of the title text: the corner
-- position is fixed while the title (left-anchored, natural width) can
-- reach all the way to the frame edge. The fix isn't "make the frame
-- wider" — tooltip:SetWidth() after OnTooltipSetItem doesn't stick, the
-- client recomputes width from its own lines and discards it. The only
-- resize that's reliable is adding a genuine line via AddLine/
-- AddDoubleLine, since that's native content the client sizes for. So
-- the verdict is now its own tooltip line instead of an overlay:
-- guaranteed to never collide with anything else, at the cost of the
-- compact corner-badge look. Direction is still unambiguous — sign on
-- the percentage plus red/green — even without the arrow icon.
local ARROW_TEXTURE = "Interface\\AddOns\\Refactor\\arrow" -- fallback texture asset
local LOOT_TOAST_ATLAS = "Interface\\LootFrame\\LootToastAtlas"

local ATLAS_COORDS = {
    ["loottoast-arrow-green"] = { left = 0.858398, right = 0.878906, top = 0.158203, bottom = 0.207031 },
    ["loottoast-arrow-blue"]  = { left = 0.835938, right = 0.856445, top = 0.158203, bottom = 0.207031 },
    ["loottoast-arrow-red"]   = { left = 0.878906, right = 0.899414, top = 0.158203, bottom = 0.207031 },
}

local function SetArrowAtlas(arrow, atlasName, fallbackR, fallbackG, fallbackB, flipY)
    local coords = ATLAS_COORDS[atlasName] or ATLAS_COORDS["loottoast-arrow-green"]
    if coords then
        if arrow:SetTexture(LOOT_TOAST_ATLAS) then
            local top = flipY and coords.bottom or coords.top
            local bottom = flipY and coords.top or coords.bottom
            arrow:SetTexCoord(coords.left, coords.right, top, bottom)
            if arrow.SetDesaturated then arrow:SetDesaturated(false) end
            if fallbackR and fallbackG and fallbackB then
                arrow:SetVertexColor(fallbackR, fallbackG, fallbackB)
            else
                arrow:SetVertexColor(1, 1, 1)
            end
            return true
        end
    end
    if arrow.SetAtlas then
        local ok = pcall(arrow.SetAtlas, arrow, atlasName)
        if ok then
            if arrow.SetDesaturated then arrow:SetDesaturated(false) end
            if fallbackR and fallbackG and fallbackB then
                arrow:SetVertexColor(fallbackR, fallbackG, fallbackB)
            else
                arrow:SetVertexColor(1, 1, 1)
            end
            arrow:SetTexCoord(0, 1, flipY and 1 or 0, flipY and 0 or 1)
            return true
        end
    end
    if arrow:SetTexture(ARROW_TEXTURE) then
        if arrow.SetDesaturated then arrow:SetDesaturated(false) end
        arrow:SetTexCoord(0, 1, flipY and 1 or 0, flipY and 0 or 1)
        arrow:SetVertexColor(fallbackR or 0, fallbackG or 1, fallbackB or 0)
        return true
    else
        arrow:SetTexture(fallbackR or 0, fallbackG or 1, fallbackB or 0, 0.9)
        return false
    end
end

-- Secondary-profile verdict color: one hue for everything secondary (text,
-- tooltip arrow, bag arrow, up and down) — color identifies the PROFILE,
-- arrow direction carries the verdict. Blue stays clear of the primary
-- green/red, the gold "even" text, and the quest-reward gold coin.
local SEC_R, SEC_G, SEC_B = 0.35, 0.65, 1

-- Anchors a tinted arrow texture just left of the given fontstring. Anchored
-- to that specific text (not the tooltip frame corner, as the old overlay
-- was) so it can never collide with a long item title above it. `down`
-- flips the (up-pointing) source art vertically for the downgrade case —
-- there's only the one arrow.tga asset, no separate down/red variant.
-- field picks which tooltip texture slot to use (the secondary verdict gets
-- its own so both can be visible at once).
local function ShowLineArrow(tooltip, fontString, r, g, b, down, field, offset)
    if not fontString then return end
    field = field or "refactorLineArrow"
    local arrow = tooltip[field]
    if not arrow then
        arrow = tooltip:CreateTexture(nil, "OVERLAY")
        tooltip[field] = arrow
    end
    arrow:ClearAllPoints()

    if not down and b > 0.5 and r < 0.5 then
        SetArrowAtlas(arrow, "loottoast-arrow-blue", nil, nil, nil, false)
    elseif not down and g > 0.5 and r < 0.5 then
        SetArrowAtlas(arrow, "loottoast-arrow-green", nil, nil, nil, false)
    elseif down then
        -- Red downgrade arrow using LootToastAtlas sprite flipped vertically with red vertex tinting
        SetArrowAtlas(arrow, "loottoast-arrow-red", r, g, b, true)
    else
        SetArrowAtlas(arrow, "loottoast-arrow-green", r, g, b, false)
    end

    arrow:SetWidth(12)
    arrow:SetHeight(14)
    if offset then
        -- Negative inset from the fontstring's RIGHT edge: parks the arrow
        -- just left of the trailing % when a label leads the text ("Warden
        -- <arrow> +66%"). Measured from the right edge so the label/gap
        -- widths never have to be known.
        arrow:SetPoint("RIGHT", fontString, "RIGHT", offset, 0)
    else
        -- -2px clearance so the primary arrow aligns perfectly with the
        -- secondary arrow on the line below.
        arrow:SetPoint("RIGHT", fontString, "LEFT", -2, 0)
    end
    arrow:Show()
end

local function HideLineArrow(tooltip)
    if tooltip.refactorLineArrow then tooltip.refactorLineArrow:Hide() end
    if tooltip.refactorLineArrow2 then tooltip.refactorLineArrow2:Hide() end
end

-- Rows whose right column is reliably blank, tried in order so the verdict
-- lands in roughly the same place regardless of item type: Durability
-- covers weapons/armor, but plenty of gear (rings, trinkets, necks) has
-- none of those and only ever shows "Requires Level N" — which every
-- piece of equipment prints (even at level 1, per Blizzard's own tooltip
-- code), so it's the reliable second choice.
local ROW_PATTERNS = { "^Durability", "^Requires Level" }

-- Rides one of the rows above instead of adding a whole new line, so the
-- verdict sits in a consistent spot (mirrors how Blizzard already puts
-- weapon Speed in the right column of its own row). Returns the
-- right-column fontstring on success so the caller can anchor the arrow.
local function SetCompareRowText(tooltip, text, r, g, b)
    local name = tooltip:GetName()
    for _, pattern in ipairs(ROW_PATTERNS) do
        for i = 2, tooltip:NumLines() do
            local left = _G[name .. "TextLeft" .. i]
            local leftText = left and left:GetText()
            if leftText and leftText:match(pattern) then
                local right = _G[name .. "TextRight" .. i]
                if not right then return nil end
                right:SetText(text)
                right:SetTextColor(r, g, b)
                right:Show()
                return right, i
            end
        end
    end
    return nil
end

-- Places text in the right column of an EXISTING tooltip line, used to sit
-- the secondary verdict directly under the primary's row. Returns the
-- right-column fontstring, or nil when that line is absent or its right
-- column is already occupied (leave it be — caller falls back to AddLine).
local function SetRowRightTextAt(tooltip, i, text, r, g, b)
    if not i or i < 2 or i > tooltip:NumLines() then return nil end
    local right = _G[tooltip:GetName() .. "TextRight" .. i]
    if not right then return nil end
    local existing = right:GetText()
    if existing and existing ~= "" then return nil end
    right:SetText(text)
    right:SetTextColor(r, g, b)
    right:Show()
    return right
end

local function AddCompareLine(tooltip, link, bag, slot, invSlot, src)
    if not RefactorCompareDB or not RefactorCompareDB.enabled then return end
    local result = CompareItem(link, bag, slot, invSlot, src)
    if not result then return end

    HideLineArrow(tooltip)

    -- result.approx (scored from the base-item link, not the scaled copy)
    -- deliberately gets no visual marker — per user preference the verdict
    -- line looks the same either way. The flag still gates bag arrows and
    -- loot alerts, which estimates never earn.
    --
    -- No "Compare:" label anywhere (per user preference) — the up/down
    -- arrow carries that meaning instead, matching the bag/quest arrows.
    local text, r, g, b, arrowDir
    if result.status == "unusable" then
        local suffix = result.context and (" (" .. result.context .. ")") or ""
        text, r, g, b = "Can't equip" .. suffix, 1, 0.4, 0.4
    elseif result.status == "wrongarmor" then
        text, r, g, b = "Filtered armor type", 0.6, 0.6, 0.6
    elseif result.status == "empty" then
        text = result.zeroBaseline and "Equipped scores 0" or "Fills empty slot"
        r, g, b, arrowDir = 0, 1, 0, "up"
    elseif result.status == "even" then
        if result.zeroAll then
            -- Neither item scores under this profile: not parity, just
            -- irrelevance — quiet gray like the armor-filter notice.
            text, r, g, b = "No value", 0.6, 0.6, 0.6
        else
            text, r, g, b = "0%", 1, 0.82, 0
        end
    elseif result.status == "upgrade" then
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 0, 1, 0, "up"
    else
        text, r, g, b, arrowDir = string.format("%+.0f%%", result.pct), 1, 0.25, 0.25, "down"
    end

    -- Read BEFORE the measure-fontstring block below, which needs to know
    -- whether a secondary verdict is coming. Declaring it after that block
    -- (as this did originally) left the `or sec` test reading a nil GLOBAL,
    -- so a no-arrow primary ("even"/"unusable"/"wrongarmor") paired with an
    -- arrowed secondary skipped creating tooltip.refactorMeasure — and the
    -- label path below then indexed that nil. Only reachable on a tooltip
    -- that had never yet drawn an arrow (ItemRefTooltip / WorldMapTooltip
    -- stay cold far longer than GameTooltip), which is why it survived.
    local sec = result.secondary

    local w1, w2 = 0, 0
    if arrowDir or sec then
        if not tooltip.refactorMeasure then
            tooltip.refactorMeasure = tooltip:CreateFontString(nil, "OVERLAY", "GameTooltipText")
        end
        local measure = tooltip.refactorMeasure
        if arrowDir then
            measure:SetText(text)
            w1 = measure:GetStringWidth() or 0
        end
    end

    local fontString, primaryLine = SetCompareRowText(tooltip, text, r, g, b)
    if not fontString then
        tooltip:AddLine(text, r, g, b)
        primaryLine = tooltip:NumLines()
        fontString = _G[tooltip:GetName() .. "TextLeft" .. primaryLine]
    end

    -- Secondary profile's verdict: rides the right column of the row
    -- directly under the primary's row, the spec-name label folded into
    -- that right-column text so the whole group right-aligns as
    -- "Requires Level 17   Warden <arrow> +24%" (the label hugs the arrow —
    -- it does NOT go to the tooltip's left edge, and no new line is added).
    local arrowDir2, fs2
    local r2, g2, b2 = SEC_R, SEC_G, SEC_B
    if sec then
        local text2
        if sec.status == "empty" then
            text2 = sec.zeroBaseline and "Equipped scores 0" or "Fills empty slot"
            arrowDir2 = "up"
        elseif sec.status == "even" then
            if sec.zeroAll then
                text2, r2, g2, b2 = "No value", 0.6, 0.6, 0.6
            else
                text2 = "0%"
            end
        else
            text2 = string.format("%+.0f%%", sec.pct)
            arrowDir2 = sec.status == "upgrade" and "up" or "down"
            if arrowDir2 == "down" then
                r2, g2, b2 = 1, 0.25, 0.25
            end
        end

        local secName = RefactorCompareDB.charSecondaryProfile[CharKey()]
        local label = secName and (secName:match("%- (.+)$") or secName)
        local display = text2
        if label then
            local measure = tooltip.refactorMeasure
            if arrowDir2 then
                measure:SetText("00")
                local pair = measure:GetStringWidth() or 6
                measure:SetText("0 0")
                local spaceW = (measure:GetStringWidth() or (pair + 3)) - pair
                if spaceW < 1 then spaceW = 3 end
                display = label .. string.rep(" ", math.ceil(16 / spaceW)) .. text2
                measure:SetText(text2)
                w2 = measure:GetStringWidth() or 0
            else
                display = label .. " " .. text2
            end
        end

        fs2 = primaryLine and SetRowRightTextAt(tooltip, primaryLine + 1, display, r2, g2, b2)
        if not fs2 then
            tooltip:AddLine(display, r2, g2, b2)
            fs2 = _G[tooltip:GetName() .. "TextLeft" .. tooltip:NumLines()]
        end
    end

    -- Align both arrows to the maximum text width so they form a 100% straight vertical column
    local maxW = math.max(w1, w2)
    local sharedOffset = (maxW > 0) and -(maxW + 2) or nil

    if arrowDir then
        ShowLineArrow(tooltip, fontString, r, g, b, arrowDir == "down", "refactorLineArrow", sharedOffset)
    end
    if arrowDir2 and fs2 then
        ShowLineArrow(tooltip, fs2, r2, g2, b2, arrowDir2 == "down", "refactorLineArrow2", sharedOffset)
    end

    tooltip:Show()
    return true -- a verdict was drawn (callers retry while this is falsy)
end

-- Figure out which real item the tooltip is showing, so the scaled
-- instance gets scanned instead of the base item. Bag buttons (stock and
-- Bagnon alike) satisfy button:GetParent():GetID() == bag and
-- button:GetID() == slot; character paperdoll slots carry the inventory
-- slot as their ID. The link check guards against unrelated owners whose
-- IDs happen to point at some other item.
--
-- src = false is a hard block: the owner is a frame with a live scaled
-- source (roll window, loot window, quest reward) that couldn't be
-- confirmed yet — falling back to a bare-link scan there scores the BASE
-- item and flashes a wrong % until the client re-renders with real data.
-- Better to show nothing for that frame.
local function GetTooltipSource(tooltip, link)
    local owner = tooltip:GetOwner()
    if not (owner and owner.GetID) then return end

    -- Group loot roll windows: the hovered icon's parent (GroupLootFrame)
    -- carries rollID. SetLootRollItem renders the scaled item being
    -- rolled, so the verdict matches what lands in the winner's bags —
    -- a bare-link scan reads the BASE item and shifts the % afterwards.
    -- Checked before the ID guard below: the icon frame's own ID is 0.
    local rollParent = owner:GetParent()
    local rollID = rollParent and rollParent.rollID
    if rollID and GetLootRollItemLink then
        -- Match by item ID, not whole link: while the roll data is still
        -- arriving GetLootRollItemLink can be nil or carry volatile link
        -- fields that differ from the tooltip's own. The rollID on the
        -- hovered frame is authoritative enough once the IDs agree.
        local rollLink = GetLootRollItemLink(rollID)
        if not rollLink
            or rollLink:match("item:(%d+)") == link:match("item:(%d+)") then
            return nil, nil, nil, { roll = rollID }
        end
        return nil, nil, nil, false
    end

    -- Corpse/chest loot window buttons: SetLootItem for the same reason.
    local ownerName = owner.GetName and owner:GetName()
    if ownerName and ownerName:match("^LootButton%d+$") and owner.slot then
        if GetLootSlotLink(owner.slot) == link then
            return nil, nil, nil, { lootSlot = owner.slot }
        end
        return nil, nil, nil, false
    end

    -- Vendor/merchant item buttons: SetMerchantItem / SetBuybackItem for scaled items.
    if ownerName and ownerName:match("^MerchantItem%d+ItemButton$") then
        local id = owner:GetID()
        if id and id > 0 then
            local isBuyback = MerchantFrame and MerchantFrame.selectedTab == 2
            local mlink = isBuyback and (GetBuybackItemLink and GetBuybackItemLink(id))
                or (GetMerchantItemLink and GetMerchantItemLink(id))
            if mlink == link then
                return nil, nil, nil, isBuyback and { buybackSlot = id } or { merchantSlot = id }
            end
        end
        return nil, nil, nil, false
    end

    local id = owner:GetID()
    if not id or id <= 0 then return end

    -- Bagnon-style item buttons know their bag directly; cached buttons
    -- show another character's (or offline) data, where the live bag
    -- APIs would read the wrong item — no live source for those.
    if owner.GetBag then
        if not (owner.IsCached and owner:IsCached()) then
            local bag = owner:GetBag()
            if type(bag) == "number" and GetContainerItemLink(bag, id) == link then
                return bag, id, nil
            end
        end
        return
    end

    -- Paperdoll slots (CharacterHeadSlot...) before the generic bag
    -- guess: their parent's ID is 0 = backpack, so a backpack item with
    -- the same link at the same slot number would shadow them.
    local name = owner.GetName and owner:GetName()
    if name and name:match("^Character.*Slot$") then
        if GetInventoryItemLink("player", id) == link then
            return nil, nil, id
        end
        return
    end

    -- Quest reward buttons (QuestInfoItem1..N, shared by the quest-giver
    -- frame and the quest log): scanning via SetQuestItem/SetQuestLogItem
    -- renders the scaled copy the server would hand over, so the verdict
    -- matches what the item scores once it's in the bags. Scoring the
    -- bare link here reads the BASE item and flips verdicts on scaled
    -- rewards.
    if name and name:match("^QuestInfoItem%d+$")
        and (owner.type == "choice" or owner.type == "reward") then
        local qlog = QuestInfoFrame and QuestInfoFrame.questLog and true or false
        local qlink
        if qlog then
            qlink = GetQuestLogItemLink(owner.type, id)
        else
            qlink = GetQuestItemLink(owner.type, id)
        end
        if qlink == link then
            return nil, nil, nil, { log = qlog, type = owner.type, index = id }
        end
        return nil, nil, nil, false
    end

    local parent = owner:GetParent()
    local bag = parent and parent.GetID and parent:GetID()
    if bag and GetContainerItemLink(bag, id) == link then
        return bag, id, nil
    end
    if GetInventoryItemLink("player", id) == link then
        return nil, nil, id
    end
end

-- True if `link` matches something already worn. Blizzard's own shift-compare
-- "Currently Equipped" panel reuses a hooked tooltip template to redisplay
-- your own gear; when that fires OnTooltipSetItem, GetTooltipSource can't map
-- it to a real bag/paperdoll button (it isn't one), so without this guard it
-- fell through to a bare-hyperlink scan of the BASE item and printed a bogus
-- second "Compare:" line for gear you already have on — the flicker between
-- two different percentages on the same item.
local function LinkIsEquipped(link)
    for slot = 1, 18 do
        if GetInventoryItemLink("player", slot) == link then return true end
    end
    return false
end

-- Verdict retry: some live sources start out unreadable — a loot-roll
-- tooltip's first render can carry the stale base armor (see the
-- stale-armor check in ScanItem) or its item data hasn't arrived yet —
-- and unlike bag tooltips, the client doesn't always re-set those once
-- the real data lands, so a verdict discarded at hover time would stay
-- missing for the whole roll. While the same tooltip keeps showing the
-- same link, re-run the pipeline every 0.25s until a verdict draws (or
-- correctly stays absent: equipped-gear re-renders count as settled) or
-- the attempts run out. Verdicts that are legitimately never shown
-- (non-gear, quality-filtered) just let the retries expire silently.
local tipRetryFrame = CreateFrame("Frame")
tipRetryFrame:Hide()
local tipRetryTip, tipRetryLink, tipRetryElapsed, tipRetryTries

local function StartTipRetry(tip, link)
    tipRetryTip, tipRetryLink = tip, link
    tipRetryElapsed, tipRetryTries = 0, 8
    tipRetryFrame:Show()
end

tipRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    tipRetryElapsed = tipRetryElapsed + elapsed
    if tipRetryElapsed < 0.25 then return end
    tipRetryElapsed = 0
    local tip = tipRetryTip
    local link = tip and tip:IsShown() and select(2, tip:GetItem())
    if not link or link ~= tipRetryLink then
        self:Hide()
        return
    end
    tipRetryTries = tipRetryTries - 1
    local done = false
    local bag, slot, invSlot, src = GetTooltipSource(tip, link)
    if src ~= false then
        if not (bag or slot or invSlot or src) and LinkIsEquipped(link) then
            done = true -- correctly verdict-free, stop retrying
        else
            done = AddCompareLine(tip, link, bag, slot, invSlot, src)
        end
    end
    if done or tipRetryTries <= 0 then self:Hide() end
end)

local function HookTooltip(tip)
    tip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        -- Dupe guard keyed on the link (not a plain boolean): the same
        -- render pass can fire this twice, but a genuine re-set — the
        -- client refreshing a loot-roll/quest tooltip once the real item
        -- data arrives — goes through OnTooltipCleared below, which
        -- resets the key so the verdict is recomputed from live data.
        if not link or self.refactorCompareDone == link then return end
        self.refactorCompareDone = link
        local bag, slot, invSlot, src = GetTooltipSource(self, link)
        if src == false then
            StartTipRetry(self, link) -- live source pending: no guessing, but keep watching
            return
        end
        if not (bag or slot or invSlot or src) and LinkIsEquipped(link) then
            return
        end
        if not AddCompareLine(self, link, bag, slot, invSlot, src) then
            StartTipRetry(self, link)
        end
    end)
    tip:HookScript("OnTooltipCleared", function(self)
        self.refactorCompareDone = nil
        HideLineArrow(self)
    end)
    tip:HookScript("OnHide", function(self)
        self.refactorCompareDone = nil
        HideLineArrow(self)
    end)
end

HookTooltip(GameTooltip)
HookTooltip(ItemRefTooltip)
-- The fullscreen map's quest pane shows rewards through QuestInfo's
-- QUEST_TEMPLATE_MAP2, whose item buttons write to WorldMapTooltip — a
-- separate GameTooltipTemplate instance — so without this hook a reward
-- hovered on the map got no verdict while the same reward in the quest
-- log (QUEST_TEMPLATE_LOG, GameTooltip) did.
if WorldMapTooltip then HookTooltip(WorldMapTooltip) end

C.SetArrowAtlas = SetArrowAtlas
C.SEC_R = SEC_R
C.SEC_G = SEC_G
C.SEC_B = SEC_B
