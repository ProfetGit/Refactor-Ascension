-- RefactorMap.lua
-- World map scroll-to-zoom/click-drag-pan and class-colored party/raid map
-- icons, ported (MIT license) from Magnify-WotLK
-- (https://github.com/rissole/Magnify-WotLK) into Refactor's own flag and
-- settings system instead of a separate SavedVariable/options panel.
--
-- WorldMapButton's OnUpdate script is fully replaced (position math for the
-- player arrow, party/raid dots, corpse, death release, battleground flags
-- and vehicles) since that positioning has no partial/stock fallback once
-- taken over — same as Magnify itself. Only the interactive pieces are
-- gated behind flags checked at use time, so toggling needs no /reload:
-- mapZoom (scroll-wheel zoom + click-drag pan) and mapClassIcons (class
-- color vs. the stock white dot).
--
-- Coexists with Refactor's own fullMapWindow shell (Refactor.lua): that
-- tweak only moves/scales the outer WorldMapFrame and never touches
-- WorldMapScrollFrame/WorldMapDetailFrame, so both run without conflict —
-- dragging the title strip resizes the window, scrolling over the map
-- content zooms it.
--
-- Performance shape: the replaced WorldMapButton OnUpdate is stock-parity
-- per frame while the map is open; on top of that, class colors are
-- cached per unit token (successes only, wiped on roster events) with
-- texture dirty-checks, the Mapster lookup is cached, map coordinates
-- throttle to 10 Hz, and quest-blob redraws during pan throttle to
-- ~16 Hz with a final redraw on mouse-up. Combat: the map tree is protected on
-- Ascension, so zoom rescales return early in combat and blob/layout
-- work is deferred to PLAYER_REGEN_ENABLED (see the combat section).
--
-- Leatrix Maps ships this SAME Magnify port (Leatrix_Maps_Zoom.lua): its
-- own zoom/pan, class icons, replaced WorldMapButton scripts and the same
-- WorldMapFrame_UpdateQuests -> ResizeQuestPOIs hook. hooksecurefunc hooks
-- stack, and resizePOI is not idempotent — each pass divides the POI
-- anchor by the scale ratio again, so with both addons active the quest
-- markers drift off their true location as the map is zoomed (x/s² instead
-- of x/s), no matter what Refactor's flags are set to. When Leatrix Maps
-- is loaded the whole port below stands down and Leatrix owns the map;
-- only the Refactor-specific extras (map coordinates, move fade) stay
-- active — they read live frame geometry and hook nothing.

do
    -- The module cannot function without any of these (the blob frame and
    -- POI frame included), so check the full set up front rather than
    -- nil-guarding every use below.
    if not (WorldMapFrame and WorldMapScrollFrame and WorldMapDetailFrame
        and WorldMapButton and WORLDMAP_SETTINGS and WorldMapBlobFrame
        and WorldMapPOIFrame and WorldMapPlayer and WorldMapPing
        and WorldMapScreenAnchor) then
        return
    end

    local MIN_ZOOM = 1.0
    local MAX_ZOOM = 5.0 -- fixed for everyone, not user-configurable
    local ZOOM_STEP = 0.1

    local MINIMODE_MIN_ZOOM, MINIMODE_MAX_ZOOM = 1.0, 3.0
    local MINIMODE_ZOOM_STEP = 0.1

    local WORLDMAP_POI_MIN_X, WORLDMAP_POI_MIN_Y = 12, -12
    local poiMaxX, poiMaxY -- set by SetPOIMaxBounds, changes with current scale

    local PLAYER_ARROW_SIZE = 36

    local function Qol(key)
        return RefactorQoL and RefactorQoL.Get(key)
    end

    --------------------------------------------------------------------
    -- Player + cursor coordinates (idea from Mapster's Coords module) —
    -- gated by mapCoords, checked at use time. Cursor math reads
    -- WorldMapDetailFrame's live geometry, so it stays correct across
    -- zoom and pan — including Leatrix Maps' own zoom while the Magnify
    -- port below is standing down.
    --------------------------------------------------------------------

    local coordsFrame = CreateFrame("Frame", nil, WorldMapFrame)
    coordsFrame:SetFrameLevel(WORLDMAP_POI_FRAMELEVEL)
    local playerCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerCoords:SetPoint("BOTTOMLEFT", WorldMapScrollFrame, "BOTTOMLEFT", 8, 8)
    local cursorCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cursorCoords:SetPoint("BOTTOMRIGHT", WorldMapScrollFrame, "BOTTOMRIGHT", -8, 8)

    local function CursorMapPosition()
        local left, top = WorldMapDetailFrame:GetLeft(), WorldMapDetailFrame:GetTop()
        if not left then return end
        local scale = WorldMapDetailFrame:GetEffectiveScale()
        local x, y = GetCursorPosition()
        local cx = (x / scale - left) / WorldMapDetailFrame:GetWidth()
        local cy = (top - y / scale) / WorldMapDetailFrame:GetHeight()
        if cx < 0 or cx > 1 or cy < 0 or cy > 1 then return end
        return cx, cy
    end

    -- OnUpdate only runs while the map is shown (parent chain hides it).
    -- Throttled to 10 Hz: coordinates don't need per-frame updates, and
    -- SetFormattedText allocates a fresh string every call.
    local coordsAccum = 0
    coordsFrame:SetScript("OnUpdate", function(_, elapsed)
        coordsAccum = coordsAccum + (elapsed or 0)
        if coordsAccum < 0.1 then return end
        coordsAccum = 0
        if not Qol("mapCoords") then
            if playerCoords:GetText() then
                playerCoords:SetText("")
                cursorCoords:SetText("")
            end
            return
        end
        local px, py = GetPlayerMapPosition("player")
        if px == 0 and py == 0 then
            playerCoords:SetText("")
        else
            playerCoords:SetFormattedText("Player: %.1f, %.1f", px * 100, py * 100)
        end
        local cx, cy = CursorMapPosition()
        if cx then
            cursorCoords:SetFormattedText("Cursor: %.1f, %.1f", cx * 100, cy * 100)
        else
            cursorCoords:SetText("")
        end
    end)

    --------------------------------------------------------------------
    -- Fade the map while the character moves — gated by mapMoveFade,
    -- checked at use time. Alpha is only touched while the feature is
    -- actively fading (baseline captured at fade start, restored after),
    -- so a Mapster/user-set map alpha is respected, not overwritten.
    -- Mousing over the map content restores full visibility.
    --------------------------------------------------------------------

    local FADE_ALPHA = 0.4
    local FADE_SPEED = 6 -- exponential smoothing factor, ~instant feel

    local fadeBaseline -- alpha before the current fade; nil = not fading
    local fadeFrame = CreateFrame("Frame", nil, WorldMapFrame)
    fadeFrame:SetScript("OnUpdate", function(_, elapsed)
        -- Feature off and not mid-fade: skip even the GetUnitSpeed poll.
        -- A fade already in progress still restores when toggled off.
        if not fadeBaseline and not Qol("mapMoveFade") then return end
        local moving = GetUnitSpeed and (GetUnitSpeed("player") or 0) > 0
        local wantFade = moving and Qol("mapMoveFade")
            and not WorldMapScrollFrame:IsMouseOver()

        local target
        if wantFade then
            if not fadeBaseline then fadeBaseline = WorldMapFrame:GetAlpha() end
            target = min(FADE_ALPHA, fadeBaseline)
        elseif fadeBaseline then
            target = fadeBaseline
        else
            return -- feature idle: leave alpha alone entirely
        end

        local cur = WorldMapFrame:GetAlpha()
        if abs(cur - target) < 0.015 then
            WorldMapFrame:SetAlpha(target)
            if not wantFade then fadeBaseline = nil end
        else
            WorldMapFrame:SetAlpha(cur + (target - cur) * min(1, elapsed * FADE_SPEED))
        end
    end)
    WorldMapFrame:HookScript("OnHide", function()
        if fadeBaseline then
            WorldMapFrame:SetAlpha(fadeBaseline)
            fadeBaseline = nil
        end
    end)

    --------------------------------------------------------------------
    -- Leatrix Maps stand-down (see file header): Leatrix ships this same
    -- Magnify port, and running both stacks the UpdateQuests hooks —
    -- quest POI markers drift off their location as the map is zoomed.
    -- Leatrix loads before Refactor (alphabetical), so this check is
    -- reliable at load time. Everything below this point is the port.
    --------------------------------------------------------------------

    if IsAddOnLoaded("Leatrix_Maps") then
        local notice = CreateFrame("Frame")
        notice:RegisterEvent("PLAYER_ENTERING_WORLD")
        notice:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            if Qol("mapZoom") or Qol("mapClassIcons") then
                DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r "
                    .. "Leatrix Maps is managing the world map, so map"
                    .. " zoom and class-colored icons are standing down"
                    .. " (Leatrix provides both). Map coordinates and"
                    .. " move-fade stay available.")
            end
        end)
        return
    end

    --------------------------------------------------------------------
    -- Mapster / ElvUI cooperation (both listed compatible upstream)
    --------------------------------------------------------------------

    local function GetElvUI()
        if ElvUI and ElvUI[1] then return ElvUI[1] end
        return nil
    end

    -- The LibStub lookup is the expensive part and its result only changes
    -- with a /reload, so cache it: the map OnUpdate calls this every frame.
    -- mapsterChecked is reset in SetupWorldMapFrame (every map open) in
    -- case Mapster was loaded on demand after Refactor.
    local mapsterAddon, mapsterChecked
    local function GetMapster(configName)
        if not mapsterChecked then
            mapsterChecked = true
            if LibStub and LibStub:GetLibrary("AceAddon-3.0", true) then
                mapsterAddon = LibStub:GetLibrary("AceAddon-3.0"):GetAddon("Mapster", true)
            end
        end
        if mapsterAddon and mapsterAddon.db and mapsterAddon.db.profile then
            return mapsterAddon, mapsterAddon.db.profile[configName]
        end
        return mapsterAddon, nil
    end

    local function updatePointRelativeTo(frame, newRelativeFrame)
        local point, _rel, relPoint, x, y = frame:GetPoint()
        frame:ClearAllPoints()
        frame:SetPoint(point, newRelativeFrame, relPoint, x, y)
    end

    local function ElvUI_SetupWorldMapFrame()
        local worldMap = GetElvUI():GetModule("WorldMap")
        if not worldMap then return end

        if worldMap.coordsHolder and worldMap.coordsHolder.playerCoords then
            updatePointRelativeTo(worldMap.coordsHolder.playerCoords, WorldMapScrollFrame)
        end

        if WorldMapDetailFrame.backdrop then
            WorldMapDetailFrame.backdrop:Hide()
            -- Upstream had `local _, relFrame = WorldMapFrame.backdrop`
            -- here (always nil, dead branch). The intent was to check what
            -- the backdrop is anchored to.
            if WorldMapFrame.backdrop then
                local _, relFrame = WorldMapFrame.backdrop:GetPoint()
                if relFrame == WorldMapDetailFrame then
                    updatePointRelativeTo(WorldMapFrame.backdrop, WorldMapScrollFrame)
                end
            end
        end

        if WorldMapFrame.backdrop then
            WorldMapFrame.backdrop.Point = function() return end
            WorldMapFrame.backdrop:ClearAllPoints()
            if WorldMapZoneMinimapDropDown:IsVisible() then
                WorldMapFrame.backdrop:SetPoint("TOPLEFT", WorldMapZoneMinimapDropDown, "TOPLEFT", -20, 40)
            else
                WorldMapFrame.backdrop:SetPoint("TOPLEFT", WorldMapTitleButton, "TOPLEFT", 0, 0)
            end
            WorldMapFrame.backdrop:SetPoint("BOTTOM", WorldMapQuestShowObjectives, "BOTTOM", 0, 0)
            WorldMapFrame.backdrop:SetPoint("RIGHT", WorldMapFrameCloseButton, "RIGHT", 0, 0)
        end
    end

    --------------------------------------------------------------------
    -- Scale / POI / quest-blob plumbing
    --------------------------------------------------------------------

    local function SetPOIMaxBounds()
        poiMaxY = WorldMapDetailFrame:GetHeight() * -WORLDMAP_SETTINGS.size + 12
        poiMaxX = WorldMapDetailFrame:GetWidth() * WORLDMAP_SETTINGS.size + 12
    end

    -- NOT idempotent by nature: each pass divides the POI anchor by the
    -- scale ratio, so a second pass on an already-rescaled button drifts
    -- it (x/s² — the same drift the Leatrix stand-down avoids), and the
    -- UpdateQuests hook can fire several times per zoom step. To stay
    -- re-entrant, remember what we set: if the button still sits where we
    -- put it, recover the original anchor (orig = ours × old s) instead of
    -- treating our own output as fresh stock input. If stock re-anchored
    -- the button in the meantime, the point won't match and it's treated
    -- as a fresh anchor.
    local function resizePOI(poiButton)
        if not poiButton then return end
        local _, _, _, x, y = poiButton:GetPoint()
        if x == nil or y == nil then return end
        if poiButton.refactorS
            and abs(poiButton.refactorX - x) < 0.01
            and abs(poiButton.refactorY - y) < 0.01 then
            x = x * poiButton.refactorS
            y = y * poiButton.refactorS
        end
        local s = WORLDMAP_SETTINGS.size / WorldMapDetailFrame:GetEffectiveScale()
        local posX = x * 1 / s
        local posY = y * 1 / s
        poiButton:SetScale(s)
        poiButton:SetPoint("CENTER", poiButton:GetParent(), "TOPLEFT", posX, posY)
        poiButton.refactorX, poiButton.refactorY, poiButton.refactorS = posX, posY, s

        if posY > WORLDMAP_POI_MIN_Y then posY = WORLDMAP_POI_MIN_Y
        elseif poiMaxY and posY < poiMaxY then posY = poiMaxY end
        if posX < WORLDMAP_POI_MIN_X then posX = WORLDMAP_POI_MIN_X
        elseif poiMaxX and posX > poiMaxX then posX = poiMaxX end
    end

    local function ResizeQuestPOIs()
        -- Take over POI placement from Mapster while it's loaded (once per
        -- pass, not once per button).
        local mapster = GetMapster("poiScale")
        if mapster then
            mapster.WorldMapFrame_DisplayQuestPOI = function() end
        end
        local QUEST_POI_MAX_TYPES = 4
        local POI_TYPE_MAX_BUTTONS = 25
        for i = 1, QUEST_POI_MAX_TYPES do
            for j = 1, POI_TYPE_MAX_BUTTONS do
                resizePOI(_G["poiWorldMapPOIFrame" .. i .. "_" .. j])
            end
        end
        if QUEST_POI_SWAP_BUTTONS then
            resizePOI(QUEST_POI_SWAP_BUTTONS["WorldMapPOIFrame"])
        end
    end

    local function RedrawSelectedQuest()
        if WORLDMAP_SETTINGS.selectedQuestId then
            WorldMapFrame_SelectQuestById(WORLDMAP_SETTINGS.selectedQuestId)
        else
            WorldMapFrame_SelectQuestFrame(_G["WorldMapQuestFrame1"])
        end
    end

    -- DrawQuestBlob touches the protected blob frame; in combat that's a
    -- blocked action, so record the intent and let combatWatcher replay it
    -- on PLAYER_REGEN_ENABLED (its restore path re-attaches the blob).
    local pendingBlobRedraw
    local function AfterScrollOrPan()
        if InCombatLockdown() then
            pendingBlobRedraw = true
            return
        end
        pendingBlobRedraw = nil
        if WORLDMAP_SETTINGS.selectedQuest then
            WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, false)
            WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, true)
        end
    end

    local function SetDetailFrameScale(num)
        WorldMapDetailFrame:SetScale(num)
        SetPOIMaxBounds()

        WorldMapPOIFrame:SetScale(1 / WORLDMAP_SETTINGS.size)
        WorldMapBlobFrame:SetScale(num)

        WorldMapPlayer:SetScale(1 / WorldMapDetailFrame:GetScale())
        WorldMapDeathRelease:SetScale(1 / WorldMapDetailFrame:GetScale())
        WorldMapCorpse:SetScale(1 / WorldMapDetailFrame:GetScale())

        local numFlags = GetNumBattlefieldFlagPositions()
        for i = 1, numFlags do
            local flag = _G["WorldMapFlag" .. i]
            if flag then flag:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end
        for i = 1, MAX_PARTY_MEMBERS do
            if _G["WorldMapParty" .. i] then
                _G["WorldMapParty" .. i]:SetScale(1 / WorldMapDetailFrame:GetScale())
            end
        end
        for i = 1, MAX_RAID_MEMBERS do
            if _G["WorldMapRaid" .. i] then
                _G["WorldMapRaid" .. i]:SetScale(1 / WorldMapDetailFrame:GetScale())
            end
        end
        for i = 1, #MAP_VEHICLES do
            if MAP_VEHICLES[i] then
                MAP_VEHICLES[i]:SetScale(1 / WorldMapDetailFrame:GetScale())
            end
        end

        WorldMapFrame_OnEvent(WorldMapFrame, "DISPLAY_SIZE_CHANGED")
        if WorldMapFrame_UpdateQuests() > 0 then
            RedrawSelectedQuest()
        end
    end

    --------------------------------------------------------------------
    -- Layout: reparents the map content into a properly sized scroll
    -- frame and positions it per map mode (fullscreen / quest-list /
    -- classic windowed). Runs on every mode switch.
    --------------------------------------------------------------------

    -- Repositions/reparents most of the Ascension-protected map tree, so
    -- it's a blocked action in combat (opening the map mid-fight runs this
    -- from the OnShow hook): record the intent and let combatWatcher run
    -- it on PLAYER_REGEN_ENABLED. Until then the map shows stock layout.
    local setupDeferred
    local function SetupWorldMapFrame()
        if InCombatLockdown() then
            setupDeferred = true
            return
        end
        setupDeferred = nil
        mapsterChecked = nil -- re-check for a load-on-demand Mapster
        WorldMapScrollFrame:SetWidth(1002)
        WorldMapScrollFrame:SetHeight(668)
        if WorldMapScrollFrameScrollBar then WorldMapScrollFrameScrollBar:Hide() end
        WorldMapFrame:EnableMouse(true)
        WorldMapScrollFrame:EnableMouse(true)
        WorldMapScrollFrame.panning = false
        WorldMapScrollFrame.moved = false

        if WORLDMAP_SETTINGS.size == WORLDMAP_QUESTLIST_SIZE then
            WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide, "TOP", -726, -99)
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide, "BOTTOMLEFT", 8, 4)
        elseif WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide, "BOTTOMLEFT", 16, -9)

            WorldMapFrame:SetPoint("TOPLEFT", WorldMapScreenAnchor, 0, 0)
            WorldMapFrame:SetScale(WorldMapScreenAnchor.preferredMinimodeScale)
            WorldMapFrame:SetMovable(true)
            WorldMapTitleButton:Show()
            WorldMapTitleButton:ClearAllPoints()
            WorldMapFrameTitle:Show()
            WorldMapFrameTitle:ClearAllPoints()
            WorldMapFrameTitle:SetPoint("CENTER", WorldMapTitleButton, "CENTER", 32, 0)

            if WORLDMAP_SETTINGS.advanced then
                WorldMapScrollFrame:SetPoint("TOPLEFT", 19, -42)
                WorldMapTitleButton:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 13, 0)
            else
                WorldMapScrollFrame:SetPoint("TOPLEFT", 37, -66)
                WorldMapTitleButton:SetPoint("TOPLEFT", WorldMapFrame, "TOPLEFT", 13, -14)
            end
        else
            WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide, "TOPLEFT", 11, -70.5)
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide, "BOTTOMLEFT", 16, -9)
        end

        WorldMapScrollFrame:SetScale(WORLDMAP_SETTINGS.size)

        SetDetailFrameScale(1)
        WorldMapDetailFrame:SetAllPoints(WorldMapScrollFrame)
        WorldMapScrollFrame:SetHorizontalScroll(0)
        WorldMapScrollFrame:SetVerticalScroll(0)
        -- The zoom interaction state must reset with the layout: without
        -- this, zooming in, closing the map and reopening it leaves
        -- zoomedIn true with stale maxX/maxY, and a left-drag then pans an
        -- unzoomed map against the old bounds.
        WorldMapScrollFrame.zoomedIn = false
        WorldMapScrollFrame.maxX = 0
        WorldMapScrollFrame.maxY = 0

        WorldMapButton:SetScale(1)
        WorldMapButton:SetAllPoints(WorldMapDetailFrame)
        WorldMapButton:SetParent(WorldMapDetailFrame)

        WorldMapPOIFrame:SetParent(WorldMapDetailFrame)
        WorldMapBlobFrame:SetParent(WorldMapDetailFrame)
        WorldMapBlobFrame:ClearAllPoints()
        WorldMapBlobFrame:SetAllPoints(WorldMapDetailFrame)

        WorldMapPlayer:SetParent(WorldMapDetailFrame)

        updatePointRelativeTo(WorldMapQuestScrollFrame, WorldMapScrollFrame)
        updatePointRelativeTo(WorldMapQuestDetailScrollFrame, WorldMapScrollFrame)

        if GetElvUI() then ElvUI_SetupWorldMapFrame() end
    end

    --------------------------------------------------------------------
    -- Zoom / pan interaction — gated by mapZoom, checked at use time
    --------------------------------------------------------------------

    -- Blob redraws are the heaviest part of panning (a full re-tessellation
    -- per call, twice), so during a drag they're throttled to ~16 Hz; the
    -- scroll itself stays per-frame and OnMouseUp does a final redraw.
    local lastPanBlob = 0
    local function WorldMapScrollFrame_OnPan(cursorX, cursorY)
        -- Divide by WorldMapButton's effective scale, not WorldMapScrollFrame's:
        -- WorldMapButton is parented under WorldMapDetailFrame and its effective
        -- scale grows with zoom, so this converts the cursor's screen-pixel delta
        -- into WorldMapScrollFrame content units at the CURRENT zoom level.
        -- Dividing by the scroll frame's own (zoom-independent) scale instead
        -- under-divides while zoomed in, making the map pan far faster than the
        -- mouse moves. Matches upstream Magnify, which reads this off `this` —
        -- the frame the OnUpdate script (WorldMapButton's) is actually running on.
        local dX = (WorldMapScrollFrame.cursorX - cursorX) / WorldMapButton:GetEffectiveScale()
        local dY = (cursorY - WorldMapScrollFrame.cursorY) / WorldMapButton:GetEffectiveScale()
        if abs(dX) >= 1 or abs(dY) >= 1 then
            WorldMapScrollFrame.moved = true

            local x = max(0, dX + WorldMapScrollFrame.x)
            x = min(x, WorldMapScrollFrame.maxX or x)
            WorldMapScrollFrame:SetHorizontalScroll(x)

            local y = max(0, dY + WorldMapScrollFrame.y)
            y = min(y, WorldMapScrollFrame.maxY or y)
            WorldMapScrollFrame:SetVerticalScroll(y)
            local now = GetTime()
            if now - lastPanBlob > 0.06 then
                lastPanBlob = now
                AfterScrollOrPan()
            end
        end
    end

    local function WorldMapScrollFrame_OnMouseWheel(self, delta)
        if not Qol("mapZoom") then return end
        -- Both paths rescale the Ascension-protected map tree (detail frame
        -- here, WorldMapFrame in the ctrl path): blocked actions in combat.
        if InCombatLockdown() then return end

        if IsControlKeyDown() and WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            local newScale = WorldMapFrame:GetScale() + delta * MINIMODE_ZOOM_STEP
            newScale = max(MINIMODE_MIN_ZOOM, min(MINIMODE_MAX_ZOOM, newScale))
            WorldMapFrame:SetScale(newScale)
            WorldMapScreenAnchor.preferredMinimodeScale = newScale
            return
        end

        local oldScrollH = self:GetHorizontalScroll()
        local oldScrollV = self:GetVerticalScroll()

        local cursorX, cursorY = GetCursorPosition()
        cursorX = cursorX / self:GetEffectiveScale()
        cursorY = cursorY / self:GetEffectiveScale()

        local frameX = cursorX - self:GetLeft()
        local frameY = self:GetTop() - cursorY

        local oldScale = WorldMapDetailFrame:GetScale()
        local newScale = oldScale * (1.0 + delta * ZOOM_STEP)
        newScale = max(MIN_ZOOM, min(MAX_ZOOM, newScale))
        -- Already at the zoom limit: skip the full rescale + quest/POI
        -- pass this wheel notch would otherwise trigger.
        if newScale == oldScale then return end

        SetDetailFrameScale(newScale)

        self.maxX = ((WorldMapDetailFrame:GetWidth() * newScale) - self:GetWidth()) / newScale
        self.maxY = ((WorldMapDetailFrame:GetHeight() * newScale) - self:GetHeight()) / newScale
        self.zoomedIn = WorldMapDetailFrame:GetScale() > MIN_ZOOM

        local centerX = oldScrollH + frameX / oldScale
        local centerY = oldScrollV + frameY / oldScale
        local newScrollH = min(max(centerX - frameX / newScale, 0), self.maxX)
        local newScrollV = min(max(centerY - frameY / newScale, 0), self.maxY)

        self:SetHorizontalScroll(newScrollH)
        self:SetVerticalScroll(newScrollV)
        AfterScrollOrPan()
    end

    local function WorldMapButton_OnMouseDown(self, button)
        if not Qol("mapZoom") then return end
        if button == "LeftButton" and WorldMapScrollFrame.zoomedIn then
            WorldMapScrollFrame.panning = true
            local x, y = GetCursorPosition()
            WorldMapScrollFrame.cursorX = x
            WorldMapScrollFrame.cursorY = y
            WorldMapScrollFrame.x = WorldMapScrollFrame:GetHorizontalScroll()
            WorldMapScrollFrame.y = WorldMapScrollFrame:GetVerticalScroll()
            WorldMapScrollFrame.moved = false
        end
    end

    local function WorldMapButton_OnMouseUp(self, button)
        WorldMapScrollFrame.panning = false
        if not WorldMapScrollFrame.moved then
            WorldMapButton_OnClick(WorldMapButton, button)

            -- Reset zoom on plain click — but only pay the full rescale
            -- when actually zoomed in (previously every map click, POI
            -- clicks included, triggered the whole quest/POI pass), and
            -- never in combat (SetDetailFrameScale hits the protected
            -- tree; the zoom visual simply persists until combat ends).
            if Qol("mapZoom") and WorldMapScrollFrame.zoomedIn
                and not InCombatLockdown() then
                SetDetailFrameScale(MIN_ZOOM)
                WorldMapScrollFrame:SetHorizontalScroll(0)
                WorldMapScrollFrame:SetVerticalScroll(0)
                AfterScrollOrPan()
                WorldMapScrollFrame.zoomedIn = false
            end
        else
            AfterScrollOrPan() -- final blob redraw after a throttled pan
        end
        WorldMapScrollFrame.moved = false
    end

    --------------------------------------------------------------------
    -- Class-colored party/raid icons — gated by mapClassIcons
    --------------------------------------------------------------------

    local function CreateClassColorIcon(memberFrame)
        if not memberFrame then return end
        memberFrame.colorIcon = memberFrame:CreateTexture(nil, "ARTWORK")
        memberFrame.colorIcon:SetAllPoints(memberFrame)
        memberFrame.colorIcon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapPlayer")
        memberFrame.colorIcon:Hide()
        -- Start in the "no color" state: a fresh texture is visible and
        -- uncolored (= white), and the dirty-check below early-returns
        -- when nothing changed — without this marker that white texture
        -- stayed on screen instead of the stock dot.
        memberFrame.shownColor = false
    end

    -- This runs per shown group member per frame while the map is open, so
    -- cache the class color per unit token (wiped on roster changes) and
    -- only touch the textures when the shown state actually changes.
    -- FAILURES ARE NOT CACHED: UnitClass returns nil until the server has
    -- sent the member's class (right after login/join), and caching that
    -- pinned every dot white until the next roster change. Ascension's
    -- client extends RAID_CLASS_COLORS with the CoA class tokens (the same
    -- table Details colors its bars from); CUSTOM_CLASS_COLORS is checked
    -- as a fallback for clients/addons that provide it instead.
    local classColorCache = {}
    local rosterWatcher = CreateFrame("Frame")
    rosterWatcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
    rosterWatcher:RegisterEvent("RAID_ROSTER_UPDATE")
    rosterWatcher:SetScript("OnEvent", function() wipe(classColorCache) end)

    local function ColorWorldMapPartyMemberFrame(memberFrame, unit)
        local classColor = unit and classColorCache[unit]
        if classColor == nil and unit then
            local token = select(2, UnitClass(unit))
            local color = token and (RAID_CLASS_COLORS[token]
                or (_G.CUSTOM_CLASS_COLORS and _G.CUSTOM_CLASS_COLORS[token]))
            if color then
                classColorCache[unit] = color
                classColor = color
            end
        end
        local wantColor = (classColor and Qol("mapClassIcons")) and classColor or nil
        if memberFrame.shownColor == wantColor then return end
        memberFrame.shownColor = wantColor
        if wantColor then
            memberFrame.colorIcon:Show()
            memberFrame.icon:Hide()
            memberFrame.colorIcon:SetVertexColor(classColor.r, classColor.g, classColor.b, 1)
        else
            memberFrame.colorIcon:Hide()
            memberFrame.icon:Show()
        end
    end

    --------------------------------------------------------------------
    -- The full per-frame position update: player arrow, party/raid dots,
    -- corpse, death release, battleground flags, vehicles, area highlight.
    -- No stock fallback once replaced, so this always runs regardless of
    -- mapZoom/mapClassIcons — those flags only gate the interactive bits
    -- and icon coloring above.
    --------------------------------------------------------------------

    local function WorldMapButton_OnUpdate(self, elapsed)
        local x, y = GetCursorPosition()
        x = x / self:GetEffectiveScale()
        y = y / self:GetEffectiveScale()

        local centerX, centerY = self:GetCenter()
        local width, height = self:GetWidth(), self:GetHeight()
        local adjustedY = (centerY + (height / 2) - y) / height
        local adjustedX = (x - (centerX - (width / 2))) / width

        local name, fileName, texPercentageX, texPercentageY, textureX, textureY, scrollChildX, scrollChildY
        if self:IsMouseOver() then
            name, fileName, texPercentageX, texPercentageY, textureX, textureY, scrollChildX, scrollChildY =
                UpdateMapHighlight(adjustedX, adjustedY)
        end

        WorldMapFrame.areaName = name
        if not WorldMapFrame.poiHighlight then
            WorldMapFrameAreaLabel:SetText(name)
        end
        if fileName then
            WorldMapHighlight:SetTexCoord(0, texPercentageX, 0, texPercentageY)
            WorldMapHighlight:SetTexture("Interface\\WorldMap\\" .. fileName .. "\\" .. fileName .. "Highlight")
            textureX = textureX * width
            textureY = textureY * height
            scrollChildX = scrollChildX * width
            scrollChildY = -scrollChildY * height
            if textureX > 0 and textureY > 0 then
                WorldMapHighlight:SetWidth(textureX)
                WorldMapHighlight:SetHeight(textureY)
                WorldMapHighlight:SetPoint("TOPLEFT", "WorldMapDetailFrame", "TOPLEFT", scrollChildX, scrollChildY)
                WorldMapHighlight:Show()
            end
        else
            WorldMapHighlight:Hide()
        end

        -- Player
        UpdateWorldMapArrowFrames()
        local playerX, playerY = GetPlayerMapPosition("player")
        if playerX == 0 and playerY == 0 then
            ShowWorldMapArrowFrame(nil)
            WorldMapPing:Hide()
            WorldMapPlayer:Hide()
        else
            playerX = playerX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale() * WORLDMAP_SETTINGS.size
            playerY = -playerY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale() * WORLDMAP_SETTINGS.size
            PositionWorldMapArrowFrame("CENTER", "WorldMapDetailFrame", "TOPLEFT", playerX, playerY)
            ShowWorldMapArrowFrame(nil)

            WorldMapPlayer:SetAllPoints(PlayerArrowFrame)
            WorldMapPlayer.Icon:SetRotation(PlayerArrowFrame:GetFacing())
            local _, mapsterArrowScale = GetMapster("arrowScale")
            WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE * (mapsterArrowScale or 1),
                PLAYER_ARROW_SIZE * (mapsterArrowScale or 1))
            WorldMapPlayer:Show()
        end

        -- Party / raid
        local playerCount = 0
        if GetNumRaidMembers() > 0 then
            for i = 1, MAX_PARTY_MEMBERS do
                _G["WorldMapParty" .. i]:Hide()
            end
            for i = 1, MAX_RAID_MEMBERS do
                local unit = "raid" .. i
                local partyX, partyY = GetPlayerMapPosition(unit)
                local memberFrame = _G["WorldMapRaid" .. (playerCount + 1)]
                if (partyX == 0 and partyY == 0) or UnitIsUnit(unit, "player") then
                    memberFrame:Hide()
                else
                    partyX = partyX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
                    partyY = -partyY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
                    memberFrame:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", partyX, partyY)
                    memberFrame.name = nil
                    memberFrame.unit = unit
                    ColorWorldMapPartyMemberFrame(memberFrame, unit)
                    memberFrame:Show()
                    playerCount = playerCount + 1
                end
            end
        else
            for i = 1, MAX_PARTY_MEMBERS do
                local partyX, partyY = GetPlayerMapPosition("party" .. i)
                local memberFrame = _G["WorldMapParty" .. i]
                if partyX == 0 and partyY == 0 then
                    memberFrame:Hide()
                else
                    partyX = partyX * WorldMapButton:GetWidth() * WorldMapDetailFrame:GetScale()
                    partyY = -partyY * WorldMapButton:GetHeight() * WorldMapDetailFrame:GetScale()
                    memberFrame:SetPoint("CENTER", "WorldMapButton", "TOPLEFT", partyX, partyY)
                    ColorWorldMapPartyMemberFrame(memberFrame, "party" .. i)
                    memberFrame:Show()
                end
            end
        end

        -- Battleground team members (no unit token, positions only)
        local numTeamMembers = GetNumBattlefieldPositions()
        for i = playerCount + 1, MAX_RAID_MEMBERS do
            local partyX, partyY, name2 = GetBattlefieldPosition(i - playerCount)
            local memberFrame = _G["WorldMapRaid" .. i]
            if partyX == 0 and partyY == 0 then
                memberFrame:Hide()
            else
                partyX = partyX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
                partyY = -partyY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
                memberFrame:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", partyX, partyY)
                memberFrame.name = name2
                memberFrame.unit = nil
                memberFrame.shownColor = nil -- keep the dirty-check honest
                memberFrame.colorIcon:Hide()
                memberFrame.icon:Show()
                memberFrame:Show()
            end
        end

        -- Battleground flags
        local numFlags = GetNumBattlefieldFlagPositions()
        for i = 1, numFlags do
            local flagX, flagY, flagToken = GetBattlefieldFlagPosition(i)
            local flagFrame = _G["WorldMapFlag" .. i]
            if flagX == 0 and flagY == 0 then
                flagFrame:Hide()
            else
                flagX = flagX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
                flagY = -flagY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
                flagFrame:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", flagX, flagY)
                _G[flagFrame:GetName() .. "Texture"]:SetTexture("Interface\\WorldStateFrame\\" .. flagToken)
                flagFrame:Show()
            end
        end
        for i = numFlags + 1, NUM_WORLDMAP_FLAGS do
            _G["WorldMapFlag" .. i]:Hide()
        end

        -- Corpse
        local corpseX, corpseY = GetCorpseMapPosition()
        if corpseX == 0 and corpseY == 0 then
            WorldMapCorpse:Hide()
        else
            corpseX = corpseX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
            corpseY = -corpseY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
            WorldMapCorpse:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", corpseX, corpseY)
            WorldMapCorpse:Show()
        end

        -- Death release
        local deathX, deathY = GetDeathReleasePosition()
        if (deathX == 0 and deathY == 0) or UnitIsGhost("player") then
            WorldMapDeathRelease:Hide()
        else
            deathX = deathX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
            deathY = -deathY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
            WorldMapDeathRelease:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", deathX, deathY)
            WorldMapDeathRelease:Show()
        end

        -- Vehicles
        local numVehicles
        if GetCurrentMapContinent() == WORLDMAP_WORLD_ID
            or (GetCurrentMapContinent() ~= -1 and GetCurrentMapZone() == 0) then
            numVehicles = 0
        else
            numVehicles = GetNumBattlefieldVehicles()
        end
        local totalVehicles = #MAP_VEHICLES
        local index = 0
        for i = 1, numVehicles do
            if i > totalVehicles then
                local vehicleName = "WorldMapVehicles" .. i
                MAP_VEHICLES[i] = CreateFrame("FRAME", vehicleName, WorldMapButton, "WorldMapVehicleTemplate")
                MAP_VEHICLES[i].texture = _G[vehicleName .. "Texture"]
            end
            local vehicleX, vehicleY, unitName, isPossessed, vehicleType, orientation, isPlayer, isAlive =
                GetBattlefieldVehicleInfo(i)
            if vehicleX and isAlive and not isPlayer and VEHICLE_TEXTURES[vehicleType] then
                local vFrame = MAP_VEHICLES[i]
                vehicleX = vehicleX * WorldMapDetailFrame:GetWidth() * WorldMapDetailFrame:GetScale()
                vehicleY = -vehicleY * WorldMapDetailFrame:GetHeight() * WorldMapDetailFrame:GetScale()
                vFrame.texture:SetRotation(orientation)
                vFrame.texture:SetTexture(WorldMap_GetVehicleTexture(vehicleType, isPossessed))
                vFrame:SetPoint("CENTER", "WorldMapDetailFrame", "TOPLEFT", vehicleX, vehicleY)
                vFrame:SetWidth(VEHICLE_TEXTURES[vehicleType].width)
                vFrame:SetHeight(VEHICLE_TEXTURES[vehicleType].height)
                vFrame.name = unitName
                vFrame:Show()
                index = i
            else
                MAP_VEHICLES[i]:Hide()
            end
        end
        if index < totalVehicles then
            for i = index + 1, totalVehicles do
                MAP_VEHICLES[i]:Hide()
            end
        end

        if WorldMapScrollFrame.panning then
            local cx, cy = GetCursorPosition()
            WorldMapScrollFrame_OnPan(cx, cy)
        end
    end

    --------------------------------------------------------------------
    -- Combat blob protection (pattern from Mapster). WorldMapBlobFrame's
    -- Show/Hide/SetScale are protected calls in combat, and
    -- SetDetailFrameScale hits SetScale on every zoom step — with the map
    -- usable mid-fight (fullMapWindow releases the keyboard) that's a
    -- blocked-action error. In combat the blob frame is parked offscreen
    -- and those three methods are shadowed with recorders; on leaving
    -- combat the frame is re-attached and the recorded intent replayed.
    -- The other combat-sensitive entry points are gated instead: the
    -- mousewheel zoom paths return early (they rescale the protected
    -- tree), AfterScrollOrPan records a pending blob redraw, and
    -- SetupWorldMapFrame defers itself — both replayed on
    -- PLAYER_REGEN_ENABLED below.
    --------------------------------------------------------------------

    local blobWasVisible, blobNewScale
    local blobHideFunc = function() blobWasVisible = nil end
    local blobShowFunc = function() blobWasVisible = true end
    local blobScaleFunc = function(self, scale) blobNewScale = scale end

    -- Hit translations read live frame geometry, so they must be
    -- recalculated one frame AFTER the restore lands, not during it.
    local blobRestorer = CreateFrame("Frame")
    local function RestoreBlobHits()
        blobRestorer:SetScript("OnUpdate", nil)
        if type(WorldMapBlobFrame_CalculateHitTranslations) == "function" then
            WorldMapBlobFrame_CalculateHitTranslations()
        end
        if WORLDMAP_SETTINGS.selectedQuest
            and not WORLDMAP_SETTINGS.selectedQuest.completed then
            WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, true)
        end
    end

    local combatWatcher = CreateFrame("Frame")
    combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatWatcher:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            blobWasVisible = WorldMapBlobFrame:IsShown()
            blobNewScale = nil
            WorldMapBlobFrame:SetParent(nil)
            WorldMapBlobFrame:ClearAllPoints()
            -- dummy offscreen position so hit calculations don't blow up
            WorldMapBlobFrame:SetPoint("TOP", UIParent, "BOTTOM")
            WorldMapBlobFrame:Hide()
            WorldMapBlobFrame.Hide = blobHideFunc
            WorldMapBlobFrame.Show = blobShowFunc
            WorldMapBlobFrame.SetScale = blobScaleFunc
        else
            WorldMapBlobFrame.Hide = nil
            WorldMapBlobFrame.Show = nil
            WorldMapBlobFrame.SetScale = nil
            WorldMapBlobFrame:SetParent(WorldMapDetailFrame)
            WorldMapBlobFrame:ClearAllPoints()
            WorldMapBlobFrame:SetAllPoints(WorldMapDetailFrame)
            if blobNewScale then
                WorldMapBlobFrame:SetScale(blobNewScale)
                blobNewScale = nil
            end
            WorldMapBlobFrame.xRatio = nil -- force hit recalculations
            if blobWasVisible then
                WorldMapBlobFrame:Show()
                blobRestorer:SetScript("OnUpdate", RestoreBlobHits)
            end
            -- Replay anything deferred during combat (pan/scroll blob
            -- redraws, and the whole layout pass if the map was opened
            -- mid-fight). The blob is re-attached above, so these are
            -- safe to run now.
            if pendingBlobRedraw then AfterScrollOrPan() end
            if setupDeferred then SetupWorldMapFrame() end
        end
    end)

    --------------------------------------------------------------------
    -- One-time setup
    --------------------------------------------------------------------

    WorldMapScrollFrame:SetWidth(1002)
    WorldMapScrollFrame:SetHeight(668)
    WorldMapScrollFrame:SetScrollChild(WorldMapDetailFrame)
    WorldMapScrollFrame:SetScript("OnMouseWheel", WorldMapScrollFrame_OnMouseWheel)
    WorldMapButton:SetScript("OnMouseDown", WorldMapButton_OnMouseDown)
    WorldMapButton:SetScript("OnMouseUp", WorldMapButton_OnMouseUp)
    WorldMapDetailFrame:SetParent(WorldMapScrollFrame)

    WorldMapFrameAreaFrame:SetParent(WorldMapFrame)
    WorldMapFrameAreaFrame:SetFrameLevel(WORLDMAP_POI_FRAMELEVEL)
    WorldMapFrameAreaFrame:SetPoint("TOP", WorldMapScrollFrame, "TOP", 0, -10)

    -- The stock ping ripple doesn't track pan/zoom correctly; drop it.
    WorldMapPing.Show = function() return end
    WorldMapPing:SetModelScale(0)

    -- WorldMapPlayer ships with its own static icon texture that never
    -- rotates — left alone it renders on top of the rotating arrow below
    -- as a second player marker. Strip every pre-existing region (texture
    -- cleared too, in case something re-shows it) so only our arrow draws.
    local playerRegions = { WorldMapPlayer:GetRegions() }
    for _, region in ipairs(playerRegions) do
        if region.SetTexture then region:SetTexture(nil) end
        region:Hide()
    end

    -- Higher-definition player arrow that stays masked correctly on pan
    -- (the default arrow stays visible even when panned off the map).
    WorldMapPlayer.Icon = WorldMapPlayer:CreateTexture(nil, "ARTWORK")
    WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE, PLAYER_ARROW_SIZE)
    WorldMapPlayer.Icon:SetPoint("CENTER", 0, 0)
    WorldMapPlayer.Icon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapArrow")

    hooksecurefunc("WorldMapFrame_SetFullMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_SetQuestMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeDown", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeUp", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_UpdateQuests", ResizeQuestPOIs)
    hooksecurefunc("WorldMapFrame_SetPOIMaxBounds", SetPOIMaxBounds)

    hooksecurefunc("WorldMapQuestShowObjectives_AdjustPosition", function()
        if WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide, "BOTTOMRIGHT",
                -30 - WorldMapQuestShowObjectivesText:GetWidth(), -9)
        else
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide, "BOTTOMRIGHT",
                -15 - WorldMapQuestShowObjectivesText:GetWidth(), 4)
        end
    end)

    WorldMapScreenAnchor:StartMoving()
    WorldMapScreenAnchor:SetPoint("TOPLEFT", 10, -118)
    WorldMapScreenAnchor:StopMovingOrSizing()
    WorldMapScreenAnchor.preferredMinimodeScale = 1 + (0.4 * WorldMapFrame:GetHeight() / WorldFrame:GetHeight())

    WorldMapTitleButton:SetScript("OnDragStart", function()
        WorldMapScreenAnchor:ClearAllPoints()
        WorldMapFrame:ClearAllPoints()
        WorldMapFrame:StartMoving()
    end)
    WorldMapTitleButton:SetScript("OnDragStop", function()
        WorldMapFrame:StopMovingOrSizing()
        WorldMapScreenAnchor:StartMoving()
        WorldMapScreenAnchor:SetPoint("TOPLEFT", WorldMapFrame)
        WorldMapScreenAnchor:StopMovingOrSizing()
    end)

    WorldMapButton:SetScript("OnUpdate", WorldMapButton_OnUpdate)

    local originalOnShow = WorldMapFrame:GetScript("OnShow")
    WorldMapFrame:SetScript("OnShow", function(self)
        if originalOnShow then originalOnShow(self) end
        SetupWorldMapFrame()
    end)

    for i = 1, MAX_RAID_MEMBERS do
        CreateClassColorIcon(_G["WorldMapParty" .. i])
        CreateClassColorIcon(_G["WorldMapRaid" .. i])
    end
end
