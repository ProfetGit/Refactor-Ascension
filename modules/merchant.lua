-- Refactor: merchant automation
-- Auto-repair and auto-sell trash, both off by default. Everything runs on
-- MERCHANT_SHOW; Shift held at that moment skips both, matching the
-- loot/quest "Shift = manual" convention.

local function MoneyString(copper)
    -- GetCoinTextureString exists in this era's FrameXML; guard anyway.
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

local function AutoRepair()
    if not CanMerchantRepair or not CanMerchantRepair() then return end
    local cost = GetRepairAllCost()
    if not cost or cost <= 0 then return end
    -- RepairAllItems fails silently when the player can't afford it;
    -- without this check the summary line claimed a repair that never
    -- happened.
    if GetMoney() < cost then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r not enough money to" ..
            " repair all gear (" .. MoneyString(cost) .. " needed).")
        return
    end
    RepairAllItems() -- no argument: the player's own funds, never the guild bank
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r repaired all gear for " ..
        MoneyString(cost) .. ".")
end

local function AutoSellTrash()
    local total, count = 0, 0
    for b = 0, 4 do
        for s = 1, GetContainerNumSlots(b) do
            local link = GetContainerItemLink(b, s)
            if link then
                -- GetItemInfo reads base-item data, but vendor price isn't
                -- shown by this addon anywhere (Ascension scales it), so a
                -- slightly-off running total is acceptable — the merchant
                -- pays what it pays; this is only a summary line.
                local _, _, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(link)
                if quality == 0 then
                    local _, itemCount = GetContainerItemInfo(b, s)
                    if sellPrice and sellPrice > 0 then
                        total = total + sellPrice * (itemCount or 1)
                        count = count + (itemCount or 1)
                    end
                    -- While the merchant window is open, UseContainerItem
                    -- sells instead of uses. Unsellable grays (quest items)
                    -- simply don't move — no harm done.
                    UseContainerItem(b, s)
                end
            end
        end
    end
    if count > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Refactor:|r sold " .. count ..
            " trash item" .. (count == 1 and "" or "s") .. " for " ..
            MoneyString(total) .. ".")
    end
end

local merchantFrame = CreateFrame("Frame")
merchantFrame:RegisterEvent("MERCHANT_SHOW")
merchantFrame:SetScript("OnEvent", function()
    -- Read at use time so toggling mid-session takes effect immediately,
    -- and neither flag needs the window reopened.
    if IsShiftKeyDown() then return end
    if Qol("autoRepair") then AutoRepair() end
    if Qol("autoSellTrash") then AutoSellTrash() end
end)
