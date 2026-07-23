-- RefactorToast
-- Loot toasts: fast auto-loot (Refactor.lua) skips the loot window, so
-- items vanish into bags unseen. Each item you loot gets a small animated
-- toast — icon, quality-colored name, stack count — that slides in, holds
-- and fades out. If the separate Refactor Gear addon is installed and
-- judges the item an upgrade (same trust rules as its bag arrows: live
-- instance scan only, never a bare-link estimate), the toast carries a
-- softly pulsing green arrow and the % verdict as its second line —
-- without that addon the toast is just the item. The stack's worth (TSM /
-- Auctionator / vendor, source picked on the Loot page) sits right-
-- aligned on that same line.
--
-- Hover a toast to pause its fade and see the item tooltip; click to
-- dismiss it; shift-click to link the item in chat.
--
-- All settings (on/off, anchor, test) live in the Loot page of the
-- config window (/rfc or /refactor) via RefactorToastShared.

local TOAST_WIDTH = 260
local TOAST_HEIGHT = 44
local TOAST_GAP = 4
local MAX_ACTIVE = 5          -- on-screen at once; extras queue up
local MAX_OVERFLOW = 20       -- queue ceiling; past it the oldest entry is dropped
local SLIDE_IN_TIME = 0.25
local SLIDE_IN_DIST = 24      -- pixels the toast slides in from the right
local HOLD_TIME = 3.5
local HOLD_TIME_UPGRADE = 6   -- upgrades are the whole point — linger longer
local FADE_OUT_TIME = 0.8
local RESOLVE_INTERVAL = 0.2  -- seconds between attempts to resolve a loot line
local RESOLVE_RETRIES = 15    -- ~3s for the item to reach cache/bags
local ARROW_WAIT_RETRIES = 10 -- keep waiting for a bag instance until this many retries remain

local ARROW_TEXTURE = "Interface\\AddOns\\Refactor\\arrow"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local SOLID = "Interface\\ChatFrame\\ChatFrameBackground" -- tintable solid
local ACCENT = { 0.20, 1.00, 0.60 } -- the addon's chat-message green

local LOOT_TOAST_ATLAS = "Interface\\LootFrame\\LootToastAtlas"

local ATLAS_COORDS = {
    ["loottoast-arrow-green"] = { left = 0.858398, right = 0.878906, top = 0.158203, bottom = 0.207031 },
    ["loottoast-arrow-blue"]  = { left = 0.835938, right = 0.856445, top = 0.158203, bottom = 0.207031 },
}

local function SetArrowAtlas(arrow, atlasName, fallbackR, fallbackG, fallbackB)
    local coords = ATLAS_COORDS[atlasName]
    if coords then
        if arrow:SetTexture(LOOT_TOAST_ATLAS) then
            arrow:SetTexCoord(coords.left, coords.right, coords.top, coords.bottom)
            arrow:SetVertexColor(1, 1, 1)
            return true
        end
    end
    if arrow.SetAtlas then
        local ok = pcall(arrow.SetAtlas, arrow, atlasName)
        if ok then
            arrow:SetVertexColor(1, 1, 1)
            arrow:SetTexCoord(0, 1, 0, 1)
            return true
        end
    end
    local info = GetAtlasInfo and GetAtlasInfo(atlasName)
    if info then
        arrow:SetTexture(info.file)
        arrow:SetTexCoord(info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord)
        arrow:SetVertexColor(1, 1, 1)
        return true
    end
    if arrow:SetTexture(ARROW_TEXTURE) then
        arrow:SetTexCoord(0, 1, 0, 1)
        arrow:SetVertexColor(fallbackR or 0, fallbackG or 1, fallbackB or 0)
        return true
    else
        arrow:SetTexture(fallbackR or 0, fallbackG or 1, fallbackB or 0, 0.9)
        return false
    end
end

local MIN_SCALE, MAX_SCALE, DEFAULT_SCALE = 0.6, 1.8, 1.0

local tdb -- RefactorCompareDB.toast after ADDON_LOADED

local function Scale() return (tdb and tdb.scale) or DEFAULT_SCALE end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor|r: " .. msg)
end

--------------------------------------------------------------------------
-- Item value (auction / vendor price on the toast)
--------------------------------------------------------------------------
-- Price sources are discovered at use time, never assumed: TSM's fork
-- exposes TSMAPI:GetPriceSources()/GetItemValue(link, key) and modules
-- register their own keys (DBMarket, DBMinBuyout, ...); Auctionator's
-- scan DB is reached through the global Atr_GetAuctionBuyout, which keys
-- by item NAME. Auction-house prices ONLY — vendor sell price is
-- deliberately not offered: GetItemInfo reports the BASE item, and on
-- Ascension the scaled instance vendors for a different amount (the
-- tooltip's own Sell Price line), so showing it just contradicts the
-- game. Same reason TSM's VendorSell source is filtered out of the
-- dropdown. AH DBs only know items the player has scanned; unknown item
-- = no text. AH prices key on the base item ID, so instance scaling
-- doesn't matter here; and money is informational, not the green-arrow
-- promise, so no trust rules apply beyond "no data → show nothing".

local function TSMValue(link, key)
    if TSMAPI and TSMAPI.GetItemValue then
        local ok, v = pcall(TSMAPI.GetItemValue, TSMAPI, link, key)
        if ok and type(v) == "number" and v > 0 then return v end
    end
end

local function AuctionatorValue(name)
    if name and Atr_GetAuctionBuyout then
        local ok, v = pcall(Atr_GetAuctionBuyout, name)
        if ok and type(v) == "number" and v > 0 then return v end
    end
end

-- Per-item value in copper under the configured source, or nil.
local function ItemValue(link, name)
    local src = (tdb and tdb.priceSource) or "auto"
    if src == "auto" then
        return TSMValue(link, "DBMarket") or TSMValue(link, "DBMinBuyout")
            or AuctionatorValue(name)
    elseif src == "auctionator" then
        return AuctionatorValue(name)
    end
    local key = src:match("^tsm:(.+)")
    if key then return TSMValue(link, key) end
end

-- TSM registers a dozen sources (vendor prices, crafting cost,
-- disenchant value, Accounting's personal buy/sell history, bridges to
-- Auctioneer/Auctionator...) but the toast answers exactly one question
-- — "what would this loot fetch at the AH" — so only the AuctionDB
-- market sources pass the whitelist. AtrValue (TSM's Auctionator
-- bridge) is the same number as the direct Auctionator entry above.
local TSM_SOURCE_WHITELIST = { DBMarket = true, DBMinBuyout = true }

-- Sources actually available right now, for the config dropdown.
-- Keys: "auto", "auctionator", "tsm:<TSM source key>".
local function GetPriceSources()
    local list = {
        { key = "auto", label = "Auto (first market price found)" },
    }
    if Atr_GetAuctionBuyout then
        tinsert(list, { key = "auctionator", label = "Auctionator - Auction Value" })
    end
    if TSMAPI and TSMAPI.GetPriceSources then
        local ok, sources = pcall(TSMAPI.GetPriceSources, TSMAPI)
        if ok and type(sources) == "table" then
            local keys = {}
            for k in pairs(sources) do
                if TSM_SOURCE_WHITELIST[k] then tinsert(keys, k) end
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                tinsert(list, { key = "tsm:" .. k, label = "TSM: " .. tostring(sources[k]) })
            end
        end
    end
    return list
end

-- Compact colored money string: two most significant denominations.
local function FormatMoney(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    if g > 0 then
        if s > 0 then
            return string.format("%d|cffffd700g|r %d|cffc7c7cfs|r", g, s)
        end
        return string.format("%d|cffffd700g|r", g)
    elseif s > 0 then
        if c > 0 then
            return string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", s, c)
        end
        return string.format("%d|cffc7c7cfs|r", s)
    end
    return string.format("%d|cffeda55fc|r", c)
end

--------------------------------------------------------------------------
-- Positioning
--------------------------------------------------------------------------

local active = {}   -- active[1] is the bottom (newest) toast
local pool = {}
local overflow = {} -- pending toast data waiting for a free slot

-- BOTTOMLEFT coordinates of the newest toast; stacks grow upward.
-- Default: lower right, pulled in past the right action bars and the
-- first stock bag column (bags open at the same moment toasts fire, and
-- toasts are mouse-enabled — overlap would steal bag-slot clicks), and
-- above the bottom-right multibar. Live-computed so it tracks
-- resolution/UI scale; only dragging the anchor persists coordinates.
local function BaseAnchor()
    if tdb and tdb.x and tdb.y then return tdb.x, tdb.y end
    return UIParent:GetWidth() - TOAST_WIDTH - 285, 140
end

local function PositionToast(t)
    local s = Scale()
    t:SetScale(s)
    t:ClearAllPoints()
    -- SetPoint offsets are in the frame's own (scaled) coordinates, so the
    -- desired on-screen pixel position is divided back out — same trick the
    -- movable map window uses for its scale.
    t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT",
        (t.baseX + (t.slide or 0)) / s, t.baseY / s)
end

local function Reposition()
    local x, y = BaseAnchor()
    local s = Scale()
    for i, t in ipairs(active) do
        t.baseX = x
        t.baseY = y + (i - 1) * (TOAST_HEIGHT + TOAST_GAP) * s
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

    if t.upgrade and t.arrow:IsShown() then
        t.arrow:SetAlpha(0.7 + 0.3 * math.sin(GetTime() * 4))
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

-- Width of the fully-opaque part of the scrim; the rest fades to zero.
-- Covers the icon and the first words of the name so text stays readable
-- over bright terrain; long names ride the fade (font shadows carry them).
local SCRIM_SOLID_W = 88

local function CreateToast()
    local t = CreateFrame("Button", nil, UIParent)
    t:SetWidth(TOAST_WIDTH)
    t:SetHeight(TOAST_HEIGHT)
    t:SetFrameStrata("HIGH")

    -- Borderless banner, classic zone-text style: black scrim solid on
    -- the left, fading to nothing toward the right. No box, no border.
    t.bgSolid = t:CreateTexture(nil, "BACKGROUND")
    t.bgSolid:SetTexture(SOLID)
    t.bgSolid:SetPoint("TOPLEFT")
    t.bgSolid:SetPoint("BOTTOMLEFT")
    t.bgSolid:SetWidth(SCRIM_SOLID_W)
    t.bgSolid:SetVertexColor(0, 0, 0, 0.5)

    t.bgFade = t:CreateTexture(nil, "BACKGROUND")
    t.bgFade:SetTexture(SOLID)
    t.bgFade:SetPoint("TOPLEFT", t.bgSolid, "TOPRIGHT", 0, 0)
    t.bgFade:SetPoint("BOTTOMRIGHT")
    t.bgFade:SetGradientAlpha("HORIZONTAL", 0, 0, 0, 0.5, 0, 0, 0, 0)

    -- Quality-colored hairlines top and bottom, fading with the banner —
    -- the old quality border reduced to a whisper.
    t.lineTop = t:CreateTexture(nil, "BORDER")
    t.lineTop:SetTexture(SOLID)
    t.lineTop:SetHeight(1)
    t.lineTop:SetPoint("TOPLEFT")
    t.lineTop:SetPoint("TOPRIGHT")

    t.lineBottom = t:CreateTexture(nil, "BORDER")
    t.lineBottom:SetTexture(SOLID)
    t.lineBottom:SetHeight(1)
    t.lineBottom:SetPoint("BOTTOMLEFT")
    t.lineBottom:SetPoint("BOTTOMRIGHT")

    t.SetQualityColor = function(self, r, g, b)
        self.lineTop:SetGradientAlpha("HORIZONTAL", r, g, b, 0.9, r, g, b, 0)
        self.lineBottom:SetGradientAlpha("HORIZONTAL", r, g, b, 0.9, r, g, b, 0)
    end

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetWidth(30)
    t.icon:SetHeight(30)
    t.icon:SetPoint("LEFT", 4, 0)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- trim the stock icon border

    -- Blizzard's own slot ring (action-button/bag border) over the icon,
    -- so the item art sits in a stock-looking slot. The 64px art is drawn
    -- at 64/36 of the icon size, like ActionButton does.
    t.iconBorder = t:CreateTexture(nil, "OVERLAY")
    t.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    t.iconBorder:SetWidth(53)
    t.iconBorder:SetHeight(53)
    t.iconBorder:SetPoint("CENTER", t.icon, "CENTER", 0, -1)

    t.count = t:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    t.count:SetPoint("BOTTOMRIGHT", t.icon, "BOTTOMRIGHT", 1, 0)

    t.name = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 9, -1)
    t.name:SetWidth(TOAST_WIDTH - 69)
    t.name:SetHeight(13) -- clip to one line instead of wrapping
    t.name:SetJustifyH("LEFT")

    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.sub:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -3)
    t.sub:SetWidth(TOAST_WIDTH - 69)
    t.sub:SetHeight(11)
    t.sub:SetJustifyH("LEFT")

    -- Item value, right-aligned on the sub line. Ends at the text column's
    -- right edge (x=234); the upgrade arrow starts at x=240, so they never
    -- collide. Neutral money colors only — accent green stays an upgrade
    -- promise. The font shadow keeps it readable over the faded scrim.
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.value:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -26, 9)
    t.value:SetJustifyH("RIGHT")
    t.value:SetTextColor(0.9, 0.9, 0.9)

    t.arrow = t:CreateTexture(nil, "OVERLAY")
    t.arrow:SetWidth(14)
    t.arrow:SetHeight(16)
    t.arrow:SetPoint("RIGHT", -8, 0)
    SetArrowAtlas(t.arrow, "loottoast-arrow-green", ACCENT[1], ACCENT[2], ACCENT[3])
    t.arrow:Hide()

    t:SetScript("OnUpdate", ToastOnUpdate)
    t:SetScript("OnEnter", ToastOnEnter)
    t:SetScript("OnLeave", ToastOnLeave)
    t:SetScript("OnClick", ToastOnClick)
    return t
end

-- data = { link, name, quality, texture, count, subText, upgrade, value }
-- upgrade = nil, or { pct, empty, zeroBaseline, levelLocked }; bag/slot when the looted
-- copy was located (used only to show the instance tooltip on hover);
-- value = total worth of the stack in copper (nil = unknown, show nothing).
SpawnToast = function(data)
    if #active >= MAX_ACTIVE then
        -- The queue drains at roughly MAX_ACTIVE per holdTime (~1 toast a
        -- second). AoE farming and mass container-opening produce loot far
        -- faster than that, and with no ceiling the backlog grew unbounded —
        -- both a memory cost and a UX one, since the player ends up watching
        -- toasts for loot from minutes ago. Past the cap, drop the OLDEST
        -- queued entry: the newest loot is the one still worth showing.
        if #overflow >= MAX_OVERFLOW then
            tremove(overflow, 1)
        end
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
        t:SetQualityColor(color.r, color.g, color.b)
    else
        t.name:SetTextColor(1, 1, 1)
        t:SetQualityColor(0.5, 0.5, 0.5)
    end
    t.name:SetText(data.name or "?")

    if data.upgrade then
        local u = data.upgrade
        local lockNote = u.levelLocked and " (at level)" or ""
        if u.empty then
            -- zeroBaseline: the slot is occupied but the equipped item
            -- scores 0 under the profile's weights — don't claim it's empty.
            t.sub:SetText((u.zeroBaseline and "Equipped scores 0" or "Fills an empty slot") .. lockNote)
        else
            t.sub:SetText(string.format("+%.0f%% upgrade%s", u.pct or 0, lockNote))
        end
        t.sub:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        t.arrow:SetAlpha(1)
        t.arrow:Show()
        t.holdTime = HOLD_TIME_UPGRADE
    else
        t.sub:SetText(data.subText or "Looted")
        t.sub:SetTextColor(0.55, 0.55, 0.60)
        t.arrow:Hide()
        t.holdTime = HOLD_TIME
    end

    -- Value shares the sub line; shrink the sub text so long labels never
    -- run under the money.
    if data.value then
        t.value:SetText(FormatMoney(data.value))
        t.value:Show()
        t.sub:SetWidth(TOAST_WIDTH - 69 - t.value:GetStringWidth() - 6)
    else
        t.value:SetText("")
        t.value:Hide()
        t.sub:SetWidth(TOAST_WIDTH - 69)
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
    -- link alone reads the base item). Give it a moment to land. Only
    -- evaluatable gear pays for the bag walk and compare — junk and
    -- materials (most loot) toast immediately with no verdict work, and
    -- their hover tooltip falls back to the plain link, which is fine
    -- since scaling only matters for gear.
    -- Refactor Gear (the standalone gear-compare addon) is optional: read
    -- it at use time, never at load, since addon load order isn't ours to
    -- control. Absent = no verdict work at all, just the item toast.
    local shared = RefactorGearShared
    local bag, slot, upgrade
    if shared and shared.IsEnabled()
        and (not shared.IsGear or shared.IsGear(link)) then
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
                    zeroBaseline = result.zeroBaseline,
                    levelLocked = result.levelLocked }
            end
        end
    end

    -- Stack worth: per-item value × looted count, under the configured
    -- price source. nil (source off / item unknown to the AH DB) = no text.
    local value
    if tdb and tdb.showValue then
        local unit = ItemValue(link, name)
        if unit then value = unit * (entry.count or 1) end
    end

    SpawnToast({ link = link, name = name, quality = quality,
        texture = texture, count = entry.count, subText = itemSubType,
        upgrade = upgrade, bag = bag, slot = slot, value = value })
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

-- Self-loot chat lines -> (link, count). The locale's own LOOT_ITEM_*
-- format strings are turned into match patterns; the multi-stack forms go
-- first so the "x3" suffix lands in the %d capture instead of being
-- swallowed by the greedy %s capture. The link is re-extracted from the
-- %s capture by item-link shape either way.
local function PatternFromFormat(fmt)
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("%%s", "(.+)")
    fmt = fmt:gsub("%%d", "(%%d+)")
    return "^" .. fmt .. "$"
end

local LOOT_SELF_PATTERNS = {
    { pattern = PatternFromFormat(LOOT_ITEM_SELF_MULTIPLE or "You receive loot: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF_MULTIPLE or "You receive item: %sx%d."), counted = true },
    { pattern = PatternFromFormat(LOOT_ITEM_SELF or "You receive loot: %s."), counted = false },
    { pattern = PatternFromFormat(LOOT_ITEM_PUSHED_SELF or "You receive item: %s."), counted = false },
}

local function OnLoot(link, count)
    if not tdb or not tdb.enabled then return end
    local entry = { link = link, retries = RESOLVE_RETRIES,
        count = count or 1 }
    if not TryResolve(entry) then
        tinsert(pending, entry)
        resolveElapsed = 0
        resolveFrame:Show()
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
        a:SetBackdrop({ bgFile = SOLID, edgeFile = SOLID, edgeSize = 1 })
        a:SetBackdropColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.12)
        a:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
        local label = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("Loot toasts — drag me\n|cff999999click Lock in the Loot page to save|r")
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
    -- Hearthstone vendors for 0, so the value is faked — the test exists
    -- to preview the layout, money text included.
    local value = (tdb and tdb.showValue) and 123456 or nil -- 12g 34s
    SpawnToast({ link = link, name = name or "Hearthstone",
        quality = quality, texture = texture, count = 1,
        subText = subType, value = value })
    SpawnToast({ link = link, name = name or "Hearthstone",
        quality = quality, texture = texture, count = 3,
        upgrade = { pct = 12.5 }, value = value })
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
    GetPriceSources = GetPriceSources,
    GetScale = Scale,
    SetScale = function(v)
        if not tdb then return end
        if v < MIN_SCALE then v = MIN_SCALE end
        if v > MAX_SCALE then v = MAX_SCALE end
        tdb.scale = v
        Reposition() -- reflows every active toast at the new scale immediately
    end,
    MIN_SCALE = MIN_SCALE,
    MAX_SCALE = MAX_SCALE,
}

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "CHAT_MSG_LOOT" then
        if not tdb or not tdb.enabled then return end
        for _, p in ipairs(LOOT_SELF_PATTERNS) do
            local itemString, count = arg1:match(p.pattern)
            if itemString then
                local link = itemString:match("|Hitem:.-|h%[.-%]|h")
                if link then
                    OnLoot(link, p.counted and tonumber(count) or 1)
                end
                return
            end
        end
    elseif event == "ADDON_LOADED" then
        if arg1 ~= "Refactor" then return end
        if type(RefactorCompareDB) ~= "table" then RefactorCompareDB = {} end
        if type(RefactorCompareDB.toast) ~= "table" then
            RefactorCompareDB.toast = {}
        end
        tdb = RefactorCompareDB.toast
        if tdb.enabled == nil then tdb.enabled = true end
        if tdb.scale == nil then tdb.scale = DEFAULT_SCALE end
        if tdb.showValue == nil then tdb.showValue = true end
        -- Only whitelisted AH sources are selectable now ("vendor" and
        -- most tsm:* keys were dropped); migrate stale picks to auto.
        local src = tdb.priceSource
        local tsmKey = type(src) == "string" and src:match("^tsm:(.+)")
        if src == nil or src == "vendor"
            or (tsmKey and not TSM_SOURCE_WHITELIST[tsmKey]) then
            tdb.priceSource = "auto"
        end
    end
end)
