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
-- Look: flat dark panel with sidebar navigation. Single accent color =
-- the addon's chat-message green (|cff33ff99). Native behavior kept:
-- Escape closes, the header drags, controls explain themselves on hover.

local SOLID = "Interface\\ChatFrame\\ChatFrameBackground" -- tintable solid

-- Palette (r, g, b)
local ACCENT   = { 0.20, 1.00, 0.60 }
local C_BG     = { 0.075, 0.075, 0.095 }
local C_SIDE   = { 0.055, 0.055, 0.072 }
local C_CTRL   = { 0.10, 0.10, 0.13 }
local C_HOVER  = { 0.16, 0.16, 0.20 }
local C_BORDER = { 0.30, 0.30, 0.36 }
local C_DIM    = { 0.55, 0.55, 0.60 }

local W_WIDTH, W_HEIGHT = 640, 520
local SIDEBAR_W = 150
local HEADER_H = 42
local PAD = 16
local CONTENT_W = W_WIDTH - SIDEBAR_W - 1 - PAD * 2 -- 457

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

-- HookScript (not SetScript) so widgets keep their own hover styling.
local function AttachTooltip(widget, title, body)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Section header: near-white label with a hairline running the width.
-- Returns the y where content below should start.
local function Section(parent, text, x, y, width)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", x, y)
    h:SetText(text)
    h:SetTextColor(0.92, 0.92, 0.95)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetTexture(1, 1, 1, 0.07)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", x, y - 16)
    line:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + width, y - 16)
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

-- Checkbox row: flat box + accent fill when checked, label, optional
-- one-line gray description. The whole row is the click target.
local function MakeCheck(parent, x, y, width, label, desc, get, set, tip)
    local row = CreateFrame("Button", nil, parent)
    row:SetPoint("TOPLEFT", x, y)
    row:SetWidth(width)
    row:SetHeight(desc and 32 or 18)

    local box = CreateFrame("Frame", nil, row)
    box:SetWidth(16)
    box:SetHeight(16)
    box:SetPoint("TOPLEFT", 0, -1)
    SetFlat(box, C_CTRL, C_BORDER)

    local mark = box:CreateTexture(nil, "OVERLAY")
    mark:SetTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    mark:SetPoint("TOPLEFT", 4, -4)
    mark:SetPoint("BOTTOMRIGHT", -4, 4)

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, -2)
    text:SetJustifyH("LEFT")
    text:SetText(label)

    if desc then
        local sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sub:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -3)
        sub:SetWidth(width - 24)
        sub:SetJustifyH("LEFT")
        sub:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        sub:SetText(desc)
    end

    row.Refresh = function(self)
        if get() then mark:Show() else mark:Hide() end
    end
    row:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
    end)
    row:SetScript("OnEnter", function()
        box:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.8)
    end)
    row:SetScript("OnLeave", function()
        box:SetBackdropBorderColor(C_BORDER[1], C_BORDER[2], C_BORDER[3], 1)
    end)
    if tip then AttachTooltip(row, label, tip) end
    return row
end

local function MakeButton(parent, w, h, label, onClick, primary)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(w)
    b:SetHeight(h)
    SetFlat(b, C_CTRL, C_BORDER)
    local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("CENTER", 0, 0)
    t:SetText(label)
    b.text = t
    b.SetNormalLook = function(self)
        if primary then
            self:SetBackdropBorderColor(ACCENT[1] * 0.6, ACCENT[2] * 0.6, ACCENT[3] * 0.6, 1)
            self.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        else
            self:SetBackdropBorderColor(C_BORDER[1], C_BORDER[2], C_BORDER[3], 1)
            self.text:SetTextColor(1, 1, 1)
        end
        self:SetBackdropColor(C_CTRL[1], C_CTRL[2], C_CTRL[3], 1)
    end
    b:SetNormalLook()
    b:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C_HOVER[1], C_HOVER[2], C_HOVER[3], 1)
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C_CTRL[1], C_CTRL[2], C_CTRL[3], 1)
    end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- Flat edit box. With get/set (numeric): commits on Enter / focus lost,
-- reverts on Escape. Without: plain text field, read via GetText().
local function MakeEdit(parent, w, get, set)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetWidth(w)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextInsets(6, 6, 0, 0)
    SetFlat(eb, { 0.09, 0.09, 0.115 }, C_BORDER)
    eb:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.8)
        self:HighlightText()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self)
        self.reverting = true
        self:ClearFocus()
    end)
    eb:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(C_BORDER[1], C_BORDER[2], C_BORDER[3], 1)
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

--------------------------------------------------------------------------
-- Window shell: header, sidebar navigation, page plumbing
--------------------------------------------------------------------------

local window
local navButtons = {}
local pages = {}
local currentKey

local PAGE_ORDER = { "general", "weights", "profiles", "loot", "tweaks" }
local PAGE_TITLES = {
    general = "General", weights = "Stat Weights", profiles = "Profiles",
    loot = "Loot", tweaks = "Tweaks",
}

local function NewPage(key)
    local p = CreateFrame("Frame", nil, window)
    p:SetPoint("TOPLEFT", SIDEBAR_W + 1 + PAD, -(HEADER_H + 14))
    p:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    p:Hide()
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
    for key, b in pairs(navButtons) do
        if key == currentKey then
            b.bg:SetTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.10)
            b.label:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
        else
            b.bg:SetTexture(0, 0, 0, 0)
            b.label:SetTextColor(0.72, 0.72, 0.76)
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
end

--------------------------------------------------------------------------
-- Page: General
--------------------------------------------------------------------------

local function BuildGeneralPage()
    local p = NewPage("general")

    local y = Section(p, "Gear compare", 0, 0, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Enable gear compare",
        "Master switch — verdicts, bag arrows, quest markers and loot alerts.",
        function() return DB().enabled end,
        function(v) DB().enabled = v; RefreshBags() end))
    y = y - 40

    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Green arrows on bag upgrades",
        "Marks bag items that beat your equipped gear under current weights.",
        function() return DB().bagIcons end,
        function(v) DB().bagIcons = v; RefreshBags() end))
    y = y - 44

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
        AttachTooltip(c, col.hex .. _G["ITEM_QUALITY" .. q .. "_DESC"] .. "|r",
            "Items below the chosen quality are ignored — no verdicts, no arrows, no alerts.")
        qCells[q] = c
    end
    qHolder.Refresh = function(self)
        local sel = DB().minQuality or 0
        for q, c in pairs(qCells) do
            if q == sel then
                c:SetAlpha(1)
                c:SetBackdropBorderColor(1, 1, 1, 1)
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
            function(v) DB().armorTypes[at] = v; RefreshBags() end,
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
-- Page: Stat Weights (scrollable — the grid, custom stats)
--------------------------------------------------------------------------

local function BuildWeightsPage()
    local p = NewPage("weights")

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
    scroll:SetScrollChild(child)

    local shared = CS()
    local y = 0

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
                if DB().activeProfile == spec.profileName then
                    self:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
                    self.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
                else
                    self:SetBackdropBorderColor(C_BORDER[1], C_BORDER[2], C_BORDER[3], 1)
                    self.text:SetTextColor(1, 1, 1)
                end
            end
            p:Track(b)
            AttachTooltip(b, spec.label,
                "Switch to the '" .. spec.profileName .. "' profile (created from the " ..
                "default weights for this spec if you haven't edited it)." ..
                "\n\n|cff999999Fine-tune the numbers below afterwards — your edits are kept.|r")
        end
        y = y - math.ceil(#specs / 4) * 26 - 12
    end

    -- Weight grid ----------------------------------------------------------
    y = Section(child, "Stat weights", 0, y, INNER_W)
    SmallText(child, "score = stat amount × weight, summed. Weight 0 ignores the stat.",
        0, y, INNER_W)
    y = y - 18

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
        AttachTooltip(eb, s.label, (s.tip or "") .. "\n\n|cff9999990 = ignore this stat.|r")
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
            AttachTooltip(r.remove, "Remove",
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
    AttachTooltip(addBtn, "Add custom stat weight",
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
-- Page: Profiles
--------------------------------------------------------------------------

local function BuildProfilesPage()
    local p = NewPage("profiles")
    local shared = CS()

    local y = Section(p, "Profiles", 0, 0, CONTENT_W)
    SmallText(p, "A profile is a saved set of stat weights, shared account-wide. " ..
        "Each character remembers which one it picked.", 0, y, CONTENT_W)
    local listStartY = y - 34

    local rows = {}
    local function GetRow(i)
        local r = rows[i]
        if not r then
            r = CreateFrame("Button", nil, p)
            r:SetWidth(CONTENT_W)
            r:SetHeight(24)
            SetFlat(r, C_CTRL, nil, 0) -- fill only shows on hover/active

            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.name:SetPoint("LEFT", 10, 0)
            r.name:SetJustifyH("LEFT")

            r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.tag:SetPoint("RIGHT", -34, 0)
            r.tag:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
            r.tag:SetText("active")

            r.delete = MakeButton(r, 20, 20, "×", function()
                local dialog = StaticPopup_Show("REFACTORCOMPARE_DELETE_PROFILE",
                    r.profileName)
                if dialog then dialog.data = r.profileName end
            end)
            r.delete:SetPoint("RIGHT", -4, 0)
            AttachTooltip(r.delete, "Delete profile", nil)

            r:SetScript("OnClick", function(self)
                if DB().activeProfile ~= self.profileName then
                    shared.SetActiveProfile(self.profileName)
                    RefreshBags()
                    Print("switched to profile '" .. self.profileName .. "'.")
                    RefactorUI.Refresh()
                end
            end)
            r:SetScript("OnEnter", function(self)
                if DB().activeProfile ~= self.profileName then
                    self:SetBackdropColor(1, 1, 1, 0.04)
                end
            end)
            r:SetScript("OnLeave", function(self)
                if DB().activeProfile ~= self.profileName then
                    self:SetBackdropColor(0, 0, 0, 0)
                end
            end)
            rows[i] = r
        end
        return r
    end

    -- Save-as block repositions below the list as it grows.
    local saveBox = CreateFrame("Frame", nil, p)
    saveBox:SetWidth(CONTENT_W)
    saveBox:SetHeight(80)
    local sy = Section(saveBox, "Save current weights as", 0, 0, CONTENT_W)
    local saveName = MakeEdit(saveBox, 200)
    saveName:SetPoint("TOPLEFT", 0, sy)
    local saveBtn = MakeButton(saveBox, 110, 20, "Save profile", function()
        local name = (saveName:GetText() or ""):match("^%s*(.-)%s*$")
        if name == "" then return end
        shared.SaveProfileAs(name)
        saveName:SetText("")
        saveName:ClearFocus()
        RefactorUI.Refresh()
    end, true)
    saveBtn:SetPoint("TOPLEFT", 208, sy)
    AttachTooltip(saveBtn, "Save profile",
        "Saves the current weights under this name (overwrites a profile with the same name) and switches to it.")
    saveName:SetScript("OnEnterPressed", function(self)
        saveBtn:GetScript("OnClick")(saveBtn)
    end)

    p.OnRefresh = function(self)
        local d = DB()
        local names = {}
        for n in pairs(d.profiles) do tinsert(names, n) end
        table.sort(names)

        for _, r in ipairs(rows) do r:Hide() end
        for i, n in ipairs(names) do
            local r = GetRow(i)
            r.profileName = n
            r.name:SetText(n)
            local active = (d.activeProfile == n)
            if active then
                r:SetBackdropColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.10)
                r.name:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
                r.tag:Show()
            else
                r:SetBackdropColor(0, 0, 0, 0)
                r.name:SetTextColor(1, 1, 1)
                r.tag:Hide()
            end
            if n == "Default" then r.delete:Hide() else r.delete:Show() end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, listStartY - (i - 1) * 26)
            r:Show()
        end

        saveBox:ClearAllPoints()
        saveBox:SetPoint("TOPLEFT", 0, listStartY - #names * 26 - 16)
    end
end

--------------------------------------------------------------------------
-- Page: Loot
--------------------------------------------------------------------------

local function BuildLootPage()
    local p = NewPage("loot")

    local y = Section(p, "Chat alerts", 0, 0, CONTENT_W)
    p:Track(MakeCheck(p, 0, y, CONTENT_W, "Announce upgrades in chat",
        "Prints a chat line when fresh loot beats your equipped gear.",
        function() return DB().lootAlert end,
        function(v) DB().lootAlert = v end))
    y = y - 44

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
    y = y - 44

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
            self:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
        else
            self.text:SetText("Move toasts")
            self:SetBackdropBorderColor(C_BORDER[1], C_BORDER[2], C_BORDER[3], 1)
        end
    end
    p:Track(moveBtn)
    AttachTooltip(moveBtn, "Move toasts",
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
    AttachTooltip(testBtn, "Test toast",
        "Spawns two sample toasts — one plain, one styled as an upgrade.")
end

--------------------------------------------------------------------------
-- Page: Tweaks (the QoL features from Refactor.lua)
--------------------------------------------------------------------------

local function BuildTweaksPage()
    local p = NewPage("tweaks")
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
    scroll:SetScrollChild(child)

    local function QolCheck(x, y, label, desc, key)
        return p:Track(MakeCheck(child, x, y, INNER_W, label, desc,
            function() return q and q.Get(key) end,
            function(v) if q then q.Set(key, v) end end))
    end

    local y = Section(child, "Looting", 0, 0, INNER_W)
    QolCheck(0, y, "Fast auto-loot",
        "Loots instantly, window hidden. Hold Shift for the normal window.",
        "fastLoot")
    y = y - 40
    QolCheck(0, y, "Auto-confirm bind-on-pickup",
        "Skips the \"will bind it to you\" popups when looting and rolling.",
        "autoConfirmBoP")
    y = y - 40
    QolCheck(0, y, "Auto-collect transmog appearances",
        "Learns uncollected appearances from bag items automatically.",
        "transmog")
    y = y - 44

    y = Section(child, "Questing", 0, y - 8, INNER_W)
    QolCheck(0, y, "Auto-accept quests",
        "Accepts quest offers and escort confirmations. Hold Shift for the normal window.",
        "questAccept")
    y = y - 40
    QolCheck(0, y, "Auto turn-in quests",
        "Hands in completed quests. Multiple reward choices leave the window open.",
        "questTurnIn")
    y = y - 40
    QolCheck(0, y, "Auto-pick quests from gossip",
        "Selects available and completable quests from NPC dialog menus.",
        "questGossip")
    y = y - 44

    y = Section(child, "Social", 0, y - 8, INNER_W)
    QolCheck(0, y, "Decline group invites",
        "Declines every party invite. Hold Shift as it arrives to accept manually.",
        "declineInvites")
    y = y - 40
    QolCheck(0, y, "Decline duels",
        "Cancels duel requests. Hold Shift as it arrives to duel anyway.",
        "declineDuels")
    y = y - 40
    QolCheck(0, y, "Decline guild invites",
        "Declines guild recruitment invites. Hold Shift as it arrives to consider it.",
        "declineGuilds")
    y = y - 40
    QolCheck(0, y, "Block trades from strangers",
        "Closes trades unless the other player is a friend, guildmate, or in your group.",
        "declineTrades")
    y = y - 40
    QolCheck(0, y, "Auto-resurrect in battlegrounds",
        "Instantly accepts resurrections from players while in a battleground.",
        "autoResBG")
    y = y - 44

    y = Section(child, "Tooltips", 0, y - 8, INNER_W)
    QolCheck(0, y, "Anchor tooltip at the cursor",
        "The default tooltip follows the mouse instead of the corner.",
        "cursorTooltip")
    y = y - 40
    QolCheck(0, y, "Hide the unit health bar",
        "Removes the health bar under unit tooltips.",
        "hideHealthBar")
    y = y - 40
    QolCheck(0, y, "Quality-colored tooltip border",
        "Tints the tooltip border with the item's quality color.",
        "qualityBorder")
    y = y - 44

    y = Section(child, "Errors", 0, y - 8, INNER_W)
    QolCheck(0, y, "Hide error text",
        "Hides the red \"Ability is not ready yet\" messages at the top of the screen.",
        "hideErrorText")
    y = y - 40
    QolCheck(0, y, "Mute error speech",
        "Silences the \"I can't do that yet\" voice when a cast fails.",
        "muteErrorSpeech")
    y = y - 40

    child:SetHeight(-y + 8)
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
    SetFlat(f, C_BG, C_BORDER, 0.97)
    f:Hide()
    tinsert(UISpecialFrames, "RefactorUIWindow") -- Escape closes
    window = f

    -- Header: title, version, drag handle for the whole window.
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    title:SetText("Refactor")
    title:SetTextColor(1, 1, 1)

    local version = GetAddOnMetadata and GetAddOnMetadata("Refactor", "Version")
    if version then
        local v = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        v:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
        v:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        v:SetText("v" .. version)
    end

    local headerLine = f:CreateTexture(nil, "ARTWORK")
    headerLine:SetTexture(1, 1, 1, 0.07)
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", 1, -HEADER_H)
    headerLine:SetPoint("TOPRIGHT", -1, -HEADER_H)

    local close = CreateFrame("Button", nil, header)
    close:SetWidth(24)
    close:SetHeight(24)
    close:SetPoint("RIGHT", -10, 0)
    local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    closeText:SetPoint("CENTER", 0, 0)
    closeText:SetText("×")
    closeText:SetTextColor(0.72, 0.72, 0.76)
    close:SetScript("OnEnter", function() closeText:SetTextColor(1, 0.35, 0.35) end)
    close:SetScript("OnLeave", function() closeText:SetTextColor(0.72, 0.72, 0.76) end)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Sidebar --------------------------------------------------------------
    local side = f:CreateTexture(nil, "BACKGROUND")
    side:SetTexture(C_SIDE[1], C_SIDE[2], C_SIDE[3], 1)
    side:SetPoint("TOPLEFT", 1, -(HEADER_H + 1))
    side:SetPoint("BOTTOMLEFT", 1, 1)
    side:SetWidth(SIDEBAR_W)

    local sideLine = f:CreateTexture(nil, "ARTWORK")
    sideLine:SetTexture(1, 1, 1, 0.06)
    sideLine:SetWidth(1)
    sideLine:SetPoint("TOPLEFT", SIDEBAR_W + 1, -(HEADER_H + 1))
    sideLine:SetPoint("BOTTOMLEFT", SIDEBAR_W + 1, 1)

    for i, key in ipairs(PAGE_ORDER) do
        local b = CreateFrame("Button", nil, f)
        b:SetWidth(SIDEBAR_W)
        b:SetHeight(26)
        b:SetPoint("TOPLEFT", 1, -(HEADER_H + 10) - (i - 1) * 26)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetTexture(0, 0, 0, 0)
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.label:SetPoint("LEFT", 14, 0)
        b.label:SetText(PAGE_TITLES[key])
        b:SetScript("OnClick", function() SelectPage(key) end)
        b:SetScript("OnEnter", function(self)
            if currentKey ~= key then self.bg:SetTexture(1, 1, 1, 0.04) end
        end)
        b:SetScript("OnLeave", function(self)
            if currentKey ~= key then self.bg:SetTexture(0, 0, 0, 0) end
        end)
        navButtons[key] = b
    end

    -- Live status: the active profile, always in view.
    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 15, 12)
    f.footer:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    BuildGeneralPage()
    BuildWeightsPage()
    BuildProfilesPage()
    BuildLootPage()
    BuildTweaksPage()

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
