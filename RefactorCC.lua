-- RefactorCC
-- Center-screen crowd-control alert: while the player is stunned, feared,
-- or otherwise CC'd, a large icon with a cooldown spiral, mechanic label
-- and countdown appears mid-screen — the 3.3.5 client has no native
-- loss-of-control display (that arrived in MoP), and in the heat of a
-- fight the tiny debuff row is easy to miss.
--
-- Detection is three layers deep, because this era's UnitDebuff exposes
-- no mechanic field:
--   1. CC_SPELLS: spell IDs with a CC mechanic, scraped from
--      db.ascension.gg per CoA class (the abilities enemy players throw
--      at you in PvP).
--   2. CC_NAMES: the same list keyed by name — charge-style abilities
--      apply their stun through a separate trigger spell whose ID isn't
--      in any class list, but the debuff usually keeps the ability's name.
--   3. Tooltip scan: the auto-generated aura text on a debuff tooltip
--      states the mechanic ("Stunned.", "Feared." ...). Matched only at
--      line start, because Ascension writes its own colored lines and a
--      mid-sentence "stun" proves nothing. Covers NPC/boss CC that no
--      scraped list could.
--
-- Settings live in RefactorCompareDB.cc; toggles are read at use time
-- (no /reload) from the Tweaks page via RefactorCCShared.

local SOLID = "Interface\\ChatFrame\\ChatFrameBackground"
local ACCENT = { 0.20, 1.00, 0.60 }

local ICON_SIZE = 44
local RING_SIZE = 78          -- 64/36 of the icon, like ActionButton art
local DEFAULT_Y = 180         -- offset above screen center
local MIN_SCALE, MAX_SCALE, DEFAULT_SCALE = 0.6, 2.0, 1.0

local cdb -- RefactorCompareDB.cc after ADDON_LOADED

local function Scale() return (cdb and cdb.scale) or DEFAULT_SCALE end

--------------------------------------------------------------------------
-- Mechanics: label, priority (higher wins when several CCs overlap),
-- label color, and which toggle gates it. Hard loss-of-control is always
-- shown while the feature is on; roots and silences have sub-toggles.
--------------------------------------------------------------------------

-- `noAnnounce` marks mechanics that don't stop a cast bar (only movement or
-- melee), so they're excluded from the party/raid chat announce even when
-- shown on the center-screen alert: rooted/frozen casters can still cast,
-- and a disarmed player can still heal.
local MECHANICS = {
    STUN      = { label = "Stunned",       prio = 100, color = { 1.00, 0.35, 0.30 } },
    HORROR    = { label = "Horrified",     prio = 95,  color = { 1.00, 0.35, 0.30 } },
    FEAR      = { label = "Feared",        prio = 90,  color = { 1.00, 0.35, 0.30 } },
    CHARM     = { label = "Charmed",       prio = 85,  color = { 1.00, 0.35, 0.30 } },
    SLEEP     = { label = "Asleep",        prio = 80,  color = { 1.00, 0.35, 0.30 } },
    POLY      = { label = "Polymorphed",   prio = 78,  color = { 1.00, 0.35, 0.30 } },
    INCAP     = { label = "Incapacitated", prio = 76,  color = { 1.00, 0.35, 0.30 } },
    DISORIENT = { label = "Disoriented",   prio = 74,  color = { 1.00, 0.35, 0.30 } },
    BANISH    = { label = "Banished",      prio = 72,  color = { 1.00, 0.35, 0.30 } },
    FREEZE    = { label = "Frozen",        prio = 45,  color = { 1.00, 0.65, 0.25 }, flag = "roots", noAnnounce = true },
    ROOT      = { label = "Rooted",        prio = 40,  color = { 1.00, 0.65, 0.25 }, flag = "roots", noAnnounce = true },
    SILENCE   = { label = "Silenced",      prio = 30,  color = { 0.80, 0.80, 0.88 }, flag = "silences" },
    DISARM    = { label = "Disarmed",      prio = 25,  color = { 0.80, 0.80, 0.88 }, flag = "silences", noAnnounce = true },
}

-- Generated from db.ascension.gg (?spells=7.<class>&filter=me=<mechanic>)
-- across the 21 CoA classes. [spellId] = mechanic key.
local CC_SPELLS = {
    [500089] = "SILENCE", -- Subjugate
    [500326] = "FREEZE", -- Bonefreeze
    [500341] = "DISORIENT", -- Entomb
    [500355] = "FEAR", -- Mark of Terror
    [500952] = "POLY", -- Amphibimorph
    [501546] = "STUN", -- Battle Rush
    [501547] = "STUN", -- Battle Rush
    [501548] = "STUN", -- Battle Rush
    [501983] = "ROOT", -- Black Ice
    [501984] = "ROOT", -- Black Ice
    [501985] = "ROOT", -- Black Ice
    [501986] = "ROOT", -- Black Ice
    [501987] = "ROOT", -- Black Ice
    [501988] = "ROOT", -- Black Ice
    [501989] = "ROOT", -- Black Ice
    [501990] = "ROOT", -- Black Ice
    [501991] = "ROOT", -- Black Ice
    [502088] = "STUN", -- Petrifying Visage
    [502089] = "STUN", -- Petrifying Visage
    [502090] = "STUN", -- Petrifying Visage
    [502634] = "STUN", -- Everfrost Scroll
    [502635] = "STUN", -- Everfrost Scroll
    [502636] = "STUN", -- Everfrost Scroll
    [502637] = "STUN", -- Everfrost Scroll
    [502638] = "STUN", -- Everfrost Scroll
    [502639] = "STUN", -- Everfrost Scroll
    [502640] = "STUN", -- Everfrost Scroll
    [502641] = "STUN", -- Everfrost Scroll
    [502642] = "STUN", -- Everfrost Scroll
    [502890] = "ROOT", -- Spindlebind
    [502891] = "ROOT", -- Spindlebind
    [502892] = "ROOT", -- Spindlebind
    [502893] = "ROOT", -- Spindlebind
    [502894] = "ROOT", -- Spindlebind
    [502895] = "ROOT", -- Spindlebind
    [503012] = "SILENCE", -- Slipstream
    [503013] = "SILENCE", -- Slipstream
    [503014] = "SILENCE", -- Slipstream
    [503015] = "SILENCE", -- Slipstream
    [503016] = "SILENCE", -- Slipstream
    [503017] = "SILENCE", -- Slipstream
    [503018] = "SILENCE", -- Slipstream
    [503142] = "ROOT", -- Hellhaul
    [503143] = "ROOT", -- Hellhaul
    [503144] = "ROOT", -- Hellhaul
    [503145] = "ROOT", -- Hellhaul
    [503146] = "ROOT", -- Hellhaul
    [503147] = "ROOT", -- Hellhaul
    [503148] = "ROOT", -- Hellhaul
    [503361] = "SILENCE", -- Chainwhip
    [503362] = "SILENCE", -- Chainwhip
    [503363] = "SILENCE", -- Chainwhip
    [503364] = "SILENCE", -- Chainwhip
    [503365] = "SILENCE", -- Chainwhip
    [503366] = "SILENCE", -- Chainwhip
    [503367] = "SILENCE", -- Chainwhip
    [503423] = "INCAP", -- Inscription: Permafrost
    [503424] = "INCAP", -- Inscription: Permafrost
    [503425] = "INCAP", -- Inscription: Permafrost
    [503426] = "INCAP", -- Inscription: Permafrost
    [503427] = "INCAP", -- Inscription: Permafrost
    [503428] = "INCAP", -- Inscription: Permafrost
    [503429] = "INCAP", -- Inscription: Permafrost
    [503430] = "INCAP", -- Inscription: Permafrost
    [503431] = "INCAP", -- Inscription: Permafrost
    [504014] = "HORROR", -- Soulslam
    [504335] = "STUN", -- Web Wrap
    [504362] = "CHARM", -- Fungify
    [520523] = "STUN", -- Headbutt
    [535505] = "ROOT", -- Cindergrip
    [535506] = "ROOT", -- Cindergrip
    [535507] = "ROOT", -- Cindergrip
    [535508] = "ROOT", -- Cindergrip
    [560109] = "FEAR", -- Corrupt Mind
    [560110] = "FEAR", -- Madness
    [560116] = "SILENCE", -- Interdict
    [560532] = "INCAP", -- Skull Smash
    [560764] = "INCAP", -- Celestial Impact
    [560963] = "BANISH", -- Shackle The Unrepentant
    [704235] = "DISARM", -- Pinch
    [704418] = "SILENCE", -- Hammer of the Law
    [707044] = "FEAR", -- Storm Alert
    [800013] = "STUN", -- Facehug
    [800081] = "SILENCE", -- Chainwhip
    [800145] = "SLEEP", -- Grip
    [800354] = "POLY", -- Enslave
    [800366] = "SILENCE", -- Slipstream
    [800706] = "FEAR", -- Ghoulify
    [800887] = "ROOT", -- Spindlebind
    [800950] = "SILENCE", -- Deathmatch
    [801074] = "FEAR", -- Scarlet Delirium
    [801135] = "STUN", -- Starshatter
    [801280] = "STUN", -- Buy Time
    [801583] = "CHARM", -- Bind Avatar
    [801665] = "ROOT", -- Big Bad Voodoo
    [801746] = "ROOT", -- Black Ice
    [801828] = "STUN", -- Vanguard X-173: Onslaught
    [801871] = "ROOT", -- Thunder Prison Unused
    [801908] = "STUN", -- Petrifying Visage
    [802139] = "STUN", -- Darkslayer's Lantern
    [802197] = "STUN", -- Battle Rush
    [802304] = "ROOT", -- Net Throw
    [803185] = "STUN", -- Chains of Malice
    [803989] = "INCAP", -- Soul Shock
    [804060] = "INCAP", -- Permafrost Rune
    [804168] = "CHARM", -- Hellbound Leash
    [804198] = "HORROR", -- Terrify
    [804461] = "POLY", -- Babify
    [804738] = "CHARM", -- Siren's Song
    [804861] = "SILENCE", -- Anti-Magic Grenades
    [804936] = "STUN", -- Ambuscade
    [804967] = "ROOT", -- Venocannon
    [805114] = "HORROR", -- Mass Nightmare
    [805162] = "STUN", -- Breath of Time
    [805235] = "FEAR", -- Whispers of the Pit
    [805476] = "ROOT", -- Cindergrip
    [805546] = "SLEEP", -- Moonlit Slumber
    [805583] = "STUN", -- Glare
    [805756] = "DISORIENT", -- Smoke Grenade
    [805847] = "ROOT", -- Clasp of Infinity
    [806121] = "INCAP", -- Judgement Day
    [806146] = "SILENCE", -- Ghastly Screech
    [806148] = "SLEEP", -- Gaze of Ysera
    [806156] = "SILENCE", -- Astral Armor
    [806173] = "STUN", -- Drill Smash
}

-- Name fallback for trigger-spell IDs; keys lowercased.
local CC_NAMES = {
    ["ambuscade"] = "STUN",
    ["amphibimorph"] = "POLY",
    ["anti-magic grenades"] = "SILENCE",
    ["astral armor"] = "SILENCE",
    ["babify"] = "POLY",
    ["battle rush"] = "STUN",
    ["big bad voodoo"] = "ROOT",
    ["bind avatar"] = "CHARM",
    ["black ice"] = "ROOT",
    ["bonefreeze"] = "FREEZE",
    ["breath of time"] = "STUN",
    ["buy time"] = "STUN",
    ["celestial impact"] = "INCAP",
    ["chains of malice"] = "STUN",
    ["chainwhip"] = "SILENCE",
    ["cindergrip"] = "ROOT",
    ["clasp of infinity"] = "ROOT",
    ["corrupt mind"] = "FEAR",
    ["darkslayer's lantern"] = "STUN",
    ["deathmatch"] = "SILENCE",
    ["drill smash"] = "STUN",
    ["enslave"] = "POLY",
    ["entomb"] = "DISORIENT",
    ["everfrost scroll"] = "STUN",
    ["facehug"] = "STUN",
    ["fungify"] = "CHARM",
    ["gaze of ysera"] = "SLEEP",
    ["ghastly screech"] = "SILENCE",
    ["ghoulify"] = "FEAR",
    ["glare"] = "STUN",
    ["grip"] = "SLEEP",
    ["hammer of the law"] = "SILENCE",
    ["headbutt"] = "STUN",
    ["hellbound leash"] = "CHARM",
    ["hellhaul"] = "ROOT",
    ["inscription: permafrost"] = "INCAP",
    ["interdict"] = "SILENCE",
    ["judgement day"] = "INCAP",
    ["madness"] = "FEAR",
    ["mark of terror"] = "FEAR",
    ["mass nightmare"] = "HORROR",
    ["moonlit slumber"] = "SLEEP",
    ["net throw"] = "ROOT",
    ["permafrost rune"] = "INCAP",
    ["petrifying visage"] = "STUN",
    ["pinch"] = "DISARM",
    ["scarlet delirium"] = "FEAR",
    ["shackle the unrepentant"] = "BANISH",
    ["siren's song"] = "CHARM",
    ["skull smash"] = "INCAP",
    ["slipstream"] = "SILENCE",
    ["smoke grenade"] = "DISORIENT",
    ["soul shock"] = "INCAP",
    ["soulslam"] = "HORROR",
    ["spindlebind"] = "ROOT",
    ["starshatter"] = "STUN",
    ["storm alert"] = "FEAR",
    ["subjugate"] = "SILENCE",
    ["terrify"] = "HORROR",
    ["thunder prison unused"] = "ROOT",
    ["vanguard x-173: onslaught"] = "STUN",
    ["venocannon"] = "ROOT",
    ["web wrap"] = "STUN",
    ["whispers of the pit"] = "FEAR",
}

--------------------------------------------------------------------------
-- Tooltip fallback: the aura description on a debuff tooltip usually
-- opens with the mechanic ("Stunned.", "Fleeing in terror." ...). Only
-- line starts count. Results cached per spell ID for the session —
-- a debuff's text never changes while logged in.
--------------------------------------------------------------------------

local TOOLTIP_PATTERNS = {
    { "^stunned",       "STUN" },
    { "^stuns? you",    "STUN" },
    { "^horrified",     "HORROR" },
    { "^feared",        "FEAR" },
    { "^fleeing",       "FEAR" },
    { "^running in fear", "FEAR" },
    { "^charmed",       "CHARM" },
    { "^seduced",       "CHARM" },
    { "^asleep",        "SLEEP" },
    { "^polymorphed",   "POLY" },
    { "^incapacitated", "INCAP" },
    { "^sapped",        "INCAP" },
    { "^gouged",        "INCAP" },
    { "^disoriented",   "DISORIENT" },
    { "^banished",      "BANISH" },
    { "^frozen",        "FREEZE" },
    { "^rooted",        "ROOT" },
    { "^immobilized",   "ROOT" },
    { "^entangled",     "ROOT" },
    { "^silenced",      "SILENCE" },
    { "^disarmed",      "DISARM" },
}

local scanTip = CreateFrame("GameTooltip", "RefactorCCScanTip", nil,
    "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

local tipCache = {} -- [spellId or "n:"..name] = mechanic key or false
local tipCacheCount = 0
local TIP_CACHE_CAP = 300 -- distinct enemy debuffs scanned this session; wipe wholesale past this rather than grow forever

local function TooltipMechanic(index, spellId, name)
    local key = spellId or ("n:" .. name)
    local cached = tipCache[key]
    if cached ~= nil then return cached or nil end

    if tipCacheCount >= TIP_CACHE_CAP then
        tipCache = {}
        tipCacheCount = 0
    end

    scanTip:SetOwner(UIParent, "ANCHOR_NONE") -- re-owning also resets state
    scanTip:ClearLines()
    scanTip:SetUnitDebuff("player", index)
    local found = false
    for i = 2, scanTip:NumLines() do -- line 1 is the debuff name
        local left = _G["RefactorCCScanTipTextLeft" .. i]
        local text = left and left:GetText()
        if text then
            text = text:lower()
            for _, p in ipairs(TOOLTIP_PATTERNS) do
                if text:find(p[1]) then
                    found = p[2]
                    break
                end
            end
        end
        if found then break end
    end
    tipCache[key] = found
    tipCacheCount = tipCacheCount + 1
    return found or nil
end

--------------------------------------------------------------------------
-- Display frame
--------------------------------------------------------------------------

local frame -- built on first use

local function BuildFrame()
    local f = CreateFrame("Frame", "RefactorCCFrame", UIParent)
    f:SetWidth(RING_SIZE)
    f:SetHeight(RING_SIZE + 26)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local iconHolder = CreateFrame("Frame", nil, f)
    iconHolder:SetWidth(ICON_SIZE)
    iconHolder:SetHeight(ICON_SIZE)
    iconHolder:SetPoint("TOP", 0, -(RING_SIZE - ICON_SIZE) / 2)

    f.icon = iconHolder:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    f.cooldown = CreateFrame("Cooldown", "RefactorCCCooldown", iconHolder,
        "CooldownFrameTemplate")
    f.cooldown:SetAllPoints()

    -- Stock slot ring over the icon, like the loot toasts.
    f.ring = f:CreateTexture(nil, "OVERLAY")
    f.ring:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    f.ring:SetWidth(RING_SIZE)
    f.ring:SetHeight(RING_SIZE)
    f.ring:SetPoint("CENTER", iconHolder, "CENTER", 0, -1)

    -- Countdown rides above the cooldown spiral, so it needs its own
    -- higher-level frame — textures on `f` would render under it.
    local textHolder = CreateFrame("Frame", nil, f)
    textHolder:SetAllPoints(iconHolder)
    textHolder:SetFrameLevel(f.cooldown:GetFrameLevel() + 1)
    f.timer = textHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
    f.timer:SetPoint("CENTER", 0, 0)

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.label:SetPoint("TOP", iconHolder, "BOTTOM", 0, -8)

    f.spell = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.spell:SetPoint("TOP", f.label, "BOTTOM", 0, -2)
    f.spell:SetTextColor(0.62, 0.62, 0.66)

    f:SetScript("OnUpdate", function(self, elapsed)
        self.throttle = (self.throttle or 0) + elapsed
        if self.throttle < 0.05 then return end
        self.throttle = 0
        if self.expiration and (not cdb or cdb.showDuration ~= false) then
            local remain = self.expiration - GetTime()
            if remain <= 0 then
                self:Hide()
                return
            end
            if remain < 10 then
                self.timer:SetFormattedText("%.1f", remain)
            else
                self.timer:SetFormattedText("%d", remain)
            end
        else
            self.timer:SetText("") -- hidden-duration aura: icon + label only
        end
    end)

    frame = f
    return f
end

local function PositionFrame(f)
    local s = Scale()
    f:SetScale(s)
    f:ClearAllPoints()
    -- SetPoint offsets are in the frame's own (scaled) coordinates, so the
    -- saved UIParent-space offset is divided back out — same trick the
    -- movable map window uses for its scale.
    if cdb and cdb.x and cdb.y then
        f:SetPoint("CENTER", UIParent, "CENTER", cdb.x / s, cdb.y / s)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, DEFAULT_Y / s)
    end
end

local function ShowCC(mech, icon, spellName, duration, expiration)
    local f = frame or BuildFrame()
    local m = MECHANICS[mech]
    PositionFrame(f)
    f.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    f.label:SetText(m.label)
    f.label:SetTextColor(m.color[1], m.color[2], m.color[3])
    f.spell:SetText(spellName or "")
    if duration and duration > 0 and expiration then
        f.expiration = expiration
        f.cooldown:SetCooldown(expiration - duration, duration)
        f.cooldown:Show()
    else
        f.expiration = nil
        f.cooldown:Hide()
    end
    f.throttle = 1 -- render the timer text on the next frame
    f:Show()
end

-- Fingerprint of what the frame currently shows. UNIT_AURA fires for the
-- player constantly in combat (procs, HoTs, everything), and while CC'd
-- every one of those used to re-run the full restyle — SetScale,
-- ClearAllPoints, SetPoint, SetTexture, SetCooldown — for an unchanged
-- aura. Same key = frame already correct, skip it all.
local shownKey

local function HideCC()
    shownKey = nil
    if frame then frame:Hide() end
end

--------------------------------------------------------------------------
-- Debuff scan
--------------------------------------------------------------------------

local testUntil -- while set (by the config window's Test button), real
                -- scans keep their hands off the frame

local function MechanicAllowed(m)
    local flag = MECHANICS[m].flag
    return not flag or cdb[flag]
end

-- Party/raid announce: fires once per CC application (not every UNIT_AURA
-- tick while it's active), skipped solo, and skipped for mechanics that
-- don't stop a cast bar (see MECHANICS' noAnnounce).
local announcedKey

local function ChatChannel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

local function Announce(mech, spellId, spellName, remain)
    local label = MECHANICS[mech].label
    local msg
    if remain and remain < math.huge then
        msg = string.format("%s! (%s, %ds)", label, spellName, math.ceil(remain))
    else
        msg = string.format("%s! (%s)", label, spellName)
    end
    local channel = ChatChannel()
    if channel then
        SendChatMessage(msg, channel)
    elseif RefactorCompareDB and RefactorCompareDB.debug then
        -- Solo + /rfc debug: echo locally so the toggle can be tested
        -- without grouping up first.
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff33ff99Refactor|r: [solo, not sent] " .. msg)
    end
end

local function Update()
    if not cdb or not cdb.enabled then
        HideCC()
        announcedKey = nil
        return
    end
    if testUntil then
        if GetTime() < testUntil then return end
        testUntil = nil
    end

    local bestMech, bestPrio, bestRemain = nil, -1, -1
    local bestIcon, bestName, bestDur, bestExp, bestSpellId
    for i = 1, 40 do
        local name, _, icon, _, _, duration, expiration, _, _, _, spellId =
            UnitDebuff("player", i)
        if not name then break end
        local mech = (spellId and CC_SPELLS[spellId])
            or CC_NAMES[name:lower()]
            or TooltipMechanic(i, spellId, name)
        if mech and MechanicAllowed(mech) then
            local prio = MECHANICS[mech].prio
            -- Hidden-duration auras sort as infinite: they outlast timed ones.
            local remain = (duration and duration > 0 and expiration)
                and (expiration - GetTime()) or math.huge
            if prio > bestPrio or (prio == bestPrio and remain > bestRemain) then
                bestMech, bestPrio, bestRemain = mech, prio, remain
                bestIcon, bestName, bestDur, bestExp, bestSpellId =
                    icon, name, duration, expiration, spellId
            end
        end
    end

    if bestMech then
        -- Restyle only when the winning aura actually changed (new CC, or
        -- the same one reapplied with a new expiration). The IsShown check
        -- covers the frame's own OnUpdate hiding it at zero while the aura
        -- lingers a moment longer server-side.
        local key = bestMech .. ":" .. tostring(bestSpellId or bestName)
            .. ":" .. tostring(bestExp)
        if key ~= shownKey or not (frame and frame:IsShown()) then
            shownKey = key
            ShowCC(bestMech, bestIcon, bestName, bestDur, bestExp)
        end
        if cdb.announce and not MECHANICS[bestMech].noAnnounce and not testUntil then
            local key = (bestSpellId or bestName) .. ":" .. tostring(bestExp)
            if key ~= announcedKey then
                announcedKey = key
                Announce(bestMech, bestSpellId, bestName, bestRemain)
            end
        end
    else
        HideCC()
        announcedKey = nil
    end
end

--------------------------------------------------------------------------
-- Anchor drag handle (config window's Move button)
--------------------------------------------------------------------------

local anchorFrame

local function ShowAnchor()
    if not anchorFrame then
        local a = CreateFrame("Frame", nil, UIParent)
        a:SetWidth(140)
        a:SetHeight(RING_SIZE + 26)
        a:SetFrameStrata("DIALOG")
        a:SetBackdrop({ bgFile = SOLID, edgeFile = SOLID, edgeSize = 1 })
        a:SetBackdropColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.12)
        a:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
        local label = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("CC alert — drag me\n|cff999999click Done in Tweaks to save|r")
        a:SetMovable(true)
        a:EnableMouse(true)
        a:RegisterForDrag("LeftButton")
        a:SetScript("OnDragStart", a.StartMoving)
        a:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local cx, cy = self:GetCenter()
            local ux, uy = UIParent:GetCenter()
            cdb.x = cx - ux
            cdb.y = cy - uy
            if frame and frame:IsShown() then PositionFrame(frame) end
        end)
        anchorFrame = a
    end
    anchorFrame:ClearAllPoints()
    anchorFrame:SetPoint("CENTER", UIParent, "CENTER",
        cdb and cdb.x or 0, cdb and cdb.y or DEFAULT_Y)
    anchorFrame:Show()
end

local function Test()
    if not cdb then return end
    local dur = 4
    testUntil = GetTime() + dur
    ShowCC("STUN", "Interface\\Icons\\Ability_MeleeDamage", "Test Stun",
        dur, GetTime() + dur)
    shownKey = nil -- test content isn't a real aura: force the next real restyle
end

-- Shared with RefactorUI.lua (the config window).
RefactorCCShared = {
    GetDB = function() return cdb end,
    ShowAnchor = function() ShowAnchor() end,
    HideAnchor = function() if anchorFrame then anchorFrame:Hide() end end,
    IsAnchorShown = function()
        return anchorFrame and anchorFrame:IsShown() or false
    end,
    ResetPosition = function()
        if cdb then cdb.x, cdb.y = nil, nil end
        if frame and frame:IsShown() then PositionFrame(frame) end
        if anchorFrame and anchorFrame:IsShown() then ShowAnchor() end
    end,
    Test = Test,
    Update = Update, -- toggles re-check immediately, not on the next debuff
    GetScale = Scale,
    SetScale = function(v)
        if not cdb then return end
        if v < MIN_SCALE then v = MIN_SCALE end
        if v > MAX_SCALE then v = MAX_SCALE end
        cdb.scale = v
        if frame and frame:IsShown() then PositionFrame(frame) end
    end,
    MIN_SCALE = MIN_SCALE,
    MAX_SCALE = MAX_SCALE,
}

--------------------------------------------------------------------------
-- Init & events
--------------------------------------------------------------------------

-- UNIT_AURA fires in bursts — several per frame in raid combat (procs,
-- HoTs, everything) — and each one used to run the full debuff walk.
-- GetTime() is frame-cached, so a same-timestamp guard collapses a burst
-- to one scan per frame. Explicit callers (UI toggles, Test) go through
-- RefactorCCShared.Update directly and skip the guard.
local lastAuraStamp

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= "Refactor" then return end
        if type(RefactorCompareDB) ~= "table" then RefactorCompareDB = {} end
        if type(RefactorCompareDB.cc) ~= "table" then
            RefactorCompareDB.cc = {}
        end
        cdb = RefactorCompareDB.cc
        if cdb.enabled == nil then cdb.enabled = true end
        if cdb.roots == nil then cdb.roots = true end
        if cdb.silences == nil then cdb.silences = true end
        if cdb.showDuration == nil then cdb.showDuration = true end
        if cdb.announce == nil then cdb.announce = false end
        if cdb.scale == nil then cdb.scale = DEFAULT_SCALE end
    elseif event == "UNIT_AURA" then
        if arg1 == "player" then
            local now = GetTime()
            if now ~= lastAuraStamp then
                lastAuraStamp = now
                Update()
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        Update()
    end
end)
