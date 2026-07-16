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
-- Look: stock Blizzard dialog art — the UI-DialogBox backdrop and
-- border, a header ribbon, red panel buttons, native checkbox and
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
local INSET = 11 -- thickness the UI-DialogBox-Border art eats
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

-- Stock red panel button (UI-Panel-Button art, drawn by hand — the
-- UIPanelButtonTemplate variants need global names, these buttons are
-- anonymous). Every button shares the one look; hierarchy comes from
-- placement, exactly like the stock UI.
local function MakeButton(parent, w, h, label, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)
    b:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    b:GetNormalTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    b:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
    b:GetPushedTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    b:GetHighlightTexture():SetTexCoord(0, 0.625, 0, 0.6875)
    b:GetHighlightTexture():SetBlendMode("ADD")
    b:SetDisabledTexture("Interface\\Buttons\\UI-Panel-Button-Disabled")
    b:GetDisabledTexture():SetTexCoord(0, 0.625, 0, 0.6875)
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

-- Edit box wearing InputBoxTemplate's three-slice border art (drawn by
-- hand — the template needs a global name). Slices tint gold on focus.
-- With get/set (numeric): commits on Enter / focus lost, reverts on
-- Escape. Without: plain text field, read via GetText().
local function MakeEdit(parent, w, get, set)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetWidth(w)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextInsets(6, 6, 0, 0)

    local slices = {}
    local function Slice(x1, x2)
        local t = eb:CreateTexture(nil, "BACKGROUND")
        t:SetTexture("Interface\\Common\\Common-Input-Border")
        t:SetTexCoord(x1, x2, 0, 0.625)
        t:SetHeight(20)
        tinsert(slices, t)
        return t
    end
    local left = Slice(0, 0.0625)
    left:SetWidth(8)
    left:SetPoint("LEFT", -5, 0)
    local right = Slice(0.9375, 1)
    right:SetWidth(8)
    right:SetPoint("RIGHT", 0, 0)
    local mid = Slice(0.0625, 0.9375)
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)

    eb:SetScript("OnEditFocusGained", function(self)
        for _, t in ipairs(slices) do
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
        for _, t in ipairs(slices) do t:SetVertexColor(1, 1, 1) end
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

-- Stock options slider (OptionsSliderTemplate's thumb + track art). Needs a
-- global name — the template's Low/High/Text labels are $parent-relative
-- and only resolve with one; every caller must pass a unique name. Low/High/
-- Text go blank (the row already carries its own label) and the live value
-- reads instead in a small fontstring to the slider's right.
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
        "body armor — rings, trinkets, cloaks and weapons always count."
    local armorTypes = { "Cloth", "Leather", "Mail", "Plate" }
    for i, at in ipairs(armorTypes) do
        p:Track(MakeCheck(p, (i - 1) * 100, y, 95, at, nil,
            function() return DB().armorTypes[at] ~= false end,
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
end

--------------------------------------------------------------------------
-- Page: Stat Weights (scrollable — profile management, spec picker,
-- the weight grid, custom stats)
--------------------------------------------------------------------------

-- Naming dialogs for the profile controls. Native StaticPopups: Enter
-- accepts, Escape cancels, and they sit above the config window.
StaticPopupDialogs["REFACTORUI_SAVEAS_PROFILE"] = {
    text = "Save current weights as:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 48,
    OnShow = function(self)
        _G[self:GetName() .. "EditBox"]:SetText("")
    end,
    OnAccept = function(self)
        local name = (_G[self:GetName() .. "EditBox"]:GetText() or "")
            :match("^%s*(.-)%s*$")
        if name ~= "" then
            CS().SaveProfileAs(name)
            RefreshBags()
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs["REFACTORUI_SAVEAS_PROFILE"].OnAccept(dialog)
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

StaticPopupDialogs["REFACTORUI_RENAME_PROFILE"] = {
    text = "Rename profile '%s' to:",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 48,
    OnShow = function(self)
        local eb = _G[self:GetName() .. "EditBox"]
        eb:SetText(self.data or "")
        eb:HighlightText()
    end,
    OnAccept = function(self)
        local name = (_G[self:GetName() .. "EditBox"]:GetText() or "")
            :match("^%s*(.-)%s*$")
        local s = CS()
        if name ~= "" and s and s.RenameProfile then
            s.RenameProfile(self.data, name)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs["REFACTORUI_RENAME_PROFILE"].OnAccept(dialog)
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}

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

    local dd = CreateFrame("Frame", "RefactorUIProfileDropdown", child,
        "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", -14, y + 4) -- template art carries ~16px side pads
    UIDropDownMenu_SetWidth(dd, 200)
    UIDropDownMenu_Initialize(dd, function()
        local d = DB()
        if not d then return end
        local names = {}
        for n in pairs(d.profiles) do tinsert(names, n) end
        table.sort(names)
        for _, n in ipairs(names) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = n
            info.checked = (d.activeProfile == n)
            info.func = function()
                shared.SetActiveProfile(n)
                RefreshBags()
                Print("switched to profile '" .. n .. "'.")
                RefactorUI.Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    dd.Refresh = function(self)
        UIDropDownMenu_SetText(self, DB().activeProfile or "")
    end
    p:Track(dd)
    y = y - 34

    local saveAsBtn = MakeButton(child, 96, 22, "Save as...", function()
        StaticPopup_Show("REFACTORUI_SAVEAS_PROFILE")
    end)
    saveAsBtn:SetPoint("TOPLEFT", 2, y)
    Explain(saveAsBtn, "Save as",
        "Saves the current weights as a new profile and switches to it. " ..
        "Reusing an existing name overwrites that profile.")

    local renameBtn = MakeButton(child, 92, 22, "Rename...", function()
        local d = DB()
        local dialog = StaticPopup_Show("REFACTORUI_RENAME_PROFILE", d.activeProfile)
        if dialog then dialog.data = d.activeProfile end
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
        local d = DB()
        local dialog = StaticPopup_Show("REFACTORCOMPARE_DELETE_PROFILE", d.activeProfile)
        if dialog then dialog.data = d.activeProfile end
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
    y = Section(child, "Custom scanned stats", 0, y, INNER_W)
    SmallText(child,
        "Ascension-only stats picked up while scanning score at the Unknown weight " ..
        "until you give them their own value here.", 0, y, INNER_W)
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
        local dd = CreateFrame("Frame", "RefactorUIPriceSourceDropdown", p,
            "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", 96, y + 4) -- template art carries ~16px side pads
        UIDropDownMenu_SetWidth(dd, 190)
        UIDropDownMenu_Initialize(dd, function()
            local ts = RefactorToastShared
            local t = TDB()
            if not (ts and ts.GetPriceSources and t) then return end
            for _, src in ipairs(ts.GetPriceSources()) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = src.label
                info.checked = (t.priceSource == src.key)
                info.func = function()
                    t.priceSource = src.key
                    RefactorUI.Refresh()
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        dd.Refresh = function(self)
            local ts = RefactorToastShared
            local t = TDB()
            if not (ts and ts.GetPriceSources and t) then
                UIDropDownMenu_SetText(self, "")
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
            UIDropDownMenu_SetText(self, text)
        end
        p:Track(dd)
        local desc = "Where the value comes from — auction house prices only. " ..
            "Auto tries TSM market value, then minimum buyout, then Auctionator. " ..
            "These prices only exist for items you've scanned at the auction " ..
            "house; when the source knows nothing, the toast shows no value. " ..
            "Vendor sell price is never shown — addons can only read the base " ..
            "item's price, which contradicts the scaled Sell Price in the tooltip."
        Explain(dd, "Price source", desc)
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

    local y = Section(child, "Looting", 0, 0, INNER_W)
    QolCheck(0, y, "Fast auto-loot",
        "Loots instantly, window hidden. Hold Shift for the normal window.",
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

    y = Section(child, "Questing", 0, y - 8, INNER_W)
    QolCheck(0, y, "Auto-accept quests",
        "Accepts quest offers and escort confirmations. Hold Shift for the normal window.",
        "questAccept")
    y = y - 28
    QolCheck(0, y, "Auto turn-in quests",
        "Hands in completed quests. Multiple reward choices leave the window open.",
        "questTurnIn")
    y = y - 28
    QolCheck(0, y, "Auto-pick quests from gossip",
        "Selects available and completable quests from NPC dialog menus.",
        "questGossip")
    y = y - 36

    y = Section(child, "World map", 0, y - 8, INNER_W)
    QolCheck(0, y, "Full-size map as a movable window",
        "The full map becomes the only mode: a scaled-down window with no black backdrop, and keyboard movement keeps working. Drag its title strip to move it; mousewheel there resizes.",
        "fullMapWindow")
    y = y - 28
    do
        local fm = RefactorFullMapShared
        local minS = (fm and fm.MIN_SCALE) or 0.5
        local maxS = (fm and fm.MAX_SCALE) or 1.0
        local baseS = (fm and fm.BASE_SCALE) or 0.85
        local label = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("TOPLEFT", 20, y - 5)
        label:SetText("Window scale")
        p:Track(label)
        local slider = MakeSlider(child, "RefactorUIFullMapScaleSlider", 140,
            minS, maxS, 0.05,
            function() return fm and fm.GetScale() end,
            function(v) if fm then fm.SetScale(v) end end,
            baseS)
        slider:SetPoint("TOPLEFT", 150, y - 3)
        local desc = string.format(
            "Size of the map window. 1.00 is the default size; the slider's own range is %.2f to %.2f. " ..
            "Same value the mousewheel sets when dragging its title strip.",
            minS / baseS, maxS / baseS)
        Explain(slider, "Window scale", desc)
        RegisterOption("Window scale", desc, child.pageKey)
        p:Track(slider)
        if not fm then slider:Disable() end
    end
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
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = INSET, right = INSET, top = INSET, bottom = INSET },
    })
    -- The stock dialog background leans blue; a warm multiply tint pulls
    -- it toward the parchment-brown of the border art.
    f:SetBackdropColor(1, 0.93, 0.82)
    -- The dialog art is authored translucent and can't be made more solid
    -- via the backdrop alone, so an earth-dark wash sits over it (tucked
    -- inside the border art) to stop the world reading through. Created
    -- first so every later BACKGROUND texture draws above it.
    local wash = f:CreateTexture(nil, "BACKGROUND")
    wash:SetTexture(0.09, 0.07, 0.05, 0.8)
    wash:SetPoint("TOPLEFT", 5, -5)
    wash:SetPoint("BOTTOMRIGHT", -5, 5)
    f:Hide()
    tinsert(UISpecialFrames, "RefactorUIWindow") -- Escape closes
    window = f

    -- Header: the stock dialog ribbon carries the title; the strip under
    -- it is the drag handle for the whole window.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local ribbon = header:CreateTexture(nil, "ARTWORK")
    ribbon:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    ribbon:SetWidth(256)
    ribbon:SetHeight(64)
    ribbon:SetPoint("TOP", f, "TOP", 0, 12)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", ribbon, "TOP", 0, -14)
    title:SetText("Refactor")

    local headerLine = f:CreateTexture(nil, "ARTWORK")
    headerLine:SetTexture(SOLID)
    headerLine:SetGradientAlpha("HORIZONTAL",
        ACCENT[1], ACCENT[2], ACCENT[3], 0.3,
        ACCENT[1], ACCENT[2], ACCENT[3], 0)
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", INSET, -HEADER_H)
    headerLine:SetPoint("TOPRIGHT", -INSET, -HEADER_H)

    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
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
    local searchBox = MakeEdit(f, SIDEBAR_W - 28)
    searchBox:SetPoint("TOPLEFT", INSET + 16, -(HEADER_H + 14))
    f.searchBox = searchBox
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    placeholder:SetPoint("LEFT", 2, 0)
    placeholder:SetText("Search")
    searchBox:HookScript("OnEditFocusGained", function() placeholder:Hide() end)
    searchBox:HookScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then placeholder:Show() end
    end)
    searchBox:SetScript("OnTextChanged", function(self)
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

local function PositionMinimapButton()
    local m = MinimapDB()
    if not (m and minimapButton) then return end
    local angle = math.rad(m.angle or 205)
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * 80, math.sin(angle) * 80)
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
    b:SetFrameLevel(8)
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
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 ~= "Refactor" then return end
    -- RefactorCompare.lua loads (and registers) first, so its handler has
    -- already created RefactorCompareDB by the time this one runs.
    RefactorUI.UpdateMinimapButton()
    self:UnregisterEvent("ADDON_LOADED")
end)
