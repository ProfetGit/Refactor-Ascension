--------------------------------------------------------------------------
-- Refactor: world map fullscreen-as-movable-window
--
-- Everything on the fullscreen map (title, dropdowns, map, quest list and
-- detail/reward panes) is anchored inside WorldMapPositioningGuide, a
-- 1024x768 box centered in WorldMapFrame — the frame itself is just a
-- screen-covering shell: SetParent(nil) + SetAllPoints + EnableKeyboard
-- (that keyboard grab is why you can't move with WASD) + the BlackoutWorld
-- backdrop. Stock code already ships the counter-recipe in the advanced
-- windowed mode (WorldMapFrame_SetMiniMode): UIPanel area "center",
-- allowOtherPanels, SetMovable, own anchor. This applies that same
-- treatment to fullscreen mode: shrink the shell to the 1024x768 content
-- box, scale it down, hide the blackout, release the keyboard, and drag
-- via the title strip (mousewheel there resizes). While the flag is on
-- this window is the ONLY map mode: the size-down button is hidden and
-- anything that still lands in mini mode (the persisted miniWorldMap CVar
-- at login) is sized straight back up.
--
-- This requires core.lua's global Qol() to already exist: the do-block
-- below calls Apply() immediately at load time (not deferred to an event),
-- so this file must load after core.lua in Refactor.toc.
--------------------------------------------------------------------------

do
    if WorldMapFrame and BlackoutWorld and WorldMapPositioningGuide
        and WORLDMAP_SETTINGS and WORLDMAP_WINDOWED_SIZE then

        local FULLMAP_W, FULLMAP_H = 1024, 768 -- WorldMapPositioningGuide box
        -- Symmetric around DEFAULT_SCALE (0.85) so the "1.00" mark sits at
        -- the exact center of the slider track: 0.85 - 0.5 == 1.2 - 0.85.
        local MIN_SCALE, MAX_SCALE = 0.5, 1.2
        local DEFAULT_SCALE = 0.85 -- most players land here; UI shows this as "1.0"

        -- Position/scale live outside qol (RefactorQoL.Set coerces values
        -- to booleans). Lazily created: saved variables don't exist yet
        -- when this file loads.
        local function FMDB()
            if type(RefactorCompareDB) ~= "table" then return nil end
            if type(RefactorCompareDB.fullmap) ~= "table" then
                RefactorCompareDB.fullmap = {}
            end
            return RefactorCompareDB.fullmap
        end

        -- Map-owning addons (issue #10): Leatrix Maps and Mapster force the
        -- windowed map (miniWorldMap CVar, panel management disabled) and
        -- remodel the frame tree around it; ElvUI's smaller world map
        -- reparents the frame and noops WorldMapFrame.SetParent outright.
        -- This tweak used to fight back (clear the CVar + ToggleSizeUp on
        -- every OnShow), which broke their layouts and ran a full mode
        -- switch mid-OnShow on a remodeled protected frame tree. If any of
        -- them owns the map, stand down completely — checked at use time,
        -- since ElvUI's config tables only exist after its own init.
        local function MapOwnedElsewhere()
            if IsAddOnLoaded("Leatrix_Maps") then return "Leatrix Maps" end
            if IsAddOnLoaded("Mapster") then return "Mapster" end
            if IsAddOnLoaded("ElvUI") and type(ElvUI) == "table" then
                local E = ElvUI[1]
                local wm = E and E.private and E.private.worldmap
                local gen = E and E.global and E.global.general
                if wm and wm.enable and gen and gen.smallerWorldMap then
                    return "ElvUI (smaller world map)"
                end
            end
            return nil
        end

        local function Windowized()
            return Qol("fullMapWindow")
                and not MapOwnedElsewhere()
                and WORLDMAP_SETTINGS.size ~= WORLDMAP_WINDOWED_SIZE
        end

        -- SetPoint offsets are in the frame's own (scaled) coordinates, so
        -- the saved UIParent-space center offset is divided back out.
        local function ApplyPosition()
            local db = FMDB()
            local s = db and db.scale or DEFAULT_SCALE
            local x = db and db.x or 0
            local y = db and db.y or 0
            WorldMapFrame:ClearAllPoints()
            WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", x / s, y / s)
        end

        local function SavePosition()
            local db = FMDB()
            if not db then return end
            local s = WorldMapFrame:GetScale()
            local fx, fy = WorldMapFrame:GetCenter()
            local ux, uy = UIParent:GetCenter()
            if fx and ux then
                db.x = fx * s - ux
                db.y = fy * s - uy
            end
        end

        -- The quest blob VISUAL is engine-drawn at screen coordinates
        -- captured by DrawQuestBlob — moving or rescaling the window leaves
        -- it painted at the old spot until the next draw. Undraw before a
        -- drag, redraw after. Skipped in combat: RefactorMap's blob
        -- protection has the frame parked offscreen then, and redraws it on
        -- leaving combat.
        local function DrawSelectedBlob(show)
            local sel = WORLDMAP_SETTINGS and WORLDMAP_SETTINGS.selectedQuest
            if not (sel and WorldMapBlobFrame and WorldMapBlobFrame.DrawQuestBlob)
                or InCombatLockdown() then
                return
            end
            local id = WORLDMAP_SETTINGS.selectedQuestId or sel.questId
            if not id then return end
            WorldMapBlobFrame:DrawQuestBlob(id, false)
            if show and not sel.completed then
                WorldMapBlobFrame:DrawQuestBlob(id, true)
            end
        end

        -- Quest blob mouseover hit-testing caches screen translations;
        -- invalidate after any move or rescale (stock does the same on its
        -- own drags and mode switches), then repaint the blob itself at the
        -- window's new position.
        local function RefreshBlob()
            if WorldMapBlobFrame then WorldMapBlobFrame.xRatio = nil end
            if type(WorldMapBlobFrame_CalculateHitTranslations) == "function"
                and WorldMapFrame:IsShown() then
                WorldMapBlobFrame_CalculateHitTranslations()
                DrawSelectedBlob(true)
            end
        end

        -- The panel manager reads the UIPanelLayout-* attributes only once
        -- "UIPanelLayout-defined" is set — and setting it is the manager's
        -- own job: on the FIRST ShowUIPanel it copies the stock
        -- UIPanelWindows["WorldMapFrame"] table (area "full") over the
        -- attributes, clobbering any attribute written earlier. A "full"
        -- panel hides UIParent, which is why the first map-open after a
        -- load blanked the whole UI. Stock's advanced windowed mode has
        -- the same problem and ships the fix (WorldMapFrame_SetMiniMode):
        -- before "defined", mutate the table; after, write the attributes.
        local function SetPanelSlot(area, allow)
            if not WorldMapFrame:GetAttribute("UIPanelLayout-defined") then
                local w = UIPanelWindows and UIPanelWindows["WorldMapFrame"]
                if w then
                    w.area = area
                    w.allowOtherPanels = allow
                end
            else
                WorldMapFrame:SetAttribute("UIPanelLayout-area", area)
                WorldMapFrame:SetAttribute("UIPanelLayout-allowOtherPanels", allow)
            end
        end

        -- Drag/resize handle: the title strip above the dropdown row. The
        -- right edge stays clear of the close / size-down buttons.
        local drag = CreateFrame("Frame", nil, WorldMapFrame)
        drag:SetPoint("TOPLEFT", WorldMapPositioningGuide, "TOPLEFT", 0, 0)
        drag:SetPoint("TOPRIGHT", WorldMapPositioningGuide, "TOPRIGHT", -120, 0)
        drag:SetHeight(30)
        drag:EnableMouse(true)
        drag:EnableMouseWheel(true)
        drag:Hide()

        -- Ascension protects the entire WorldMapFrame tree: any addon touch
        -- (SetParent/SetPoint/SetScale/...) during combat is blocked and
        -- blamed on this addon. Skip in combat, redo when combat ends.
        local combatWatcher = CreateFrame("Frame")

        local function Apply()
            if MapOwnedElsewhere() then return end
            if InCombatLockdown() then
                combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
                return
            end
            if Windowized() then
                local db = FMDB()
                local s = db and db.scale or DEFAULT_SCALE
                WorldMapFrame:SetParent(UIParent)
                WorldMapFrame:SetWidth(FULLMAP_W)
                WorldMapFrame:SetHeight(FULLMAP_H)
                WorldMapFrame:SetScale(s)
                ApplyPosition()
                WorldMapFrame:SetMovable(true)
                WorldMapFrame:EnableKeyboard(false) -- WASD stays live
                -- Same panel-slot switch stock's advanced windowed mode
                -- uses: managed as a centered panel that tolerates others,
                -- instead of the UIParent-hiding "full" slot.
                SetPanelSlot("center", true)
                BlackoutWorld:Hide()
                -- The window IS the only mode while the flag is on: the
                -- size-down button is hidden so the mini map is
                -- unreachable (ToggleSizeUp re-shows it every switch).
                if WorldMapFrameSizeDownButton then
                    WorldMapFrameSizeDownButton:Hide()
                end
                drag:Show()
                RefreshBlob()
            elseif WORLDMAP_SETTINGS.size == WORLDMAP_WINDOWED_SIZE then
                drag:Hide()
                if Qol("fullMapWindow") then
                    -- Something still landed in mini mode (the persisted
                    -- miniWorldMap CVar at login, or the flag was turned
                    -- on while the mini map was active): clear the CVar
                    -- and size back up — that call re-enters Apply through
                    -- its hook and windowizes.
                    SetCVar("miniWorldMap", 0)
                    if type(WorldMap_ToggleSizeUp) == "function" then
                        WorldMap_ToggleSizeUp()
                    end
                end
            else
                -- Flag turned off while fullscreen: faithfully redo the
                -- shell bits of WorldMap_ToggleSizeUp.
                drag:Hide()
                WorldMapFrame:SetParent(nil)
                WorldMapFrame:ClearAllPoints()
                WorldMapFrame:SetAllPoints()
                WorldMapFrame:SetScale(1)
                if type(SetupFullscreenScale) == "function"
                    and WorldMapFrame:IsShown() then
                    SetupFullscreenScale(WorldMapFrame)
                end
                WorldMapFrame:SetMovable(false)
                WorldMapFrame:EnableKeyboard(true)
                SetPanelSlot("full", false)
                BlackoutWorld:Show()
                if WorldMapFrameSizeDownButton then
                    WorldMapFrameSizeDownButton:Show()
                end
                RefreshBlob()
            end
        end
        -- Global (not local): core.lua's RefactorQoL.Set re-applies the
        -- flag through this while the map is open.
        ApplyFullMapWindow = Apply

        combatWatcher:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            Apply()
        end)

        drag:SetScript("OnMouseDown", function(self, button)
            if button ~= "LeftButton" or not Windowized() then return end
            DrawSelectedBlob(false) -- don't let the blob trail behind the drag
            WorldMapFrame:StartMoving()
        end)
        drag:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" or not Windowized() then return end
            WorldMapFrame:StopMovingOrSizing()
            SavePosition()
            ApplyPosition() -- normalize back to the saved CENTER anchor
            RefreshBlob()
        end)
        -- Shared by the mousewheel handler and the settings-window field
        -- (RefactorUI): clamp, keep the window centered where it is, and
        -- re-scale in place. A no-op scale write while not windowized still
        -- saves so the value takes effect next time the window opens.
        local function SetScale(s)
            local db = FMDB()
            if not db then return end
            if s < MIN_SCALE then s = MIN_SCALE end
            if s > MAX_SCALE then s = MAX_SCALE end
            if Windowized() then
                SavePosition()
                db.scale = s
                WorldMapFrame:SetScale(s)
                ApplyPosition()
                RefreshBlob()
            else
                db.scale = s
            end
        end

        drag:SetScript("OnMouseWheel", function(self, delta)
            if not Windowized() then return end
            local db = FMDB()
            if not db then return end
            SetScale((db.scale or DEFAULT_SCALE) + delta * 0.05)
        end)

        RefactorFullMapShared = {
            GetScale = function()
                local db = FMDB()
                return (db and db.scale) or DEFAULT_SCALE
            end,
            SetScale = SetScale,
            MIN_SCALE = MIN_SCALE,
            MAX_SCALE = MAX_SCALE,
            -- The real WoW frame scale at the "1.0" mark shown in the UI —
            -- everything there is actual-scale / BASE_SCALE, so the default
            -- reads as a clean 1.0 instead of the raw 0.85.
            BASE_SCALE = DEFAULT_SCALE,
            -- Non-nil = another addon owns the world map and this tweak is
            -- standing down; returns that addon's display name.
            Conflict = MapOwnedElsewhere,
        }

        -- ToggleSizeUp rebuilds the fullscreen shell (and re-shows the
        -- blackout) on every size switch; OnShow covers plain opens plus
        -- the stock SetupFullscreenScale that runs just before this hook;
        -- ToggleSizeDown needs the scale cleanup above.
        hooksecurefunc("WorldMap_ToggleSizeUp", Apply)
        hooksecurefunc("WorldMap_ToggleSizeDown", Apply)
        WorldMapFrame:HookScript("OnShow", Apply)

        -- The panel slot must be right BEFORE the first ShowUIPanel, not
        -- fixed up during it (OnShow is too late — a "full" open has
        -- already hidden UIParent by then). Apply now with default flags,
        -- and again at PLAYER_ENTERING_WORLD once the saved flag is
        -- readable; the map can't be opened before that fires.
        Apply()
        local loader = CreateFrame("Frame")
        loader:RegisterEvent("PLAYER_ENTERING_WORLD")
        loader:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            local owner = MapOwnedElsewhere()
            if owner and Qol("fullMapWindow") then
                DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r "
                    .. owner .. " is managing the world map, so the"
                    .. " movable-map tweak is standing down (it changes"
                    .. " nothing while that addon is enabled).")
            end
            Apply()
            -- Old versions persisted miniWorldMap=0 while forcing the map
            -- fullscreen even against map-owning addons. That session then
            -- starts fullscreen although the owner runs the map windowed —
            -- and Leatrix's zoom rubberbands there: every quest update
            -- bounces the fullscreen map through the quest-list relayout,
            -- whose SetupWorldMapFrame hook resets the zoom. Once the
            -- owner's own login handler has restored the CVar (hence the
            -- delay), hand the mode back too. Uses the stock toggle from
            -- the same place stock calls it (login, map closed).
            if owner then
                local t = 0
                self:SetScript("OnUpdate", function(self, elapsed)
                    t = t + elapsed
                    if t < 1 then return end
                    self:SetScript("OnUpdate", nil)
                    if not InCombatLockdown()
                        and GetCVarBool("miniWorldMap")
                        and WORLDMAP_SETTINGS.size ~= WORLDMAP_WINDOWED_SIZE
                        and not WorldMapFrame:IsShown()
                        and type(WorldMap_ToggleSizeDown) == "function" then
                        WorldMap_ToggleSizeDown()
                    end
                end)
            end
        end)
    end
end
