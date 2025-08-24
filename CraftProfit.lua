local ADDON_NAME = "AHProfProfit"
local AHPP = CreateFrame("Frame", "AHProfProfit_EventFrame")

------------------------------------------------------------
-- SavedVariables schema
------------------------------------------------------------
AHProfProfitDB = AHProfProfitDB or {
  itemPrices = {},   -- [itemID] = { minBuyout = <copper>, lastSeen = <time()> }
  recipes    = {},   -- [itemID] = { itemID = number, itemLink = string, reagents = { { itemID = number, count = number }, ... } }
}

------------------------------------------------------------
-- Constants / Utils
------------------------------------------------------------
local ITEMS_PER_PAGE = 10         -- UI pagination
local AUCTIONS_PER_PAGE = 50      -- 3.3.5 page size

-- Add helper function for string trimming (Lua 5.1 doesn't have string.trim)
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function Debug(msg)
  -- print("|cff33ccff[AHProfProfit]|r " .. tostring(msg)) -- uncomment for debugging
end

local function ToItemIDFromLink(link)
  if not link then return nil end
  local itemID = link:match("item:(%d+)")
  if itemID then
    local id = tonumber(itemID)
    if id and id > 0 then
      return id
    end
  end
  return nil
end

local function FormatMoney(copper)
  if not copper or copper < 0 then return "-" end
  if copper == 0 then return "0c" end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local result = ""
  if g > 0 then result = result .. g .. "g " end
  if s > 0 then result = result .. s .. "s " end
  if c > 0 or result == "" then result = result .. c .. "c" end
  return result
end

local function SafeItemName(itemID, fallbackLink)
  local name = itemID and (GetItemInfo(itemID)) or nil
  if name then return name end
  return fallbackLink or (itemID and ("item:" .. itemID) or "?")
end

-- by a vendor the price is embedded in the item info table.  The game stores
-- the amount the vendor pays when you sell the item to them (the "sell" price),
-- while the purchase price is typically double that.  We approximate the cost
-- to buy from a vendor as sellPrice * 2 and return nil if the item has no sell
-- price information.
local function GetVendorPrice(itemID)
  if not itemID then return nil end
  local sellPrice = select(11, GetItemInfo(itemID))
  if sellPrice and sellPrice > 0 then
    return sellPrice * 2
  end
  return nil
end

------------------------------------------------------------
-- Auction data storage (historical min unit buyout)
------------------------------------------------------------
local function RecordAuctionPrice(itemLink, buyoutTotal, stackCount)
  if not buyoutTotal or buyoutTotal <= 0 or not stackCount or stackCount <= 0 then 
    return 
  end
  
  local itemID = nil
  if itemLink then
    itemID = ToItemIDFromLink(itemLink)
  end
  
  if not itemID then 
    Debug("Failed to extract itemID from link: " .. (itemLink or "nil"))
    return 
  end
  
  local unitPrice = math.floor(buyoutTotal / stackCount)
  if unitPrice <= 0 then return end
  
  local rec = AHProfProfitDB.itemPrices[itemID]
  local isNew = false

  if not rec or rec.source == "vendor" or unitPrice < (rec.minBuyout or math.huge) then
    AHProfProfitDB.itemPrices[itemID] = {
      minBuyout = unitPrice,
      lastSeen = time(),
      source = "auction"
    }
    isNew = true
    Debug("Recorded auction price for itemID " .. itemID .. ": " .. FormatMoney(unitPrice))
  else
    rec.lastSeen = time()
    Debug("Updated price for itemID " .. itemID .. ": " .. FormatMoney(unitPrice))
  end

  return isNew
end

------------------------------------------------------------
-- Full Auction House scan
------------------------------------------------------------
AHPP.fullScan = {
  running = false,
  page = 0,
  totalPages = 0,
  processedItems = 0
}

function AHPP:StartFullScan()
  if self.fullScan.running then
    print("AHProfProfit: Full scan already in progress.")
    return
  end
  
  if not (AuctionFrame and AuctionFrame:IsShown()) then
    print("AHProfProfit: Open the Auction House first.")
    return
  end
  
  self.fullScan.running = true
  self.fullScan.page = 0
  self.fullScan.totalPages = 0
  self.fullScan.processedItems = 0
  
  print("AHProfProfit: Starting full auction house scan...")
  
  -- Start with a blank search to get all items
  QueryAuctionItems("", nil, nil, 0, false, 0, false, false, nil)
end

function AHPP:StopFullScan()
  if self.fullScan.running then
    self.fullScan.running = false
    print("AHProfProfit: Full auction scan completed. Processed " .. self.fullScan.processedItems .. " auctions.")
    self:RefreshUI()
  end
end

function AHPP:ProcessFullScanPage()
  if not self.fullScan.running then return end
  
  local numBatch, totalAuctions = GetNumAuctionItems("list")
  if not numBatch or numBatch == 0 then
    -- No more items, scan complete
    self:StopFullScan()
    return
  end
  
  -- Calculate total pages if we haven't yet
  if self.fullScan.totalPages == 0 and totalAuctions then
    self.fullScan.totalPages = math.ceil(totalAuctions / AUCTIONS_PER_PAGE)
    print("AHProfProfit: Scanning " .. totalAuctions .. " auctions across " .. self.fullScan.totalPages .. " pages...")
  end
  
  -- Process all auctions on current page
  for i = 1, numBatch do
    local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
    local itemLink = GetAuctionItemLink("list", i)
    
    if itemLink and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
      RecordAuctionPrice(itemLink, buyoutPrice, count)
      self.fullScan.processedItems = self.fullScan.processedItems + 1
    end
  end
  
  -- Move to next page
  self.fullScan.page = self.fullScan.page + 1
  
  if self.fullScan.totalPages > 0 and self.fullScan.page >= self.fullScan.totalPages then
    -- Scan complete
    self:StopFullScan()
  else
    -- Query next page
    print("AHProfProfit: Scanning page " .. (self.fullScan.page + 1) .. "...")
    QueryAuctionItems("", nil, nil, self.fullScan.page, false, 0, false, false, nil)
  end
end

------------------------------------------------------------
-- Targeted Auction scan (only craft results + reagents)
------------------------------------------------------------
AHPP.scan = {
  running = false,
  page = 0,
  total = 0,
  pages = 0,
  queue = {},
  current = nil,
  lastSig = nil,
  repeatCount = 0,
  stats = {
    itemsScanned = 0,
    itemsFound = 0,
    pricesRecorded = 0
  }
}

local function CanSendQuery()
  if CanSendAuctionQuery then
    local ok = CanSendAuctionQuery()
    return ok and true or false
  end
  return true
end

-- Throttle frame to pace QueryAuctionItems calls
local throttle = CreateFrame("Frame")
throttle.accum = 0
throttle.delay = 0
throttle:Hide()

AHPP._pending = false

local function BuildNeededItems()
  local need = {}
  for _, recipe in pairs(AHProfProfitDB.recipes or {}) do
    if recipe.itemID then
      need[recipe.itemID] = need[recipe.itemID] or {}
      need[recipe.itemID].isRecipe = true
    end
    for _, r in ipairs(recipe.reagents or {}) do
      if r.itemID then
        need[r.itemID] = need[r.itemID] or {}
        need[r.itemID].isReagent = true
      end
    end
  end

  local q = {}
  for id, info in pairs(need) do
    local name = GetItemInfo(id)

    if info.isReagent then
      local vendorPrice = GetVendorPrice(id)
      if vendorPrice then
        local rec = AHProfProfitDB.itemPrices[id]
        if not rec or rec.source == "vendor" or vendorPrice < (rec.minBuyout or math.huge) then
          AHProfProfitDB.itemPrices[id] = { minBuyout = vendorPrice, lastSeen = time(), source = "vendor" }
        end
        Debug("Using vendor price for '" .. (name or ("ID:"..id)) .. "'")
      end
    end

    if name then
      Debug("Added to scan queue: '" .. name .. "' (ID: " .. id .. ")")
    else
      Debug("Added to scan queue: ID " .. id .. " (name unknown)")
    end
    table.insert(q, { itemID = id, name = name, page = 0, retries = 0, searchAttempt = 1 })
  end

  table.sort(q, function(a,b) return (a.name or ("item:"..a.itemID)) < (b.name or ("item:"..b.itemID)) end)
  return q
end

function AHPP:StartTargetedScan()
  if self.scan.running or self.fullScan.running then
    print("AHProfProfit: Scan already in progress.")
    return
  end
  if not (AuctionFrame and AuctionFrame:IsShown()) then
    print("AHProfProfit: Open the Auction House first.")
    return
  end
  
  local numRecipes = 0
  for _ in pairs(AHProfProfitDB.recipes) do numRecipes = numRecipes + 1 end
  if numRecipes == 0 then
    print("AHProfProfit: No recipes cached. Open a profession window and click 'Scan Profession' first.")
    return
  end

  self.scan.running = true
  self.scan.queue = BuildNeededItems()
  self.scan.current = nil
  self.scan.page = 0
  self.scan.total = 0
  self.scan.pages = 0
  self.scan.lastSig = nil
  self.scan.repeatCount = 0
  self.scan.stats = { itemsScanned = 0, itemsFound = 0, pricesRecorded = 0 }

  if #self.scan.queue == 0 then
    print("AHProfProfit: Nothing to scan (no mats/crafts found).")
    self:StopTargetedScan()
    return
  end
  
  -- Show what we're about to scan
  print("AHProfProfit: Will scan " .. #self.scan.queue .. " items:")
  for i = 1, math.min(5, #self.scan.queue) do
    local item = self.scan.queue[i]
    print("  " .. (item.name or ("ID:" .. item.itemID)))
  end
  if #self.scan.queue > 5 then
    print("  ... and " .. (#self.scan.queue - 5) .. " more")
  end
  
  self:DequeueAndQuery()
end

function AHPP:StopTargetedScan()
  if self.scan.running then
    self.scan.running = false
    AHPP._pending = false
    throttle:Hide()
    self.scan.current = nil
    wipe(self.scan.queue)
    
    -- Show scan results
    local stats = self.scan.stats
    print("AHProfProfit: Targeted scan completed!")
    print("  Items scanned: " .. stats.itemsScanned)
    print("  Items found: " .. stats.itemsFound .. " (" .. math.floor((stats.itemsFound / math.max(1, stats.itemsScanned)) * 100) .. "%)")
    print("  Prices recorded: " .. stats.pricesRecorded)
    
    self:RefreshUI()
  end
end

function AHPP:DequeueAndQuery()
  if not self.scan.running then return end
  self.scan.current = table.remove(self.scan.queue, 1)
  if not self.scan.current then
    self:StopTargetedScan()
    return
  end
  
  local t = self.scan.current
  self.scan.stats.itemsScanned = self.scan.stats.itemsScanned + 1
  
  if not t.name then
    -- request cache fill
    GetItemInfo(t.itemID)
    t.retries = (t.retries or 0) + 1
    if t.retries > 10 then
      print("AHProfProfit: skipping itemID "..t.itemID.." (no item name available)")
      self:DequeueAndQuery()
      return
    end
    throttle.delay = 0.25
    throttle.accum = 0
    throttle:Show()
    AHPP._pending = false
    return
  end
  
  t.page = 0
  t.searchAttempt = t.searchAttempt or 1
  self.scan.lastSig = nil
  self.scan.repeatCount = 0
  self:QueryCurrentPage()
end

function AHPP:QueryCurrentPage()
  AHPP._pending = true
  throttle.delay = 1.0
  throttle.accum = 0
  throttle:Show()
end

throttle:SetScript("OnUpdate", function(_, elapsed)
  if not AHPP.scan.running then throttle:Hide() return end
  throttle.accum = throttle.accum + elapsed
  if throttle.accum < (throttle.delay or 1.0) then return end

  local t = AHPP.scan.current
  if not t then throttle:Hide() return end

  -- Name resolution delay path
  if not AHPP._pending and not t.name then
    t.name = GetItemInfo(t.itemID)
    if not t.name then
      throttle.accum = 0
      throttle.delay = 0.25
      return
    end
    AHPP:QueryCurrentPage()
    return
  end

  if not AHPP._pending then return end
  if CanSendQuery() then
    AHPP._pending = false
    throttle.accum = 0
    
    -- Try different search strategies based on attempt number
    local searchName = t.name
    local searchStrategy = "original"
    
    if t.searchAttempt == 1 then
      searchName = t.name
      searchStrategy = "original name"
    elseif t.searchAttempt == 2 then
      searchName = string.gsub(t.name, "'", "")
      searchStrategy = "no apostrophe"
    elseif t.searchAttempt == 3 then
      searchName = string.match(t.name, "^(%S+)")
      searchStrategy = "first word"
    elseif t.searchAttempt == 4 then
      local words = {}
      for word in string.gmatch(t.name, "%S+") do
        table.insert(words, word)
      end
      searchName = words[#words] or t.name
      searchStrategy = "last word"
    end
    
    Debug("Querying for: '" .. (searchName or "unknown") .. "' (ID: " .. t.itemID .. ", attempt " .. (t.searchAttempt or 1) .. " - " .. searchStrategy .. ")")
    
    QueryAuctionItems(searchName, nil, nil, t.page or 0, false, nil, false, false, nil)
  end
end)

local function ProcessAuctionListPage_Targeted()
  local t = AHPP.scan.current
  if not t then return end
  local numBatch, total = GetNumAuctionItems("list")
  if not numBatch then return end

  Debug("Processing page for " .. (t.name or "unknown") .. " (ID: " .. t.itemID .. "): " .. numBatch .. " auctions, total: " .. (total or "unknown"))

  local foundMatches = 0
  local checkedItems = {}
  
  for i = 1, numBatch do
    local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
    local link = GetAuctionItemLink("list", i)
    local id = ToItemIDFromLink(link)
    
    -- Debug first few items
    if i <= 3 then
      Debug("  Auction " .. i .. ": '" .. (name or "nil") .. "' ID:" .. (id or "nil") .. " Buyout:" .. (buyoutPrice or "nil"))
    end
    
    -- Store unique item names for debugging
    if name and not checkedItems[name] then
      checkedItems[name] = true
    end
    
    -- Try multiple matching approaches
    local isMatch = false
    local matchReason = ""
    
    if id and id == t.itemID then
      isMatch = true
      matchReason = "exact ID match"
    elseif name and t.name then
      if string.lower(name) == string.lower(t.name) then
        isMatch = true
        matchReason = "exact name match"
        id = t.itemID
      elseif string.lower(name) == string.lower(string.gsub(t.name, "'", "")) then
        isMatch = true
        matchReason = "name match (no apostrophe)"
        id = t.itemID
      elseif string.find(string.lower(name), string.lower(t.name)) then
        isMatch = true
        matchReason = "partial name match"
        id = t.itemID
      end
    end
    
    if isMatch and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
      RecordAuctionPrice(link or ("item:" .. t.itemID), buyoutPrice, count)
      foundMatches = foundMatches + 1
      Debug("  MATCH #" .. foundMatches .. ": " .. matchReason)
    end
  end
  
  -- Show items we found if no matches for debugging
  if foundMatches == 0 and next(checkedItems) then
    Debug("No matches found. Items seen on this page:")
    local count = 0
    for itemName in pairs(checkedItems) do
      if count < 5 then
        Debug("  '" .. itemName .. "'")
        count = count + 1
      end
    end
  end
  
  Debug("Found " .. foundMatches .. " matching auctions for itemID " .. t.itemID)

  -- Watchdog: detect stuck pages
  local firstLink = GetAuctionItemLink("list", 1) or ""
  local sig = string.format("%s|%d|%s", tostring(t.itemID), t.page or 0, firstLink)
  if AHPP.scan.lastSig == sig then
    AHPP.scan.repeatCount = (AHPP.scan.repeatCount or 0) + 1
  else
    AHPP.scan.lastSig = sig
    AHPP.scan.repeatCount = 0
  end

  -- Decide next action
  local nextPage = nil
  local pagesFromTotal = (total and total > 0) and math.ceil(total / AUCTIONS_PER_PAGE) or nil
  if pagesFromTotal and (t.page + 1) < pagesFromTotal then
    nextPage = t.page + 1
  else
    if numBatch == AUCTIONS_PER_PAGE and (t.page or 0) < 4 then
      nextPage = t.page + 1
    end
  end

  if AHPP.scan.repeatCount >= 2 then
    Debug("Watchdog tripped; trying different search strategy")
    nextPage = nil
  end

  if nextPage then
    t.page = nextPage
    AHPP:QueryCurrentPage()
  else
    if foundMatches > 0 then
      AHPP.scan.stats.itemsFound = AHPP.scan.stats.itemsFound + 1
      AHPP.scan.stats.pricesRecorded = AHPP.scan.stats.pricesRecorded + foundMatches
      Debug("SUCCESS: Found " .. foundMatches .. " auctions for " .. (t.name or "unknown"))
      AHPP:DequeueAndQuery()
    else
      if (t.searchAttempt or 1) < 4 then
        Debug("No matches, trying search attempt " .. ((t.searchAttempt or 1) + 1))
        t.searchAttempt = (t.searchAttempt or 1) + 1
        t.page = 0
        AHPP.scan.lastSig = nil
        AHPP.scan.repeatCount = 0
        table.insert(AHPP.scan.queue, 1, t)
        AHPP:DequeueAndQuery()
      else
        Debug("FAILED: All search strategies failed for " .. (t.name or "unknown"))
        AHPP:DequeueAndQuery()
      end
    end
  end
end

------------------------------------------------------------
-- Trade skill scan
------------------------------------------------------------
local function ScanCurrentTradeSkill()
  local num = GetNumTradeSkills()
  if not num or num <= 0 then
    print("AHProfProfit: No trade skill open. Open a profession window and try again.")
    return
  end

  local added = 0
  for i = 1, num do
    local name, type, available, expand = GetTradeSkillInfo(i)
    if type ~= "header" and name then
      local itemLink = GetTradeSkillItemLink(i)
      local itemID = ToItemIDFromLink(itemLink)
      if itemID then
        local reagents = {}
        local rnum = GetTradeSkillNumReagents(i) or 0
        for r = 1, rnum do
          local reagentLink = GetTradeSkillReagentItemLink(i, r)
          local _, _, reagentCount = GetTradeSkillReagentInfo(i, r)
          local reagentID = ToItemIDFromLink(reagentLink)
          if reagentID and reagentCount and reagentCount > 0 then
            table.insert(reagents, { itemID = reagentID, count = reagentCount })
          end
        end
        AHProfProfitDB.recipes[itemID] = {
          itemID = itemID,
          itemLink = itemLink,
          reagents = reagents,
        }
        added = added + 1
        Debug("Added recipe: " .. (name or "unknown"))
      end
    end
  end

  print("AHProfProfit: Scanned " .. added .. " craftable recipes.")
end

------------------------------------------------------------
-- Profit calculations
------------------------------------------------------------
local rowsCache = {}

local function ComputeRecipeRow(recipe)
  local itemID = recipe.itemID
  local name = SafeItemName(itemID, recipe.itemLink)

  local itemRec = AHProfProfitDB.itemPrices[itemID]
  local itemPrice = itemRec and itemRec.minBuyout or nil
  if not itemPrice then
    local vendorPrice = GetVendorPrice(itemID)
    if vendorPrice then
      itemPrice = vendorPrice
      AHProfProfitDB.itemPrices[itemID] = {
        minBuyout = vendorPrice,
        lastSeen = time(),
        source = "vendor"
      }
    end
  end

  local matsCost = 0
  local missing = (itemPrice == nil)
  local hasMissingMats = false

  for _, mat in ipairs(recipe.reagents or {}) do
    local priceRec = AHProfProfitDB.itemPrices[mat.itemID]
    local price = priceRec and priceRec.minBuyout
    if not price then
      local vendorPrice = GetVendorPrice(mat.itemID)
      if vendorPrice then
        price = vendorPrice
        AHProfProfitDB.itemPrices[mat.itemID] = {
          minBuyout = vendorPrice,
          lastSeen = time(),
          source = "vendor"
        }
      end
    end
    if price then
      matsCost = matsCost + (price * (mat.count or 1))
    else
      hasMissingMats = true
    end
  end

  if hasMissingMats then missing = true end

  local profit = nil
  if itemPrice and not hasMissingMats then
    profit = itemPrice - matsCost
  end

  return {
    itemID = itemID,
    name = name,
    itemPrice = itemPrice,
    matsCost = (not hasMissingMats and matsCost > 0) and matsCost or nil,
    profit = profit,
    missing = missing,
  }
end

local function RebuildRows()
  wipe(rowsCache)
  for _, recipe in pairs(AHProfProfitDB.recipes or {}) do
    table.insert(rowsCache, ComputeRecipeRow(recipe))
  end
  table.sort(rowsCache, function(a, b)
    if a.profit and b.profit then
      return a.profit > b.profit
    elseif a.profit and not b.profit then
      return true
    elseif not a.profit and b.profit then
      return false
    else
      return (a.name or "") < (b.name or "")
    end
  end)
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local UI = CreateFrame("Frame", "AHProfProfitFrame", UIParent)
UI:SetSize(760, 450)
UI:SetPoint("CENTER")
UI:SetBackdrop({ 
  bgFile = "Interface/Tooltips/UI-Tooltip-Background", 
  edgeFile = "Interface/DialogFrame/UI-DialogBox-Border", 
  tile = true, 
  tileSize = 16, 
  edgeSize = 16, 
  insets = { left = 3, right = 3, top = 5, bottom = 3 } 
})
UI:SetBackdropColor(0,0,0,0.85)
UI:EnableMouse(true)
UI:SetMovable(true)
UI:RegisterForDrag("LeftButton")
UI:SetScript("OnDragStart", UI.StartMoving)
UI:SetScript("OnDragStop", UI.StopMovingOrSizing)
UI:Hide()

local title = UI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -10)
title:SetText("AHProfProfit — Crafting Profit Calculator")

-- Buttons
local btnScanFull = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnScanFull:SetSize(120, 22)
btnScanFull:SetPoint("TOPLEFT", 14, -36)
btnScanFull:SetText("Scan All AH")
btnScanFull:SetScript("OnClick", function()
  AHPP:StartFullScan()
end)

local btnScanAH = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnScanAH:SetSize(120, 22)
btnScanAH:SetPoint("LEFT", btnScanFull, "RIGHT", 8, 0)
btnScanAH:SetText("Scan Needed")
btnScanAH:SetScript("OnClick", function()
  AHPP:StartTargetedScan()
end)

local btnScanTS = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnScanTS:SetSize(140, 22)
btnScanTS:SetPoint("LEFT", btnScanAH, "RIGHT", 8, 0)
btnScanTS:SetText("Scan Profession")
btnScanTS:SetScript("OnClick", function()
  ScanCurrentTradeSkill()
  RebuildRows()
  UI:UpdatePage()
end)

local btnRefresh = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnRefresh:SetSize(100, 22)
btnRefresh:SetPoint("LEFT", btnScanTS, "RIGHT", 8, 0)
btnRefresh:SetText("Refresh")
btnRefresh:SetScript("OnClick", function()
  RebuildRows()
  UI:UpdatePage()
end)

local btnClear = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnClear:SetSize(80, 22)
btnClear:SetPoint("LEFT", btnRefresh, "RIGHT", 8, 0)
btnClear:SetText("Clear Data")
btnClear:SetScript("OnClick", function()
  AHProfProfitDB.itemPrices = {}
  AHProfProfitDB.recipes = {}
  wipe(rowsCache)
  UI:UpdatePage()
  print("AHProfProfit: All data cleared.")
end)

-- Status text
local statusText = UI:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusText:SetPoint("TOPLEFT", 14, -62)
statusText:SetWidth(720)
statusText:SetJustifyH("LEFT")
statusText:SetText("Ready. Use 'Scan Profession' first, then 'Scan All AH' or 'Scan Needed'.")

-- Headers
local header = CreateFrame("Frame", nil, UI)
header:SetPoint("TOPLEFT", 12, -85)
header:SetSize(736, 20)

local function MakeHeaderLabel(parent, text, width, x)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("LEFT", parent, "LEFT", x, 0)
  fs:SetWidth(width)
  fs:SetJustifyH("LEFT")
  fs:SetText(text)
  return fs
end

local H_NAME = MakeHeaderLabel(header, "Item", 300, 6)
local H_ITEM = MakeHeaderLabel(header, "Item Cost (AH)", 130, 310)
local H_MATS = MakeHeaderLabel(header, "Mats Cost (AH)", 130, 446)
local H_PROF = MakeHeaderLabel(header, "Profit", 130, 582)

-- Rows
local rows = {}
local function MakeRow(i)
  local row = CreateFrame("Button", nil, UI)
  row:SetSize(736, 30)
  row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")

  if i == 1 then
    row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
  else
    row:SetPoint("TOPLEFT", rows[i-1], "BOTTOMLEFT", 0, 0)
  end

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.name:SetPoint("LEFT", row, "LEFT", 6, 0)
  row.name:SetWidth(300)
  row.name:SetJustifyH("LEFT")

  row.item = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.item:SetPoint("LEFT", row, "LEFT", 310, 0)
  row.item:SetWidth(130)
  row.item:SetJustifyH("LEFT")

  row.mats = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.mats:SetPoint("LEFT", row, "LEFT", 446, 0)
  row.mats:SetWidth(130)
  row.mats:SetJustifyH("LEFT")

  row.prof = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.prof:SetPoint("LEFT", row, "LEFT", 582, 0)
  row.prof:SetWidth(130)
  row.prof:SetJustifyH("LEFT")

  return row
end

for i = 1, ITEMS_PER_PAGE do
  rows[i] = MakeRow(i)
end

-- Pagination
UI.page = 1

local btnPrev = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnPrev:SetSize(80, 22)
btnPrev:SetPoint("BOTTOMLEFT", 12, 12)
btnPrev:SetText("< Prev")
btnPrev:SetScript("OnClick", function()
  if UI.page > 1 then
    UI.page = UI.page - 1
    UI:UpdatePage()
  end
end)

local btnNext = CreateFrame("Button", nil, UI, "UIPanelButtonTemplate")
btnNext:SetSize(80, 22)
btnNext:SetPoint("BOTTOMRIGHT", -12, 12)
btnNext:SetText("Next >")
btnNext:SetScript("OnClick", function()
  local maxPage = math.max(1, math.ceil(#rowsCache / ITEMS_PER_PAGE))
  if UI.page < maxPage then
    UI.page = UI.page + 1
    UI:UpdatePage()
  end
end)

local pageLabel = UI:CreateFontString(nil, "OVERLAY", "GameFontNormal")
pageLabel:SetPoint("BOTTOM", 0, 14)
pageLabel:SetText("Page 1/1")

function UI:UpdatePage()
  local maxPage = math.max(1, math.ceil(#rowsCache / ITEMS_PER_PAGE))
  if UI.page > maxPage then UI.page = maxPage end
  pageLabel:SetText(("Page %d/%d (%d recipes)"):format(UI.page, maxPage, #rowsCache))

  local startIndex = (UI.page - 1) * ITEMS_PER_PAGE + 1
  for i = 1, ITEMS_PER_PAGE do
    local row = rows[i]
    local data = rowsCache[startIndex + (i - 1)]
    if data then
      row:Show()
      
      local nameColor = data.missing and "|cffff8888" or "|cffffffff"
      row.name:SetText(nameColor .. (data.name or "Unknown") .. (data.missing and " (missing prices)" or ""))
      
      row.item:SetText(data.itemPrice and FormatMoney(data.itemPrice) or "|cffff8888-")
      row.mats:SetText(data.matsCost and FormatMoney(data.matsCost) or "|cffff8888-")
      
      if data.profit then
        local profitColor = (data.profit >= 0) and "|cff88ff88" or "|cffff8888"
        local profitSign = (data.profit >= 0) and "" or "-"
        row.prof:SetText(profitColor .. profitSign .. FormatMoney(math.abs(data.profit)))
      else
        row.prof:SetText("|cffff8888-")
      end
    else
      row:Hide()
    end
  end
  
  -- Update status
  local numPrices = 0
  for _ in pairs(AHProfProfitDB.itemPrices) do numPrices = numPrices + 1 end
  local numRecipes = 0
  for _ in pairs(AHProfProfitDB.recipes) do numRecipes = numRecipes + 1 end
  local statusMsg = string.format("Recipes: %d | Cached prices: %d", numRecipes, numPrices)
  statusText:SetText(statusMsg)
end

function AHPP:RefreshUI()
  RebuildRows()
  if UI:IsShown() then
    UI:UpdatePage()
  end
end

-- Toggle UI via slash command
SLASH_AHPP1 = "/ahpp"
SlashCmdList["AHPP"] = function(msg)
  if UI:IsShown() then 
    UI:Hide() 
  else 
    UI:Show() 
    RebuildRows()
    UI:UpdatePage() 
  end
end

------------------------------------------------------------
-- Event handling
------------------------------------------------------------
AHPP:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON_NAME then
      AHProfProfitDB.itemPrices = AHProfProfitDB.itemPrices or {}
      AHProfProfitDB.recipes    = AHProfProfitDB.recipes or {}
      Debug("ADDON_LOADED - " .. (name or "unknown"))
    end

  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    if AHPP.fullScan.running then
      AHPP:ProcessFullScanPage()
    elseif AHPP.scan.running then
      ProcessAuctionListPage_Targeted()
      AHPP:RefreshUI()
    end

  elseif event == "TRADE_SKILL_SHOW" then
    ScanCurrentTradeSkill()
    AHPP:RefreshUI()

  elseif event == "AUCTION_HOUSE_CLOSED" then
    AHPP:StopTargetedScan()
    AHPP:StopFullScan()

  elseif event == "GET_ITEM_INFO_RECEIVED" then
    local itemID, success = ...
    if success then
      if AHPP.scan.current and AHPP.scan.current.itemID == itemID and not AHPP.scan.current.name then
        AHPP.scan.current.name = GetItemInfo(itemID)
      end
      for _, e in ipairs(AHPP.scan.queue or {}) do
        if e.itemID == itemID and not e.name then
          e.name = GetItemInfo(itemID)
        end
      end
      if UI:IsShown() then
        AHPP:RefreshUI()
      end
    end
  end
end)

AHPP:RegisterEvent("ADDON_LOADED")
AHPP:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
AHPP:RegisterEvent("GET_ITEM_INFO_RECEIVED")
AHPP:RegisterEvent("TRADE_SKILL_SHOW")
AHPP:RegisterEvent("AUCTION_HOUSE_CLOSED")

------------------------------------------------------------
-- Auction House button
------------------------------------------------------------
local function CreateAuctionButton()
  if not AuctionFrame or UI._auctionButtonCreated then return end
  local btn = CreateFrame("Button", nil, AuctionFrame, "UIPanelButtonTemplate")
  btn:SetSize(100, 22)
  btn:SetPoint("TOPRIGHT", AuctionFrame, "TOPRIGHT", -24, -40)
  btn:SetText("AHProfProfit")
  btn:SetScript("OnClick", function()
    if UI:IsShown() then UI:Hide() else UI:Show() AHPP:RefreshUI() end
  end)
  UI._auctionButtonCreated = true
end

local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:SetScript("OnEvent", function()
  CreateAuctionButton()
end)

------------------------------------------------------------
-- Debug and utility functions
------------------------------------------------------------
function AHPP:AddTestData()
  AHProfProfitDB.itemPrices[2589] = { minBuyout = 500, lastSeen = time() }   -- Linen Cloth
  AHProfProfitDB.itemPrices[2996] = { minBuyout = 1000, lastSeen = time() }  -- Bolt of Linen Cloth
  AHProfProfitDB.itemPrices[2456] = { minBuyout = 2500, lastSeen = time() }  -- Minor Mana Potion
  AHProfProfitDB.itemPrices[785] = { minBuyout = 150, lastSeen = time() }    -- Mageroyal
  AHProfProfitDB.itemPrices[118] = { minBuyout = 25, lastSeen = time() }     -- Minor Healing Potion
  
  print("AHProfProfit: Test data added for common items.")
  AHPP:RefreshUI()
end

function AHPP:DebugItem(itemID)
  if not itemID then
    print("Usage: AHPP:DebugItem(itemID)")
    return
  end
  
  local name = GetItemInfo(itemID)
  print("=== Debug Info for Item ID: " .. itemID .. " ===")
  print("Item Name: " .. (name or "UNKNOWN"))
  
  local priceData = AHProfProfitDB.itemPrices[itemID]
  if priceData then
    print("Price Data: " .. FormatMoney(priceData.minBuyout) .. " (seen " .. (time() - priceData.lastSeen) .. " seconds ago)")
  else
    print("Price Data: NONE")
  end
  
  -- Check if this item is in any recipes
  local foundInRecipes = {}
  for recipeItemID, recipe in pairs(AHProfProfitDB.recipes or {}) do
    if recipe.itemID == itemID then
      table.insert(foundInRecipes, "Crafted item in recipe: " .. SafeItemName(recipeItemID))
    end
    for _, mat in ipairs(recipe.reagents or {}) do
      if mat.itemID == itemID then
        table.insert(foundInRecipes, "Material for: " .. SafeItemName(recipeItemID) .. " (x" .. mat.count .. ")")
      end
    end
  end
  
  if #foundInRecipes > 0 then
    print("Used in recipes:")
    for _, usage in ipairs(foundInRecipes) do
      print("  " .. usage)
    end
  else
    print("Not found in any cached recipes")
  end
  
  print("=== End Debug Info ===")
end

function AHPP:ShowDebugInfo()
  print("=== AHProfProfit Debug Info ===")
  local numRecipes = 0
  for _ in pairs(AHProfProfitDB.recipes) do numRecipes = numRecipes + 1 end
  local numPrices = 0
  for _ in pairs(AHProfProfitDB.itemPrices) do numPrices = numPrices + 1 end
  print("Recipes count: " .. numRecipes)
  print("Price data count: " .. numPrices)
  
  print("\n--- Sample Recipes ---")
  local count = 0
  for itemID, recipe in pairs(AHProfProfitDB.recipes or {}) do
    if count < 3 then
      local name = SafeItemName(itemID, recipe.itemLink)
      print(string.format("Recipe: %s (%d) - %d reagents", name, itemID, #(recipe.reagents or {})))
      count = count + 1
    end
  end
  
  print("\n--- Sample Prices ---")
  count = 0
  for itemID, priceData in pairs(AHProfProfitDB.itemPrices or {}) do
    if count < 5 then
      local name = SafeItemName(itemID)
      print(string.format("Price: %s (%d) = %s", name, itemID, FormatMoney(priceData.minBuyout)))
      count = count + 1
    end
  end
  print("=== End Debug Info ===")
end

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
SLASH_AHPPTEST1 = "/ahpptest"
SlashCmdList["AHPPTEST"] = function()
  AHPP:AddTestData()
end

SLASH_AHPPFIND1 = "/ahppfind"
SlashCmdList["AHPPFIND"] = function(msg)
  local itemName = trim(msg)
  if itemName == "" then
    print("Usage: /ahppfind ItemName")
    print("Example: /ahppfind Elixir of Lion's Strength")
    return
  end
  
  if not (AuctionFrame and AuctionFrame:IsShown()) then
    print("AHProfProfit: Open the Auction House first.")
    return
  end
  
  print("Searching for: '" .. itemName .. "'")
  
  QueryAuctionItems(itemName, nil, nil, 0, false, nil, false, false, nil)
  
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  frame:SetScript("OnEvent", function()
    frame:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
    
    local numBatch, total = GetNumAuctionItems("list")
    print("Search results: " .. (numBatch or 0) .. " auctions found")
    
    if numBatch and numBatch > 0 then
      for i = 1, math.min(5, numBatch) do
        local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice = GetAuctionItemInfo("list", i)
        local link = GetAuctionItemLink("list", i)
        local id = ToItemIDFromLink(link)
        print("  " .. i .. ". '" .. (name or "nil") .. "' ID:" .. (id or "nil") .. " Price:" .. (buyoutPrice and FormatMoney(buyoutPrice) or "nil"))
      end
    end
  end)
end

SLASH_AHPPFAILED1 = "/ahppfailed"
SlashCmdList["AHPPFAILED"] = function()
  print("=== Items with No Price Data ===")
  local needed = {}
  for _, recipe in pairs(AHProfProfitDB.recipes or {}) do
    if recipe.itemID then needed[recipe.itemID] = true end
    for _, r in ipairs(recipe.reagents or {}) do
      if r.itemID then needed[r.itemID] = true end
    end
  end
  
  local missing = {}
  for itemID in pairs(needed) do
    if not AHProfProfitDB.itemPrices[itemID] then
      table.insert(missing, itemID)
    end
  end
  
  table.sort(missing)
  
  if #missing == 0 then
    print("All needed items have price data!")
  else
    print("Missing price data for " .. #missing .. " items:")
    for i = 1, math.min(10, #missing) do
      local itemID = missing[i]
      local name = GetItemInfo(itemID) or ("ID:" .. itemID)
      print("  " .. name)
    end
    if #missing > 10 then
      print("  ... and " .. (#missing - 10) .. " more")
    end
  end
end

SLASH_AHPPDEBUG1 = "/ahppdebug"
SlashCmdList["AHPPDEBUG"] = function()
  AHPP:ShowDebugInfo()
end

------------------------------------------------------------
-- Usage Instructions
------------------------------------------------------------
--[[
USAGE INSTRUCTIONS:

1. Type "/ahpp" to open the main window.

2. Open a profession window (Tailoring, Blacksmithing, etc.) and click 
   "Scan Profession" to gather all your craftable recipes.

3. Open the Auction House and choose one scanning option:
   - "Scan All AH": Scans entire auction house (slow but comprehensive)
   - "Scan Needed": Only scans items from your recipes (faster)

4. Click "Refresh" to update profit calculations after scanning.

5. The table shows:
   - Item: Name of craftable item
   - Item Cost (AH): Lowest buyout price for the item
   - Mats Cost (AH): Total cost of all materials needed
   - Profit: Item Cost minus Materials Cost

6. Items with missing prices are shown in red.

DEBUG COMMANDS:
- "/ahppdebug" - Show data summary
- "/ahpptest" - Add test data
- "/ahppfind ItemName" - Test search for specific item
- "/ahppfailed" - Show items with missing price data

The addon saves all data between sessions via SavedVariables.
--]]