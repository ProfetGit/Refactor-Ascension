-- RefactorUI
-- The addon's control panel: one window that manages every Refactor
-- feature — gear compare, stat weights, profiles, loot alerts & toasts,
-- interface tweaks — plus the minimap button that opens it.
--
-- All reads/writes go through the small tables the other files export
-- (RefactorCompareShared, RefactorToastShared, RefactorQoL); no compare
-- or toast logic lives here. Every change applies immediately (bag
-- arrows refresh, tweaks re-check their flag at use time), so there is
-- no Apply/OK step.
--
-- Look: the DiamondMetal atlas frame border over a flat dark
-- background, a header ribbon, red panel buttons, native checkbox and
-- input-box art, quest-log gold highlights — so the window reads as
-- part of the game, not a web panel dropped into it. Three columns:
-- sidebar (search + nav), the option list, and a detail pane that
-- explains whatever the mouse is over (option descriptions live there,
-- not under the rows). Native behavior kept: Escape closes, the header
-- drags.

local SOLID = "Interface\\ChatFrame\\ChatFrameBackground" -- tintable solid

-- Palette (r, g, b) — Blizzard's own warm colors. ACCENT is the stock
-- gold of NORMAL_FONT_COLOR; the addon's chat green stays in chat.
local ACCENT   = { 1.00, 0.82, 0.00 }
local C_BORDER = { 0.45, 0.40, 0.28 } -- warm border for the quality chips
local C_DIM    = { 0.62, 0.56, 0.44 } -- warm gray for descriptions
local C_PARCH  = { 0.85, 0.80, 0.68 } -- parchment-white for idle nav labels

-- Three-column layout (like the retail-style options panels): sidebar
-- with search + nav, the option list in the middle, and a detail pane on
-- the right that explains whatever the mouse is over.
local W_WIDTH, W_HEIGHT = 920, 600
local SIDEBAR_W = 170
local DETAIL_W = 210
local HEADER_H = 42
local PAD = 16
local INSET = 11 -- thickness the DiamondMetal border art eats
local BORDER_SIZE = 32 -- display size of the -8x DiamondMetal border pieces
-- Center column right edge: detail pane + its divider gutter.
local CENTER_RIGHT = INSET + DETAIL_W + 18
local CONTENT_W = W_WIDTH - (INSET + SIDEBAR_W + PAD) - CENTER_RIGHT -- 484

local function CS() return RefactorCompareShared end
local function DB()
    local s = CS()
    return s and s.GetDB and s.GetDB() or nil
end
local function TDB()
    return RefactorToastShared and RefactorToastShared.GetDB() or nil
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor|r: " .. msg)
end

local function RefreshBags()
    local s = CS()
    if s and s.RefreshOpenBags then s.RefreshOpenBags() end
end

--------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------

local function SetFlat(frame, bg, border, bgAlpha)
    frame:SetBackdrop({ bgFile = SOLID, edgeFile = SOLID, edgeSize = 1 })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bgAlpha or 1)
    if border then
        frame:SetBackdropBorderColor(border[1], border[2], border[3], 1)
    else
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end
end

-- Explanations render in the right-hand detail pane, not GameTooltip:
-- hovering a control puts its title + body there and leaves them until
-- the next hover or a page switch (sticky, so text doesn't flicker away
-- while the mouse travels). SetDetail is bound in BuildWindow.
local SetDetail

-- Modal confirm/prompt popup (built near BuildWindow, below); forward
-- declared so the earlier page builders can call it from button handlers.
local ShowPopup

-- HookScript (not SetScript) so widgets keep their own hover styling.
local function Explain(widget, title, body)
    widget:HookScript("OnEnter", function()
        if SetDetail then SetDetail(title, body) end
    end)
end

-- Everything a MakeCheck row shows also lands here, feeding the sidebar
-- search: label + body matched case-insensitively, page key to jump to.
local searchRegistry = {}
local function RegisterOption(label, body, pageKey)
    tinsert(searchRegistry, {
        label = label, body = body, page = pageKey,
        needle = (label .. " " .. (body or "")):lower(),
    })
end

-- Section header: stock-gold label (GameFontNormal's own color) over a
-- gold hairline that fades out to the right, with a small gold stud at
-- its left end (the diamond-finial divider look; true 45° rotation isn't
-- possible on 3.3.5 textures, a 4px stud reads the same at this size).
-- Returns the y where content below should start.
local function Section(parent, text, x, y, width)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", x, y)
    h:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(SOLID)
    line:SetGradientAlpha("HORIZONTAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0.35,
        ACCENT[1], ACCENT[2], ACCENT[3], 0)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", x, y - 16)
    line:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + width, y - 16)
    local stud = parent:CreateTexture(nil, "ARTWORK")
    stud:SetTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.8)
    stud:SetWidth(4)
    stud:SetHeight(4)
    stud:SetPoint("CENTER", line, "LEFT", 2, 0)
    return y - 26
end

local function SmallText(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
    fs:SetText(text)
    return fs
end

-- Checkbox row: stock checkbox art (UICheckButtonTemplate's anatomy,
-- drawn by hand so the whole row stays the click target) plus a
-- single-line label — the description shows in the detail pane on hover
-- instead of under the label, keeping rows one line tall like the stock
-- options list. Rows highlight full-width on hover and feed the search.
-- isEnabled (optional): predicate for a sub-option gated by another flag.
-- While false the row dims and ignores clicks, but its saved value is left
-- untouched so it comes back as-was when the parent is re-enabled.
local function MakeCheck(parent, x, y, width, label, desc, get, set, tip, isEnabled)
    local row = CreateFrame("Button", nil, parent)
    row:SetPoint("TOPLEFT", x, y)
    row:SetWidth(width)
    row:SetHeight(20)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.35)
    hl:SetAllPoints()

    -- The 24px art carries ~4px of transparent padding, hence the bleed.
    local box = row:CreateTexture(nil, "ARTWORK")
    box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    box:SetWidth(24)
    box:SetHeight(24)
    box:SetPoint("LEFT", -3, 0)

    local mark = row:CreateTexture(nil, "OVERLAY")
    mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    mark:SetAllPoints(box)

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", box, "RIGHT", 2, 0)
    text:SetJustifyH("LEFT")
    text:SetText(label)

    local info = desc
    if desc and tip then
        info = desc .. "\n\n" .. tip
    elseif tip then
        info = tip
    end
    Explain(row, label, info)
    RegisterOption(label, info, parent.pageKey)

    row.enabled = true
    row.Refresh = function(self)
        if get() then mark:Show() else mark:Hide() end
        self.enabled = not isEnabled or (isEnabled() and true or false)
        self:SetAlpha(self.enabled and 1 or 0.4)
    end
    row:SetScript("OnClick", function(self)
        if not self.enabled then return end
        set(not get())
        self:Refresh()
    end)
    return row
end

-- Resolves an atlas name onto a texture. SetAtlas is preferred;
-- GetAtlasInfo + manual texcoords is the fallback if it is missing.
local function ApplyAtlas(tex, atlas)
    if tex.SetAtlas then
        tex:SetAtlas(atlas)
        return
    end
    local info = GetAtlasInfo and GetAtlasInfo(atlas)
    if not info then return end
    tex:SetTexture(info.file)
    tex:SetTexCoord(info.leftTexCoord, info.rightTexCoord,
                    info.topTexCoord, info.bottomTexCoord)
end

-- Keeps only the rightmost `keep` fraction of a texture's current
-- texcoord span (squares off the over-wide redbutton right cap).
local function CropRightTexCoord(tex, keep)
    local ulx, uly, _, lly, urx, ury, _, lry = tex:GetTexCoord()
    local nl = urx - (urx - ulx) * keep
    tex:SetTexCoord(nl, uly, nl, lly, urx, ury, urx, lry)
end

-- Crops a texture's current texcoord rect (already set by ApplyAtlas) down
-- to the pixel range [x1,x2]x[y1,y2] of a srcW x srcH source region — the
-- manual nine-slice this client's plain textures can't apply on their own
-- (the CommonDropdown2x atlas ships slice= data for it, but that's a
-- retail 9-slice hint this client's SetAtlas doesn't act on).
local function CropTexCoordRect(tex, srcW, srcH, x1, y1, x2, y2)
    local ulx, uly, _, lly, urx, ury, _, lry = tex:GetTexCoord()
    local spanX, spanY = urx - ulx, lly - uly
    local nx1, nx2 = ulx + spanX * (x1 / srcW), ulx + spanX * (x2 / srcW)
    local ny1, ny2 = uly + spanY * (y1 / srcH), uly + spanY * (y2 / srcH)
    tex:SetTexCoord(nx1, ny1, nx1, ny2, nx2, ny1, nx2, ny2)
end

-- Horizontal three-slice strip (fixed end caps, stretched middle) cut from
-- one atlas image via CropTexCoordRect, stretched to fill `region`. Used
-- for both the dropdown pill (whole button) and the list-row hover strip
-- (common-dropdown-textholder). Returns a Show/Hide pair driving all three
-- pieces as one unit.
local function BuildStripH(region, atlas, srcW, srcH, capL, capR, layer)
    local left = region:CreateTexture(nil, layer or "ARTWORK")
    ApplyAtlas(left, atlas)
    CropTexCoordRect(left, srcW, srcH, 0, 0, capL, srcH)
    left:SetWidth(capL)
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", 0, 0)

    local center = region:CreateTexture(nil, layer or "ARTWORK")
    ApplyAtlas(center, atlas)
    CropTexCoordRect(center, srcW, srcH, capL, 0, srcW - capR, srcH)
    center:SetPoint("TOPLEFT", capL, 0)
    center:SetPoint("BOTTOMRIGHT", -capR, 0)

    local right = region:CreateTexture(nil, layer or "ARTWORK")
    ApplyAtlas(right, atlas)
    CropTexCoordRect(right, srcW, srcH, srcW - capR, 0, srcW, srcH)
    right:SetWidth(capR)
    right:SetPoint("TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", 0, 0)

    local pieces = { left, center, right }
    return {
        Show = function() for _, t in ipairs(pieces) do t:Show() end end,
        Hide = function() for _, t in ipairs(pieces) do t:Hide() end end,
    }
end

-- Nine-slice panel (fixed corners, stretched edges, stretched center fill)
-- cut from one atlas image — the CommonDropdown2x list background.
local function BuildNineSlicePanel(region, atlas, srcW, srcH, capL, capT, capR, capB)
    local function piece(x1, y1, x2, y2)
        local t = region:CreateTexture(nil, "BACKGROUND")
        ApplyAtlas(t, atlas)
        CropTexCoordRect(t, srcW, srcH, x1, y1, x2, y2)
        return t
    end

    local tl = piece(0, 0, capL, capT)
    tl:SetSize(capL, capT)
    tl:SetPoint("TOPLEFT", 0, 0)
    local tr = piece(srcW - capR, 0, srcW, capT)
    tr:SetSize(capR, capT)
    tr:SetPoint("TOPRIGHT", 0, 0)
    local bl = piece(0, srcH - capB, capL, srcH)
    bl:SetSize(capL, capB)
    bl:SetPoint("BOTTOMLEFT", 0, 0)
    local br = piece(srcW - capR, srcH - capB, srcW, srcH)
    br:SetSize(capR, capB)
    br:SetPoint("BOTTOMRIGHT", 0, 0)

    local top = piece(capL, 0, srcW - capR, capT)
    top:SetHeight(capT)
    top:SetPoint("TOPLEFT", capL, 0)
    top:SetPoint("TOPRIGHT", -capR, 0)

    local bottom = piece(capL, srcH - capB, srcW - capR, srcH)
    bottom:SetHeight(capB)
    bottom:SetPoint("BOTTOMLEFT", capL, 0)
    bottom:SetPoint("BOTTOMRIGHT", -capR, 0)

    local left = piece(0, capT, capL, srcH - capB)
    left:SetWidth(capL)
    left:SetPoint("TOPLEFT", 0, -capT)
    left:SetPoint("BOTTOMLEFT", 0, capB)

    local right = piece(srcW - capR, capT, srcW, srcH - capB)
    right:SetWidth(capR)
    right:SetPoint("TOPRIGHT", 0, -capT)
    right:SetPoint("BOTTOMRIGHT", 0, capB)

    local center = piece(capL, capT, srcW - capR, srcH - capB)
    center:SetPoint("TOPLEFT", capL, -capT)
    center:SetPoint("BOTTOMRIGHT", -capR, capB)
end

-- Red panel button from the 128-redbutton atlas set: left/right caps
-- around the tiling center, drawn as three ARTWORK textures per state
-- (a Button's NormalTexture is a single texture, so three-slice states
-- are swapped by hand). The right slice ships 292px wide and is cropped
-- to the left cap's 114px.
-- The right slices are the mixed-case "128-RedButton-Right*" names: this
-- client registers those separately from the all-lowercase spellings the
-- other slices use, and the lowercase right variants resolve to older art.
local RB_CAP = 114 / 128      -- cap width as a fraction of button height
local RB_RIGHT_KEEP = 114 / 292

local function MakeButton(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)

    local capW = math.min(math.floor(h * RB_CAP + 0.5), math.floor(w / 2))
    local stateAtlases = {
        normal   = { "128-redbutton-left", "_128-redbutton-center", "128-RedButton-Right" },
        pressed  = { "128-redbutton-left-pressed", "_128-redbutton-center-pressed", "128-RedButton-Right-Pressed" },
        disabled = { "128-redbutton-left-disabled", "_128-redbutton-center-disabled", "128-RedButton-Right-Disabled" },
    }

    local groups = {}
    for state, atlases in pairs(stateAtlases) do
        local left = b:CreateTexture(nil, "ARTWORK")
        ApplyAtlas(left, atlases[1])
        left:SetWidth(capW)
        left:SetPoint("TOPLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", 0, 0)

        local center = b:CreateTexture(nil, "ARTWORK")
        ApplyAtlas(center, atlases[2])
        center:SetPoint("TOPLEFT", capW, 0)
        center:SetPoint("BOTTOMRIGHT", -capW, 0)

        local right = b:CreateTexture(nil, "ARTWORK")
        ApplyAtlas(right, atlases[3])
        CropRightTexCoord(right, RB_RIGHT_KEEP)
        right:SetWidth(capW)
        right:SetPoint("TOPRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", 0, 0)

        groups[state] = { left, center, right }
    end

    local function ShowState(state)
        for name, g in pairs(groups) do
            for i = 1, 3 do
                if name == state then g[i]:Show() else g[i]:Hide() end
            end
        end
    end

    -- One full-width highlight art, stretched over the assembled button.
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    ApplyAtlas(hl, "128-redbutton-highlight")
    hl:SetAllPoints(b)
    hl:SetBlendMode("ADD")

    b:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then ShowState("pressed") end
    end)
    b:SetScript("OnMouseUp", function(self)
        ShowState(self:IsEnabled() and "normal" or "disabled")
    end)
    b:SetScript("OnEnable", function() ShowState("normal") end)
    b:SetScript("OnDisable", function() ShowState("disabled") end)
    ShowState("normal")

    local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("CENTER", 0, 0)
    b:SetFontString(t)
    b:SetNormalFontObject(GameFontNormal)
    b:SetDisabledFontObject(GameFontDisable)
    b:SetText(label)
    b.text = t
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- common-dropdown-b-button (CommonDropdown2x atlas): a 97x26 pill with the
-- dropdown chevron baked into its right cap, slice={8,0,18,0} — left cap
-- 8px, right cap 18px, middle stretches. None of Refactor's dropdowns are
-- ever disabled, so only the states the click handler actually drives are
-- built (the kit also has disabled/open/pressedhover for a future caller).
local DD_PILL_W, DD_PILL_H = 97, 26
local DD_PILL_CAP_L, DD_PILL_CAP_R = 8, 18
local DD_PILL_ATLAS_STATES = {
    normal  = "common-dropdown-b-button-2x",
    hover   = "common-dropdown-b-button-hover-2x",
    pressed = "common-dropdown-b-button-pressed-2x",
}

-- Builds one BuildStripH per state and returns a ShowState(name) setter
-- that shows exactly one at a time.
local function BuildDropdownPill(parent)
    local groups = {}
    for state, atlas in pairs(DD_PILL_ATLAS_STATES) do
        local strip = BuildStripH(parent, atlas, DD_PILL_W, DD_PILL_H,
            DD_PILL_CAP_L, DD_PILL_CAP_R)
        strip.Hide() -- BuildStripH's textures start shown; stack all three
                     -- and only the active one is revealed below
        groups[state] = strip
    end
    local current
    local function ShowState(state)
        if current then current.Hide() end
        current = groups[state]
        current.Show()
    end
    ShowState("normal")
    return ShowState
end

--------------------------------------------------------------------------
-- Dropdown popup list (common-dropdown-bg panel + common-dropdown-
-- textholder row highlight + the yellow checkmark icon) — a full custom
-- replacement for Blizzard's UIDropDownMenu list frame, not a reskin of
-- it, since that frame's own art can't be swapped out from under it.
-- One shared list frame (nothing here stacks); items are plain
-- {text, checked, func} tables the dropdown's itemsFn returns.
--------------------------------------------------------------------------
local DD_BG_ATLAS = "common-dropdown-bg-2x"
local DD_BG_W, DD_BG_H = 68, 68
local DD_BG_L, DD_BG_T, DD_BG_R, DD_BG_B = 16, 13, 16, 19 -- asymmetric: baked drop shadow at the bottom

local DD_ROWSTRIP_ATLAS = "common-dropdown-textholder-2x"
local DD_ROWSTRIP_W, DD_ROWSTRIP_H = 54, 41
local DD_ROWSTRIP_CAP_L, DD_ROWSTRIP_CAP_R = 16, 19
local DD_ROW_H = 24
-- Row label insets: the left one clears the checkmark column.
local DD_LABEL_L, DD_LABEL_R = 30, 10
-- The list is free to be wider than its pill (it opens over the page, and
-- profile names like "Knight of Xoroth - Defiance" don't fit a 200px pill).
-- Capped so a stray long name can't run off the window.
local DD_MAX_W = 420

local ddList, ddBlocker

local function HideDropdownList()
    if ddList then
        ddList:Hide()
        ddList.owner = nil
    end
end

local function BuildDropdownList()
    -- Full-screen catcher behind the list: closes it on an outside click.
    local blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetAllPoints(UIParent)
    blocker:SetFrameStrata("FULLSCREEN_DIALOG")
    blocker:SetFrameLevel(1)
    blocker:Hide()
    blocker:SetScript("OnClick", HideDropdownList)
    ddBlocker = blocker

    local list = CreateFrame("Frame", "RefactorUIDropdownList", UIParent)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetFrameLevel(10)
    list:SetToplevel(true)
    list:SetClampedToScreen(true)
    list:Hide()
    BuildNineSlicePanel(list, DD_BG_ATLAS, DD_BG_W, DD_BG_H,
        DD_BG_L, DD_BG_T, DD_BG_R, DD_BG_B)
    list.rows = {}
    -- Hidden, width-unconstrained twin of a row label: the real labels are
    -- anchored LEFT+RIGHT, so their GetStringWidth reports the constrained
    -- (truncated) width and can't size the list. This one measures the
    -- text's natural width instead.
    list.measure = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    list.measure:SetPoint("TOPLEFT")
    list.measure:Hide()
    -- The blocker only exists to back an open list, so bind it to the
    -- list's visibility here: every close path (row click, outside click,
    -- Escape via UISpecialFrames, window close) runs through OnHide, so
    -- the full-screen catcher can never outlive the list it belongs to.
    list:SetScript("OnHide", function()
        if ddBlocker then ddBlocker:Hide() end
    end)
    tinsert(UISpecialFrames, "RefactorUIDropdownList") -- Escape closes
    ddList = list
    return list
end

local function GetDropdownRow(list, index)
    local row = list.rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, list)
    row:SetHeight(DD_ROW_H)

    local hl = BuildStripH(row, DD_ROWSTRIP_ATLAS, DD_ROWSTRIP_W, DD_ROWSTRIP_H,
        DD_ROWSTRIP_CAP_L, DD_ROWSTRIP_CAP_R, "ARTWORK")
    hl.Hide()

    local check = row:CreateTexture(nil, "OVERLAY")
    ApplyAtlas(check, "common-dropdown-icon-checkmark-yellow-2x")
    check:SetSize(15, 14)
    check:SetPoint("LEFT", 10, 0)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", DD_LABEL_L, 0)
    label:SetPoint("RIGHT", -DD_LABEL_R, 0)
    label:SetJustifyH("LEFT")

    row:SetScript("OnEnter", function() hl.Show() end)
    row:SetScript("OnLeave", function() hl.Hide() end)
    row:SetScript("OnClick", function(self)
        HideDropdownList()
        if self.onClick then self.onClick() end
    end)

    row.hl, row.check, row.label = hl, check, label
    list.rows[index] = row
    return row
end

local function OpenDropdownList(dd)
    local list = ddList or BuildDropdownList()
    local items = dd.itemsFn and dd.itemsFn() or {}

    -- Width first: measure every entry's natural text width so long profile
    -- names read in full. The pill's width is the floor, DD_MAX_W the cap.
    local chrome = DD_LABEL_L + DD_LABEL_R + DD_BG_L + DD_BG_R
    local w = dd:GetWidth()
    for _, item in ipairs(items) do
        list.measure:SetText(item.text)
        local need = list.measure:GetStringWidth() + chrome
        if need > w then w = need end
    end
    w = math.min(math.ceil(w), DD_MAX_W)

    for i, item in ipairs(items) do
        local row = GetDropdownRow(list, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", DD_BG_L, -(DD_BG_T + (i - 1) * DD_ROW_H))
        row:SetWidth(w - DD_BG_L - DD_BG_R)
        row.label:SetText(item.text)
        row.onClick = item.func
        if item.checked then row.check:Show() else row.check:Hide() end
        row:Show()
    end
    for i = #items + 1, #list.rows do
        list.rows[i]:Hide()
    end

    list:SetWidth(w)
    list:SetHeight(DD_BG_T + math.max(#items, 1) * DD_ROW_H + DD_BG_B)
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    list.owner = dd
    list:Show()
    ddBlocker:Show()
end

-- Retail-style dropdown: the CommonDropdown2x pill as the closed-state
-- button, opening a fully custom list (above) instead of Blizzard's
-- UIDropDownMenu — that frame's own art can't be swapped from under it,
-- so this doesn't reskin it, it replaces it outright. `width` sets the
-- pill's (and the popup list's) width; the caller assigns `dd.itemsFn`
-- (a function returning an array of {text, checked, func}) and positions
-- `dd` like any other widget — no template, no global name required.
local function MakeDropdown(parent, width)
    local dd = CreateFrame("Frame", nil, parent)
    dd:SetSize(width, 26)

    local ShowState = BuildDropdownPill(dd)

    local text = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", 14, 1)
    text:SetPoint("RIGHT", -20, 1)
    text:SetJustifyH("LEFT")
    dd.text = text
    dd.SetText = function(self, t) self.text:SetText(t or "") end

    local click = CreateFrame("Button", nil, dd)
    click:SetAllPoints(dd)
    click.enabled = true
    click:SetScript("OnEnter", function(self)
        if self.enabled then ShowState("hover") end
    end)
    click:SetScript("OnLeave", function(self)
        if self.enabled then ShowState("normal") end
    end)
    click:SetScript("OnMouseDown", function(self)
        if self.enabled then ShowState("pressed") end
    end)
    click:SetScript("OnMouseUp", function(self)
        if not self.enabled then return end
        ShowState(self:IsMouseOver() and "hover" or "normal")
    end)
    click:SetScript("OnClick", function()
        if not click.enabled then return end
        if ddList and ddList:IsShown() and ddList.owner == dd then
            HideDropdownList()
        else
            OpenDropdownList(dd)
        end
    end)
    dd.click = click

    return dd
end

-- Retail-style minimal scrollbar (minimal-scrollbar-small atlas kit) for
-- UIPanelScrollFrameTemplate scrollbars, which are fully named. Stock
-- art is hidden; the arrows get atlas normal/over/down overlays swapped
-- by scripts; the engine-driven thumb keeps its behavior but wears the
-- atlas middle with cap textures over its ends (thumb over/down states
-- exist in the kit but the thumb is a texture, not a button — no mouse
-- scripts, so it stays in the normal state); a three-piece track sits
-- behind it.
local function SkinMinimalScrollbar(scroll)
    local sb = _G[scroll:GetName() .. "ScrollBar"]
    if not sb then return end
    local sbName = sb:GetName()
    local thumb = sb.GetThumbTexture and sb:GetThumbTexture()
                  or _G[sbName .. "ThumbTexture"]

    -- Hide the stock track art ($parentTop/Middle/Bottom regions).
    for i = 1, sb:GetNumRegions() do
        local r = select(i, sb:GetRegions())
        if r and r:IsObjectType("Texture") and r ~= thumb then r:Hide() end
    end

    local function Arrow(btnName, base)
        local btn = _G[sbName .. btnName]
        if not btn then return end
        for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture",
                                  "GetHighlightTexture", "GetDisabledTexture" }) do
            local t = btn[getter](btn)
            if t then t:SetAlpha(0) end
        end
        local function overlay(atlas)
            local t = btn:CreateTexture(nil, "OVERLAY")
            ApplyAtlas(t, atlas)
            t:SetSize(17, 11)
            t:SetPoint("CENTER", 0, 0)
            t:Hide()
            return t
        end
        local up, over, down = overlay(base), overlay(base .. "-over"), overlay(base .. "-down")
        local pressed = false
        local function Refresh()
            up:Hide() over:Hide() down:Hide()
            if pressed then down:Show()
            elseif btn:IsMouseOver() then over:Show()
            else up:Show() end
        end
        btn:HookScript("OnEnter", Refresh)
        btn:HookScript("OnLeave", function() pressed = false Refresh() end)
        btn:HookScript("OnMouseDown", function() pressed = true Refresh() end)
        btn:HookScript("OnMouseUp", function() pressed = false Refresh() end)
        Refresh()
    end
    Arrow("ScrollUpButton", "minimal-scrollbar-small-arrow-top")
    Arrow("ScrollDownButton", "minimal-scrollbar-small-arrow-bottom")

    -- Track behind the thumb, spanning between the two arrows.
    local trackTop = sb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackTop, "minimal-scrollbar-small-track-top")
    trackTop:SetSize(8, 8)
    trackTop:SetPoint("TOP", 0, -12)
    local trackBot = sb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackBot, "minimal-scrollbar-small-track-bottom")
    trackBot:SetSize(8, 8)
    trackBot:SetPoint("BOTTOM", 0, 12)
    local trackMid = sb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackMid, "!minimal-scrollbar-small-track-middle")
    trackMid:SetWidth(8)
    trackMid:SetPoint("TOP", trackTop, "BOTTOM", 0, 0)
    trackMid:SetPoint("BOTTOM", trackBot, "TOP", 0, 0)

    if thumb then
        ApplyAtlas(thumb, "minimal-scrollbar-small-thumb-middle")
        thumb:SetWidth(8)
        local capTop = sb:CreateTexture(nil, "OVERLAY")
        ApplyAtlas(capTop, "minimal-scrollbar-small-thumb-top")
        capTop:SetSize(8, 8)
        capTop:SetPoint("CENTER", thumb, "TOP", 0, 0)
        local capBot = sb:CreateTexture(nil, "OVERLAY")
        ApplyAtlas(capBot, "minimal-scrollbar-small-thumb-bottom")
        capBot:SetSize(8, 8)
        capBot:SetPoint("CENTER", thumb, "BOTTOM", 0, 0)
        -- The engine hides the thumb when the content fits; the caps
        -- anchored to it must follow (textures have no OnHide script).
        -- Polled rather than event-driven because the engine hides the
        -- ThumbTexture directly and textures carry no OnHide script. 10 Hz
        -- is plenty for a cosmetic cap follow — at 60 Hz this was two C
        -- calls per frame per scrollbar for as long as the window was open.
        local capAccum = 0
        sb:HookScript("OnUpdate", function(_, elapsed)
            capAccum = capAccum + (elapsed or 0)
            if capAccum < 0.1 then return end
            capAccum = 0
            local show = thumb:IsShown() and true or false
            if (capTop:IsShown() and true or false) ~= show then
                if show then capTop:Show() capBot:Show()
                else capTop:Hide() capBot:Hide() end
            end
        end)
    end
end

-- Three-slice input-field border from the common-search atlas (16x40 caps
-- around a tiling middle), drawn as BACKGROUND textures filling `frame`.
-- capW scales the 16px cap to the field's height. Returns the {left, right,
-- mid} list so callers can tint it (gold on focus). Shared by MakeEdit
-- (numeric fields) and MakeSearchBox.
local function ApplySearchBorder(frame, height, capW)
    local left = frame:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(left, "common-search-border-left")
    left:SetSize(capW, height)
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", 0, 0)

    local right = frame:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(right, "common-search-border-right")
    right:SetSize(capW, height)
    right:SetPoint("TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", 0, 0)

    local mid = frame:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(mid, "common-search-border-middle")
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)

    return { left, right, mid }
end

-- Edit box wearing the common-search border art (same kit as the sidebar
-- search, minus the glyph/clear button). Border tints gold on focus.
-- With get/set (numeric): commits on Enter / focus lost, reverts on
-- Escape. Without: plain text field, read via GetText().
local EDIT_H = 22
local EDIT_CAP = 9 -- 16px cap scaled from the atlas's 40px native height
local function MakeEdit(parent, w, get, set)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetWidth(w)
    eb:SetHeight(EDIT_H)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextInsets(8, 8, 0, 0)

    local border = ApplySearchBorder(eb, EDIT_H, EDIT_CAP)

    eb:SetScript("OnEditFocusGained", function(self)
        for _, t in ipairs(border) do
            t:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3])
        end
        self:HighlightText()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        self.reverting = true
        self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        for _, t in ipairs(border) do t:SetVertexColor(1, 1, 1) end
        self:HighlightText(0, 0)
        if get and set then
            if not self.reverting then
                local v = tonumber(self:GetText())
                if v then set(v) end
            end
            self:Refresh()
        end
        self.reverting = nil
    end)
    eb.Refresh = function(self)
        if get then self:SetText(tostring(get() or 0)) end
    end
    return eb
end

-- Search box wearing the common-search atlas kit: left/right caps (16x40
-- native) around a tiling middle, a magnifying-glass glyph pinned at the
-- left and a clear button at the right that appears only while there's
-- text. The border tints gold on focus like MakeEdit. Returns the EditBox
-- (so SetText/GetText/ClearFocus work directly); the caller wires its own
-- OnTextChanged via HookScript for the actual filtering. The internal
-- affordance/focus handlers are all HookScript too, so caller and widget
-- coexist without either clobbering the other's OnTextChanged.
local SEARCH_H = 26
local SEARCH_CAP = 10 -- 16px cap scaled from the atlas's 40px native height
local function MakeSearchBox(parent, width)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width, SEARCH_H)

    local border = ApplySearchBorder(container, SEARCH_H, SEARCH_CAP)

    local icon = container:CreateTexture(nil, "OVERLAY")
    ApplyAtlas(icon, "common-search-magnifyingglass")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 8, 0)

    local clear = CreateFrame("Button", nil, container)
    clear:SetSize(13, 13)
    clear:SetPoint("RIGHT", -(SEARCH_CAP - 1), 0)
    local clearTex = clear:CreateTexture(nil, "OVERLAY")
    ApplyAtlas(clearTex, "common-search-clearbutton")
    clearTex:SetAllPoints()
    clear:Hide()

    local eb = CreateFrame("EditBox", nil, container)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextInsets(2, 2, 0, 0)
    eb:SetHeight(SEARCH_H)
    eb:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    eb:SetPoint("RIGHT", clear, "LEFT", -3, 0)

    local placeholder = eb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search")

    local function UpdateAffordances()
        local has = (eb:GetText() or "") ~= ""
        if has then clear:Show() else clear:Hide() end
        if has or eb:HasFocus() then placeholder:Hide() else placeholder:Show() end
    end

    clear:SetScript("OnClick", function()
        eb:SetText("")
        eb:SetFocus()
    end)

    eb:HookScript("OnTextChanged", UpdateAffordances)
    eb:HookScript("OnEditFocusGained", function()
        for _, t in ipairs(border) do
            t:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3])
        end
        UpdateAffordances()
    end)
    eb:HookScript("OnEditFocusLost", function()
        for _, t in ipairs(border) do t:SetVertexColor(1, 1, 1) end
        UpdateAffordances()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    eb.container = container
    return eb
end

-- Options slider wearing the MinimalSliderBar atlas kit (Left + tiling
-- _Middle + Right track, Button thumb) instead of OptionsSliderTemplate's
-- stock art; the template still supplies behavior, so the engine keeps
-- driving the thumb. Needs a global name — the template's Low/High/Text
-- labels are $parent-relative and only resolve with one; every caller
-- must pass a unique name. Low/High/Text go blank (the row already
-- carries its own label) and the live value reads instead in a small
-- fontstring to the slider's right.
-- get/set still deal in the widget's own min..max units; displayBase (optional)
-- only rescales the readout — passing the value that should read "1.00" makes
-- that the visible "default size" mark without moving where it sits physically
-- on the track.
local function MakeSlider(parent, name, w, minV, maxV, step, get, set, displayBase)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetWidth(w)
    s:SetHeight(17)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    _G[name .. "Low"]:SetText("")
    _G[name .. "High"]:SetText("")
    _G[name .. "Text"]:SetText("")

    -- MinimalSliderBar art: hide the stock track regions, re-lay the
    -- three-piece track, and re-skin the engine thumb.
    local thumb = s.GetThumbTexture and s:GetThumbTexture()
    for i = 1, s:GetNumRegions() do
        local r = select(i, s:GetRegions())
        if r:IsObjectType("Texture") and r ~= thumb then r:Hide() end
    end
    local trackL = s:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackL, "Minimal_SliderBar_Left")
    trackL:SetSize(11, 17)
    trackL:SetPoint("LEFT", 0, 0)
    local trackR = s:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackR, "Minimal_SliderBar_Right")
    trackR:SetSize(11, 17)
    trackR:SetPoint("RIGHT", 0, 0)
    local trackM = s:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(trackM, "_Minimal_SliderBar_Middle")
    trackM:SetHeight(17)
    trackM:SetPoint("LEFT", trackL, "RIGHT", 0, 0)
    trackM:SetPoint("RIGHT", trackR, "LEFT", 0, 0)
    if thumb then
        ApplyAtlas(thumb, "Minimal_SliderBar_Button")
        thumb:SetSize(20, 19)
    end

    local valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", s, "RIGHT", 10, 0)
    local function Display(value)
        if displayBase and displayBase ~= 0 then value = value / displayBase end
        valueText:SetText(string.format("%.2f", value))
    end

    s:SetScript("OnValueChanged", function(self, value)
        Display(value)
        if not self.suppress and set then set(value) end
    end)
    s.Refresh = function(self)
        local v = (get and get()) or minV
        self.suppress = true
        self:SetValue(v)
        self.suppress = nil
        Display(v)
    end
    return s
end

--------------------------------------------------------------------------
-- Window shell: header, sidebar navigation, page plumbing
--------------------------------------------------------------------------

local window
local navButtons = {}
local pages = {}
local currentKey

-- "search" is a page too (results list), just never in the nav.
local PAGE_ORDER = { "general", "weights", "loot", "tweaks" }
local PAGE_TITLES = {
    general = "General", weights = "Stat Weights",
    loot = "Loot", tweaks = "Tweaks", search = "Search",
}

local function NewPage(key)
    local p = CreateFrame("Frame", nil, window)
    p:SetPoint("TOPLEFT", INSET + SIDEBAR_W + PAD, -(HEADER_H + 14))
    p:SetPoint("BOTTOMRIGHT", -CENTER_RIGHT, PAD + 6)
    p:Hide()
    p.pageKey = key
    p.tracked = {}
    p.Track = function(self, widget)
        tinsert(self.tracked, widget)
        return widget
    end
    p.Refresh = function(self)
        for _, w in ipairs(self.tracked) do
            if w.Refresh then w:Refresh() end
        end
        if self.OnRefresh then self:OnRefresh() end
    end
    pages[key] = p
    return p
end

local function UpdateNav()
    -- Active page: gold dot bullet + gold label; everything else parchment.
    -- (currentKey may be "search", which has no nav button — all deselect.)
    for key, b in pairs(navButtons) do
        if key == currentKey then
            b.dot:Show()
            b.label:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        else
            b.dot:Hide()
            b.label:SetTextColor(C_PARCH[1], C_PARCH[2], C_PARCH[3])
        end
    end
end

local function UpdateFooter()
    if not window then return end
    local d = DB()
    window.footer:SetText("Profile  |cffffffff"
        .. (d and d.activeProfile or "?") .. "|r")
end

local function SelectPage(key)
    HideDropdownList() -- an open dropdown belongs to the page being left
    currentKey = key
    for k, p in pairs(pages) do
        if k == key then p:Show() else p:Hide() end
    end
    UpdateNav()
    UpdateFooter()
    if pages[key] then pages[key]:Refresh() end
    -- Reset the detail pane to the page's own summary.
    if SetDetail and pages[key] then
        SetDetail(PAGE_TITLES[key] or "", pages[key].blurb)
    end
end

--------------------------------------------------------------------------
-- Page: General
--------------------------------------------------------------------------

local function BuildGeneralPage()
    local p = NewPage("general")
    p.blurb = "Master switches: gear compare, bag upgrade arrows, the quality " ..
        "cutoff, armor-type filters and the minimap button.\n\nHover any option " ..
        "to read about it here."

    local y = Section(p, "Gear compare", 0, 0, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Enable gear compare",
        "Master switch — verdicts, bag arrows, quest markers and loot alerts.",
        function() return DB().enabled end,
        function(v) DB().enabled = v; RefreshBags() end))
    y = y - 28

    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Green arrows on bag upgrades",
        "Marks bag items that beat your equipped gear under current weights.",
        function() return DB().bagIcons end,
        function(v) DB().bagIcons = v; RefreshBags() end))
    y = y - 28

    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Blue arrows for secondary profile",
        "Also marks bag items that beat your equipped gear under the " ..
        "secondary profile's weights, top-left corner of the icon. Off by default.",
        function() return DB().secondaryBagArrow end,
        function(v) DB().secondaryBagArrow = v; RefreshBags() end))
    y = y - 28

    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Smart equip rings, trinkets and weapons",
        "Right-click equip replaces the weaker of the two equipped items " ..
        "under current weights, instead of always the first slot. Needs " ..
        "readable stats on both equipped items, or it leaves the click alone.",
        function() return DB().smartEquip ~= false end,
        function(v) DB().smartEquip = v end))
    y = y - 36

    -- Minimum quality: six swatches in item-quality colors. Qualities
    -- below the pick render dim — the row shows the cutoff at a glance.
    local qLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    qLabel:SetPoint("TOPLEFT", 0, y - 3)
    qLabel:SetText("Minimum quality")

    local qHolder = CreateFrame("Frame", nil, p)
    qHolder:SetPoint("TOPLEFT", 130, y)
    qHolder:SetWidth(CONTENT_W - 130)
    qHolder:SetHeight(20)
    local qName = qHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qName:SetPoint("LEFT", 6 * 25 + 8, 0)
    local qCells = {}
    for q = 0, 5 do
        local c = CreateFrame("Button", nil, qHolder)
        c:SetWidth(18)
        c:SetHeight(18)
        c:SetPoint("LEFT", q * 25, 0)
        local col = ITEM_QUALITY_COLORS[q]
        SetFlat(c, { col.r * 0.85, col.g * 0.85, col.b * 0.85 }, C_BORDER)
        c:SetScript("OnClick", function()
            DB().minQuality = q
            RefreshBags()
            qHolder:Refresh()
        end)
        Explain(c, col.hex .. _G["ITEM_QUALITY" .. q .. "_DESC"] .. "|r",
            "Items below the chosen quality are ignored — no verdicts, no arrows, no alerts.")
        qCells[q] = c
    end
    qHolder.Refresh = function(self)
        local sel = DB().minQuality or 0
        for q, c in pairs(qCells) do
            if q == sel then
                c:SetAlpha(1)
                c:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
            else
                c:SetAlpha(q < sel and 0.25 or 0.9)
                c:SetBackdropBorderColor(0, 0, 0, 0.7)
            end
        end
        local col = ITEM_QUALITY_COLORS[sel]
        qName:SetText(col.hex .. _G["ITEM_QUALITY" .. sel .. "_DESC"] .. "|r")
    end
    p:Track(qHolder)
    y = y - 36

    y = Section(p, "Armor types considered", 0, y - 8, CONTENT_W)
    local armorTip = "Unchecked armor types are never shown as upgrades. Only applies to " ..
        "body armor — rings, trinkets, cloaks and weapons always count.\n\n" ..
        "Saved per character and never changed for you: armor this character " ..
        "can't actually wear is already filtered out by the item's own red " ..
        "proficiency line, learned proficiencies included."
    local armorTypes = { "Cloth", "Leather", "Mail", "Plate" }
    for i, at in ipairs(armorTypes) do
        p:Track(MakeCheck(p, (i - 1) * 100, y, 95, at, nil,
            function() return CS().GetArmorType(at) end,
            function(v) CS().SetArmorType(at, v); RefreshBags() end,
            armorTip))
    end
    y = y - 30

    y = Section(p, "Minimap", 0, y - 8, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Show minimap button",
        "Left-click opens settings, right-click toggles compare, drag to move.",
        function()
            local db = DB()
            return not (db.minimap and db.minimap.hide)
        end,
        function(v)
            local db = DB()
            if type(db.minimap) ~= "table" then db.minimap = {} end
            db.minimap.hide = not v
            if RefactorUI.UpdateMinimapButton then RefactorUI.UpdateMinimapButton() end
        end))
    y = y - 30

    y = Section(p, "Updates", 0, y - 8, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "New version notice",
        "Prints a chat line when a guild or group member runs a newer " ..
        "Refactor than yours. Versions travel on hidden addon messages — " ..
        "nothing is ever shown to other players.",
        function() return RefactorQoL and RefactorQoL.Get("versionCheck") end,
        function(v) if RefactorQoL then RefactorQoL.Set("versionCheck", v) end end))
end

--------------------------------------------------------------------------
-- Page: Stat Weights (scrollable — profile management, spec picker,
-- the weight grid, custom stats)
--------------------------------------------------------------------------

local function BuildWeightsPage()
    local p = NewPage("weights")
    p.blurb = "Profiles, per-spec default weights, and the per-stat numbers " ..
        "that drive every verdict, arrow and alert."

    local scroll = CreateFrame("ScrollFrame", "RefactorUIWeightsScroll", p,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G[self:GetName() .. "ScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * 40) end
    end)
    SkinMinimalScrollbar(scroll)

    local INNER_W = CONTENT_W - 26
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(INNER_W)
    child:SetHeight(600) -- corrected after the custom-stat list is laid out
    child.pageKey = "weights" -- MakeCheck reads it off its direct parent
    scroll:SetScrollChild(child)

    local shared = CS()
    local y = 0

    -- Profile ---------------------------------------------------------------
    -- Profiles ARE stat-weight sets, so they live on this page: a dropdown
    -- to switch, popups to save-as / rename / delete.
    y = Section(child, "Profile", 0, y, INNER_W)
    SmallText(child, "A profile is a saved set of stat weights, shared account-wide. " ..
        "Each character remembers which one it picked.", 0, y, INNER_W)
    y = y - 30

    local dd = MakeDropdown(child, 200)
    dd:SetPoint("TOPLEFT", 0, y)
    dd.itemsFn = function()
        local d = DB()
        if not d then return {} end
        local names = {}
        for n in pairs(d.profiles) do tinsert(names, n) end
        table.sort(names)
        local items = {}
        for _, n in ipairs(names) do
            tinsert(items, {
                text = n,
                checked = (d.activeProfile == n),
                func = function()
                    shared.SetActiveProfile(n)
                    RefreshBags()
                    Print("switched to profile '" .. n .. "'.")
                    RefactorUI.Refresh()
                end,
            })
        end
        return items
    end
    dd.Refresh = function(self)
        self:SetText(DB().activeProfile or "")
    end
    p:Track(dd)
    y = y - 34

    local saveAsBtn = MakeButton(child, 96, 22, "Save as...", function()
        ShowPopup({
            text = "Save current weights as:",
            hasEditBox = true,
            onAccept = function(name)
                name = (name or ""):match("^%s*(.-)%s*$")
                if name ~= "" then
                    CS().SaveProfileAs(name)
                    RefreshBags()
                end
            end,
        })
    end)
    saveAsBtn:SetPoint("TOPLEFT", 2, y)
    Explain(saveAsBtn, "Save as",
        "Saves the current weights as a new profile and switches to it. " ..
        "Reusing an existing name overwrites that profile.")

    local renameBtn = MakeButton(child, 92, 22, "Rename...", function()
        local current = DB().activeProfile
        ShowPopup({
            text = string.format("Rename profile '%s' to:", current),
            hasEditBox = true,
            editDefault = current,
            editHighlight = true,
            onAccept = function(name)
                name = (name or ""):match("^%s*(.-)%s*$")
                local s = CS()
                if name ~= "" and s and s.RenameProfile then
                    s.RenameProfile(current, name)
                end
            end,
        })
    end)
    renameBtn:SetPoint("TOPLEFT", 104, y)
    renameBtn.Refresh = function(self)
        if DB().activeProfile == "Default" then self:Disable() else self:Enable() end
    end
    p:Track(renameBtn)
    Explain(renameBtn, "Rename",
        "Renames the active profile everywhere — every character pointing at it " ..
        "follows along. Default and class-spec profiles keep their names " ..
        "(auto-selection finds those by name); copy them with Save as instead.")

    local deleteBtn = MakeButton(child, 80, 22, "Delete", function()
        local name = DB().activeProfile
        ShowPopup({
            text = string.format("Delete profile '%s'?", name),
            button1 = YES, button2 = NO,
            onAccept = function()
                CS().DeleteProfile(name)
            end,
        })
    end)
    deleteBtn:SetPoint("TOPLEFT", 202, y)
    deleteBtn.Refresh = function(self)
        if DB().activeProfile == "Default" then self:Disable() else self:Enable() end
    end
    p:Track(deleteBtn)
    Explain(deleteBtn, "Delete profile",
        "Deletes the active profile (asks first). Characters using it fall back " ..
        "to Default.")
    y = y - 38

    -- Secondary verdict -----------------------------------------------------
    -- Hybrid builds gear two roles at once: a second profile whose verdict
    -- shows in blue alongside the active profile's green/red, on tooltips
    -- and bag arrows both. Per-character, manual-only (auto-selection never
    -- picks one), "None" turns it off.
    y = Section(child, "Secondary verdict", 0, y, INNER_W)
    SmallText(child, "Show a second profile's verdict in blue next to the active " ..
        "profile's — for gearing two roles at the same time.", 0, y, INNER_W)
    y = y - 30

    local secDD = MakeDropdown(child, 200)
    secDD:SetPoint("TOPLEFT", 0, y)
    secDD.itemsFn = function()
        local d = DB()
        if not d then return {} end
        local cur = shared.SecondaryProfileName and shared.SecondaryProfileName()
        local items = {
            { text = "None", checked = (cur == nil),
              func = function() shared.SetSecondaryProfile(nil) end },
        }
        local names = {}
        for n in pairs(d.profiles) do tinsert(names, n) end
        table.sort(names)
        for _, n in ipairs(names) do
            -- The active profile is excluded: its verdict is already the
            -- primary one, doubling it would be noise.
            if n ~= d.activeProfile then
                tinsert(items, {
                    text = n,
                    checked = (cur == n),
                    func = function() shared.SetSecondaryProfile(n) end,
                })
            end
        end
        return items
    end
    secDD.Refresh = function(self)
        local cur = shared.SecondaryProfileName and shared.SecondaryProfileName()
        self:SetText(cur or "None")
    end
    p:Track(secDD)
    Explain(secDD.click, "Secondary verdict",
        "Picks a second profile whose upgrade verdict appears in blue alongside " ..
        "the active profile's green/red one — on item tooltips (its own line) " ..
        "and bag arrows (blue arrow, top-left corner). Blue arrow = upgrade for " ..
        "the secondary profile.\n\n" ..
        "|cffff8060Caveat: both verdicts compare against what you're currently " ..
        "wearing. If your two roles use different gearsets, the secondary verdict " ..
        "scores the hovered item against your worn gear through the secondary " ..
        "profile's weights — read it as an estimate in that case.|r")
    y = y - 38

    -- Spec profiles --------------------------------------------------------
    -- One button per spec of the player's class. Gearing role is a choice,
    -- not a consequence of talents: a tank can keep collecting DPS gear by
    -- picking the DPS spec here. Clicking counts as a deliberate profile
    -- choice, so auto-selection won't fight it (/rfc auto hands control back).
    local specs = shared.GetClassSpecs and shared.GetClassSpecs()
    if specs and #specs > 0 then
        y = Section(child, "Spec profiles", 0, y, INNER_W)
        SmallText(child, "Default weights per spec of your class — pick the role " ..
            "you're gearing for, it doesn't have to match your talents.", 0, y, INNER_W)
        y = y - 30
        for i, spec in ipairs(specs) do
            local b = MakeButton(child, 102, 22, spec.label, function()
                shared.SelectSpecProfile(spec.label)
                RefreshBags()
                RefactorUI.Refresh()
            end)
            b:SetPoint("TOPLEFT", (i - 1) % 4 * 107, y - math.floor((i - 1) / 4) * 26)
            b.Refresh = function(self)
                -- Active spec: keep the button lit, text white-hot.
                if DB().activeProfile == spec.profileName then
                    self:LockHighlight()
                    self.text:SetTextColor(1, 1, 1)
                else
                    self:UnlockHighlight()
                    self.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
                end
            end
            p:Track(b)
            Explain(b, spec.label,
                "Switch to the '" .. spec.profileName .. "' profile (created from the " ..
                "default weights for this spec if you haven't edited it)." ..
                "\n\n|cff999999Fine-tune the numbers below afterwards — your edits are kept.|r")
        end
        y = y - math.ceil(#specs / 4) * 26 - 12
    end

    -- Hit cap --------------------------------------------------------------
    -- Hit rating past the cap is wasted; below it, it's valuable. Per profile,
    -- pick which cap applies (melee 8% / ranged 8% / spell 17%). The addon
    -- then values hit at the profile's HIT weight up to the cap — measured
    -- against the hit you already wear — and ~zero past it. Off = plain linear.
    y = Section(child, "Hit cap", 0, y, INNER_W)
    SmallText(child, "Value hit rating only until you're capped, counting the hit " ..
        "you already wear. Reads your live rating — matches the character sheet's " ..
        "hit X/Y display.", 0, y, INNER_W)
    y = y - 34

    local HITCAP_LABELS = { off = "Off", melee = "Melee (8%)", ranged = "Ranged (8%)", spell = "Spell (17%)", custom = "Custom" }
    local hcDD = MakeDropdown(child, 160)
    hcDD:SetPoint("TOPLEFT", 0, y)
    hcDD.itemsFn = function()
        local cur = (shared.GetHitCapMode and shared.GetHitCapMode()) or "off"
        local items = {}
        for _, m in ipairs({ "off", "melee", "ranged", "spell", "custom" }) do
            tinsert(items, {
                text = HITCAP_LABELS[m],
                checked = (cur == m),
                func = function()
                    if shared.SetHitCapMode then shared.SetHitCapMode(m) end
                    RefreshBags()
                    RefactorUI.Refresh()
                end,
            })
        end
        return items
    end
    hcDD.Refresh = function(self)
        local cur = (shared.GetHitCapMode and shared.GetHitCapMode()) or "off"
        self:SetText(HITCAP_LABELS[cur] or "Off")
    end
    p:Track(hcDD)
    Explain(hcDD.click, "Hit cap",
        "Hit rating stops helping once you reach the cap. With this on, an item's " ..
        "hit counts at the profile's Hit Rating weight up to the cap (given the hit " ..
        "already on your other gear) and as worthless past it — so a capped character " ..
        "stops seeing hit-heavy items as upgrades.\n\n" ..
        "|cffffd200Never-miss caps|r (PvE raid boss / PvP player):\n" ..
        "  Melee  - 8% PvE / 5% PvP\n" ..
        "  Ranged - 8% PvE / 5% PvP\n" ..
        "  Spell  - 17% PvE / 4% PvP\n" ..
        "Pick the one your build uses to deal damage.\n\n" ..
        "The checkbox below switches the scoring target between the PvE and " ..
        "PvP cap — use it if you're gearing for PvP and want to stop valuing " ..
        "hit past the lower PvP number.\n\n" ..
        "The cap rating is read live from the game, so it tracks your level.\n\n" ..
        "|cffffd200Custom|r: type your own target rating directly, skipping the " ..
        "%→rating conversion above — use this if talent or racial flat-% hit " ..
        "means your real cap is lower than the built-in number. Still needs a " ..
        "melee/ranged/spell pick below, since the same rating converts to a " ..
        "different % for each.\n\n" ..
        "|cffff8060Note: only counts hit from gear (rating), matching the character " ..
        "sheet's X/Y number - talent and racial hit isn't included by the built-in " ..
        "percentages. Compares against your currently equipped gear.|r")

    local hcReadout = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hcReadout:SetPoint("TOPLEFT", 172, y - 6)
    hcReadout.Refresh = function(self)
        local info = shared.HitCapInfo and shared.HitCapInfo()
        if not info or info.mode == "off" then
            self:SetText("")
            return
        end
        if info.cap then
            local refStr = ""
            if info.refCap then
                local refLabel = info.pvp and "PvE" or "PvP"
                refStr = string.format("  |cff999999(%s cap %d)|r",
                    refLabel, math.floor(info.refCap + 0.5))
            end
            self:SetText(string.format("Current %d  /  Cap %d",
                info.current or 0, math.floor(info.cap + 0.5)) .. refStr)
        else
            self:SetText("Current " .. (info.current or 0) ..
                "  /  Cap —  (equip some hit to read the cap)")
        end
    end
    p:Track(hcReadout)
    y = y - 28

    p:Track(MakeCheck(child, 0, y, INNER_W, "Target PvP cap (lower %)",
        "Score against the PvP never-miss cap instead of the PvE one. " ..
        "The other cap is shown in grey for reference.",
        function() return shared.GetHitCapPvP and shared.GetHitCapPvP() or false end,
        function(v) if shared.SetHitCapPvP then shared.SetHitCapPvP(v) end; RefreshBags(); RefactorUI.Refresh() end,
        nil,
        function()
            local m = shared.GetHitCapMode and shared.GetHitCapMode() or "off"
            return m ~= "off" and m ~= "custom"
        end))
    y = y - 30

    -- Custom mode: a type picker (still needed for the rating conversion)
    -- plus the target rating itself, typed directly.
    local HITCAP_TYPE_LABELS = { melee = "Melee", ranged = "Ranged", spell = "Spell" }
    local hcTypeLabel = SmallText(child, "Type", 0, y, 40)
    p:Track(hcTypeLabel)
    hcTypeLabel.Refresh = function(self)
        local shown = (shared.GetHitCapMode and shared.GetHitCapMode()) == "custom"
        if shown then self:Show() else self:Hide() end
    end

    local hcTypeDD = MakeDropdown(child, 100)
    hcTypeDD:SetPoint("TOPLEFT", 40, y + 12)
    hcTypeDD.itemsFn = function()
        local cur = (shared.GetHitCapCustomType and shared.GetHitCapCustomType()) or "melee"
        local items = {}
        for _, t in ipairs({ "melee", "ranged", "spell" }) do
            tinsert(items, {
                text = HITCAP_TYPE_LABELS[t],
                checked = (cur == t),
                func = function()
                    if shared.SetHitCapCustomType then shared.SetHitCapCustomType(t) end
                    RefreshBags()
                    RefactorUI.Refresh()
                end,
            })
        end
        return items
    end
    hcTypeDD.Refresh = function(self)
        local shown = (shared.GetHitCapMode and shared.GetHitCapMode()) == "custom"
        if shown then self:Show() else self:Hide() end
        if shown then
            local cur = (shared.GetHitCapCustomType and shared.GetHitCapCustomType()) or "melee"
            self:SetText(HITCAP_TYPE_LABELS[cur] or "Melee")
        end
    end
    p:Track(hcTypeDD)
    Explain(hcTypeDD.click, "Custom cap type",
        "Which combat table your typed rating targets — the same rating converts " ..
        "to a different hit % for melee, ranged, and spell.")

    local hcRatingLabel = SmallText(child, "Target rating", 148, y, 84)
    p:Track(hcRatingLabel)
    hcRatingLabel.Refresh = function(self)
        local shown = (shared.GetHitCapMode and shared.GetHitCapMode()) == "custom"
        if shown then self:Show() else self:Hide() end
    end

    local hcRatingEdit = MakeEdit(child, 60,
        function() return shared.GetHitCapCustomRating and shared.GetHitCapCustomRating() end,
        function(v) if shared.SetHitCapCustomRating then shared.SetHitCapCustomRating(v) end; RefreshBags(); RefactorUI.Refresh() end)
    hcRatingEdit:SetPoint("TOPLEFT", 236, y + 12)
    local hcRatingRefreshBase = hcRatingEdit.Refresh
    hcRatingEdit.Refresh = function(self)
        local shown = (shared.GetHitCapMode and shared.GetHitCapMode()) == "custom"
        if shown then self:Show() else self:Hide() end
        if shown then hcRatingRefreshBase(self) end
    end
    p:Track(hcRatingEdit)
    Explain(hcRatingEdit, "Target rating",
        "Your own hit-rating cap, computed with talents/racials already folded in. " ..
        "0 or blank = cap unknown (treated the same as off until you set it).")
    y = y - 30

    -- Weight grid ----------------------------------------------------------
    local sectionTop = y
    y = Section(child, "Stat weights", 0, y, INNER_W)
    SmallText(child, "score = stat amount × weight, summed. Weight 0 ignores the stat.",
        0, y, INNER_W)
    y = y - 18

    -- Info icon: short label above only covers the formula. The tooltip
    -- covers the rest of the pipeline players actually ask about — how the
    -- % verdict is derived and why some items show no verdict at all.
    local infoBtn = CreateFrame("Frame", nil, child)
    infoBtn:SetWidth(20)
    infoBtn:SetHeight(14)
    infoBtn:SetPoint("TOPLEFT", 82, sectionTop - 3)
    infoBtn:EnableMouse(true)
    local infoText = infoBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    infoText:SetPoint("CENTER", 0, 0)
    infoText:SetText("(?)")
    Explain(infoBtn, "How verdicts are calculated",
        "Each stat on an item is multiplied by its weight below and summed into a single " ..
        "score (weapon DPS counts as its own pseudo-stat). Your hovered item's score is " ..
        "compared against your currently equipped item(s) in that slot, and the % " ..
        "difference is what shows as the verdict.\n\n" ..
        "|cff9999ffExample: with Strength weight 1 and Stamina weight 1, an item with " ..
        "+10 Strength and +5 Stamina scores 15. If your equipped item scores 12, the " ..
        "new item shows as a +25% upgrade.|r")

    local resetBtn = MakeButton(child, 130, 20, "Reset to defaults", function()
        if shared.ResetActiveProfileWeights() then
            RefreshBags()
            RefactorUI.Refresh()
        end
    end)
    resetBtn:SetPoint("TOPLEFT", INNER_W - 130, sectionTop)
    p:Track(resetBtn)
    Explain(resetBtn, "Reset to defaults",
        "Discards your edits and restores this spec's default weights. Only works on " ..
        "a class-spec profile, not a custom saved profile.")

    local ROWS = 11
    for i, s in ipairs(shared.STATS) do
        local col = math.floor((i - 1) / ROWS)
        local row = (i - 1) % ROWS
        local x = col * 218
        local ry = y - row * 26

        local label = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", x, ry - 5)
        label:SetText(s.label)
        label.Refresh = function(self)
            -- Grey out ignored stats so what feeds the score reads at a glance.
            local w = shared.Weights()[s.key]
            if not w or w == 0 then
                self:SetTextColor(0.45, 0.45, 0.50)
            else
                self:SetTextColor(1, 1, 1)
            end
        end
        p:Track(label)

        local eb = MakeEdit(child, 52,
            function() return shared.Weights()[s.key] end,
            function(v)
                shared.Weights()[s.key] = v
                RefreshBags()
                label:Refresh()
            end)
        eb:SetPoint("TOPLEFT", x + 150, ry)
        Explain(eb, s.label, (s.tip or "") .. "\n\n|cff9999990 = ignore this stat.|r")
        p:Track(eb)
    end
    y = y - ROWS * 26 - 10

    -- Custom scanned stats ---------------------------------------------------
    local customSectionTop = y
    y = Section(child, "Custom scanned stats", 0, y, INNER_W)
    SmallText(child,
        "Ascension-only stats picked up while scanning score at the Unknown weight " ..
        "until you give them their own value here.", 0, y, INNER_W)

    local customInfoBtn = CreateFrame("Frame", nil, child)
    customInfoBtn:SetWidth(20)
    customInfoBtn:SetHeight(14)
    customInfoBtn:SetPoint("TOPLEFT", 165, customSectionTop - 3)
    customInfoBtn:EnableMouse(true)
    local customInfoText = customInfoBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customInfoText:SetPoint("CENTER", 0, 0)
    customInfoText:SetText("(?)")
    Explain(customInfoBtn, "Adding a custom stat weight",
        "1. Hover the item and read the line exactly as it appears on the tooltip " ..
        "(e.g. \"Vampirism\" or \"Fire Resistance\"). Case doesn't matter.\n" ..
        "2. Type that wording into the box below, set a weight, click Add.\n" ..
        "3. Any item carrying that line now scores it at your weight instead of Unknown.\n\n" ..
        "|cff9999ffPercent effects (meta gem halves, \"3% Increased Critical Damage\", " ..
        "percent Equip: lines) show up under a \"<name> %\" entry — add that exact name " ..
        "including the trailing %.|r\n\n" ..
        "|cff999999Same thing from chat: /rfc weight <stat name> <value>. Weight 0 makes " ..
        "the addon ignore the stat entirely.|r")

    y = y - 34
    local customStartY = y

    local emptyText = SmallText(child,
        "None yet. Add one below using the stat's tooltip wording, e.g. \"vampirism\".",
        0, customStartY, INNER_W)

    local customRows = {}
    local function GetCustomRow(i)
        local r = customRows[i]
        if not r then
            r = CreateFrame("Frame", nil, child)
            r:SetWidth(INNER_W)
            r:SetHeight(22)

            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.name:SetPoint("TOPLEFT", 0, -5)
            r.name:SetWidth(230)
            r.name:SetJustifyH("LEFT")

            r.edit = MakeEdit(r, 52,
                function()
                    local cw = shared.ActiveProfile().customWeights
                    return r.statName and cw[r.statName] or 0
                end,
                function(v)
                    if r.statName then
                        shared.ActiveProfile().customWeights[r.statName] = v
                        RefreshBags()
                    end
                end)
            r.edit:SetPoint("TOPLEFT", 240, 0)

            r.remove = MakeButton(r, 20, 20, "×", function()
                if r.statName then
                    shared.ActiveProfile().customWeights[r.statName] = nil
                    RefreshBags()
                    RefactorUI.Refresh()
                end
            end)
            r.remove:SetPoint("TOPLEFT", 300, 0)
            Explain(r.remove, "Remove",
                "Drop this custom weight — the stat falls back to the Unknown weight.")

            customRows[i] = r
        end
        return r
    end

    -- Add row: stat name + weight + Add.
    local addName = MakeEdit(child, 180)
    local addValue = MakeEdit(child, 52)
    local addBtn = MakeButton(child, 60, 20, "Add", function()
        local name = (addName:GetText() or ""):match("^%s*(.-)%s*$"):lower()
        if name == "" then return end
        local v = tonumber(addValue:GetText()) or 0
        shared.ActiveProfile().customWeights[name] = v
        addName:SetText("")
        addValue:SetText("")
        addName:ClearFocus()
        addValue:ClearFocus()
        RefreshBags()
        RefactorUI.Refresh()
    end, true)
    Explain(addBtn, "Add custom stat weight",
        "Use the exact wording the stat has on item tooltips (case doesn't matter).")

    p.OnRefresh = function(self)
        local cw = shared.ActiveProfile().customWeights
        local names = {}
        for n in pairs(cw) do tinsert(names, n) end
        table.sort(names)

        for i, r in ipairs(customRows) do r:Hide() end
        for i, n in ipairs(names) do
            local r = GetCustomRow(i)
            r.statName = n
            r.name:SetText(n)
            r.edit:Refresh()
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, customStartY - (i - 1) * 24)
            r:Show()
        end

        if #names == 0 then emptyText:Show() else emptyText:Hide() end

        local addY = customStartY - #names * 24 - (#names == 0 and 20 or 4)
        addName:ClearAllPoints()
        addName:SetPoint("TOPLEFT", 0, addY)
        addValue:ClearAllPoints()
        addValue:SetPoint("TOPLEFT", 188, addY)
        addBtn:ClearAllPoints()
        addBtn:SetPoint("TOPLEFT", 248, addY)

        child:SetHeight(-addY + 40)
    end
end

--------------------------------------------------------------------------
-- Page: Loot
--------------------------------------------------------------------------

local function BuildLootPage()
    local p = NewPage("loot")
    p.blurb = "What happens at the loot moment: chat lines for upgrades and " ..
        "the animated loot toasts."

    local y = Section(p, "Chat alerts", 0, 0, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Announce upgrades in chat",
        "Prints a chat line when fresh loot beats your equipped gear.",
        function() return DB().lootAlert end,
        function(v) DB().lootAlert = v end))
    y = y - 36

    y = Section(p, "Loot toasts", 0, y - 8, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Show loot toasts",
        "Popup for each looted item — upgrades glow green and linger.",
        function()
            local t = TDB()
            return t and t.enabled or false
        end,
        function(v)
            local t = TDB()
            if t then t.enabled = v end
        end))
    y = y - 36
    do
        local ts = RefactorToastShared
        local minS = (ts and ts.MIN_SCALE) or 0.6
        local maxS = (ts and ts.MAX_SCALE) or 1.8
        local label = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 0, y - 5)
        label:SetText("Toast scale")
        p:Track(label)
        local slider = MakeSlider(p, "RefactorUIToastScaleSlider", 140,
            minS, maxS, 0.05,
            function() return ts and ts.GetScale() end,
            function(v) if ts then ts.SetScale(v) end end)
        slider:SetPoint("TOPLEFT", 130, y - 3)
        local desc = "Size of the loot toasts. Use Test toast below to preview."
        Explain(slider, "Toast scale", desc)
        RegisterOption("Toast scale", desc, p.pageKey)
        p:Track(slider)
        if not ts then slider:Disable() end
    end
    y = y - 28

    -- Item value ------------------------------------------------------------
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Show item value",
        "Shows what the looted stack is worth on the toast's second line.",
        function()
            local t = TDB()
            return t and t.showValue or false
        end,
        function(v)
            local t = TDB()
            if t then t.showValue = v end
        end))
    y = y - 30

    do
        local label = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 0, y - 9)
        label:SetText("Price source")

        -- Sources are re-discovered every time the menu opens, so a TSM or
        -- Auctionator install/removal is picked up without a /reload.
        local dd = MakeDropdown(p, 190)
        dd:SetPoint("TOPLEFT", 96, y)
        dd.itemsFn = function()
            local ts = RefactorToastShared
            local t = TDB()
            if not (ts and ts.GetPriceSources and t) then return {} end
            local items = {}
            for _, src in ipairs(ts.GetPriceSources()) do
                tinsert(items, {
                    text = src.label,
                    checked = (t.priceSource == src.key),
                    func = function()
                        t.priceSource = src.key
                        RefactorUI.Refresh()
                    end,
                })
            end
            return items
        end
        dd.Refresh = function(self)
            local ts = RefactorToastShared
            local t = TDB()
            if not (ts and ts.GetPriceSources and t) then
                self:SetText("")
                return
            end
            -- A saved source whose addon is gone still shows its raw key, so
            -- the player can see what's selected and why nothing prints.
            local text = t.priceSource or "auto"
            for _, src in ipairs(ts.GetPriceSources()) do
                if src.key == t.priceSource then
                    text = src.label
                    break
                end
            end
            self:SetText(text)
        end
        p:Track(dd)
        local desc = "Where the value comes from — auction house prices only. " ..
            "Auto tries TSM market value, then minimum buyout, then Auctionator. " ..
            "These prices only exist for items you've scanned at the auction " ..
            "house; when the source knows nothing, the toast shows no value. " ..
            "Vendor sell price is never shown — addons can only read the base " ..
            "item's price, which contradicts the scaled Sell Price in the tooltip."
        Explain(dd.click, "Price source", desc)
        RegisterOption("Price source", desc, p.pageKey)
    end
    y = y - 34

    local moveBtn
    moveBtn = MakeButton(p, 130, 22, "Move toasts", function()
        local ts = RefactorToastShared
        if not ts then return end
        if ts.IsAnchorShown() then ts.HideAnchor() else ts.ShowAnchor() end
        moveBtn:Refresh()
    end)
    moveBtn:SetPoint("TOPLEFT", 0, y)
    moveBtn.Refresh = function(self)
        local ts = RefactorToastShared
        if ts and ts.IsAnchorShown() then
            self.text:SetText("Done — position saved")
            self:LockHighlight()
        else
            self.text:SetText("Move toasts")
            self:UnlockHighlight()
        end
    end
    p:Track(moveBtn)
    Explain(moveBtn, "Move toasts",
        "Shows a green drag handle where toasts appear. Drag it, then click again to save.")

    local resetBtn = MakeButton(p, 130, 22, "Reset position", function()
        if RefactorToastShared then RefactorToastShared.ResetPosition() end
        Print("toast position reset.")
    end)
    resetBtn:SetPoint("TOPLEFT", 140, y)

    local testBtn = MakeButton(p, 110, 22, "Test toast", function()
        if RefactorToastShared then RefactorToastShared.Test() end
    end)
    testBtn:SetPoint("TOPLEFT", 280, y)
    Explain(testBtn, "Test toast",
        "Spawns two sample toasts — one plain, one styled as an upgrade.")
end

--------------------------------------------------------------------------
-- Page: Tweaks (the QoL features from Refactor.lua)
--------------------------------------------------------------------------

local function BuildTweaksPage()
    local p = NewPage("tweaks")
    p.blurb = "Quality-of-life switches: looting, questing, the world map, " ..
        "social auto-declines, tooltips, the crowd-control alert and error " ..
        "muting. Every flag applies instantly."
    local q = RefactorQoL

    -- Scrollable like the weights page — the section list outgrew the window.
    local scroll = CreateFrame("ScrollFrame", "RefactorUITweaksScroll", p,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local sb = _G[self:GetName() .. "ScrollBar"]
        if sb then sb:SetValue(sb:GetValue() - delta * 40) end
    end)
    SkinMinimalScrollbar(scroll)

    local INNER_W = CONTENT_W - 26
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(INNER_W)
    child.pageKey = "tweaks" -- MakeCheck reads it off its direct parent
    scroll:SetScrollChild(child)

    -- refreshPage: re-refresh the whole page after toggling, so rows whose
    -- isEnabled predicate depends on this flag dim/undim immediately.
    local function QolCheck(x, y, label, desc, key, isEnabled, refreshPage)
        return p:Track(MakeCheck(child, x, y, INNER_W - x, label, desc,
            function() return q and q.Get(key) end,
            function(v)
                if q then q.Set(key, v) end
                if refreshPage then RefactorUI.Refresh() end
            end,
            nil, isEnabled))
    end

    local disableAllBtn = MakeButton(child, 130, 22, "Disable all", function()
        ShowPopup({
            text = "Turn off every QoL tweak? You can then opt back into the ones you want, one at a time.",
            button1 = YES, button2 = NO,
            onAccept = function()
                if RefactorQoL then RefactorQoL.DisableAll() end
                RefactorUI.Refresh()
            end,
        })
    end)
    disableAllBtn:SetPoint("TOPLEFT", 0, 0)
    p:Track(disableAllBtn)
    Explain(disableAllBtn, "Disable all",
        "Turns off every tweak on this page in one click, so you can opt " ..
        "back into just the ones you want — like starting from Pawn's " ..
        "clean slate instead of hunting each one down. Gear compare, loot " ..
        "toasts and the CC alert live on their own pages and aren't affected.")

    local resetBtn = MakeButton(child, 130, 22, "Restore defaults", function()
        ShowPopup({
            text = "Restore all QoL tweaks to their defaults?",
            button1 = YES, button2 = NO,
            onAccept = function()
                if RefactorQoL then RefactorQoL.ResetDefaults() end
                RefactorUI.Refresh()
            end,
        })
    end)
    resetBtn:SetPoint("TOPLEFT", 140, 0)
    p:Track(resetBtn)
    Explain(resetBtn, "Restore defaults",
        "Resets every tweak on this page back to what it shipped with. " ..
        "Map window position/scale, minimap button, and the CC alert " ..
        "position are untouched.")

    local y = Section(child, "Looting", 0, -32, INNER_W)
    QolCheck(0, y, "Fast auto-loot",
        "Loots instantly, window hidden. Hold Shift for the normal window. Tied to the game's Auto Loot setting: turning that off turns this off too.",
        "fastLoot")
    y = y - 28
    QolCheck(0, y, "Auto-confirm bind-on-pickup",
        "Skips the \"will bind it to you\" popups when looting and rolling.",
        "autoConfirmBoP")
    y = y - 28
    QolCheck(0, y, "Auto-collect transmog appearances",
        "Learns appearances from soulbound bag items automatically.",
        "transmog", nil, true)
    y = y - 28
    QolCheck(20, y, "Include tradeable items (BoE)",
        "Also learns from unbound items — collecting soulbinds them.",
        "transmogBoE", function() return q and q.Get("transmog") end)
    y = y - 28
    QolCheck(0, y, "Skip the learn confirmation popup",
        "Auto-accepts the soulbound warning when you Ctrl+Shift-click to learn.",
        "transmogSkipConfirm")
    y = y - 36

    y = Section(child, "Merchants", 0, y - 8, INNER_W)
    QolCheck(0, y, "Auto-sell trash",
        "Sells every poor-quality (gray) bag item when you open a merchant. Hold Shift while opening to keep them.",
        "autoSellTrash")
    y = y - 28
    QolCheck(0, y, "Auto-repair",
        "Repairs all gear when you open a repair merchant, using your own money (never the guild bank). Hold Shift while opening to skip.",
        "autoRepair")
    y = y - 36

    y = Section(child, "Questing", 0, y - 8, INNER_W)
    QolCheck(0, y, "Auto-accept quests",
        "Accepts quest offers and escort confirmations. Hold Shift for the normal window.",
        "questAccept")
    y = y - 28
    QolCheck(0, y, "Auto turn-in quests",
        "Hands in completed quests. Multiple reward choices leave the window open.",
        "questTurnIn")
    y = y - 28
    QolCheck(0, y, "Auto-pick quest rewards",
        "Takes the reward that's the biggest upgrade under your stat weights; if none is an upgrade, takes the one with the highest sell value. Needs the gear comparison enabled. Skips the pick (leaving the window open) whenever the answer isn't clear-cut — an unreadable reward, an exact tie, or a reward your secondary profile wants. Hold Shift to decide yourself.",
        "questAutoReward", function()
            return RefactorCompareShared and RefactorCompareShared.IsEnabled()
        end)
    y = y - 28
    QolCheck(0, y, "Auto-pick quests from gossip",
        "Selects available and completable quests from NPC dialog menus.",
        "questGossip")
    y = y - 36

    y = Section(child, "Social", 0, y - 8, INNER_W)
    QolCheck(0, y, "Decline group invites",
        "Declines every party invite. Hold Shift as it arrives to accept manually.",
        "declineInvites")
    y = y - 28
    QolCheck(0, y, "Decline duels",
        "Cancels duel requests. Hold Shift as it arrives to duel anyway.",
        "declineDuels")
    y = y - 28
    QolCheck(0, y, "Decline guild invites",
        "Declines guild recruitment invites. Hold Shift as it arrives to consider it.",
        "declineGuilds")
    y = y - 28
    QolCheck(0, y, "Block trades from strangers",
        "Closes trades unless the other player is a friend, guildmate, or in your group.",
        "declineTrades")
    y = y - 28
    QolCheck(0, y, "Auto-resurrect in battlegrounds",
        "Instantly accepts resurrections from players while in a battleground.",
        "autoResBG")
    y = y - 28
    QolCheck(0, y, "Quick invite player",
        "Alt + Right-Click a player's unit frame, name in chat, or model in the world to quickly invite them to your party. Off by default.",
        "quickInvite")
    y = y - 28
    QolCheck(0, y, "Leave party on dungeon exit",
        "Also leaves the party when you click the Leave Dungeon button at the end of a dungeon.",
        "leavePartyOnDungeon")
    y = y - 36

    y = Section(child, "Bags", 0, y - 8, INNER_W)
    QolCheck(0, y, "Seamless bag upgrade",
        "Right-clicking a bag while all bag slots are full moves the smallest equipped bag's contents elsewhere and equips the new one in its place, instead of just erroring.",
        "seamlessBagUpgrade")
    y = y - 36

    y = Section(child, "Tooltips", 0, y - 8, INNER_W)
    QolCheck(0, y, "Anchor tooltip at the cursor",
        "The default tooltip follows the mouse instead of the corner.",
        "cursorTooltip")
    y = y - 28
    QolCheck(0, y, "Hide the unit health bar",
        "Removes the health bar under unit tooltips.",
        "hideHealthBar")
    y = y - 28
    QolCheck(0, y, "Quality-colored tooltip border",
        "Tints the tooltip border with the item's quality color.",
        "qualityBorder")
    y = y - 36

    y = Section(child, "Crowd control", 0, y - 8, INNER_W)
    local function CDB()
        return RefactorCCShared and RefactorCCShared.GetDB() or nil
    end
    local function CCCheck(x, y2, label, desc, key, isEnabled)
        return p:Track(MakeCheck(child, x, y2, INNER_W - x, label, desc,
            function()
                local c = CDB()
                return c and c[key] or false
            end,
            function(v)
                local c = CDB()
                if c then c[key] = v end
                if RefactorCCShared then RefactorCCShared.Update() end
                RefactorUI.Refresh()
            end,
            nil, isEnabled))
    end
    CCCheck(0, y, "Show crowd-control alert",
        "Big center-screen icon and timer while you're stunned, feared, or otherwise CC'd.",
        "enabled")
    y = y - 28
    CCCheck(20, y, "Include roots",
        "Also alerts on rooted and frozen effects.",
        "roots", function()
            local c = CDB()
            return c and c.enabled
        end)
    y = y - 28
    CCCheck(20, y, "Include silences and disarms",
        "Also alerts on silence and disarm effects.",
        "silences", function()
            local c = CDB()
            return c and c.enabled
        end)
    y = y - 28
    CCCheck(20, y, "Show countdown numbers",
        "Shows a digital countdown timer over the icon.",
        "showDuration", function()
            local c = CDB()
            return c and c.enabled
        end)
    y = y - 28
    CCCheck(20, y, "Announce to party/raid chat",
        "Posts a chat line when you're stunned, feared, silenced, or otherwise unable to cast — so healers and other key roles know to adjust immediately. Skips rooted/frozen/disarmed, since casting still works. Off by default.",
        "announce", function()
            local c = CDB()
            return c and c.enabled
        end)
    y = y - 28
    do
        local cs = RefactorCCShared
        local minS = (cs and cs.MIN_SCALE) or 0.6
        local maxS = (cs and cs.MAX_SCALE) or 2.0
        local label = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 20, y - 5)
        label:SetText("Alert scale")
        p:Track(label)
        local slider = MakeSlider(child, "RefactorUICCScaleSlider", 140,
            minS, maxS, 0.05,
            function() return cs and cs.GetScale() end,
            function(v) if cs then cs.SetScale(v) end end)
        slider:SetPoint("TOPLEFT", 150, y - 3)
        local desc = "Size of the center-screen crowd-control alert. Use Test alert below to preview."
        Explain(slider, "Alert scale", desc)
        RegisterOption("Alert scale", desc, child.pageKey)
        p:Track(slider)
        if not cs then slider:Disable() end
    end
    y = y - 28

    local ccMoveBtn
    ccMoveBtn = MakeButton(child, 130, 22, "Move alert", function()
        local cs = RefactorCCShared
        if not cs then return end
        if cs.IsAnchorShown() then cs.HideAnchor() else cs.ShowAnchor() end
        ccMoveBtn:Refresh()
    end)
    ccMoveBtn:SetPoint("TOPLEFT", 0, y)
    ccMoveBtn.Refresh = function(self)
        local cs = RefactorCCShared
        if cs and cs.IsAnchorShown() then
            self.text:SetText("Done — saved")
            self:LockHighlight()
        else
            self.text:SetText("Move alert")
            self:UnlockHighlight()
        end
    end
    p:Track(ccMoveBtn)
    Explain(ccMoveBtn, "Move alert",
        "Shows a green drag handle where the CC alert appears. Drag it, then click again to save.")

    local ccResetBtn = MakeButton(child, 130, 22, "Reset position", function()
        if RefactorCCShared then RefactorCCShared.ResetPosition() end
        Print("CC alert position reset.")
    end)
    ccResetBtn:SetPoint("TOPLEFT", 140, y)

    local ccTestBtn = MakeButton(child, 110, 22, "Test alert", function()
        if RefactorCCShared then RefactorCCShared.Test() end
    end)
    ccTestBtn:SetPoint("TOPLEFT", 280, y)
    Explain(ccTestBtn, "Test alert",
        "Shows a 4-second sample stun alert.")
    y = y - 36

    y = Section(child, "Errors", 0, y - 8, INNER_W)
    QolCheck(0, y, "Hide error text",
        "Hides the red \"Ability is not ready yet\" messages at the top of the screen.",
        "hideErrorText")
    y = y - 28
    QolCheck(0, y, "Mute error speech",
        "Silences the \"I can't do that yet\" voice when a cast fails.",
        "muteErrorSpeech")
    y = y - 28
    QolCheck(0, y, "Mute cast-deny sounds",
        "Silences the fizzle / error sound when a cast is denied. Needs the silent-sound client patch; untick to hear the sounds again.",
        "muteDenySounds")
    y = y - 28

    child:SetHeight(-y + 8)
end

--------------------------------------------------------------------------
-- Page: Search results (reached only by typing in the sidebar box)
--------------------------------------------------------------------------

local function BuildSearchPage()
    local p = NewPage("search")
    p.blurb = "Results from every page, matched against option names and " ..
        "descriptions. Click one to jump to its page."

    local listTop = Section(p, "Search results", 0, 0, CONTENT_W)
    local empty = SmallText(p,
        "Nothing matches. Options are searched by name and description.",
        0, listTop, CONTENT_W)

    local rows = {}
    local function GetRow(i)
        local r = rows[i]
        if not r then
            r = CreateFrame("Button", nil, p)
            r:SetWidth(CONTENT_W)
            r:SetHeight(22)
            local hl = r:CreateTexture(nil, "HIGHLIGHT")
            hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            hl:SetBlendMode("ADD")
            hl:SetAlpha(0.35)
            hl:SetAllPoints()
            r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.label:SetPoint("LEFT", 4, 0)
            r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.tag:SetPoint("RIGHT", -4, 0)
            r:SetScript("OnClick", function(self)
                if window.searchBox then
                    window.suppressSearch = true
                    window.searchBox:SetText("")
                    window.searchBox:ClearFocus()
                    window.suppressSearch = nil
                end
                SelectPage(self.target)
            end)
            r:SetScript("OnEnter", function(self)
                if SetDetail then SetDetail(self.titleText, self.bodyText) end
            end)
            rows[i] = r
        end
        return r
    end

    p.OnRefresh = function(self)
        local q = (self.query or ""):lower()
        local shown = 0
        for _, r in ipairs(rows) do r:Hide() end
        if q ~= "" then
            for _, opt in ipairs(searchRegistry) do
                if opt.needle:find(q, 1, true) then
                    shown = shown + 1
                    local r = GetRow(shown)
                    r.label:SetText(opt.label)
                    r.tag:SetText(PAGE_TITLES[opt.page] or "")
                    r.target = opt.page or "general"
                    r.titleText = opt.label
                    r.bodyText = opt.body
                    r:ClearAllPoints()
                    r:SetPoint("TOPLEFT", 0, listTop - (shown - 1) * 24)
                    r:Show()
                end
            end
        end
        if shown == 0 then empty:Show() else empty:Hide() end
    end
end

--------------------------------------------------------------------------
-- Window construction
--------------------------------------------------------------------------

-- The DiamondMetal atlas set (corners + tiling edges) drawn as eight
-- OVERLAY textures around the frame.
local function BuildMetalBorder(f)
    local S = BORDER_SIZE
    local function piece(atlas)
        local t = f:CreateTexture(nil, "OVERLAY")
        ApplyAtlas(t, atlas)
        return t
    end

    local tl = piece("UI-Frame-DiamondMetal-CornerTopLeft-8x")
    tl:SetSize(S, S)
    tl:SetPoint("TOPLEFT", 0, 0)

    local tr = piece("UI-Frame-DiamondMetal-CornerTopRight-8x")
    tr:SetSize(S, S)
    tr:SetPoint("TOPRIGHT", 0, 0)

    local bl = piece("UI-Frame-DiamondMetal-CornerBottomLeft-8x")
    bl:SetSize(S, S)
    bl:SetPoint("BOTTOMLEFT", 0, 0)

    local br = piece("UI-Frame-DiamondMetal-CornerBottomRight-8x")
    br:SetSize(S, S)
    br:SetPoint("BOTTOMRIGHT", 0, 0)

    local top = piece("_UI-Frame-DiamondMetal-EdgeTop-8x")
    top:SetHeight(S)
    top:SetPoint("TOPLEFT", S, 0)
    top:SetPoint("TOPRIGHT", -S, 0)

    local bot = piece("_UI-Frame-DiamondMetal-EdgeBottom-8x")
    bot:SetHeight(S)
    bot:SetPoint("BOTTOMLEFT", S, 0)
    bot:SetPoint("BOTTOMRIGHT", -S, 0)

    local left = piece("!UI-Frame-DiamondMetal-EdgeLeft-8x")
    left:SetWidth(S)
    left:SetPoint("TOPLEFT", 0, -S)
    left:SetPoint("BOTTOMLEFT", 0, S)

    local right = piece("!UI-Frame-DiamondMetal-EdgeRight-8x")
    right:SetWidth(S)
    right:SetPoint("TOPRIGHT", 0, -S)
    right:SetPoint("BOTTOMRIGHT", 0, S)
end

--------------------------------------------------------------------------
-- Modal confirm/prompt popup — replaces StaticPopupDialogs so destructive
-- confirms and profile-naming prompts wear the same DiamondMetal
-- border/redbutton look as the rest of the window instead of the stock
-- Blizzard dialog frame. One reusable frame (nothing here stacks).
--------------------------------------------------------------------------
local popup
local POPUP_W = 380

local function BuildPopup()
    local f = CreateFrame("Frame", "RefactorUIPopup", UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetWidth(POPUP_W)
    f:SetPoint("CENTER", 0, 80)
    f:Hide()

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(0.10, 0.09, 0.08, 0.55)
    bg:SetPoint("TOPLEFT", 8, -8)
    bg:SetPoint("BOTTOMRIGHT", -8, 8)
    BuildMetalBorder(f)
    local wash = f:CreateTexture(nil, "BACKGROUND")
    wash:SetTexture(0.09, 0.07, 0.05, 0.4)
    wash:SetPoint("TOPLEFT", 5, -5)
    wash:SetPoint("BOTTOMRIGHT", -5, 5)

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetWidth(POPUP_W - (BORDER_SIZE + 16) * 2)
    text:SetJustifyH("CENTER")
    f.text = text

    local edit = MakeEdit(f, 220)
    f.edit = edit

    local btn1 = MakeButton(f, 120, 26, ACCEPT, function()
        local val = f.edit:IsShown() and f.edit:GetText() or nil
        local onAccept = f.onAccept
        f:Hide()
        if onAccept then onAccept(val) end
    end)
    local btn2 = MakeButton(f, 120, 26, CANCEL, function()
        local onCancel = f.onCancel
        f:Hide()
        if onCancel then onCancel() end
    end)
    f.btn1, f.btn2 = btn1, btn2

    f:SetScript("OnHide", function(self)
        self.edit:ClearFocus()
        self.onAccept, self.onCancel = nil, nil
    end)

    tinsert(UISpecialFrames, "RefactorUIPopup") -- Escape closes
    popup = f
    return f
end

-- opts: text, hasEditBox, editDefault, editHighlight, button1, button2,
-- onAccept(editText|nil), onCancel
ShowPopup = function(opts)
    local f = popup or BuildPopup()

    f.text:SetText(opts.text)
    f.onAccept = opts.onAccept
    f.onCancel = opts.onCancel
    f.btn1.text:SetText(opts.button1 or ACCEPT)
    f.btn2.text:SetText(opts.button2 or CANCEL)

    local y = -(BORDER_SIZE + 16)
    f.text:ClearAllPoints()
    f.text:SetPoint("TOP", 0, y)
    y = y - f.text:GetStringHeight()

    f.edit:ClearAllPoints()
    if opts.hasEditBox then
        y = y - 14
        f.edit:SetPoint("TOP", 0, y)
        f.edit:Show()
        f.edit:SetText(opts.editDefault or "")
        f.edit:SetScript("OnEnterPressed", function(self)
            local text = self:GetText()
            self:ClearFocus()
            local onAccept = f.onAccept
            f:Hide()
            if onAccept then onAccept(text) end
        end)
        f.edit:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            f:Hide()
        end)
        y = y - EDIT_H - 6 -- edit is TOP-anchored; reserve its full height
    else
        f.edit:Hide()
        y = y - 20
    end

    f.btn1:ClearAllPoints()
    f.btn2:ClearAllPoints()
    f.btn1:SetPoint("TOP", -64, y)
    f.btn2:SetPoint("TOP", 64, y)
    y = y - 26 - (BORDER_SIZE + 16)

    f:SetHeight(-y)
    f:Show()
    if opts.hasEditBox then
        f.edit:SetFocus()
        if opts.editHighlight then f.edit:HighlightText() end
    end
end

local function BuildWindow()
    local f = CreateFrame("Frame", "RefactorUIWindow", UIParent)
    f:SetWidth(W_WIDTH)
    f:SetHeight(W_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    -- Flat dark background as a texture, pulled 8px in from the frame
    -- rect so the DiamondMetal border rim sits on its own art.
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture(0.10, 0.09, 0.08, 1)
    bg:SetPoint("TOPLEFT", 8, -8)
    bg:SetPoint("BOTTOMRIGHT", -8, 8)
    BuildMetalBorder(f)
    -- An earth-dark wash sits over the flat background (tucked inside the
    -- border art) to stop the world reading through. Created first so
    -- every later BACKGROUND texture draws above it.
    local wash = f:CreateTexture(nil, "BACKGROUND")
    wash:SetTexture(0.09, 0.07, 0.05, 0.8)
    wash:SetPoint("TOPLEFT", 5, -5)
    wash:SetPoint("BOTTOMRIGHT", -5, 5)
    f:Hide()
    f:HookScript("OnHide", HideDropdownList)
    tinsert(UISpecialFrames, "RefactorUIWindow") -- Escape closes
    window = f

    -- Header: a DiamondMetal-Header band carries the title; the strip
    -- under it is the drag handle for the whole window.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    -- Title band: the DiamondMetal-Header kit (corner + tiling middle +
    -- corner), sized to the title text and riding the top border rim.
    local bar = CreateFrame("Frame", nil, header)
    local barH = 28
    local barCapW = math.floor(barH * 32 / 39 + 0.5) -- keep the corner aspect
    bar:SetHeight(barH)

    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER", 0, 0)
    title:SetText("Refactor")
    bar:SetWidth(math.floor(title:GetStringWidth() + 0.5) + barCapW * 2 + 8)
    bar:SetPoint("TOP", f, "TOP", 0, 4)

    local barL = bar:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(barL, "UI-Frame-DiamondMetal-Header-CornerLeft-2x")
    barL:SetSize(barCapW, barH)
    barL:SetPoint("TOPLEFT", 0, 0)

    local barC = bar:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(barC, "_UI-Frame-DiamondMetal-Header-Tile-2x")
    barC:SetPoint("TOPLEFT", barCapW, 0)
    barC:SetPoint("BOTTOMRIGHT", -barCapW, 0)

    local barR = bar:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(barR, "UI-Frame-DiamondMetal-Header-CornerRight-2x")
    barR:SetSize(barCapW, barH)
    barR:SetPoint("TOPRIGHT", 0, 0)

    local headerLine = f:CreateTexture(nil, "ARTWORK")
    headerLine:SetTexture(SOLID)
    headerLine:SetGradientAlpha("HORIZONTAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0.3,
        ACCENT[1], ACCENT[2], ACCENT[3], 0)
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", INSET, -HEADER_H)
    headerLine:SetPoint("TOPRIGHT", -INSET, -HEADER_H)

    -- Close: the 128-redbutton-exit art (the UIPanelCloseButton template
    -- needs a global name; this button is anonymous).
    local close = CreateFrame("Button", nil, header)
    close:SetWidth(20)
    close:SetHeight(20)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    local closeUp = close:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(closeUp, "128-redbutton-exit")
    closeUp:SetAllPoints(close)
    local closeDown = close:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(closeDown, "128-redbutton-exit-pressed")
    closeDown:SetAllPoints(close)
    closeDown:Hide()
    local closeHl = close:CreateTexture(nil, "HIGHLIGHT")
    ApplyAtlas(closeHl, "128-redbutton-refresh-highlight")
    closeHl:SetAllPoints(close)
    closeHl:SetBlendMode("ADD")
    close:SetScript("OnMouseDown", function() closeDown:Show() end)
    close:SetScript("OnMouseUp", function() closeDown:Hide() end)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Sidebar --------------------------------------------------------------
    local side = f:CreateTexture(nil, "BACKGROUND")
    side:SetTexture(0, 0, 0, 0.35)
    side:SetPoint("TOPLEFT", INSET, -(HEADER_H + 1))
    side:SetPoint("BOTTOMLEFT", INSET, INSET)
    side:SetWidth(SIDEBAR_W)

    local sideLine = f:CreateTexture(nil, "ARTWORK")
    sideLine:SetTexture(SOLID)
    sideLine:SetGradientAlpha("VERTICAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0,
        ACCENT[1], ACCENT[2], ACCENT[3], 0.25)
    sideLine:SetWidth(1)
    sideLine:SetPoint("TOPLEFT", INSET + SIDEBAR_W, -(HEADER_H + 1))
    sideLine:SetPoint("BOTTOMLEFT", INSET + SIDEBAR_W, INSET)

    -- Sidebar search: type to filter every registered option, results as
    -- a jump list on the (nav-less) Search page. Clearing returns home.
    -- MakeSearchBox owns the placeholder, magnifying glass, clear button
    -- and focus tint; this only adds the filtering (HookScript, so it runs
    -- alongside the widget's own OnTextChanged rather than replacing it).
    local searchBox = MakeSearchBox(f, SIDEBAR_W - 24)
    searchBox.container:SetPoint("TOPLEFT", INSET + 12, -(HEADER_H + 12))
    f.searchBox = searchBox
    searchBox:HookScript("OnTextChanged", function(self)
        if f.suppressSearch then return end
        local q = (self:GetText() or ""):match("^%s*(.-)%s*$")
        if q ~= "" then
            pages.search.query = q
            SelectPage("search")
        elseif currentKey == "search" then
            SelectPage("general")
        end
    end)

    local searchLine = f:CreateTexture(nil, "ARTWORK")
    searchLine:SetTexture(SOLID)
    searchLine:SetGradientAlpha("HORIZONTAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0.25,
        ACCENT[1], ACCENT[2], ACCENT[3], 0)
    searchLine:SetHeight(1)
    searchLine:SetPoint("TOPLEFT", INSET + 8, -(HEADER_H + 42))
    searchLine:SetPoint("TOPRIGHT", f, "TOPLEFT",
        INSET + SIDEBAR_W - 8, -(HEADER_H + 42))

    -- Nav: plain labels, gold dot bullet on the active page (the stock
    -- category-list look), quest-log wash on hover.
    for i, key in ipairs(PAGE_ORDER) do
        local b = CreateFrame("Button", nil, f)
        b:SetWidth(SIDEBAR_W)
        b:SetHeight(24)
        b:SetPoint("TOPLEFT", INSET, -(HEADER_H + 52) - (i - 1) * 24)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.3)
        hl:SetAllPoints()
        b.dot = b:CreateTexture(nil, "ARTWORK")
        b.dot:SetTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
        b.dot:SetWidth(4)
        b.dot:SetHeight(4)
        b.dot:SetPoint("LEFT", 9, 0)
        b.dot:Hide()
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.label:SetPoint("LEFT", 20, 0)
        b.label:SetText(PAGE_TITLES[key])
        b:SetScript("OnClick", function() SelectPage(key) end)
        navButtons[key] = b
    end

    -- Detail pane: the third column. Explain() writes hover text here;
    -- SelectPage resets it to the page summary.
    local detailDivider = f:CreateTexture(nil, "ARTWORK")
    detailDivider:SetTexture(SOLID)
    detailDivider:SetGradientAlpha("VERTICAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0,
        ACCENT[1], ACCENT[2], ACCENT[3], 0.25)
    detailDivider:SetWidth(1)
    detailDivider:SetPoint("TOPRIGHT", -(INSET + DETAIL_W + 10), -(HEADER_H + 1))
    detailDivider:SetPoint("BOTTOMRIGHT", -(INSET + DETAIL_W + 10), INSET)

    local detailTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailTitle:SetPoint("TOPLEFT", f, "TOPRIGHT",
        -(INSET + DETAIL_W), -(HEADER_H + 16))
    detailTitle:SetWidth(DETAIL_W - 8)
    detailTitle:SetJustifyH("LEFT")

    local detailBody = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailBody:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -10)
    detailBody:SetWidth(DETAIL_W - 8)
    detailBody:SetJustifyH("LEFT")
    detailBody:SetTextColor(0.9, 0.88, 0.8)

    SetDetail = function(title, body)
        detailTitle:SetText(title or "")
        detailBody:SetText(body or "")
    end

    -- Live status: the active profile, always in view.
    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", INSET + 8, INSET + 6)
    f.footer:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    local version = GetAddOnMetadata and GetAddOnMetadata("Refactor", "Version")
    if version then
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        v:SetPoint("BOTTOMRIGHT", -(INSET + 8), INSET + 6)
        v:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        v:SetText("v" .. version)
    end

    BuildGeneralPage()
    BuildWeightsPage()
    BuildLootPage()
    BuildTweaksPage()
    BuildSearchPage()

    f:SetScript("OnShow", function() SelectPage(currentKey or "general") end)
end

--------------------------------------------------------------------------
-- Public interface (used by RefactorCompare's /rfc and RefreshConfig)
--------------------------------------------------------------------------

RefactorUI = {}

function RefactorUI.Toggle()
    if not DB() then
        Print("still loading — try again in a second.")
        return
    end
    if not window then BuildWindow() end
    if window:IsShown() then window:Hide() else window:Show() end
end

function RefactorUI.Refresh()
    if window and window:IsShown() then
        UpdateFooter()
        UpdateNav()
        if currentKey and pages[currentKey] then pages[currentKey]:Refresh() end
    end
end

--------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------

local minimapButton

local function MinimapDB()
    local d = DB()
    if not d then return nil end
    if type(d.minimap) ~= "table" then
        d.minimap = { angle = 205, hide = false }
    end
    return d.minimap
end

-- Minimap shape, by the same convention LibDBIcon uses: addons that make
-- the minimap non-round (ElvUI among them) define a global GetMinimapShape.
-- Anything other than "ROUND" is treated as a square — the corner-rounding
-- variants ("SIDE-LEFT", "TRICORNER-*") only differ in which corners bulge,
-- and clamping to the square perimeter lands on the edge either way.
-- pcall'd: third-party implementations are ordinary addon code and do error.
local function MinimapIsRound()
    if type(GetMinimapShape) ~= "function" then return true end
    local ok, shape = pcall(GetMinimapShape)
    return not ok or shape == nil or shape == "ROUND"
end

local function PositionMinimapButton()
    local m = MinimapDB()
    if not (m and minimapButton) then return end
    -- Stand down once something else owns the button: ElvUI/AddOnSkins-style
    -- collector bars reparent minimap buttons into a row of their own, and
    -- snapping it back to a minimap-relative point on every refresh would
    -- fight that layout (same stand-down rule the bag hooks follow).
    if minimapButton:GetParent() ~= Minimap then return end

    -- Radius from the live minimap, not a constant: ElvUI resizes it, and a
    -- hardcoded 80 then leaves the button floating inside the map or well
    -- outside it. Stock 140px minimap gives 80, so default placement is
    -- unchanged.
    local r = (Minimap:GetWidth() / 2) + 10
    local angle = math.rad(m.angle or 205)
    local x, y = math.cos(angle), math.sin(angle)
    if MinimapIsRound() then
        x, y = x * r, y * r
    else
        -- Project onto the square's edge, then clamp: overshooting by 1.5x
        -- before the clamp is what keeps the button ON the edge for angles
        -- between the corners instead of cutting the corner inside it.
        x = math.max(-r, math.min(r, x * r * 1.5))
        y = math.max(-r, math.min(r, y * r * 1.5))
    end

    -- Above ElvUI's minimap panels, which sit on top of the minimap itself.
    minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function MinimapButtonTooltip(self)
    local d = DB()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Refactor")
    if d then
        GameTooltip:AddLine("Profile: |cffffffff" .. (d.activeProfile or "?") .. "|r",
            0.8, 0.8, 0.8)
        GameTooltip:AddLine("Gear compare: "
            .. (d.enabled and "|cff33ff99on|r" or "|cffff4040off|r"), 0.8, 0.8, 0.8)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: settings", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Right-click: toggle gear compare", 0.6, 0.6, 0.6)
    GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function BuildMinimapButton()
    local b = CreateFrame("Button", "RefactorMinimapButton", Minimap)
    b:SetWidth(31)
    b:SetHeight(31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8) -- re-derived from the minimap in PositionMinimapButton
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Standard minimap-button anatomy: dark disc, icon, ring overlay.
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetWidth(20)
    bg:SetHeight(20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(17)
    icon:SetHeight(17)
    icon:SetPoint("TOPLEFT", 7, -6)
    -- The addon's own gear icon, full color. Falls back to a stock gear
    -- icon if the texture is missing.
    if not icon:SetTexture("Interface\\AddOns\\Refactor\\refactor") then
        icon:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end

    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetWidth(53)
    ring:SetHeight(53)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetPoint("TOPLEFT")

    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            cx, cy = cx / scale, cy / scale
            local m = MinimapDB()
            if m then
                m.angle = math.deg(math.atan2(cy - my, cx - mx))
                PositionMinimapButton()
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local d = DB()
            if d then
                d.enabled = not d.enabled
                RefreshBags()
                Print("gear compare "
                    .. (d.enabled and "|cff00ff00enabled|r" or "|cffff4040disabled|r") .. ".")
                RefactorUI.Refresh()
                if GameTooltip:GetOwner() == self then MinimapButtonTooltip(self) end
            end
        else
            RefactorUI.Toggle()
        end
    end)
    b:SetScript("OnEnter", MinimapButtonTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton = b
    PositionMinimapButton()
end

function RefactorUI.UpdateMinimapButton()
    local m = MinimapDB()
    if not m then return end
    if not minimapButton then BuildMinimapButton() end
    if m.hide then minimapButton:Hide() else minimapButton:Show() end
    PositionMinimapButton()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
-- Minimap-skinning addons resize and reshape the minimap after ADDON_LOADED,
-- so the radius read there can be the stock one. PLAYER_ENTERING_WORLD is the
-- first point on this client where everyone else is done; reposition once
-- more there, then stop listening.
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "Refactor" then return end
        -- RefactorCompare.lua loads (and registers) first, so its handler has
        -- already created RefactorCompareDB by the time this one runs.
        RefactorUI.UpdateMinimapButton()
        self:UnregisterEvent("ADDON_LOADED")
    else
        RefactorUI.UpdateMinimapButton()
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end)
