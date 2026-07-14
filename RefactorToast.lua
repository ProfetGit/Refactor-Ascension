-- RefactorToast
-- Loot toasts: fast auto-loot (Refactor.lua) skips the loot window, so
-- items vanish into bags unseen. Each item you loot gets a small animated
-- toast — icon, quality-colored name, stack count — that slides in, holds
-- and fades out. If RefactorCompare judges the item an upgrade (same
-- trust rules as the bag arrows: live instance scan only, never a
-- bare-link estimate), the toast carries the green arrow, a pulsing icon
-- glow, and the % verdict as its second line.
--
-- Hover a toast to pause its fade and see the item tooltip; click to
-- dismiss it; shift-click to link the item in chat.
--
-- Slash commands:
--   /rfct           toggle loot toasts on/off
--   /rfct unlock    show a drag handle to reposition the toasts
--   /rfct lock      hide the drag handle and save the position
--   /rfct reset     restore the default position
--   /rfct test      show a sample toast

local TOAST_WIDTH = 262
local TOAST_HEIGHT = 52
local TOAST_GAP = 6
local MAX_ACTIVE = 5          -- on-screen at once; extras queue up
local SLIDE_IN_TIME = 0.25
local SLIDE_IN_DIST = 40      -- pixels the toast slides in from the right
local HOLD_TIME = 3.5
local HOLD_TIME_UPGRADE = 6   -- upgrades are the whole point — linger longer
local FADE_OUT_TIME = 0.8
local RESOLVE_INTERVAL = 0.2  -- seconds between attempts to resolve a loot line
local RESOLVE_RETRIES = 15    -- ~3s for the item to reach cache/bags
local ARROW_WAIT_RETRIES = 10 -- keep waiting for a bag instance until this many retries remain

local ARROW_TEXTURE = "Interface\\AddOns\\Refactor\\arrow"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local tdb -- RefactorCompareDB.toast after ADDON_LOADED

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor|r: " .. msg)
end

--------------------------------------------------------------------------
-- Positioning
--------------------------------------------------------------------------

local active = {}   -- active[1] is the bottom (newest) toast
local pool = {}
local overflow = {} -- pending toast data waiting for a free slot

-- BOTTOMLEFT coordinates of the newest toast; stacks grow upward.
local function BaseAnchor()
    if tdb and tdb.x and tdb.y then return tdb.x, tdb.y end
    return (UIParent:GetWidth() - TOAST_WIDTH) / 2, 300
end

local function PositionToast(t)
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        t.baseX + (t.slide or 0), t.baseY)
end

local function Reposition()
    local x, y = BaseAnchor()
    for i, t in ipairs(active) do
        t.baseX = x
        t.baseY = y + (i - 1) * (TOAST_HEIGHT + TOAST_GAP)
        PositionToast(t)
    end
end

--------------------------------------------------------------------------
-- Toast frames
--------------------------------------------------------------------------

local SpawnToast -- forward declared: ReleaseToast pops the overflow queue

local function ReleaseToast(t)
    for i, v in ipairs(active) do
        if v == t then
            tremove(active, i)
            break
        end
    end
    t:Hide()
    tinsert(pool, t)
    Reposition()
    if overflow[1] and #active < MAX_ACTIVE then
        SpawnToast(tremove(overflow, 1))
    end
end

local function DismissToast(t)
    if t.phase ~= "out" then
        t.phase = "out"
        t.elapsed = 0
        t.outFrom = t:GetAlpha()
    end
end

local function ToastOnUpdate(t, elapsed)
    t.elapsed = t.elapsed + elapsed

    if t.upgrade and t.glow:IsShown() then
        t.glow:SetAlpha(0.35 + 0.25 * math.sin(GetTime() * 5))
    end

    if t.phase == "in" then
        local p = t.elapsed / SLIDE_IN_TIME
        if p >= 1 then
            t.slide = 0
            t:SetAlpha(1)
            t.phase = "hold"
            t.elapsed = 0
        else
            -- Ease out: fast start, gentle landing.
            local e = 1 - (1 - p) * (1 - p)
            t.slide = SLIDE_IN_DIST * (1 - e)
            t:SetAlpha(p)
        end
        PositionToast(t)
    elseif t.phase == "hold" then
        if t.hover then
            t.elapsed = 0 -- mouse on it = player is reading, don't tick
        elseif t.elapsed >= t.holdTime then
            DismissToast(t)
        end
    elseif t.phase == "out" then
        if t.hover then
            -- Came back to look at it mid-fade: revive.
            t.phase = "hold"
            t.elapsed = 0
            t:SetAlpha(1)
        else
            local p = t.elapsed / FADE_OUT_TIME
            if p >= 1 then
                ReleaseToast(t)
            else
                t:SetAlpha(t.outFrom * (1 - p))
            end
        end
    end
end

local function ToastOnEnter(t)
    t.hover = true
    if not t.link then return end
    GameTooltip:SetOwner(t, "ANCHOR_LEFT")
    -- Prefer the live bag instance (scaled stats); the bare link renders
    -- the base item. The slot may have moved/merged since the toast was
    -- built, so verify it still holds this link.
    if t.bag and t.slot and GetContainerItemLink(t.bag, t.slot) == t.link then
        GameTooltip:SetBagItem(t.bag, t.slot)
    else
        GameTooltip:SetHyperlink(t.link)
    end
    GameTooltip:Show()
end

local function ToastOnLeave(t)
    t.hover = false
    GameTooltip:Hide()
end

local function ToastOnClick(t)
    if IsShiftKeyDown() and t.link and ChatEdit_InsertLink then
        ChatEdit_InsertLink(t.link)
    else
        t.hover = false
        DismissToast(t)
    end
end

local function CreateToast()
    local t = CreateFrame("Button", nil, UIParent)
    t:SetWidth(TOAST_WIDTH)
    t:SetHeight(TOAST_HEIGHT)
    t:SetFrameStrata("HIGH")
    t:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    t:SetBackdropColor(0.05, 0.05, 0.08, 0.92)

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetWidth(36)
    t.icon:SetHeight(36)
    t.icon:SetPoint("LEFT", 9, 0)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the stock icon border

    -- Additive ring behind the icon, pulsed in OnUpdate for upgrades.
    t.glow = t:CreateTexture(nil, "OVERLAY")
    t.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    t.glow:SetBlendMode("ADD")
    t.glow:SetWidth(62)
    t.glow:SetHeight(62)
    t.glow:SetPoint("CENTER", t.icon, "CENTER", 0, 0)
    t.glow:SetVertexColor(0, 1, 0)
    t.glow:Hide()

    t.count = t:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    t.count:SetPoint("BOTTOMRIGHT", t.icon, "BOTTOMRIGHT", 0, 1)

    t.name = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 8, -2)
    t.name:SetWidth(TOAST_WIDTH - 82)
    t.name:SetHeight(13) -- clip to one line instead of wrapping
    t.name:SetJustifyH("LEFT")

    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.sub:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -4)
    t.sub:SetWidth(TOAST_WIDTH - 82)
    t.sub:SetHeight(11)
    t.sub:SetJustifyH("LEFT")

    t.arrow = t:CreateTexture(nil, "OVERLAY")
    t.arrow:SetWidth(15)
    t.arrow:SetHeight(15)
    t.arrow:SetPoint("TOPRIGHT", -7, -7)
    if t.arrow:SetTexture(ARROW_TEXTURE) then
        t.arrow:SetVertexColor(0, 1, 0)
    else
        t.arrow:SetTexture(0, 1, 0, 0.9)
        t.arrow:SetWidth(10)
        t.arrow:SetHeight(10)
    end
    t.arrow:Hide()

    t:SetScript("OnUpdate", ToastOnUpdate)
    t:SetScript("OnEnter", ToastOnEnter)
    t:SetScript("OnLeave", ToastOnLeave)
    t:SetScript("OnClick", ToastOnClick)
    return t
end

-- data = { link, name, quality, texture, count, subText, upgrade }
-- upgrade = nil, or { pct, empty, levelLocked }; bag/slot when the looted
-- copy was located (used only to show the instance tooltip on hover).
SpawnToast = function(data)
    if #active >= MAX_ACTIVE then
        tinsert(overflow, data)
        return
    end
    local t = tremove(pool) or CreateToast()

    t.link, t.bag, t.slot = data.link, data.bag, data.slot
    t.upgrade = data.upgrade

    t.icon:SetTexture(data.texture or FALLBACK_ICON)
    t.count:SetText(data.count and data.count > 1 and ("x" .. data.count) or "")

    local q = data.quality
    local color = q and ITEM_QUALITY_COLORS[q]
    if color then
        t.name:SetTextColor(color.r, color.g, color.b)
        t:SetBackdropBorderColor(color.r, color.g, color.b)
    else
        t.name:SetTextColor(1, 1, 1)
        t:SetBackdropBorderColor(1, 1, 1)
    end
    t.name:SetText(data.name or "?")

    if data.upgrade then
        local u = data.upgrade
        local lockNote = u.levelLocked and " (at level)" or ""
        if u.empty then
            t.sub:SetText("Fills an empty slot" .. lockNote)
        else
            t.sub:SetText(string.format("+%.0f%% upgrade%s", u.pct or 0, lockNote))
        end
        t.sub:SetTextColor(0, 1, 0)
        t.arrow:Show()
        t.glow:Show()
        t.holdTime = HOLD_TIME_UPGRADE
    else
        t.sub:SetText(data.subText or "Looted")
        t.sub:SetTextColor(0.6, 0.6, 0.6)
        t.arrow:Hide()
        t.glow:Hide()
        t.holdTime = HOLD_TIME
    end

    t.phase = "in"
    t.elapsed = 0
    t.slide = SLIDE_IN_DIST
    t.hover = false
    t:SetAlpha(0)

    tinsert(active, 1, t) -- newest at the anchor, older toasts pushed up
    Reposition()
    t:Show()
end

--------------------------------------------------------------------------
-- Loot message parsing & resolution
--------------------------------------------------------------------------

-- Turn "You receive loot: %sx%d." into a match pattern. Multi-stack
-- formats must be tried before the single ones — %s is greedy and would
-- swallow the "x3" suffix otherwise.
local function PatternFromFormat(fmt)
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("%%s", "(.+)")
    fmt = fmt:gsub("%%d", "(%%d+)")
    return "^" .. fmt .. "$"
end

local LOOT_PATTERNS = {
    { pattern = PatternFromFormat(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_SELF or "You receive loot: %s."), counted = false },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF or "You receive item: %s."), counted = false },
}

-- Loot lines resolve asynchronously: the item may not be in the client
-- cache when the message arrives, and the upgrade verdict needs the item
-- to physically reach a bag slot so the scaled instance can be scanned.
-- Each entry retries on a timer; the toast shows once the name is known,
-- waiting a bit longer for the bag copy before giving up on the arrow.
local pending = {}
local resolveFrame = CreateFrame("Frame")
resolveFrame:Hide()
local resolveElapsed = 0

-- Extract name from the link so a never-cached item still shows something.
local function NameFromLink(link)
    return link:match("|h%[(.-)%]|h") or "?"
end

local function TryResolve(entry)
    local link = entry.link
    local name, _, quality, _, _, _, itemSubType, _, _, texture = GetItemInfo(link)
    if not name then
        if entry.retries <= 1 then
            SpawnToast({ link = link, name = NameFromLink(link),
                count = entry.count })
            return true
        end
        return false
    end

    -- Upgrade verdict wants the real bag copy (Ascension scaling: the
    -- link alone reads the base item). Give it a moment to land.
    local shared = RefactorCompareShared
    local bag, slot, upgrade
    if shared and shared.IsEnabled() then
        bag, slot = shared.FindBagItem(link)
        if not bag and entry.retries > ARROW_WAIT_RETRIES then
            return false
        end
        if bag then
            local result = shared.CompareItem(link, bag, slot)
            -- The arrow is a promise, not a hint: estimates never earn it.
            if result and not result.approx
                and (result.status == "upgrade" or result.status == "empty") then
                upgrade = { pct = result.pct,
                    empty = result.status == "empty",
                    levelLocked = result.levelLocked }
            end
        end
    end

    SpawnToast({ link = link, name = name, quality = quality,
        texture = texture, count = entry.count, subText = itemSubType,
        upgrade = upgrade, bag = bag, slot = slot })
    return true
end

resolveFrame:SetScript("OnUpdate", function(self, elapsed)
    resolveElapsed = resolveElapsed + elapsed
    if resolveElapsed < RESOLVE_INTERVAL then return end
    resolveElapsed = 0
    for i = #pending, 1, -1 do
        local entry = pending[i]
        if TryResolve(entry) or entry.retries <= 1 then
            tremove(pending, i)
        else
            entry.retries = entry.retries - 1
        end
    end
    if #pending == 0 then self:Hide() end
end)

local function OnLootMessage(msg)
    if not tdb or not tdb.enabled then return end
    for _, p in ipairs(LOOT_PATTERNS) do
        local itemString, count = msg:match(p.pattern)
        if itemString then
            local link = itemString:match("|Hitem:.-|h%[.-%]|h")
            if link then
                local entry = { link = link, retries = RESOLVE_RETRIES,
                    count = p.counted and tonumber(count) or 1 }
                if not TryResolve(entry) then
                    tinsert(pending, entry)
                    resolveElapsed = 0
                    resolveFrame:Show()
                end
            end
            return
        end
    end
end

--------------------------------------------------------------------------
-- Anchor drag handle
--------------------------------------------------------------------------

local anchorFrame

local function ShowAnchor()
    if not anchorFrame then
        local a = CreateFrame("Frame", nil, UIParent)
        a:SetWidth(TOAST_WIDTH)
        a:SetHeight(TOAST_HEIGHT)
        a:SetFrameStrata("DIALOG")
        a:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        a:SetBackdropColor(0, 0.8, 0, 0.3)
        a:SetBackdropBorderColor(0, 1, 0)
        local label = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("Loot toasts — drag me\n|cff999999/rfct lock to save|r")
        a:SetMovable(true)
        a:EnableMouse(true)
        a:RegisterForDrag("LeftButton")
        a:SetScript("OnDragStart", a.StartMoving)
        a:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            tdb.x = self:GetLeft()
            tdb.y = self:GetBottom()
            Reposition()
        end)
        anchorFrame = a
    end
    local x, y = BaseAnchor()
    anchorFrame:ClearAllPoints()
    anchorFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    anchorFrame:Show()
end

local function SpawnTestToasts()
    local name, link, quality, _, _, _, subType, _, _, texture =
        GetItemInfo(6948) -- Hearthstone: always known to the client
    SpawnToast({ link = link, name = name or "Hearthstone",
        quality = quality, texture = texture, count = 1,
        subText = subType })
    SpawnToast({ link = link, name = name or "Hearthstone",
        quality = quality, texture = texture, count = 3,
        upgrade = { pct = 12.5 } })
end

-- Shared with RefactorUI.lua (the config window).
RefactorToastShared = {
    GetDB = function() return tdb end,
    ShowAnchor = function() ShowAnchor() end,
    HideAnchor = function() if anchorFrame then anchorFrame:Hide() end end,
    IsAnchorShown = function()
        return anchorFrame and anchorFrame:IsShown() or false
    end,
    ResetPosition = function()
        if tdb then tdb.x, tdb.y = nil, nil end
        Reposition()
        if anchorFrame and anchorFrame:IsShown() then ShowAnchor() end
    end,
    Test = SpawnTestToasts,
}

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

SLASH_REFACTORTOAST1 = "/rfct"
SlashCmdList.REFACTORTOAST = function(msg)
    local cmd = (msg or ""):match("^(%S*)"):lower()
    if not tdb then return end

    if cmd == "" or cmd == "toggle" then
        tdb.enabled = not tdb.enabled
        Print("loot toasts " .. (tdb.enabled and "|cff00ff00on|r" or "|cffff4040off|r") .. ".")
    elseif cmd == "unlock" then
        ShowAnchor()
        Print("drag the green box, then /rfct lock.")
    elseif cmd == "lock" then
        if anchorFrame then anchorFrame:Hide() end
        Print("toast position saved.")
    elseif cmd == "reset" then
        RefactorToastShared.ResetPosition()
        Print("toast position reset.")
    elseif cmd == "test" then
        SpawnTestToasts()
    else
        Print("usage: /rfct (toggle) | unlock | lock | reset | test")
    end
end

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "Refactor" then return end
        -- RefactorCompare.lua loads first and owns RefactorCompareDB; the
        -- guard is only for load-order accidents.
        if type(RefactorCompareDB) ~= "table" then RefactorCompareDB = {} end
        if type(RefactorCompareDB.toast) ~= "table" then
            RefactorCompareDB.toast = {}
        end
        tdb = RefactorCompareDB.toast
        if tdb.enabled == nil then tdb.enabled = true end
    elseif event == "CHAT_MSG_LOOT" then
        OnLootMessage(arg1)
    end
end)
