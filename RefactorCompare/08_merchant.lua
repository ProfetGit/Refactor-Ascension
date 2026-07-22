local C = RefactorCompareInternal
local CompareItem = C.CompareItem
local SLOTS_FOR_INVTYPE = C.SLOTS_FOR_INVTYPE
local SetArrowAtlas = C.SetArrowAtlas

--------------------------------------------------------------------------
-- Vendor/Merchant item upgrade markers
--------------------------------------------------------------------------

-- Green arrow on a vendor item button when the item is an upgrade —
-- same promise as the bag/quest/roll arrows, same trust rules
-- (live SetMerchantItem/SetBuybackItem scan via CompareItem's src, never approx).

local function GetMerchantArrow(button)
    local arrow = button.refactorMerchantArrow
    if not arrow then
        arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetWidth(14)
        arrow:SetHeight(16)
        arrow:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
        SetArrowAtlas(arrow, "loottoast-arrow-green", 0, 1, 0)
        button.refactorMerchantArrow = arrow
    end
    return arrow
end

local function UpdateMerchantArrowsNow()
    local maxItems = MERCHANT_ITEMS_PER_PAGE or 10
    if not (RefactorCompareDB and RefactorCompareDB.enabled and RefactorCompareDB.bagIcons and MerchantFrame and MerchantFrame:IsShown()) then
        for i = 1, maxItems do
            local button = _G["MerchantItem" .. i .. "ItemButton"]
            if button and button.refactorMerchantArrow then
                button.refactorMerchantArrow:Hide()
            end
        end
        return true
    end

    local complete = true
    local isBuyback = MerchantFrame.selectedTab == 2
    local page = MerchantFrame.page or 1

    for i = 1, maxItems do
        local button = _G["MerchantItem" .. i .. "ItemButton"]
        if button then
            local show = false
            local index = ((page - 1) * maxItems) + i
            local link
            if isBuyback then
                link = GetBuybackItemLink and GetBuybackItemLink(index)
            else
                link = GetMerchantItemLink and GetMerchantItemLink(index)
            end

            if link then
                local name, equipLoc
                local n, _, _, _, _, _, _, _, e = GetItemInfo(link)
                name, equipLoc = n, e
                if not name then
                    complete = false
                elseif equipLoc and SLOTS_FOR_INVTYPE[equipLoc] then
                    local src = isBuyback and { buybackSlot = index } or { merchantSlot = index }
                    local result = CompareItem(link, nil, nil, nil, src)
                    if not result then
                        complete = false
                    elseif not result.approx
                        and (result.status == "upgrade" or result.status == "empty") then
                        show = true
                    end
                end
            end

            if show then
                GetMerchantArrow(button):Show()
            elseif button.refactorMerchantArrow then
                button.refactorMerchantArrow:Hide()
            end
        end
    end

    return complete
end

local merchantRetryFrame = CreateFrame("Frame")
merchantRetryFrame:Hide()
local merchantRetryElapsed, merchantRetriesLeft = 0, 0
merchantRetryFrame:SetScript("OnUpdate", function(self, elapsed)
    merchantRetryElapsed = merchantRetryElapsed + elapsed
    if merchantRetryElapsed < 0.25 then return end
    merchantRetryElapsed = 0
    merchantRetriesLeft = merchantRetriesLeft - 1
    if UpdateMerchantArrowsNow() or merchantRetriesLeft <= 0 then
        self:Hide()
    end
end)

function C.UpdateMerchantArrows()
    if UpdateMerchantArrowsNow() then
        merchantRetryFrame:Hide()
    else
        merchantRetriesLeft = 8
        merchantRetryElapsed = 0
        merchantRetryFrame:Show()
    end
end

if type(MerchantFrame_Update) == "function" then
    hooksecurefunc("MerchantFrame_Update", C.UpdateMerchantArrows)
end
