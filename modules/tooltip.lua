-- Refactor: tooltip tweaks
-- Anchors the default tooltip beside the cursor (right side) and follows
-- it while shown, hides the tooltip health bar, and colors the tooltip
-- border by item quality.

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
