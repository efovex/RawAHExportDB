local ADDON_NAME = ...
local FRAME = CreateFrame("Frame")

RAW_AH_EXPORT_DB = RAW_AH_EXPORT_DB or {}

local TRACKED_ITEMS = {
  [13446] = { label = "Major Healing Potion", category = "consumable" },
  [13444] = { label = "Major Mana Potion", category = "consumable" },
  [3825] = { label = "Elixir of Fortitude", category = "consumable" },
}

local Exporter = {
  waitingForReplicate = false,
  pendingContinuables = 0,
  currentScan = nil,
  requestedAt = nil,
}

local function Debug(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RawAHExport|r: " .. tostring(msg))
end

local function GetRealmKey()
  local realm = GetRealmName() or "UnknownRealm"
  local faction = UnitFactionGroup("player") or "Neutral"
  return realm .. "-" .. faction
end

local function EnsureDB()
  RAW_AH_EXPORT_DB = RAW_AH_EXPORT_DB or {}
  RAW_AH_EXPORT_DB.version = 1
  RAW_AH_EXPORT_DB.scans = RAW_AH_EXPORT_DB.scans or {}
  RAW_AH_EXPORT_DB.meta = RAW_AH_EXPORT_DB.meta or {}
end

local function IsTrackedItem(itemID)
  return itemID ~= nil and TRACKED_ITEMS[itemID] ~= nil
end

local function CountTrackedItems()
  local count = 0
  for _ in pairs(TRACKED_ITEMS) do
    count = count + 1
  end
  return count
end

local function NewScanContainer()
  local now = time()
  local realmKey = GetRealmKey()

  return {
    scannedAtEpoch = now,
    scannedAtText = date("!%Y-%m-%dT%H:%M:%SZ", now),
    realmKey = realmKey,
    realmName = GetRealmName(),
    faction = UnitFactionGroup("player"),
    player = UnitName("player"),
    requestedAt = Exporter.requestedAt,
    completed = false,
    trackedItemCount = CountTrackedItems(),
    filteredRows = {},
    filteredRowCount = 0,
    itemSummary = {},
    itemSummaryCount = 0,
    topUntracked = {},
  }
end

local function ReadAuctionRow(index)
  local name,
    texture,
    count,
    qualityID,
    usable,
    level,
    levelType,
    minBid,
    minIncrement,
    buyoutPrice,
    bidAmount,
    highBidder,
    bidderFullName,
    owner,
    ownerFullName,
    saleStatus,
    itemID,
    hasAllInfo = C_AuctionHouse.GetReplicateItemInfo(index)

  local timeLeft = nil
  if C_AuctionHouse.GetReplicateItemTimeLeft then
    timeLeft = C_AuctionHouse.GetReplicateItemTimeLeft(index)
  end

  local petSpeciesID, petDisplayID = nil, nil
  if C_AuctionHouse.GetReplicateItemBattlePetInfo then
    petSpeciesID, petDisplayID = C_AuctionHouse.GetReplicateItemBattlePetInfo(index)
  end

  return {
    index = index,
    itemID = itemID,
    name = name,
    texture = texture,
    count = count,
    qualityID = qualityID,
    usable = usable,
    level = level,
    levelType = levelType,
    minBid = minBid,
    minIncrement = minIncrement,
    buyoutPrice = buyoutPrice,
    bidAmount = bidAmount,
    highBidder = highBidder,
    bidderFullName = bidderFullName,
    owner = owner,
    ownerFullName = ownerFullName,
    saleStatus = saleStatus,
    hasAllInfo = hasAllInfo,
    timeLeft = timeLeft,
    petSpeciesID = petSpeciesID,
    petDisplayID = petDisplayID,
  }
end

local function UpdateItemSummary(scan, row)
  if not row or not row.itemID then
    return
  end

  local summary = scan.itemSummary[row.itemID]
  if not summary then
    summary = {
      itemID = row.itemID,
      name = row.name,
      auctionCount = 0,
      totalQuantity = 0,
      minBuyout = nil,
      maxBuyout = nil,
      seenWithBuyoutCount = 0,
      isTracked = IsTrackedItem(row.itemID),
    }
    scan.itemSummary[row.itemID] = summary
  end

  if row.name and not summary.name then
    summary.name = row.name
  end

  summary.auctionCount = summary.auctionCount + 1
  summary.totalQuantity = summary.totalQuantity + (row.count or 0)

  if row.buyoutPrice and row.buyoutPrice > 0 then
    summary.seenWithBuyoutCount = summary.seenWithBuyoutCount + 1

    if not summary.minBuyout or row.buyoutPrice < summary.minBuyout then
      summary.minBuyout = row.buyoutPrice
    end

    if not summary.maxBuyout or row.buyoutPrice > summary.maxBuyout then
      summary.maxBuyout = row.buyoutPrice
    end
  end
end

local function StoreFilteredRow(scan, row)
  if row and row.itemID and IsTrackedItem(row.itemID) then
    table.insert(scan.filteredRows, row)
  end
end

local function BuildTopUntracked(scan, limit)
  local temp = {}

  for _, summary in pairs(scan.itemSummary) do
    if not summary.isTracked then
      temp[#temp + 1] = {
        itemID = summary.itemID,
        name = summary.name,
        auctionCount = summary.auctionCount,
        totalQuantity = summary.totalQuantity,
        minBuyout = summary.minBuyout,
        maxBuyout = summary.maxBuyout,
        seenWithBuyoutCount = summary.seenWithBuyoutCount,
        isTracked = false,
      }
    end
  end

  table.sort(temp, function(a, b)
    if (a.totalQuantity or 0) == (b.totalQuantity or 0) then
      if (a.auctionCount or 0) == (b.auctionCount or 0) then
        return (a.itemID or 0) < (b.itemID or 0)
      end
      return (a.auctionCount or 0) > (b.auctionCount or 0)
    end
    return (a.totalQuantity or 0) > (b.totalQuantity or 0)
  end)

  scan.topUntracked = {}
  local maxCount = math.min(limit or 100, #temp)
  for i = 1, maxCount do
    scan.topUntracked[i] = temp[i]
  end
end

local function FinalizeScan()
  if not Exporter.currentScan then
    return
  end

  Exporter.currentScan.filteredRowCount = #Exporter.currentScan.filteredRows

  local summaryCount = 0
  for _ in pairs(Exporter.currentScan.itemSummary) do
    summaryCount = summaryCount + 1
  end
  Exporter.currentScan.itemSummaryCount = summaryCount

  BuildTopUntracked(Exporter.currentScan, 100)

  Exporter.currentScan.completed = true

  table.insert(RAW_AH_EXPORT_DB.scans, 1, Exporter.currentScan)
  RAW_AH_EXPORT_DB.meta.lastScanAt = Exporter.currentScan.scannedAtEpoch
  RAW_AH_EXPORT_DB.meta.lastScanRealm = Exporter.currentScan.realmKey
  RAW_AH_EXPORT_DB.meta.lastFilteredRowCount = Exporter.currentScan.filteredRowCount
  RAW_AH_EXPORT_DB.meta.lastItemSummaryCount = Exporter.currentScan.itemSummaryCount
  RAW_AH_EXPORT_DB.meta.lastTrackedItemCount = Exporter.currentScan.trackedItemCount

  Debug(
    "Scan complete. Saved "
      .. Exporter.currentScan.filteredRowCount
      .. " filtered rows across "
      .. Exporter.currentScan.itemSummaryCount
      .. " unique items."
  )

  Exporter.currentScan = nil
  Exporter.waitingForReplicate = false
  Exporter.pendingContinuables = 0
end

local function MaybeFinalizeScan()
  if Exporter.pendingContinuables == 0 then
    FinalizeScan()
  end
end

local function RefreshRowAfterItemLoad(index)
  if not Exporter.currentScan then
    return
  end

  local row = ReadAuctionRow(index)
  UpdateItemSummary(Exporter.currentScan, row)
  StoreFilteredRow(Exporter.currentScan, row)
end

local function QueueItemRefresh(index, itemID)
  if not itemID or not Item or not Item.CreateFromItemID then
    return
  end

  local item = Item:CreateFromItemID(itemID)
  if not item or not item.ContinueOnItemLoad then
    return
  end

  Exporter.pendingContinuables = Exporter.pendingContinuables + 1

  item:ContinueOnItemLoad(function()
    RefreshRowAfterItemLoad(index)
    Exporter.pendingContinuables = Exporter.pendingContinuables - 1
    MaybeFinalizeScan()
  end)
end

local function BuildScanFromReplicate()
  local total = C_AuctionHouse.GetNumReplicateItems() or 0

  Exporter.currentScan = NewScanContainer()
  Exporter.pendingContinuables = 0

  for index = 0, total - 1 do
    local row = ReadAuctionRow(index)

    UpdateItemSummary(Exporter.currentScan, row)
    StoreFilteredRow(Exporter.currentScan, row)

    if row.itemID and row.hasAllInfo == false then
      QueueItemRefresh(index, row.itemID)
    end
  end

  if Exporter.pendingContinuables == 0 then
    FinalizeScan()
  else
    Debug("Replicate received. Waiting for " .. Exporter.pendingContinuables .. " item loads before finalizing.")
  end
end

local function StartFullScan()
  if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
    Debug("Open the Auction House first.")
    return
  end

  if Exporter.waitingForReplicate then
    Debug("A scan is already in progress.")
    return
  end

  EnsureDB()

  Exporter.waitingForReplicate = true
  Exporter.requestedAt = time()

  Debug("Requesting full replicate scan...")
  C_AuctionHouse.ReplicateItems()
end

local function WipeScans()
  EnsureDB()
  RAW_AH_EXPORT_DB.scans = {}
  RAW_AH_EXPORT_DB.meta.lastScanAt = nil
  RAW_AH_EXPORT_DB.meta.lastScanRealm = nil
  RAW_AH_EXPORT_DB.meta.lastFilteredRowCount = nil
  RAW_AH_EXPORT_DB.meta.lastItemSummaryCount = nil
  RAW_AH_EXPORT_DB.meta.lastTrackedItemCount = nil
  Debug("Stored scans cleared.")
end

local function PrintStatus()
  EnsureDB()

  local scanCount = #RAW_AH_EXPORT_DB.scans
  local lastScanAt = RAW_AH_EXPORT_DB.meta.lastScanAt

  if lastScanAt then
    Debug(
      "Stored scans: "
        .. scanCount
        .. ". Last scan: "
        .. date("%Y-%m-%d %H:%M:%S", lastScanAt)
        .. ". Last filtered rows: "
        .. tostring(RAW_AH_EXPORT_DB.meta.lastFilteredRowCount or 0)
        .. ". Last unique items: "
        .. tostring(RAW_AH_EXPORT_DB.meta.lastItemSummaryCount or 0)
    )
  else
    Debug("Stored scans: " .. scanCount .. ". No completed scans yet.")
  end

  if Exporter.waitingForReplicate then
    Debug("A scan request is currently in progress.")
  end
end

local function PrintTrackedItems()
  local ids = {}

  for itemID in pairs(TRACKED_ITEMS) do
    ids[#ids + 1] = itemID
  end

  table.sort(ids)

  Debug("Tracked items: " .. #ids)
  for _, itemID in ipairs(ids) do
    local entry = TRACKED_ITEMS[itemID]
    local label = entry and entry.label or "Unknown"
    local category = entry and entry.category or "uncategorized"
    Debug(itemID .. " - " .. label .. " (" .. category .. ")")
  end
end

SLASH_RAWAHEXPORT1 = "/rahexport"
SLASH_RAWAHEXPORT2 = "/rawah"

SlashCmdList["RAWAHEXPORT"] = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")

  if msg == "scan" then
    StartFullScan()
  elseif msg == "status" then
    PrintStatus()
  elseif msg == "tracked" then
    PrintTrackedItems()
  elseif msg == "reset" then
    WipeScans()
  else
    Debug("Commands: /rahexport scan | status | tracked | reset")
  end
end

FRAME:RegisterEvent("ADDON_LOADED")
FRAME:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")

FRAME:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    EnsureDB()
    Debug("Loaded. Use /rahexport scan at the Auction House.")
    return
  end

  if event == "REPLICATE_ITEM_LIST_UPDATE" then
    if not Exporter.waitingForReplicate then
      return
    end

    Debug("Replicate update received. Reading raw auction rows...")
    BuildScanFromReplicate()
  end
end)