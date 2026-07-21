-- RefactorMap.lua
-- World map scroll-to-zoom/click-drag-pan and class-colored party/raid map
-- icons, ported directly from the working Magnify-WotLK addon into Refactor.

-- Shim IsAddOnLoaded so Questie, HereBeDragons, and other map icon libraries
-- know a map zoom addon is active and parent their pins to WorldMapButton.
if IsAddOnLoaded then
    local orig_IsAddOnLoaded = IsAddOnLoaded
    function IsAddOnLoaded(name, ...)
        if name == "Magnify-WotLK" or name == "Magnify" then
            return true, true
        end
        return orig_IsAddOnLoaded(name, ...)
    end
end

local function InitRefactorMap()
    if not (WorldMapFrame and WorldMapDetailFrame
        and WorldMapButton and WORLDMAP_SETTINGS and WorldMapBlobFrame
        and WorldMapPOIFrame and WorldMapPlayer and WorldMapPing
        and WorldMapScreenAnchor) then
        return
    end

    if not WorldMapScrollFrame then
        WorldMapScrollFrame = CreateFrame("ScrollFrame", "WorldMapScrollFrame", WorldMapFrame, "FauxScrollFrameTemplate")
        WorldMapScrollFrame:SetSize(1002, 668)
        WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide or WorldMapFrame, "TOPLEFT")
    end

    local MIN_ZOOM = 1.0
    local MAX_ZOOM = 4.0
    local ZOOM_STEP = 0.1

    local MINIMODE_MIN_ZOOM, MINIMODE_MAX_ZOOM = 1.0, 3.0
    local MINIMODE_ZOOM_STEP = 0.1

    local WORLDMAP_POI_MIN_X, WORLDMAP_POI_MIN_Y = 12, -12
    local poiMaxX, poiMaxY

    local PLAYER_ARROW_SIZE = 36

    local function Qol(key)
        return RefactorQoL and RefactorQoL.Get(key)
    end

    --------------------------------------------------------------------
    -- Player + cursor coordinates
    --------------------------------------------------------------------

    local coordsFrame = CreateFrame("Frame", nil, WorldMapFrame)
    coordsFrame:SetFrameLevel((WORLDMAP_POI_FRAMELEVEL or 10) + 20)
    local playerCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerCoords:SetPoint("BOTTOMLEFT", WorldMapFrame, "BOTTOMLEFT", 20, 10)
    local cursorCoords = coordsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cursorCoords:SetPoint("BOTTOMRIGHT", WorldMapFrame, "BOTTOMRIGHT", -20, 10)

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
    -- Map move fade
    --------------------------------------------------------------------

    local FADE_ALPHA = 0.4
    local FADE_SPEED = 6

    local fadeBaseline
    local fadeFrame = CreateFrame("Frame", nil, WorldMapFrame)
    fadeFrame:SetScript("OnUpdate", function(_, elapsed)
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
            return
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
    -- Leatrix Maps stand-down check
    --------------------------------------------------------------------

    if orig_IsAddOnLoaded and orig_IsAddOnLoaded("Leatrix_Maps") then
        return
    end

    --------------------------------------------------------------------
    -- Map Icon Parent Sync Helper
    --------------------------------------------------------------------

    local function SyncMapIconParents()
        if not WorldMapButton or not WorldMapFrame then return end
        local children = { WorldMapFrame:GetChildren() }
        for _, child in ipairs(children) do
            if child ~= WorldMapScrollFrame and child ~= WorldMapDetailFrame and child ~= WorldMapButton and child ~= WorldMapFrameAreaFrame and child ~= coordsFrame and child ~= fadeFrame then
                local name = child:GetName()
                if name and (name:find("Mapster") or name:find("Option") or name:find("DropDown") or name:find("Title") or name:find("Close") or name:find("Track") or name:find("Zoom") or name:find("Guide")) then
                    -- UI control frame on WorldMapFrame: DO NOT REPARENT
                elseif (name and (name:find("Questie") or name:find("HBDPin") or name:find("HBDDot") or name:find("HandyNotes") or name:find("GatherMate") or name:find("TomTomPin"))) or child.data or child.questId then
                    child:SetParent(WorldMapButton)
                end
            end
        end
    end

    --------------------------------------------------------------------
    -- Magnify Map Engine (ported from Magnify-WotLK Main.lua)
    --------------------------------------------------------------------

    local PreviousState = {
        panX = 0,
        panY = 0,
        scale = 1,
        zone = 0
    }

    local function updatePointRelativeTo(frame, newRelativeFrame)
        if not frame then return end
        local currentPoint, _currentRelativeFrame, currentRelativePoint, currentOffsetX, currentOffsetY = frame:GetPoint()
        frame:ClearAllPoints()
        frame:SetPoint(currentPoint, newRelativeFrame, currentRelativePoint, currentOffsetX, currentOffsetY)
    end

    local function GetElvUI()
        if ElvUI and ElvUI[1] then return ElvUI[1] end
        return nil
    end

    local function GetMapster(configName)
        if LibStub and LibStub:GetLibrary("AceAddon-3.0", true) then
            local mapster = LibStub:GetLibrary("AceAddon-3.0"):GetAddon("Mapster", true)
            if not mapster then return nil, nil end
            if mapster.db and mapster.db.profile then return mapster, mapster.db.profile[configName] end
        end
        return nil, nil
    end

    local function SetPOIMaxBounds()
        local mapSize = WORLDMAP_SETTINGS.size or 1
        local detailHeight = WorldMapDetailFrame:GetHeight() or 1000
        local detailWidth = WorldMapDetailFrame:GetWidth() or 1000
        poiMaxY = detailHeight * -mapSize + 12
        poiMaxX = detailWidth * mapSize + 12
    end

    local function resizePOI(poiButton)
        if not poiButton then return end
        local _, _, _, x, y = poiButton:GetPoint()
        local mapster, mapsterPoiScale = GetMapster("poiScale")
        local _, mapsterQuestObjectives = GetMapster("questObjectives")
        if mapster then
            mapster.WorldMapFrame_DisplayQuestPOI = function() end
        end

        local effectivePoiScale = (mapsterPoiScale or 1)
        local posX, posY

        if mapsterQuestObjectives and mapsterQuestObjectives == 1 then
            local questId = poiButton.questId
            if questId then
                local _, normalizedX, normalizedY = QuestPOIGetIconInfo(questId)
                if normalizedX and normalizedY then
                    posX = normalizedX * WorldMapDetailFrame:GetWidth() * WORLDMAP_SETTINGS.size
                    posY = -normalizedY * WorldMapDetailFrame:GetHeight() * WORLDMAP_SETTINGS.size
                end
            end
            if not posX and x ~= nil and y ~= nil then
                posX = x
                posY = y
            end
        elseif x ~= nil and y ~= nil then
            posX = x
            posY = y
        end

        if posX and posY then
            local s = WORLDMAP_SETTINGS.size / WorldMapDetailFrame:GetEffectiveScale() * effectivePoiScale
            posX = posX / s
            posY = posY / s
            poiButton:SetScale(s)
            poiButton:SetPoint("CENTER", poiButton:GetParent(), "TOPLEFT", posX, posY)

            if poiMaxX == nil or poiMaxY == nil then SetPOIMaxBounds() end

            if posY > WORLDMAP_POI_MIN_Y then
                posY = WORLDMAP_POI_MIN_Y
            elseif poiMaxY and posY < poiMaxY then
                posY = poiMaxY
            end
            if posX < WORLDMAP_POI_MIN_X then
                posX = WORLDMAP_POI_MIN_X
            elseif poiMaxX and posX > poiMaxX then
                posX = poiMaxX
            end
        end
    end

    local function PersistMapScrollAndPan()
        PreviousState.panX = WorldMapScrollFrame:GetHorizontalScroll()
        PreviousState.panY = WorldMapScrollFrame:GetVerticalScroll()
        PreviousState.scale = WorldMapDetailFrame:GetScale()
        PreviousState.zone = GetCurrentMapZone()
    end

    local function AfterScrollOrPan()
        PersistMapScrollAndPan()
        if InCombatLockdown() then return end
        if WORLDMAP_SETTINGS.selectedQuest then
            WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, false)
            WorldMapBlobFrame:DrawQuestBlob(WORLDMAP_SETTINGS.selectedQuestId, true)
        end
    end

    local function ResizeQuestPOIs()
        if poiMaxX == nil or poiMaxY == nil then SetPOIMaxBounds() end

        local QUEST_POI_MAX_TYPES = 4
        local POI_TYPE_MAX_BUTTONS = 25

        for i = 1, QUEST_POI_MAX_TYPES do
            for j = 1, POI_TYPE_MAX_BUTTONS do
                local buttonName = "poiWorldMapPOIFrame" .. i .. "_" .. j
                resizePOI(_G[buttonName])
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

    local function SetDetailFrameScale(num)
        WorldMapDetailFrame:SetScale(num)
        SetPOIMaxBounds()

        WorldMapPOIFrame:SetScale(1 / WORLDMAP_SETTINGS.size)
        WorldMapBlobFrame:SetScale(num)

        WorldMapPlayer:SetScale(1 / WorldMapDetailFrame:GetScale())
        WorldMapDeathRelease:SetScale(1 / WorldMapDetailFrame:GetScale())
        if PlayerArrowFrame then PlayerArrowFrame:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        if PlayerArrowEffectFrame then PlayerArrowEffectFrame:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        WorldMapCorpse:SetScale(1 / WorldMapDetailFrame:GetScale())

        local numFlags = GetNumBattlefieldFlagPositions()
        for i = 1, numFlags do
            local flagFrameName = "WorldMapFlag" .. i
            if _G[flagFrameName] then _G[flagFrameName]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        for i = 1, MAX_PARTY_MEMBERS do
            if _G["WorldMapParty" .. i] then _G["WorldMapParty" .. i]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        for i = 1, MAX_RAID_MEMBERS do
            if _G["WorldMapRaid" .. i] then _G["WorldMapRaid" .. i]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        for i = 1, #MAP_VEHICLES do
            if MAP_VEHICLES[i] then MAP_VEHICLES[i]:SetScale(1 / WorldMapDetailFrame:GetScale()) end
        end

        WorldMapFrame_OnEvent(WorldMapFrame, "DISPLAY_SIZE_CHANGED")
        if WorldMapFrame_UpdateQuests() > 0 then
            RedrawSelectedQuest()
        end
    end

    local function ElvUI_SetupWorldMapFrame()
        local elv = GetElvUI()
        if not elv then return end
        local worldMap = elv:GetModule("WorldMap")
        if not worldMap then return end

        if worldMap.coordsHolder and worldMap.coordsHolder.playerCoords then
            updatePointRelativeTo(worldMap.coordsHolder.playerCoords, WorldMapScrollFrame)
        end

        if WorldMapDetailFrame.backdrop then
            WorldMapDetailFrame.backdrop:Hide()
            if WorldMapFrame.backdrop then
                local _, worldMapRelativeFrame = WorldMapFrame.backdrop:GetPoint()
                if worldMapRelativeFrame == WorldMapDetailFrame then
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

    local setupDeferred
    local function SetupWorldMapFrame()
        if InCombatLockdown() then
            setupDeferred = true
            return
        end
        setupDeferred = nil

        local scrollBar = _G["WorldMapScrollFrameScrollBar"]
        if scrollBar then scrollBar:Hide() end
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
            WorldMapScrollFrame:SetPoint("TOPLEFT", WorldMapPositioningGuide or WorldMapFrame, "TOPLEFT", 11, -70.5)
            WorldMapTrackQuest:SetPoint("BOTTOMLEFT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMLEFT", 16, -9)
        end

        WorldMapScrollFrame:SetScale(WORLDMAP_SETTINGS.size)

        SetDetailFrameScale(1)
        WorldMapDetailFrame:SetAllPoints(WorldMapScrollFrame)
        WorldMapScrollFrame:SetHorizontalScroll(0)
        WorldMapScrollFrame:SetVerticalScroll(0)

        if GetCurrentMapZone() == PreviousState.zone and PreviousState.scale and PreviousState.scale > 1 then
            SetDetailFrameScale(PreviousState.scale)
            WorldMapScrollFrame:SetHorizontalScroll(PreviousState.panX)
            WorldMapScrollFrame:SetVerticalScroll(PreviousState.panY)
        end

        WorldMapButton:SetScale(1)
        WorldMapButton:SetAllPoints(WorldMapDetailFrame)
        WorldMapButton:SetParent(WorldMapDetailFrame)

        if not InCombatLockdown() then
            if WorldMapPOIFrame:GetParent() ~= WorldMapDetailFrame then WorldMapPOIFrame:SetParent(WorldMapDetailFrame) end
            if WorldMapBlobFrame:GetParent() ~= WorldMapDetailFrame then
                WorldMapBlobFrame:SetParent(WorldMapDetailFrame)
                WorldMapBlobFrame:ClearAllPoints()
                WorldMapBlobFrame:SetAllPoints(WorldMapDetailFrame)
            end
            if WorldMapPlayer:GetParent() ~= WorldMapDetailFrame then WorldMapPlayer:SetParent(WorldMapDetailFrame) end
            if PlayerArrowFrame and PlayerArrowFrame:GetParent() ~= WorldMapDetailFrame then
                PlayerArrowFrame:SetParent(WorldMapDetailFrame)
            end
            if PlayerArrowEffectFrame and PlayerArrowEffectFrame:GetParent() ~= WorldMapDetailFrame then
                PlayerArrowEffectFrame:SetParent(WorldMapDetailFrame)
            end

            for i = 1, MAX_PARTY_MEMBERS do
                local partyFrame = _G["WorldMapParty" .. i]
                if partyFrame and partyFrame:GetParent() ~= WorldMapDetailFrame then
                    partyFrame:SetParent(WorldMapDetailFrame)
                end
            end
            for i = 1, MAX_RAID_MEMBERS do
                local raidFrame = _G["WorldMapRaid" .. i]
                if raidFrame and raidFrame:GetParent() ~= WorldMapDetailFrame then
                    raidFrame:SetParent(WorldMapDetailFrame)
                end
            end

            SyncMapIconParents()
        end

        updatePointRelativeTo(WorldMapQuestScrollFrame, WorldMapScrollFrame)
        updatePointRelativeTo(WorldMapQuestDetailScrollFrame, WorldMapScrollFrame)

        if GetElvUI() then ElvUI_SetupWorldMapFrame() end
    end

    local function WorldMapScrollFrame_OnPan(cursorX, cursorY)
        local dX = WorldMapScrollFrame.cursorX - cursorX
        local dY = cursorY - WorldMapScrollFrame.cursorY
        local effScale = WorldMapButton:GetEffectiveScale()
        if effScale and effScale > 0 then
            dX = dX / effScale
            dY = dY / effScale
        end
        if abs(dX) >= 1 or abs(dY) >= 1 then
            WorldMapScrollFrame.moved = true

            local x = max(0, dX + WorldMapScrollFrame.x)
            x = min(x, WorldMapScrollFrame.maxX or x)
            WorldMapScrollFrame:SetHorizontalScroll(x)

            local y = max(0, dY + WorldMapScrollFrame.y)
            y = min(y, WorldMapScrollFrame.maxY or y)
            WorldMapScrollFrame:SetVerticalScroll(y)
            AfterScrollOrPan()
        end
    end

    local function ColorWorldMapPartyMemberFrame(partyMemberFrame, unit)
        local classColor = select(2, UnitClass(unit))
        local colorObj = classColor and (RAID_CLASS_COLORS[classColor] or (_G.CUSTOM_CLASS_COLORS and _G.CUSTOM_CLASS_COLORS[classColor]))
        if colorObj and Qol("mapClassIcons") then
            if partyMemberFrame.colorIcon then
                partyMemberFrame.colorIcon:Show()
                partyMemberFrame.colorIcon:SetVertexColor(colorObj.r, colorObj.g, colorObj.b, 1)
            end
            if partyMemberFrame.icon then partyMemberFrame.icon:Hide() end
        else
            if partyMemberFrame.colorIcon then partyMemberFrame.colorIcon:Hide() end
            if partyMemberFrame.icon then partyMemberFrame.icon:Show() end
        end
    end

    local function WorldMapButton_OnUpdate(self, elapsed)
        if not Qol("mapZoom") and not Qol("mapClassIcons") then return end

        if WorldMapScrollFrame.panning then
            WorldMapScrollFrame_OnPan(GetCursorPosition())
        end

        SyncMapIconParents()

        local playerX, playerY = GetPlayerMapPosition("player")
        if not (playerX == 0 and playerY == 0) then
            local _, mapsterArrowScale = GetMapster("arrowScale")
            if WorldMapPlayer.Icon then
                WorldMapPlayer.Icon:SetRotation(PlayerArrowFrame:GetFacing())
                WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE * (mapsterArrowScale or 1), PLAYER_ARROW_SIZE * (mapsterArrowScale or 1))
            end
            local detailWidth = WorldMapDetailFrame:GetWidth()
            local detailHeight = WorldMapDetailFrame:GetHeight()
            local scale = WorldMapDetailFrame:GetScale()
            WorldMapPlayer:ClearAllPoints()
            WorldMapPlayer:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", playerX * detailWidth * scale, -playerY * detailHeight * scale)

            if PlayerArrowFrame then PlayerArrowFrame:Hide() end
            if PlayerArrowEffectFrame then PlayerArrowEffectFrame:Hide() end
            if WorldMapPlayer.Player then WorldMapPlayer.Player:Hide() end
            if WorldMapPlayer.texture then WorldMapPlayer.texture:Hide() end
        end

        local detailWidth = WorldMapDetailFrame:GetWidth()
        local detailHeight = WorldMapDetailFrame:GetHeight()
        local scale = WorldMapDetailFrame:GetScale()

        if WorldMapScrollFrame.zoomedIn then
            if GetNumRaidMembers() == 0 then
                for i = 1, MAX_PARTY_MEMBERS do
                    local unit = "party" .. i
                    if UnitExists(unit) then
                        local icon = _G["WorldMapParty" .. i]
                        if icon then
                            local x, y = GetPlayerMapPosition(unit)
                            if x > 0 and y > 0 then
                                icon:ClearAllPoints()
                                icon:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", x * detailWidth * scale, -y * detailHeight * scale)
                            end
                        end
                    end
                end
            else
                for i = 1, MAX_RAID_MEMBERS do
                    local unit = "raid" .. i
                    if UnitExists(unit) then
                        local icon = _G["WorldMapRaid" .. i]
                        if icon then
                            local x, y = GetPlayerMapPosition(unit)
                            if x > 0 and y > 0 then
                                icon:ClearAllPoints()
                                icon:SetPoint("CENTER", WorldMapDetailFrame, "TOPLEFT", x * detailWidth * scale, -y * detailHeight * scale)
                            end
                        end
                    end
                end
            end
        end

        if Qol("mapClassIcons") then
            if GetNumRaidMembers() == 0 then
                for i = 1, MAX_PARTY_MEMBERS do
                    local partyMemberFrame = _G["WorldMapParty" .. i]
                    if partyMemberFrame and partyMemberFrame:IsVisible() then ColorWorldMapPartyMemberFrame(partyMemberFrame, "party" .. i) end
                end
            else
                for i = 1, MAX_RAID_MEMBERS do
                    local partyMemberFrame = _G["WorldMapRaid" .. i]
                    if partyMemberFrame and partyMemberFrame:IsVisible() and partyMemberFrame.unit then ColorWorldMapPartyMemberFrame(partyMemberFrame, partyMemberFrame.unit) end
                end
            end
        end
    end

    local function WorldMapScrollFrame_OnMouseWheel(self, delta)
        if not Qol("mapZoom") then return end
        if InCombatLockdown() then return end

        if IsControlKeyDown() and WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            local oldScale = WorldMapFrame:GetScale()
            local newScale = oldScale + delta * MINIMODE_ZOOM_STEP
            newScale = max(MINIMODE_MIN_ZOOM, newScale)
            newScale = min(MINIMODE_MAX_ZOOM, newScale)

            WorldMapFrame:SetScale(newScale)
            WorldMapScreenAnchor.preferredMinimodeScale = newScale
            return
        end

        local oldScrollH = WorldMapScrollFrame:GetHorizontalScroll()
        local oldScrollV = WorldMapScrollFrame:GetVerticalScroll()

        local cursorX, cursorY = GetCursorPosition()
        cursorX = cursorX / WorldMapScrollFrame:GetEffectiveScale()
        cursorY = cursorY / WorldMapScrollFrame:GetEffectiveScale()

        local frameX = cursorX - WorldMapScrollFrame:GetLeft()
        local frameY = WorldMapScrollFrame:GetTop() - cursorY

        local oldScale = WorldMapDetailFrame:GetScale()
        local newScale = oldScale * (1.0 + delta * ZOOM_STEP)
        newScale = max(MIN_ZOOM, newScale)
        newScale = min(MAX_ZOOM, newScale)

        SetDetailFrameScale(newScale)

        WorldMapScrollFrame.maxX = ((WorldMapDetailFrame:GetWidth() * newScale) - WorldMapScrollFrame:GetWidth()) / newScale
        WorldMapScrollFrame.maxY = ((WorldMapDetailFrame:GetHeight() * newScale) - WorldMapScrollFrame:GetHeight()) / newScale
        WorldMapScrollFrame.zoomedIn = WorldMapDetailFrame:GetScale() > MIN_ZOOM

        local centerX = oldScrollH + frameX / oldScale
        local centerY = oldScrollV + frameY / oldScale
        local newScrollH = centerX - frameX / newScale
        local newScrollV = centerY - frameY / newScale

        newScrollH = min(newScrollH, WorldMapScrollFrame.maxX)
        newScrollH = max(0, newScrollH)
        newScrollV = min(newScrollV, WorldMapScrollFrame.maxY)
        newScrollV = max(0, newScrollV)

        WorldMapScrollFrame:SetHorizontalScroll(newScrollH)
        WorldMapScrollFrame:SetVerticalScroll(newScrollV)
        AfterScrollOrPan()
    end

    local function WorldMapButton_OnMouseDown(self, button)
        if not Qol("mapZoom") then return end
        if button == 'LeftButton' and WorldMapScrollFrame.zoomedIn then
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

            if Qol("mapZoom") and WorldMapScrollFrame.zoomedIn and not InCombatLockdown() then
                SetDetailFrameScale(MIN_ZOOM)
                WorldMapScrollFrame:SetHorizontalScroll(0)
                WorldMapScrollFrame:SetVerticalScroll(0)
                AfterScrollOrPan()
                WorldMapScrollFrame.zoomedIn = false
            end
        end

        WorldMapScrollFrame.moved = false
    end

    local function CreateClassColorIcon(partyMemberFrame)
        if partyMemberFrame then
            partyMemberFrame.colorIcon = partyMemberFrame:CreateTexture(nil, "ARTWORK")
            partyMemberFrame.colorIcon:SetAllPoints(partyMemberFrame)
            partyMemberFrame.colorIcon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapPlayer")
            if partyMemberFrame.icon then partyMemberFrame.icon:Hide() end
        end
    end

    -- Initial setup
    WorldMapScrollFrame:SetScrollChild(WorldMapDetailFrame)
    WorldMapScrollFrame:SetScript("OnMouseWheel", WorldMapScrollFrame_OnMouseWheel)
    WorldMapButton:SetScript("OnMouseDown", WorldMapButton_OnMouseDown)
    WorldMapButton:SetScript("OnMouseUp", WorldMapButton_OnMouseUp)
    WorldMapDetailFrame:SetParent(WorldMapScrollFrame)

    WorldMapFrameAreaFrame:SetParent(WorldMapFrame)
    WorldMapFrameAreaFrame:SetFrameLevel(WORLDMAP_POI_FRAMELEVEL or 10)
    WorldMapFrameAreaFrame:SetPoint("TOP", WorldMapScrollFrame, "TOP", 0, -10)

    WorldMapPing.Show = function() return end
    WorldMapPing:SetModelScale(0)

    WorldMapPlayer.Icon = WorldMapPlayer:CreateTexture(nil, "ARTWORK")
    WorldMapPlayer.Icon:SetSize(PLAYER_ARROW_SIZE, PLAYER_ARROW_SIZE)
    WorldMapPlayer.Icon:SetPoint("CENTER", 0, 0)
    WorldMapPlayer.Icon:SetTexture("Interface\\AddOns\\Refactor\\textures\\WorldMapArrow")

    if WorldMapPlayer.Player then WorldMapPlayer.Player:Hide() end
    if WorldMapPlayer.texture then WorldMapPlayer.texture:Hide() end

    if PlayerArrowFrame then
        PlayerArrowFrame:Hide()
        PlayerArrowFrame.Show = function() end
    end
    if PlayerArrowEffectFrame then
        PlayerArrowEffectFrame:Hide()
        PlayerArrowEffectFrame.Show = function() end
    end

    hooksecurefunc("WorldMapFrame_SetFullMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_SetQuestMapView", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeDown", SetupWorldMapFrame)
    hooksecurefunc("WorldMap_ToggleSizeUp", SetupWorldMapFrame)
    hooksecurefunc("WorldMapFrame_UpdateQuests", ResizeQuestPOIs)

    hooksecurefunc("WorldMapQuestShowObjectives_AdjustPosition", function()
        if WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMRIGHT", -30 - WorldMapQuestShowObjectivesText:GetWidth(), -9)
        else
            WorldMapQuestShowObjectives:SetPoint("BOTTOMRIGHT", WorldMapPositioningGuide or WorldMapFrame, "BOTTOMRIGHT", -15 - WorldMapQuestShowObjectivesText:GetWidth(), 4)
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

    local original_WorldMapButton_OnUpdate = WorldMapButton:GetScript("OnUpdate")
    WorldMapButton:SetScript("OnUpdate", function(self, elapsed)
        if original_WorldMapButton_OnUpdate then original_WorldMapButton_OnUpdate(self, elapsed) end
        WorldMapButton_OnUpdate(self, elapsed)
    end)

    local original_WorldMapFrame_OnShow = WorldMapFrame:GetScript("OnShow")
    WorldMapFrame:SetScript("OnShow", function(self)
        if original_WorldMapFrame_OnShow then original_WorldMapFrame_OnShow(self) end
        SetupWorldMapFrame()
    end)

    for i = 1, MAX_RAID_MEMBERS do
        CreateClassColorIcon(_G["WorldMapParty" .. i])
        CreateClassColorIcon(_G["WorldMapRaid" .. i])
    end

    local combatWatcher = CreateFrame("Frame")
    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatWatcher:SetScript("OnEvent", function()
        if setupDeferred then SetupWorldMapFrame() end
    end)
end

if orig_IsAddOnLoaded and orig_IsAddOnLoaded("Blizzard_WorldMap") or WorldMapFrame then
    InitRefactorMap()
else
    local loadFrame = CreateFrame("Frame")
    loadFrame:RegisterEvent("ADDON_LOADED")
    loadFrame:SetScript("OnEvent", function(self, event, addonName)
        if addonName == "Blizzard_WorldMap" or WorldMapFrame then
            self:UnregisterEvent("ADDON_LOADED")
            InitRefactorMap()
        end
    end)
end
