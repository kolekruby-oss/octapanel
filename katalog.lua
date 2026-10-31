--[[
	Katalog (LocalScript)
	Letak: StarterPlayer > StarterPlayerScripts
	Katalog avatar ala marketplace Roblox. Semua jalan di client, jadi cuma kamu yang melihat hasilnya.
	- Cari item (aksesori, rambut, pakaian, wajah, badan, emote). Klik item = coba pakai, klik lagi = lepas.
	- Item yang sedang dipakai avatar (bawaan) juga tampil di daftar "Dipakai" dan bisa dilepas.
	- Tab Badan: warna kulit, ukuran badan, paket badan, kepala dinamis.
	- Tidak ada tombol beli, cuma coba (try).
	- Simpan hasil jadi outfit lalu pakai lagi kapan saja (tersimpan selama sesi game).
	- Tab TEMA: ganti warna UI (gradient dari Workspace["SALON MUSIC BY OCTA"].TEAMS).
	Buka / tutup: tombol "Katalog" di kiri layar atau tombol K.
	Style UI: sama dengan PlayerUtilityPanel (gelap + gradient tema).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local AvatarEditorService = game:GetService("AvatarEditorService")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local TOGGLE_KEY = Enum.KeyCode.K
local MAX_ACCESSORIES = 10
local DEFAULT_THEME = "Merah"
local PANEL_W, PANEL_H = 980, 580

---------------------------------------------------------------------
-- PALET TEMA (sama dengan PlayerUtilityPanel)
---------------------------------------------------------------------
local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local FONT = Enum.Font.MontserratBold
local FONT_REGULAR = Enum.Font.Montserrat

local function teamGradient(c0, c1, c2)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, c0),
		ColorSequenceKeypoint.new(0.38, c1),
		ColorSequenceKeypoint.new(1, c2),
	})
end
local TEAM_FALLBACK = {
	{ name = "Merah", color = teamGradient(rgb(255, 0, 0), rgb(255, 53, 26), rgb(185, 0, 0)) },
	{ name = "Kuning", color = teamGradient(rgb(255, 220, 78), rgb(255, 220, 78), rgb(255, 155, 67)) },
	{ name = "Biru", color = teamGradient(rgb(0, 255, 247), rgb(26, 244, 255), rgb(51, 185, 156)) },
	{ name = "Hijau", color = teamGradient(rgb(0, 221, 0), rgb(64, 185, 50), rgb(39, 104, 32)) },
	{ name = "Merahmudah", color = teamGradient(rgb(255, 116, 218), rgb(226, 118, 203), rgb(182, 106, 169)) },
	{ name = "Birugelap", color = teamGradient(rgb(0, 13, 194), rgb(0, 4, 255), rgb(11, 17, 120)) },
	{ name = "Ungu", color = teamGradient(rgb(145, 35, 255), rgb(153, 28, 255), rgb(105, 58, 185)) },
}

local function lum(c)
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end
local function scale(c, k)
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end
local NEAR_BLACK = rgb(10, 8, 9)
local function dark(base, k)
	return NEAR_BLACK:Lerp(base, k)
end
local function colorKey(c)
	return string.format("%d,%d,%d", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end
local function seqKey(s)
	local parts = {}
	for _, k in ipairs(s.Keypoints) do
		table.insert(parts, string.format("%.3f:%s", k.Time, colorKey(k.Value)))
	end
	return table.concat(parts, "|")
end

local PALETTE_KEYS = {
	"Bg", "Card", "Bar", "Input", "Section", "Line", "Hover", "Stroke", "Border", "Accent", "Placeholder",
	"Muted", "Text", "OffText", "TabText", "OnPrimary", "Selected", "Dark", "CloseHover",
}
local function makePalette(seq)
	local kp = seq.Keypoints
	local c0, c2 = kp[1].Value, kp[#kp].Value
	local c1 = kp[math.min(2, #kp)].Value
	local base = c0:Lerp(c2, 0.5)
	local bright = lum(c1) > 0.6
	local p = {
		Bg = dark(base, 0.09),
		Card = dark(base, 0.05),
		Bar = dark(base, 0.13),
		Input = dark(base, 0.16),
		Section = dark(base, 0.19),
		Line = dark(base, 0.21),
		Hover = dark(base, 0.29),
		Stroke = scale(c2, 0.8),
		Border = scale(c2, 0.8),
		Accent = c1:Lerp(WHITE, 0.25),
		Placeholder = bright and scale(c2, 0.45) or c0:Lerp(WHITE, 0.75),
		Muted = scale(base, 0.75):Lerp(WHITE, 0.55),
		Text = base:Lerp(WHITE, 0.92),
		OffText = base:Lerp(WHITE, 0.65),
		TabText = scale(c2, 0.12),
		OnPrimary = bright and scale(c2, 0.2) or rgb(255, 254, 254),
		Selected = scale(c2, 0.75),
		Dark = c2,
		CloseHover = scale(c2, 0.6),
	}
	-- tiap warna dibuat unik (beda 1-2 angka, tidak kelihatan) supaya bisa dipetakan saat ganti tema
	local used = { ["255,255,255"] = true, ["0,0,0"] = true, ["225,225,225"] = true, ["255,95,95"] = true }
	for _, key in ipairs(PALETTE_KEYS) do
		local c = p[key]
		local r, g, b = math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255)
		local dir = b < 128 and 1 or -1
		local tries = 0
		while used[string.format("%d,%d,%d", r, g, b)] and tries < 60 do
			b += dir
			tries += 1
		end
		p[key] = Color3.fromRGB(r, g, b)
		used[string.format("%d,%d,%d", r, g, b)] = true
	end
	p.Primary = seq
	p.Danger = teamGradient(scale(c0, 0.6), scale(c1, 0.5), scale(c2, 0.45))
	p.Off = teamGradient(dark(base, 0.3), dark(base, 0.26), dark(base, 0.18))
	p.Error = rgb(255, 95, 95)
	return p
end

-- P = palet aktif (isinya diganti saat ganti tema, tabelnya jangan diganti)
local P = makePalette(TEAM_FALLBACK[1].color)

local PRIMARY = { color = P.Primary, text = P.OnPrimary }
local THEMES = {
	Green = PRIMARY,
	Red = { color = P.Danger, text = WHITE },
	Off = { color = P.Off, text = P.OffText },
	Tab = { color = P.Primary, text = P.TabText },
	TabOff = { color = P.Primary, text = P.Accent, transparent = true },
}
local function syncThemes()
	PRIMARY.color, PRIMARY.text = P.Primary, P.OnPrimary
	THEMES.Red.color = P.Danger
	THEMES.Off.color, THEMES.Off.text = P.Off, P.OffText
	THEMES.Tab.color, THEMES.Tab.text = P.Primary, P.TabText
	THEMES.TabOff.color, THEMES.TabOff.text = P.Primary, P.Accent
end

local themeRoots = {}
local themeSkip = {}
local themeListeners = {}
local THEMED_PROPS = { "BackgroundColor3", "TextColor3", "PlaceholderColor3", "ImageColor3", "ScrollBarImageColor3", "Color3" }

local function isSkipped(inst)
	for _, skip in ipairs(themeSkip) do
		if inst == skip or inst:IsDescendantOf(skip) then
			return true
		end
	end
	return false
end

local function applyPalette(newP)
	local colorMap, seqMap = {}, {}
	for key, old in pairs(P) do
		local value = newP[key]
		if typeof(old) == "Color3" then
			colorMap[colorKey(old)] = value
		elseif typeof(old) == "ColorSequence" then
			seqMap[seqKey(old)] = value
		end
	end
	for _, root in ipairs(themeRoots) do
		for _, inst in ipairs(root:GetDescendants()) do
			if not isSkipped(inst) then
				if inst:IsA("UIGradient") then
					local mapped = seqMap[seqKey(inst.Color)]
					if mapped then
						inst.Color = mapped
					end
				elseif inst:IsA("UIStroke") then
					local mapped = colorMap[colorKey(inst.Color)]
					if mapped then
						inst.Color = mapped
					end
				else
					for _, prop in ipairs(THEMED_PROPS) do
						local ok, value = pcall(function()
							return inst[prop]
						end)
						if ok and typeof(value) == "Color3" then
							local mapped = colorMap[colorKey(value)]
							if mapped then
								inst[prop] = mapped
							end
						end
					end
				end
			end
		end
	end
	for key, value in pairs(newP) do
		P[key] = value
	end
	syncThemes()
	for _, listener in ipairs(themeListeners) do
		task.spawn(listener)
	end
end

---------------------------------------------------------------------
-- UI HELPERS
---------------------------------------------------------------------
local function new(className, props)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(parent, color, thickness)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

local function setTheme(refs, theme)
	refs.theme = theme
	refs.gradient.Color = theme.color
	refs.button.BackgroundTransparency = theme.transparent and 1 or 0
	refs.label.TextColor3 = theme.text
end

-- Tombol gradient: rounded, teks tebal (gaya panel)
local function glossyButton(parent, size, theme, text, textSize, extra)
	local props = {
		Size = size,
		BackgroundColor3 = WHITE,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	}
	if extra then
		for key, value in pairs(extra) do
			props[key] = value
		end
	end
	local refs = {}
	refs.button = new("TextButton", props)
	corner(refs.button, 8)
	refs.gradient = new("UIGradient", { Rotation = 90, Parent = refs.button })
	refs.label = new("TextLabel", {
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = text,
		Font = FONT,
		TextSize = textSize,
		TextColor3 = WHITE,
		ZIndex = 2,
		Parent = refs.button,
	})
	refs.button.MouseEnter:Connect(function()
		refs.button.BackgroundColor3 = rgb(225, 225, 225)
	end)
	refs.button.MouseLeave:Connect(function()
		refs.button.BackgroundColor3 = WHITE
	end)
	setTheme(refs, theme)
	return refs
end

---------------------------------------------------------------------
-- DATA KATEGORI
---------------------------------------------------------------------
local AT = Enum.AvatarAssetType
local ACC = Enum.AccessoryType

-- sub kategori: types = AssetType katalog, bundles = BundleType, mode = panel khusus (bukan katalog)
local function S(label, types)
	return { label = label, types = types }
end
local CATEGORIES = {
	{ name = "Aksesori", subs = {
		S("Semua", { AT.Hat, AT.FaceAccessory, AT.NeckAccessory, AT.ShoulderAccessory, AT.FrontAccessory, AT.BackAccessory, AT.WaistAccessory }),
		S("Topi", { AT.Hat }),
		S("Wajah", { AT.FaceAccessory }),
		S("Leher", { AT.NeckAccessory }),
		S("Bahu", { AT.ShoulderAccessory }),
		S("Depan", { AT.FrontAccessory }),
		S("Belakang", { AT.BackAccessory }),
		S("Pinggang", { AT.WaistAccessory }),
	} },
	{ name = "Rambut", subs = {
		S("Rambut", { AT.HairAccessory }),
		S("Alis", { AT.EyebrowAccessory }),
		S("Bulu Mata", { AT.EyelashAccessory }),
	} },
	{ name = "Pakaian", subs = {
		S("Kaos", { AT.TShirt }),
		S("Kemeja", { AT.Shirt }),
		S("Celana", { AT.Pants }),
		S("Kaos Berlapis", { AT.TShirtAccessory }),
		S("Kemeja Berlapis", { AT.ShirtAccessory }),
		S("Celana Berlapis", { AT.PantsAccessory }),
		S("Jaket", { AT.JacketAccessory }),
		S("Sweater", { AT.SweaterAccessory }),
		S("Celana Pendek", { AT.ShortsAccessory }),
		S("Rok", { AT.DressSkirtAccessory }),
		S("Sepatu Kiri", { AT.LeftShoeAccessory }),
		S("Sepatu Kanan", { AT.RightShoeAccessory }),
	} },
	{ name = "Wajah", subs = {
		S("Wajah", { AT.Face }),
	} },
	{ name = "Badan", subs = {
		{ label = "Salin Avatar", mode = "copy" },
		{ label = "Warna Kulit", mode = "skin" },
		{ label = "Ukuran", mode = "scale" },
		{ label = "Paket Badan", bundles = { Enum.BundleType.BodyParts } },
		{ label = "Kepala Dinamis", bundles = { Enum.BundleType.DynamicHead, Enum.BundleType.DynamicHeadAvatar } },
	} },
	{ name = "Animasi", subs = {
		S("Emote", { AT.EmoteAnimation }),
	} },
}

local SORTS = {
	{ "Terlaris", Enum.CatalogSortType.Bestselling },
	{ "Relevansi", Enum.CatalogSortType.Relevance },
	{ "Terbaru", Enum.CatalogSortType.RecentlyCreated },
	{ "Favorit", Enum.CatalogSortType.MostFavorited },
}

-- nama AssetType (string dari hasil katalog) -> cara memakainya
local CLASSIC = { TShirt = "GraphicTShirt", Shirt = "Shirt", Pants = "Pants", Face = "Face" }
local ACCESSORY_TYPE = {
	Hat = ACC.Hat, HairAccessory = ACC.Hair, FaceAccessory = ACC.Face, NeckAccessory = ACC.Neck,
	ShoulderAccessory = ACC.Shoulder, FrontAccessory = ACC.Front, BackAccessory = ACC.Back, WaistAccessory = ACC.Waist,
	TShirtAccessory = ACC.TShirt, ShirtAccessory = ACC.Shirt, PantsAccessory = ACC.Pants, JacketAccessory = ACC.Jacket,
	SweaterAccessory = ACC.Sweater, ShortsAccessory = ACC.Shorts, LeftShoeAccessory = ACC.LeftShoe,
	RightShoeAccessory = ACC.RightShoe, DressSkirtAccessory = ACC.DressSkirt, EyebrowAccessory = ACC.Eyebrow,
	EyelashAccessory = ACC.Eyelash,
}
local LAYERED = {
	TShirtAccessory = true, ShirtAccessory = true, PantsAccessory = true, JacketAccessory = true, SweaterAccessory = true,
	ShortsAccessory = true, LeftShoeAccessory = true, RightShoeAccessory = true, DressSkirtAccessory = true,
}
-- cuma boleh satu per jenis: yang lama (bawaan avatar) diganti
local EXCLUSIVE = { [ACC.Hair] = true, [ACC.Face] = true, [ACC.Eyebrow] = true, [ACC.Eyelash] = true }

-- bagian badan dari paket badan -> properti HumanoidDescription -> bagian R15 di karakter
local BODY_SLOTS = {
	Head = "Head", DynamicHead = "Head", Torso = "Torso", LeftArm = "LeftArm", RightArm = "RightArm",
	LeftLeg = "LeftLeg", RightLeg = "RightLeg",
}
local SLOT_PARTS = {
	Head = { "Head" },
	Torso = { "UpperTorso", "LowerTorso" },
	LeftArm = { "LeftUpperArm", "LeftLowerArm", "LeftHand" },
	RightArm = { "RightUpperArm", "RightLowerArm", "RightHand" },
	LeftLeg = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot" },
	RightLeg = { "RightUpperLeg", "RightLowerLeg", "RightFoot" },
}
local SKIN_PROPS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
local BODYCOLOR_PROPS = { "HeadColor3", "TorsoColor3", "LeftArmColor3", "RightArmColor3", "LeftLegColor3", "RightLegColor3" }
local SKIN_COLORS = {
	rgb(255, 233, 220), rgb(255, 219, 172), rgb(255, 204, 153), rgb(241, 194, 125), rgb(234, 184, 146), rgb(224, 172, 105),
	rgb(204, 142, 105), rgb(198, 134, 66), rgb(166, 119, 74), rgb(141, 85, 36), rgb(124, 92, 70), rgb(105, 64, 40),
	rgb(86, 66, 54), rgb(63, 42, 30), rgb(245, 245, 245), rgb(163, 162, 165), rgb(99, 95, 98), rgb(245, 205, 48),
	rgb(218, 133, 65), rgb(196, 40, 28), rgb(255, 102, 204), rgb(180, 128, 255), rgb(13, 105, 172), rgb(75, 151, 75),
}
-- batas ukuran sesuai pengaturan avatar Roblox
local SCALES = {
	{ label = "Tinggi", prop = "HeightScale", min = 0.9, max = 1.05, step = 0.01 },
	{ label = "Lebar", prop = "WidthScale", min = 0.7, max = 1, step = 0.02, also = "DepthScale" },
	{ label = "Kepala", prop = "HeadScale", min = 0.95, max = 1, step = 0.01 },
	{ label = "Proporsi", prop = "ProportionScale", min = 0, max = 1, step = 0.1 },
	{ label = "Tipe Badan", prop = "BodyTypeScale", min = 0, max = 1, step = 0.1 },
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local worn = {} -- urutan item yang dicoba: { id, name, type, slots? }
local removed = {} -- item bawaan avatar yang dilepas: [key] = true
local originals = {} -- item bawaan avatar: { key, kind, id, slot? }
local body = { skin = nil, scale = nil } -- warna kulit + ukuran yang diubah
local saved = {} -- outfit tersimpan
local baseDesc = nil -- HumanoidDescription avatar asli
local copied = nil -- avatar pemain lain yang disalin: { id, name, desc }
local stopCopy, refreshPlayerList -- diisi di bawah
local keyword, catIndex, subIndex, sortIndex = "", 1, 1, 1
local pages, loadingMore = nil, false
local searchToken = 0
local previewToken = 0
local previewModel = nil
local previewYaw = 0
local cellRefs = {} -- [id] = { stroke, badge }
local playingEmote = nil
local nameCache = {}
local baseModel = nil -- model avatar asli (pose diam), jadi acuan posisi bagian badan

local function getCharacter()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return char, hum
end

local function rigType()
	local _, hum = getCharacter()
	return hum and hum.RigType or Enum.HumanoidRigType.R15
end

local function isWorn(id)
	for _, it in ipairs(worn) do
		if it.id == id then
			return true
		end
	end
	return false
end

local function anyChange()
	return #worn > 0 or next(removed) ~= nil or body.skin ~= nil or body.scale ~= nil or copied ~= nil
end

local function wornSlots()
	local slots = {}
	for _, it in ipairs(worn) do
		if it.type == "Bundle" and it.slots then
			for slot, id in pairs(it.slots) do
				slots[slot] = id
			end
		end
	end
	return slots
end

local function wornBundle()
	for _, it in ipairs(worn) do
		if it.type == "Bundle" then
			return it
		end
	end
	return nil
end

-- deskripsi dasar: avatar pemain yang disalin, kalau tidak ada ya avatar sendiri
local function activeBase()
	return (copied and copied.desc) or baseDesc
end

-- badan harus diganti total (paket badan dipilih atau avatar pemain lain disalin)
local function bodyActive()
	return copied ~= nil or wornBundle() ~= nil
end

local function thumbUrl(id, kind)
	return string.format("rbxthumb://type=%s&id=%d&w=150&h=150", kind or "Asset", id)
end

local function setNameLabel(label, id)
	local cached = nameCache[id]
	if cached then
		label.Text = cached
		return
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.Asset)
		end)
		local name = ok and info and info.Name or ("Item " .. id)
		nameCache[id] = name
		if label.Parent then
			label.Text = name
		end
	end)
end

local function computeOriginals()
	table.clear(originals)
	local base = activeBase()
	if not base then
		return
	end
	local ok, accs = pcall(function()
		return base:GetAccessories(true)
	end)
	if ok then
		for _, a in ipairs(accs) do
			table.insert(originals, { key = "acc:" .. a.AssetId, kind = "acc", id = a.AssetId })
		end
	end
	for _, slot in ipairs({ "Shirt", "Pants", "GraphicTShirt", "Face" }) do
		local id = base[slot]
		if id and id > 0 then
			table.insert(originals, { key = "classic:" .. slot, kind = "classic", slot = slot, id = id })
		end
	end
end

---------------------------------------------------------------------
-- UI BUILD
---------------------------------------------------------------------
local old = playerGui:FindFirstChild("KatalogUI")
if old then
	old:Destroy()
end

local gui = new("ScreenGui", {
	Name = "KatalogUI",
	ResetOnSpawn = false,
	DisplayOrder = 95,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})
table.insert(themeRoots, gui)

local main = new("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(PANEL_W, PANEL_H),
	BackgroundColor3 = P.Bg,
	Visible = false,
	Parent = gui,
})
corner(main, 14)
stroke(main, P.Stroke, 2)

local uiScale = new("UIScale", { Parent = main })
local function updateScale()
	local cam = workspace.CurrentCamera
	if cam then
		local vs = cam.ViewportSize
		uiScale.Scale = math.clamp(math.min((vs.X - 30) / PANEL_W, (vs.Y - 30) / PANEL_H), 0.4, 1)
	end
end
updateScale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

-- toast kecil di bawah panel
local toastLabel = new("TextLabel", {
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -14),
	Size = UDim2.fromOffset(420, 30),
	BackgroundColor3 = P.Card,
	BackgroundTransparency = 0.05,
	Font = FONT,
	TextSize = 14,
	TextColor3 = P.Text,
	Text = "",
	Visible = false,
	ZIndex = 30,
	Parent = main,
})
corner(toastLabel, 8)
stroke(toastLabel, P.Stroke, 1.5)
local toastToken = 0
local function toast(text)
	toastToken += 1
	local token = toastToken
	toastLabel.Text = text
	toastLabel.Visible = true
	task.delay(2.6, function()
		if token == toastToken then
			toastLabel.Visible = false
		end
	end)
end

----------------------------- KOLOM KIRI ---------------------------
local left = new("Frame", {
	Name = "Left",
	Position = UDim2.fromOffset(12, 12),
	Size = UDim2.fromOffset(300, PANEL_H - 24),
	BackgroundTransparency = 1,
	Parent = main,
})

local viewport = new("ViewportFrame", {
	Name = "Preview",
	Size = UDim2.new(1, 0, 0, 300),
	BackgroundColor3 = P.Card,
	Ambient = Color3.fromRGB(170, 170, 170),
	LightColor = Color3.fromRGB(255, 255, 255),
	LightDirection = Vector3.new(-0.3, -0.6, 0.8),
	Parent = left,
})
corner(viewport, 10)
local vpCamera = new("Camera", { FieldOfView = 30, Parent = viewport })
viewport.CurrentCamera = vpCamera
local previewHint = new("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 14,
	TextColor3 = P.Muted,
	Text = "Memuat avatar...",
	ZIndex = 3,
	Parent = viewport,
})

local toolbar = new("Frame", {
	Name = "Toolbar",
	Position = UDim2.fromOffset(0, 308),
	Size = UDim2.new(1, 0, 0, 36),
	BackgroundTransparency = 1,
	Parent = left,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = toolbar,
})
local resetRefs = glossyButton(toolbar, UDim2.new(1 / 3, -4, 1, 0), THEMES.Red, "Reset", 14, { LayoutOrder = 1 })
local saveRefs = glossyButton(toolbar, UDim2.new(1 / 3, -4, 1, 0), THEMES.Green, "Simpan", 14, { LayoutOrder = 2 })
local outfitRefs = glossyButton(toolbar, UDim2.new(1 / 3, -4, 1, 0), THEMES.Off, "Outfit", 14, { LayoutOrder = 3 })

local wornTitle = new("TextLabel", {
	Position = UDim2.fromOffset(2, 352),
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 13,
	TextColor3 = P.Muted,
	Text = "Dipakai (0)",
	Parent = left,
})
local wornList = new("ScrollingFrame", {
	Name = "WornList",
	Position = UDim2.fromOffset(0, 374),
	Size = UDim2.new(1, 0, 0, 120),
	BackgroundColor3 = P.Card,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.X,
	ScrollingDirection = Enum.ScrollingDirection.X,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = P.Accent,
	Parent = left,
})
corner(wornList, 10)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Top,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = wornList,
})
new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), Parent = wornList })
local wornEmpty = new("TextLabel", {
	Position = UDim2.fromOffset(0, 374),
	Size = UDim2.new(1, 0, 0, 100),
	BackgroundTransparency = 1,
	Font = FONT_REGULAR,
	TextSize = 12,
	TextColor3 = P.Muted,
	TextWrapped = true,
	Text = "Belum ada item. Klik item di katalog untuk mencoba.",
	Parent = left,
})

new("TextLabel", {
	Position = UDim2.fromOffset(2, 498),
	Size = UDim2.new(1, -4, 0, 44),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Font = FONT_REGULAR,
	TextSize = 11,
	TextColor3 = P.Muted,
	Text = "Hanya kamu yang melihat hasilnya. Klik item di daftar Dipakai untuk melepasnya. Seret avatar untuk memutar. Outfit tersimpan selama kamu masih di game ini.",
	Parent = left,
})

-- panel outfit tersimpan (menutupi kolom kiri)
local outfitPanel = new("Frame", {
	Name = "OutfitPanel",
	Position = UDim2.fromOffset(0, 0),
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = P.Bg,
	Visible = false,
	ZIndex = 10,
	Parent = left,
})
corner(outfitPanel, 10)
new("TextLabel", {
	Size = UDim2.new(1, -80, 0, 30),
	Position = UDim2.fromOffset(4, 0),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 18,
	TextColor3 = WHITE,
	Text = "Outfit Tersimpan",
	ZIndex = 11,
	Parent = outfitPanel,
})
local outfitClose = glossyButton(outfitPanel, UDim2.fromOffset(70, 28), THEMES.Red, "Tutup", 13, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 1), ZIndex = 11,
})
local outfitScroll = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 38),
	Size = UDim2.new(1, 0, 1, -38),
	BackgroundColor3 = P.Card,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = P.Accent,
	ZIndex = 11,
	Parent = outfitPanel,
})
corner(outfitScroll, 10)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = outfitScroll })
new("UIPadding", {
	PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 10),
	Parent = outfitScroll,
})
local outfitEmpty = new("TextLabel", {
	Position = UDim2.fromOffset(0, 60),
	Size = UDim2.new(1, 0, 0, 60),
	BackgroundTransparency = 1,
	Font = FONT_REGULAR,
	TextSize = 13,
	TextColor3 = P.Muted,
	TextWrapped = true,
	Text = "Belum ada outfit. Coba beberapa item lalu tekan Simpan.",
	ZIndex = 12,
	Parent = outfitPanel,
})

----------------------------- KOLOM KANAN --------------------------
local right = new("Frame", {
	Name = "Right",
	Position = UDim2.fromOffset(324, 12),
	Size = UDim2.fromOffset(PANEL_W - 324 - 12, PANEL_H - 24),
	BackgroundTransparency = 1,
	Parent = main,
})

local header = new("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 38),
	BackgroundTransparency = 1,
	Parent = right,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = header,
})
local tabKatalog = glossyButton(header, UDim2.fromOffset(130, 34), THEMES.Tab, "KATALOG", 14, { LayoutOrder = 1 })
local tabTema = glossyButton(header, UDim2.fromOffset(130, 34), THEMES.TabOff, "TEMA", 14, { LayoutOrder = 2 })

local closeButton = glossyButton(right, UDim2.fromOffset(34, 34), THEMES.Red, "X", 16, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2),
})

local PAGE_Y = 46
local pageSize = UDim2.new(1, 0, 1, -PAGE_Y)

-- halaman katalog
local katalogPage = new("Frame", {
	Name = "KatalogPage",
	Position = UDim2.fromOffset(0, PAGE_Y),
	Size = pageSize,
	BackgroundTransparency = 1,
	Parent = right,
})

local searchBox = new("TextBox", {
	Name = "Search",
	Size = UDim2.new(1, -168, 0, 36),
	BackgroundColor3 = P.Input,
	Font = FONT,
	TextSize = 15,
	TextColor3 = P.Text,
	PlaceholderText = "Cari item...",
	PlaceholderColor3 = P.Placeholder,
	Text = "",
	ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = katalogPage,
})
corner(searchBox, 8)
stroke(searchBox, P.Line, 1.5)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = searchBox })
local sortRefs = glossyButton(katalogPage, UDim2.fromOffset(160, 36), THEMES.Off, "Urut: Terlaris", 13, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
})

local function makeTabRow(name, y, height)
	local row = new("ScrollingFrame", {
		Name = name,
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, height),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Parent = katalogPage,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = row,
	})
	return row
end
local catRow = makeTabRow("CatRow", 44, 34)
local subRow = makeTabRow("SubRow", 82, 28)

local gridFrame = new("Frame", {
	Name = "GridFrame",
	Position = UDim2.fromOffset(0, 116),
	Size = UDim2.new(1, 0, 1, -116),
	BackgroundColor3 = P.Card,
	Parent = katalogPage,
})
corner(gridFrame, 10)
local grid = new("ScrollingFrame", {
	Name = "Grid",
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 5,
	ScrollBarImageColor3 = P.Accent,
	Parent = gridFrame,
})
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = grid,
})
new("UIGridLayout", {
	CellSize = UDim2.fromOffset(142, 190),
	CellPadding = UDim2.fromOffset(8, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = grid,
})
local statusLabel = new("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 15,
	TextColor3 = P.Muted,
	Text = "",
	ZIndex = 3,
	Parent = gridFrame,
})

-- panel badan (warna kulit + ukuran), menggantikan grid saat sub kategori khusus dipilih
local bodyPanel = new("Frame", {
	Name = "BodyPanel",
	Position = UDim2.fromOffset(0, 116),
	Size = UDim2.new(1, 0, 1, -116),
	BackgroundColor3 = P.Card,
	Visible = false,
	Parent = katalogPage,
})
corner(bodyPanel, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
	Parent = bodyPanel,
})

local skinFrame = new("Frame", { Name = "Skin", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = bodyPanel })
new("TextLabel", {
	Size = UDim2.new(1, -190, 0, 24),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 18,
	TextColor3 = WHITE,
	Text = "Warna Kulit",
	Parent = skinFrame,
})
local skinResetRefs = glossyButton(skinFrame, UDim2.fromOffset(180, 28), THEMES.Red, "Kembali ke asli", 13, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
})
local skinGrid = new("Frame", {
	Name = "Swatches",
	Position = UDim2.fromOffset(0, 40),
	Size = UDim2.new(1, 0, 1, -40),
	BackgroundTransparency = 1,
	Parent = skinFrame,
})
new("UIGridLayout", {
	CellSize = UDim2.fromOffset(60, 60),
	CellPadding = UDim2.fromOffset(10, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = skinGrid,
})
table.insert(themeSkip, skinGrid) -- warna kulit tidak ikut tema

local scaleFrame = new("Frame", { Name = "Scale", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = bodyPanel })
new("TextLabel", {
	Size = UDim2.new(1, -190, 0, 24),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 18,
	TextColor3 = WHITE,
	Text = "Ukuran Badan",
	Parent = scaleFrame,
})
local scaleResetRefs = glossyButton(scaleFrame, UDim2.fromOffset(180, 28), THEMES.Red, "Kembali ke asli", 13, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0),
})
new("TextLabel", {
	Position = UDim2.new(0, 0, 1, -46),
	Size = UDim2.new(1, 0, 0, 44),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Font = FONT_REGULAR,
	TextSize = 12,
	TextColor3 = P.Muted,
	Text = "Pratinjau di kiri memakai semua ukuran. Di karakter aslimu hanya Tinggi yang ikut berubah (batas ukuran mengikuti pengaturan avatar Roblox).",
	Parent = scaleFrame,
})

-- salin avatar pemain lain (input UserId / username + daftar pemain di game)
local copyFrame = new("Frame", { Name = "Copy", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = bodyPanel })
new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 18,
	TextColor3 = WHITE,
	Text = "Salin Avatar Pemain",
	Parent = copyFrame,
})
new("TextLabel", {
	Position = UDim2.fromOffset(0, 28),
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Font = FONT_REGULAR,
	TextSize = 12,
	TextColor3 = P.Muted,
	Text = "Masukkan UserId atau username, lalu tekan Pakai Avatar. Badan, baju, dan aksesori orang itu dipasang ke avatarmu (cuma kamu yang melihatnya).",
	Parent = copyFrame,
})
local copyBox = new("TextBox", {
	Name = "UserInput",
	Position = UDim2.fromOffset(0, 68),
	Size = UDim2.new(1, -176, 0, 40),
	BackgroundColor3 = P.Input,
	Font = FONT,
	TextSize = 15,
	TextColor3 = P.Text,
	PlaceholderText = "UserId atau username...",
	PlaceholderColor3 = P.Placeholder,
	Text = "",
	ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = copyFrame,
})
corner(copyBox, 8)
stroke(copyBox, P.Line, 1.5)
new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = copyBox })
local copyGoRefs = glossyButton(copyFrame, UDim2.fromOffset(168, 40), THEMES.Green, "Pakai Avatar", 14, {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 68),
})
local copyStatus = new("TextLabel", {
	Position = UDim2.fromOffset(0, 114),
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 12,
	TextColor3 = P.Muted,
	Text = "",
	Parent = copyFrame,
})
new("TextLabel", {
	Position = UDim2.fromOffset(0, 140),
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 13,
	TextColor3 = P.Text,
	Text = "Pemain di game ini",
	Parent = copyFrame,
})
local copyList = new("ScrollingFrame", {
	Name = "PlayerList",
	Position = UDim2.fromOffset(0, 164),
	Size = UDim2.new(1, 0, 1, -164 - 44),
	BackgroundColor3 = P.Bar,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = P.Accent,
	Parent = copyFrame,
})
corner(copyList, 8)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = copyList })
new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 10), Parent = copyList })
local copyBackRefs = glossyButton(copyFrame, UDim2.new(1, 0, 0, 36), THEMES.Red, "Kembali ke avatarku", 14, {
	AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0),
})

-- halaman tema
local temaPage = new("Frame", {
	Name = "TemaPage",
	Position = UDim2.fromOffset(0, PAGE_Y),
	Size = pageSize,
	BackgroundColor3 = P.Card,
	Visible = false,
	Parent = right,
})
corner(temaPage, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
	Parent = temaPage,
})
new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 26),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 20,
	TextColor3 = WHITE,
	Text = "Tema Warna",
	Parent = temaPage,
})
local themeGrid = new("Frame", {
	Name = "Swatches",
	Position = UDim2.fromOffset(0, 36),
	Size = UDim2.new(1, 0, 1, -36),
	BackgroundTransparency = 1,
	Parent = temaPage,
})
new("UIGridLayout", {
	CellSize = UDim2.new(0.25, -8, 0, 50),
	CellPadding = UDim2.fromOffset(10, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = themeGrid,
})
table.insert(themeSkip, themeGrid) -- kotak pilihan tema tetap pakai warna aslinya

-- tombol buka (di kiri layar, di bawah tombol Utility)
local openRefs = glossyButton(gui, UDim2.fromOffset(110, 40), THEMES.Tab, "Katalog", 18, {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.5, 56),
})

---------------------------------------------------------------------
-- PREVIEW + TRY-ON DI KARAKTER (cuma di client)
---------------------------------------------------------------------
local stash = {} -- item asli karakter yang dilepas sementara: { inst, parent }
local mine = {} -- item buatan kita yang ditempel ke karakter
local overlays = {} -- bagian badan asli yang disembunyikan: { part, t, decals }
local savedColors = nil
local origScale = nil

local function restoreOriginals()
	local char = player.Character
	if char and origScale then
		pcall(function()
			char:ScaleTo(origScale)
		end)
	end
	origScale = nil
	for _, inst in ipairs(mine) do
		if inst.Parent then
			inst:Destroy()
		end
	end
	table.clear(mine)
	for _, s in ipairs(stash) do
		if s.parent and s.parent.Parent then
			s.inst.Parent = s.parent
		end
	end
	table.clear(stash)
	for _, o in ipairs(overlays) do
		if o.part and o.part.Parent then
			o.part.Transparency = o.t
		end
		for _, d in ipairs(o.decals) do
			if d.inst.Parent then
				d.inst.Transparency = d.t
			end
		end
	end
	table.clear(overlays)
	if savedColors and char then
		local bc = char:FindFirstChildOfClass("BodyColors")
		if bc then
			for prop, value in pairs(savedColors) do
				bc[prop] = value
			end
		end
	end
	savedColors = nil
end

local function stashInstance(inst)
	table.insert(stash, { inst = inst, parent = inst.Parent })
	inst.Parent = nil
end

-- tempel aksesori ke karakter lokal dengan weld sendiri.
-- (Humanoid:AddAccessory dari client dibuang engine setelah ~2 detik, jadi tidak dipakai)
local function attachAccessory(acc, char)
	local handle = acc:FindFirstChild("Handle")
	if not handle then
		return false
	end
	local function mapPart(p)
		if p and (p == handle or p:IsDescendantOf(acc)) then
			return p
		end
		if not p then
			return nil
		end
		-- bagian badan baru (overlay) didahulukan: aksesori ikut kepala/badan yang terlihat
		return char:FindFirstChild(p.Name .. "_Katalog") or char:FindFirstChild(p.Name)
	end
	-- pakai weld bawaan model (C0/C1 sudah benar), arahkan ke bagian tubuh karakter asli
	local weld = handle:FindFirstChildWhichIsA("Weld")
	if weld then
		local p0, p1 = mapPart(weld.Part0), mapPart(weld.Part1)
		if p0 and p1 then
			weld.Part0, weld.Part1 = p0, p1
			handle.CanCollide = false
			acc.Parent = char
			return true
		end
	end
	-- cadangan: cocokkan attachment di handle dengan attachment di karakter
	local att = handle:FindFirstChildOfClass("Attachment")
	local target = att and char:FindFirstChild(att.Name, true)
	if not (att and target and target:IsA("Attachment")) then
		return false
	end
	if weld then
		weld:Destroy()
	end
	local w = new("Weld", { Name = "AccessoryWeld", Part0 = target.Parent, Part1 = handle, C0 = target.CFrame, C1 = att.CFrame })
	w.Parent = handle
	handle.CanCollide = false
	acc.Parent = char
	return true
end

-- bagian badan baru ditempel di atas bagian asli (yang disembunyikan).
-- Bagian asli tidak boleh dibuang: kalau Head hilang karakter langsung mati.
-- batas bawah telapak kaki relatif ke HumanoidRootPart (dipakai menyamakan tinggi badan baru)
local function footBottom(m)
	local root = m:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local lowest
	for _, n in ipairs({ "LeftFoot", "RightFoot" }) do
		local p = m:FindFirstChild(n)
		if p then
			local y = root.CFrame:ToObjectSpace(p.CFrame).Position.Y - p.Size.Y / 2
			lowest = lowest and math.min(lowest, y) or y
		end
	end
	return lowest
end

local function overlayPart(char, name, model, ref, shiftY)
	local oldPart, src = char:FindFirstChild(name), model:FindFirstChild(name)
	if not (oldPart and src and oldPart:IsA("BasePart") and src:IsA("BasePart")) then
		return
	end
	-- bentuk sama persis dengan yang sudah dipakai: tidak perlu diganti (baju klasik tetap tampil)
	if oldPart:IsA("MeshPart") and src:IsA("MeshPart") and oldPart.MeshId == src.MeshId and (oldPart.Size - src.Size).Magnitude < 0.08 then
		return
	end
	-- posisi bagian baru relatif ke bagian lama: dihitung dari selisih model asli vs model bundle
	-- (pose diam, skala asli), supaya bentuk dan sendi bundle tetap pada tempatnya
	local offset = CFrame.new()
	local srcRoot = model:FindFirstChild("HumanoidRootPart")
	local charRoot = char:FindFirstChild("HumanoidRootPart")
	if srcRoot and charRoot then
		-- acuan = posisi bagian lama di karakter asli sekarang (bukan model dari deskripsi,
		-- karena avatar dengan bagian/aksesori kustom bisa punya rig yang beda dari modelnya)
		local newRel = srcRoot.CFrame:ToObjectSpace(src.CFrame)
		local oldRel = charRoot.CFrame:ToObjectSpace(oldPart.CFrame)
		offset = oldRel:Inverse() * (CFrame.new(0, shiftY or 0, 0) * newRel)
	end
	local newPart = src:Clone()
	for _, d in ipairs(newPart:GetChildren()) do
		if d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Attachment") then
			d:Destroy()
		end
	end
	newPart.Name = name .. "_Katalog"
	newPart.CanCollide = false
	newPart.CanTouch = false
	newPart.CanQuery = false
	newPart.Massless = true
	newPart.Anchored = false
	newPart.CFrame = oldPart.CFrame * offset
	new("Weld", { Part0 = oldPart, Part1 = newPart, C0 = offset, C1 = CFrame.new(), Parent = newPart })
	newPart.Parent = char
	table.insert(mine, newPart)
	local rec = { part = oldPart, t = oldPart.Transparency, decals = {} }
	oldPart.Transparency = 1
	for _, d in ipairs(oldPart:GetChildren()) do
		if d:IsA("Decal") then
			table.insert(rec.decals, { inst = d, t = d.Transparency })
			d.Transparency = 1
		end
	end
	table.insert(overlays, rec)
end

-- pindahkan aksesori / pakaian / wajah / badan dari model hasil HumanoidDescription ke karakter lokal
local function applyToCharacter(model, bodyModel, ref)
	local char, hum = getCharacter()
	if not (char and hum) then
		return
	end
	restoreOriginals()
	if not model then
		return
	end
	origScale = char:GetScale()
	for _, a in ipairs(char:GetChildren()) do
		if a:IsA("Accessory") then
			stashInstance(a)
		end
	end
	for _, className in ipairs({ "Shirt", "Pants", "ShirtGraphic" }) do
		local src = model:FindFirstChildOfClass(className)
		local cur = char:FindFirstChildOfClass(className)
		if cur then
			stashInstance(cur)
		end
		if src then
			local c = src:Clone()
			c.Parent = char
			table.insert(mine, c)
		end
	end
	local head, srcHead = char:FindFirstChild("Head"), model:FindFirstChild("Head")
	if head and srcHead then
		local srcFace = srcHead:FindFirstChildOfClass("Decal")
		local curFace = head:FindFirstChildOfClass("Decal")
		if srcFace and curFace and srcFace.Texture ~= curFace.Texture then
			stashInstance(curFace)
			local c = srcFace:Clone()
			c.Parent = head
			table.insert(mine, c)
		end
	end
	-- warna kulit
	local bundle = wornBundle()
	if body.skin or (bundle and bundle.colors) or copied then
		local bc = char:FindFirstChildOfClass("BodyColors")
		if bc then
			savedColors = {}
			for i, prop in ipairs(BODYCOLOR_PROPS) do
				local color = body.skin or (bundle and bundle.colors and bundle.colors[SKIN_PROPS[i]])
					or (copied and copied.desc[SKIN_PROPS[i]])
				if color then
					savedColors[prop] = bc[prop]
					bc[prop] = color
				end
			end
		end
	end
	-- bagian badan dari paket badan (cuma R15)
	if hum.RigType == Enum.HumanoidRigType.R15 and bodyActive() then
		local src = bodyModel or model
		-- satu badan dipilih = seluruh badan diganti (bundle bisa mengubah proporsi semua bagian),
		-- dan tinggi disamakan lewat telapak kaki supaya pas berdiri di tanah
		local shiftY = 0
		if bodyModel then
			local a, b = footBottom(char), footBottom(bodyModel)
			if a and b then
				shiftY = a - b
			end
		end
		for _, slot in ipairs({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }) do
			for _, name in ipairs(SLOT_PARTS[slot]) do
				overlayPart(char, name, src, ref, shiftY)
			end
		end
	end
	-- aksesori ditempel setelah bagian badan baru ada. Kalau badan diganti, pakai model badan
	-- (skala sama dengan bagian baru) supaya posisinya pas di kepala/badan yang terlihat
	local accSource = (#overlays > 0 and bodyModel) or model
	for _, a in ipairs(accSource:GetChildren()) do
		if a:IsA("Accessory") then
			local c = a:Clone()
			if attachAccessory(c, char) then
				table.insert(mine, c)
			else
				c:Destroy()
			end
		end
	end
	-- ukuran: karakter asli cuma bisa mengikuti Tinggi (skala seragam)
	if baseDesc and baseDesc.HeightScale > 0 then
		local h = (body.scale and body.scale.HeightScale) or (bundle and bundle.scales and bundle.scales.HeightScale) or (copied and copied.desc.HeightScale) or baseDesc.HeightScale
		if h ~= baseDesc.HeightScale then
			pcall(function()
				char:ScaleTo(origScale * (h / baseDesc.HeightScale))
			end)
		end
	end
end

local function fetchBase()
	local _, hum = getCharacter()
	local desc
	if hum then
		local ok, d = pcall(function()
			return hum:GetAppliedDescription()
		end)
		if ok then
			desc = d
		end
	end
	if not desc then
		local ok, d = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end)
		if ok then
			desc = d
		end
	end
	return desc
end

local function buildDescription()
	local base = activeBase()
	local desc = base and base:Clone() or Instance.new("HumanoidDescription")
	local accs = desc:GetAccessories(true)
	-- item bawaan yang dilepas
	for i = #accs, 1, -1 do
		if removed["acc:" .. accs[i].AssetId] then
			table.remove(accs, i)
		end
	end
	for _, slot in ipairs({ "Shirt", "Pants", "GraphicTShirt", "Face" }) do
		if removed["classic:" .. slot] then
			desc[slot] = 0
		end
	end
	local maxOrder = 0
	for _, a in ipairs(accs) do
		if a.Order and a.Order > maxOrder then
			maxOrder = a.Order
		end
	end
	for _, it in ipairs(worn) do
		if it.type == "Bundle" then
			-- badan penuh: bagian yang tidak ada di bundle kembali ke bawaan (bukan bagian avatar sekarang)
			for _, s in ipairs({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }) do
				desc[s] = 0
			end
			for slot, id in pairs(it.slots or {}) do
				desc[slot] = id
			end
			for prop, color in pairs(it.colors or {}) do
				desc[prop] = color
			end
			for prop, value in pairs(it.scales or {}) do
				desc[prop] = value
			end
		else
			local slot = CLASSIC[it.type]
			if slot then
				desc[slot] = it.id
			else
				local at = ACCESSORY_TYPE[it.type]
				if at then
					if EXCLUSIVE[at] then
						for i = #accs, 1, -1 do
							if accs[i].AccessoryType == at then
								table.remove(accs, i)
							end
						end
					end
					if #accs < MAX_ACCESSORIES then
						local entry = { AssetId = it.id, AccessoryType = at, IsLayered = LAYERED[it.type] == true }
						if entry.IsLayered then
							maxOrder += 1
							entry.Order = maxOrder
						end
						table.insert(accs, entry)
					end
				end
			end
		end
	end
	desc:SetAccessories(accs, true)
	if body.skin then
		for _, prop in ipairs(SKIN_PROPS) do
			desc[prop] = body.skin
		end
	end
	if body.scale then
		for prop, value in pairs(body.scale) do
			desc[prop] = value
		end
	end
	return desc
end

local function placePreview(model)
	if previewModel then
		previewModel:Destroy()
	end
	previewModel = model
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	model.Parent = viewport
	model:PivotTo(CFrame.Angles(0, previewYaw, 0))
	-- kamera ukuran tetap (bounding box tidak dipakai: aksesori besar bikin avatar kelihatan kecil)
	local target = Vector3.new(0, -0.2, 0)
	vpCamera.CFrame = CFrame.lookAt(target + Vector3.new(0, 0.3, -13), target)
	previewHint.Visible = false
end

local refreshCells -- dideklarasikan di bawah
local refreshWornList
local afterWornChanged

local function refreshPreview()
	previewToken += 1
	local token = previewToken
	task.spawn(function()
		if not baseDesc then
			baseDesc = fetchBase()
		end
		local desc = buildDescription()
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(desc, rigType())
		end)
		if token ~= previewToken then
			if ok and model then
				model:Destroy()
			end
			return
		end
		if not (ok and model) then
			previewHint.Text = "Gagal memuat preview avatar"
			previewHint.Visible = true
			return
		end
		placePreview(model)
		if not anyChange() then
			applyToCharacter(nil) -- balik ke avatar asli
			return
		end
		-- model khusus bagian badan (skala asli) supaya posisinya cocok dengan karakter
		local bodyModel
		if bodyActive() and rigType() == Enum.HumanoidRigType.R15 then
			local bodyDesc = buildDescription()
			if baseDesc then
				-- ukuran keseluruhan pakai skala asli (karakter di-ScaleTo terpisah); bentuk (tipe badan,
				-- proporsi) tetap ikut resep bundle
				for _, def in ipairs(SCALES) do
					if def.prop ~= "BodyTypeScale" and def.prop ~= "ProportionScale" then
						bodyDesc[def.prop] = baseDesc[def.prop]
						if def.also then
							bodyDesc[def.also] = baseDesc[def.also]
						end
					end
				end
			end
			local okB, bm = pcall(function()
				return Players:CreateHumanoidModelFromDescription(bodyDesc, rigType())
			end)
			if okB then
				bodyModel = bm
			end
			if token ~= previewToken then
				if bodyModel then
					bodyModel:Destroy()
				end
				return
			end
		end
		applyToCharacter(model, bodyModel, baseModel)
		if bodyModel then
			bodyModel:Destroy()
		end
	end)
end

function afterWornChanged()
	refreshCells()
	refreshWornList()
	refreshPreview()
end

-- seret preview untuk memutar avatar
do
	local dragging, lastX = false, 0
	viewport.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			previewYaw += (input.Position.X - lastX) * 0.012
			lastX = input.Position.X
			if previewModel then
				previewModel:PivotTo(CFrame.Angles(0, previewYaw, 0))
			end
		end
	end)
end

---------------------------------------------------------------------
-- DAFTAR "DIPAKAI": item bawaan avatar + yang dicoba + warna kulit / ukuran
---------------------------------------------------------------------
local function addTile(o)
	local tile = new("Frame", {
		Name = "Tile",
		Size = UDim2.fromOffset(76, 104),
		BackgroundTransparency = 1,
		LayoutOrder = o.order,
		Parent = wornList,
	})
	local btn = new("ImageButton", {
		Size = UDim2.fromOffset(70, 70),
		Position = UDim2.fromOffset(3, 0),
		BackgroundColor3 = o.color or P.Bar,
		Image = o.image or "",
		ImageTransparency = o.dim and 0.7 or 0,
		AutoButtonColor = true,
		Parent = tile,
	})
	corner(btn, 8)
	stroke(btn, o.stroke, 1.5)
	if o.cross then
		new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 11,
			TextColor3 = P.Text,
			Text = "DILEPAS",
			Parent = btn,
		})
	elseif o.centerText then
		new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 13,
			TextColor3 = P.Accent,
			Text = o.centerText,
			Parent = btn,
		})
	end
	local label = new("TextLabel", {
		Position = UDim2.fromOffset(0, 74),
		Size = UDim2.fromOffset(76, 28),
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 10,
		TextColor3 = P.Text,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = o.text or "",
		Parent = tile,
	})
	if o.id and not o.text then
		setNameLabel(label, o.id)
	end
	btn.Activated:Connect(o.onClick)
end

function refreshWornList()
	for _, c in ipairs(wornList:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local order, count = 0, 0
	if copied then
		order += 1
		count += 1
		addTile({
			order = order,
			image = thumbUrl(copied.id, "AvatarHeadShot"),
			text = "Avatar @" .. copied.name,
			stroke = P.Accent,
			onClick = function()
				stopCopy()
			end,
		})
	end
	for _, o in ipairs(originals) do
		order += 1
		local isRemoved = removed[o.key] == true
		if not isRemoved then
			count += 1
		end
		addTile({
			order = order,
			image = thumbUrl(o.id),
			id = o.id,
			dim = isRemoved,
			cross = isRemoved,
			stroke = P.Line,
			onClick = function()
				removed[o.key] = (not removed[o.key]) or nil
				afterWornChanged()
			end,
		})
	end
	for _, it in ipairs(worn) do
		order += 1
		count += 1
		addTile({
			order = order,
			image = thumbUrl(it.id, it.type == "Bundle" and "BundleThumbnail" or "Asset"),
			text = it.name,
			stroke = P.Accent,
			onClick = function()
				for k, w in ipairs(worn) do
					if w == it then
						table.remove(worn, k)
						break
					end
				end
				afterWornChanged()
			end,
		})
	end
	if body.skin then
		order += 1
		count += 1
		addTile({
			order = order, color = body.skin, text = "Warna kulit", stroke = P.Accent,
			onClick = function()
				body.skin = nil
				afterWornChanged()
			end,
		})
	end
	if body.scale then
		order += 1
		count += 1
		addTile({
			order = order, centerText = "UKURAN", text = "Ukuran badan", stroke = P.Accent,
			onClick = function()
				body.scale = nil
				afterWornChanged()
			end,
		})
	end
	wornTitle.Text = string.format("Dipakai (%d)", count)
	wornEmpty.Visible = order == 0
	wornList.Visible = order > 0
end

local function toggleItem(item)
	local id = item.Id
	local typeName = item.AssetType
	if typeof(typeName) == "EnumItem" then
		typeName = typeName.Name
	end
	if not typeName then
		return
	end
	for k, w in ipairs(worn) do
		if w.id == id then
			table.remove(worn, k)
			toast("Dilepas: " .. item.Name)
			afterWornChanged()
			return
		end
	end
	if not CLASSIC[typeName] and not ACCESSORY_TYPE[typeName] then
		toast("Jenis item ini belum didukung.")
		return
	end
	-- pakaian klasik / wajah: satu per jenis
	if CLASSIC[typeName] then
		for k = #worn, 1, -1 do
			if worn[k].type == typeName then
				table.remove(worn, k)
			end
		end
	end
	table.insert(worn, { id = id, name = item.Name, type = typeName })
	toast("Dicoba: " .. item.Name)
	afterWornChanged()
end

-- paket badan / kepala dinamis: ambil aset bagian badannya dari detail bundle
local function toggleBundle(item)
	for k, w in ipairs(worn) do
		if w.type == "Bundle" and w.id == item.Id then
			table.remove(worn, k)
			toast("Dilepas: " .. item.Name)
			afterWornChanged()
			return
		end
	end
	toast("Memuat " .. item.Name .. "...")
	task.spawn(function()
		local ok, det = pcall(function()
			return AvatarEditorService:GetItemDetails(item.Id, Enum.AvatarItemType.Bundle)
		end)
		if not (ok and det) then
			toast("Gagal memuat paket badan.")
			return
		end
		local slots, colors, scales = {}, nil, nil
		-- resep tampilan bundle (UserOutfit): bagian badan + warna kulit + ukuran bawaannya
		for _, b in ipairs(det.BundledItems or {}) do
			if b.Type == "UserOutfit" and not colors then
				local okO, od = pcall(function()
					return Players:GetHumanoidDescriptionFromOutfitId(b.Id)
				end)
				if okO and od then
					for _, slot in ipairs({ "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }) do
						if od[slot] and od[slot] > 0 then
							slots[slot] = od[slot]
						end
					end
					colors, scales = {}, {}
					for _, prop in ipairs(SKIN_PROPS) do
						colors[prop] = od[prop]
					end
					for _, def in ipairs(SCALES) do
						scales[def.prop] = od[def.prop]
						if def.also then
							scales[def.also] = od[def.also]
						end
					end
				end
			end
		end
		-- cadangan: bagian badan dari daftar aset bundle
		for _, b in ipairs(det.BundledItems or {}) do
			if b.Type == "Asset" then
				local okA, ad = pcall(function()
					return AvatarEditorService:GetItemDetails(b.Id, Enum.AvatarItemType.Asset)
				end)
				local at = okA and ad and ad.AssetType
				if typeof(at) == "EnumItem" then
					at = at.Name
				end
				local slot = at and BODY_SLOTS[at]
				if slot and not slots[slot] then
					slots[slot] = b.Id
				end
			end
		end
		if next(slots) == nil then
			toast("Paket ini tidak berisi bagian badan.")
			return
		end
		for k = #worn, 1, -1 do
			if worn[k].type == "Bundle" then
				table.remove(worn, k)
			end
		end
		table.insert(worn, { id = item.Id, name = item.Name, type = "Bundle", slots = slots, colors = colors, scales = scales })
		-- badan dipilih = jadi 100% badan itu: warna kulit dan ukuran kembali ke bawaan bundle
		body.skin, body.scale = nil, nil
		toast("Dicoba: " .. item.Name)
		afterWornChanged()
	end)
end

local function copyState()
	local items = {}
	for _, it in ipairs(worn) do
		local c = { id = it.id, name = it.name, type = it.type }
		if it.slots then
			c.slots = table.clone(it.slots)
		end
		c.colors, c.scales = it.colors, it.scales
		table.insert(items, c)
	end
	return {
		items = items,
		removed = table.clone(removed),
		copied = copied,
		skin = body.skin,
		scale = body.scale and table.clone(body.scale) or nil,
	}
end

local refreshSkin, refreshScales -- dideklarasikan di bawah

local function refreshOutfits()
	for _, c in ipairs(outfitScroll:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	outfitEmpty.Visible = #saved == 0
	for i, o in ipairs(saved) do
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, 64),
			BackgroundColor3 = P.Bar,
			LayoutOrder = i,
			ZIndex = 12,
			Parent = outfitScroll,
		})
		corner(row, 8)
		new("TextLabel", {
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -20, 0, 22),
			BackgroundTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = FONT,
			TextSize = 14,
			TextColor3 = P.Text,
			Text = string.format("%s  (%d item)", o.name, #o.items),
			ZIndex = 13,
			Parent = row,
		})
		local use = glossyButton(row, UDim2.new(0.5, -14, 0, 26), THEMES.Green, "Pakai", 13, { Position = UDim2.fromOffset(10, 32), ZIndex = 13 })
		local del = glossyButton(row, UDim2.new(0.5, -14, 0, 26), THEMES.Red, "Hapus", 13, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 32), ZIndex = 13 })
		use.button.Activated:Connect(function()
			table.clear(worn)
			for _, it in ipairs(o.items) do
				local c = { id = it.id, name = it.name, type = it.type }
				if it.slots then
					c.slots = table.clone(it.slots)
				end
				c.colors, c.scales = it.colors, it.scales
				table.insert(worn, c)
			end
			removed = table.clone(o.removed)
			copied = o.copied
			computeOriginals()
			body.skin = o.skin
			body.scale = o.scale and table.clone(o.scale) or nil
			outfitPanel.Visible = false
			toast("Memakai " .. o.name)
			refreshSkin()
			refreshScales()
			afterWornChanged()
		end)
		del.button.Activated:Connect(function()
			table.remove(saved, i)
			refreshOutfits()
		end)
	end
end

resetRefs.button.Activated:Connect(function()
	table.clear(worn)
	table.clear(removed)
	body.skin, body.scale = nil, nil
	copied = nil
	computeOriginals()
	playingEmote = nil
	toast("Avatar dikembalikan seperti semula")
	refreshSkin()
	refreshScales()
	afterWornChanged()
end)
saveRefs.button.Activated:Connect(function()
	if not anyChange() then
		toast("Belum ada perubahan untuk disimpan.")
		return
	end
	local state = copyState()
	state.name = "Outfit " .. (#saved + 1)
	table.insert(saved, state)
	refreshOutfits()
	toast("Tersimpan sebagai " .. state.name)
end)
outfitRefs.button.Activated:Connect(function()
	refreshOutfits()
	outfitPanel.Visible = true
end)
outfitClose.button.Activated:Connect(function()
	outfitPanel.Visible = false
end)

---------------------------------------------------------------------
-- EMOTE (cuma R15)
---------------------------------------------------------------------
local function playEmote(item)
	local _, hum = getCharacter()
	if not hum then
		return
	end
	if playingEmote == item.Id then
		playingEmote = nil
		for _, t in ipairs(hum:GetPlayingAnimationTracks()) do
			if t.Priority == Enum.AnimationPriority.Action or t.Priority == Enum.AnimationPriority.Core then
				t:Stop()
			end
		end
		refreshCells()
		return
	end
	if hum.RigType ~= Enum.HumanoidRigType.R15 then
		toast("Emote cuma bisa dimainkan di avatar R15.")
		return
	end
	local dd = hum:FindFirstChildOfClass("HumanoidDescription")
	if not dd then
		dd = Instance.new("HumanoidDescription")
		dd.Parent = hum
	end
	local key = "Katalog" .. item.Id
	local okSet = pcall(function()
		dd:SetEmotes({ [key] = { item.Id } })
		dd:SetEquippedEmotes({ key })
	end)
	local ok, res = false, nil
	if okSet then
		ok, res = pcall(function()
			return hum:PlayEmote(key)
		end)
	end
	if ok and res then
		playingEmote = item.Id
		toast("Emote: " .. item.Name)
	else
		toast("Emote ini tidak bisa dimainkan.")
	end
	refreshCells()
end

---------------------------------------------------------------------
-- KATALOG: CARI + GRID
---------------------------------------------------------------------
local function clearGrid()
	for _, c in ipairs(grid:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	table.clear(cellRefs)
end

function refreshCells()
	for id, refs in pairs(cellRefs) do
		local on = isWorn(id) or playingEmote == id
		refs.stroke.Color = on and P.Accent or P.Line
		refs.stroke.Thickness = on and 2.5 or 1.5
		refs.badge.Visible = on
	end
end

local cellCount = 0
local function addCell(item)
	cellCount += 1
	local id = item.Id
	local isBundle = item.ItemType == "Bundle"
	local cell = new("Frame", {
		Name = tostring(id),
		BackgroundColor3 = P.Bar,
		LayoutOrder = cellCount,
		Parent = grid,
	})
	corner(cell, 10)
	local cellStroke = stroke(cell, P.Line, 1.5)
	local thumb = new("ImageLabel", {
		Position = UDim2.fromOffset(9, 9),
		Size = UDim2.fromOffset(124, 124),
		BackgroundColor3 = P.Card,
		Image = thumbUrl(id, isBundle and "BundleThumbnail" or "Asset"),
		Parent = cell,
	})
	corner(thumb, 8)
	new("TextLabel", {
		Position = UDim2.fromOffset(9, 138),
		Size = UDim2.fromOffset(124, 44),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = FONT,
		TextSize = 12,
		TextColor3 = P.Text,
		Text = item.Name,
		Parent = cell,
	})
	local badge = new("Frame", {
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(62, 20),
		BackgroundColor3 = WHITE,
		Visible = false,
		ZIndex = 3,
		Parent = cell,
	})
	corner(badge, 6)
	new("UIGradient", { Color = P.Primary, Rotation = 90, Parent = badge })
	-- teks di label terpisah supaya tidak ikut diwarnai gradient
	new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 11,
		TextColor3 = P.OnPrimary,
		Text = "DICOBA",
		ZIndex = 4,
		Parent = badge,
	})
	local click = new("TextButton", {
		Name = "Click",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 5,
		Parent = cell,
	})
	cellRefs[id] = { stroke = cellStroke, badge = badge }
	click.MouseEnter:Connect(function()
		cell.BackgroundColor3 = P.Hover
	end)
	click.MouseLeave:Connect(function()
		cell.BackgroundColor3 = P.Bar
	end)
	click.Activated:Connect(function()
		local typeName = item.AssetType
		if typeof(typeName) == "EnumItem" then
			typeName = typeName.Name
		end
		if isBundle then
			toggleBundle(item)
		elseif typeName == "EmoteAnimation" then
			playEmote(item)
		else
			toggleItem(item)
		end
	end)
end

local function setStatus(text)
	statusLabel.Text = text or ""
	statusLabel.Visible = text ~= nil and text ~= ""
end

local function appendPage(items)
	for _, item in ipairs(items) do
		addCell(item)
	end
	refreshCells()
end

-- grid katalog atau panel khusus (warna kulit / ukuran)
local function showMode(mode)
	local custom = mode ~= nil
	gridFrame.Visible = not custom
	bodyPanel.Visible = custom
	skinFrame.Visible = mode == "skin"
	scaleFrame.Visible = mode == "scale"
	copyFrame.Visible = mode == "copy"
	if mode == "copy" then
		refreshPlayerList()
	end
	if mode == "scale" then
		refreshScales()
	elseif mode == "skin" then
		refreshSkin()
	end
	searchBox.Visible = not custom
	sortRefs.button.Visible = not custom
end

local function runSearch()
	searchToken += 1
	local token = searchToken
	local sub = CATEGORIES[catIndex].subs[subIndex]
	showMode(sub.mode)
	if sub.mode then
		return
	end
	clearGrid()
	cellCount = 0
	pages = nil
	grid.CanvasPosition = Vector2.zero
	setStatus("Memuat katalog...")
	task.spawn(function()
		local params = CatalogSearchParams.new()
		params.SearchKeyword = keyword
		if sub.bundles then
			params.BundleTypes = sub.bundles
		else
			params.AssetTypes = sub.types
		end
		params.SortType = SORTS[sortIndex][2]
		local ok, result = pcall(function()
			return AvatarEditorService:SearchCatalog(params)
		end)
		if token ~= searchToken then
			return
		end
		if not ok then
			setStatus("Gagal memuat katalog. Coba lagi sebentar.")
			return
		end
		local okPage, items = pcall(function()
			return result:GetCurrentPage()
		end)
		if token ~= searchToken then
			return
		end
		if not okPage or #items == 0 then
			setStatus("Tidak ada hasil.")
			return
		end
		pages = result
		setStatus(nil)
		appendPage(items)
	end)
end

local function loadMore()
	if loadingMore or not pages or pages.IsFinished then
		return
	end
	loadingMore = true
	local token = searchToken
	task.spawn(function()
		local ok = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if ok and token == searchToken then
			local okPage, items = pcall(function()
				return pages:GetCurrentPage()
			end)
			if okPage then
				appendPage(items)
			end
		end
		loadingMore = false
	end)
end

grid:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
	local maxY = grid.AbsoluteCanvasSize.Y - grid.AbsoluteWindowSize.Y
	if maxY > 0 and grid.CanvasPosition.Y > maxY - 240 then
		loadMore()
	end
end)

-- baris tab kategori + sub kategori
local catRefs, subRefs = {}, {}

local function refreshTabs()
	for i, refs in ipairs(catRefs) do
		setTheme(refs, i == catIndex and THEMES.Tab or THEMES.TabOff)
	end
	for i, refs in ipairs(subRefs) do
		setTheme(refs, i == subIndex and THEMES.Green or THEMES.Off)
	end
end

local function buildSubRow()
	for _, c in ipairs(subRow:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	table.clear(subRefs)
	for i, sub in ipairs(CATEGORIES[catIndex].subs) do
		local width = math.max(70, #sub.label * 9 + 28)
		local refs = glossyButton(subRow, UDim2.fromOffset(width, 26), THEMES.Off, sub.label, 12, { LayoutOrder = i })
		subRefs[i] = refs
		refs.button.Activated:Connect(function()
			if subIndex == i then
				return
			end
			subIndex = i
			refreshTabs()
			runSearch()
		end)
	end
	subRow.Visible = #CATEGORIES[catIndex].subs > 1
end

for i, cat in ipairs(CATEGORIES) do
	local width = math.max(86, #cat.name * 10 + 30)
	local refs = glossyButton(catRow, UDim2.fromOffset(width, 32), THEMES.TabOff, cat.name, 14, { LayoutOrder = i })
	catRefs[i] = refs
	refs.button.Activated:Connect(function()
		if catIndex == i then
			return
		end
		catIndex, subIndex = i, 1
		buildSubRow()
		refreshTabs()
		runSearch()
	end)
end

searchBox.FocusLost:Connect(function(enter)
	if enter and searchBox.Text ~= keyword then
		keyword = searchBox.Text
		runSearch()
	end
end)
sortRefs.button.Activated:Connect(function()
	sortIndex = sortIndex % #SORTS + 1
	sortRefs.label.Text = "Urut: " .. SORTS[sortIndex][1]
	runSearch()
end)

---------------------------------------------------------------------
-- BADAN: WARNA KULIT + UKURAN
---------------------------------------------------------------------
local skinButtons = {}
for i, color in ipairs(SKIN_COLORS) do
	local b = new("TextButton", {
		Name = "Skin" .. i,
		BackgroundColor3 = color,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = i,
		Parent = skinGrid,
	})
	corner(b, 10)
	local s = new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Enabled = false, Parent = b })
	skinButtons[i] = { button = b, stroke = s, color = color }
	b.Activated:Connect(function()
		body.skin = color
		refreshSkin()
		afterWornChanged()
	end)
end

function refreshSkin()
	for _, e in ipairs(skinButtons) do
		e.stroke.Enabled = body.skin ~= nil and colorKey(e.color) == colorKey(body.skin)
	end
end

skinResetRefs.button.Activated:Connect(function()
	body.skin = nil
	refreshSkin()
	afterWornChanged()
end)

local scaleRows = {}
local function scaleValue(def)
	local bundle = wornBundle()
	return (body.scale and body.scale[def.prop])
		or (bundle and bundle.scales and bundle.scales[def.prop])
		or (activeBase() and activeBase()[def.prop])
		or 1
end

function refreshScales()
	for _, r in ipairs(scaleRows) do
		r.value.Text = string.format("%.2f", scaleValue(r.def))
	end
end

local function adjustScale(def, dir)
	local v = math.clamp(math.round((scaleValue(def) + dir * def.step) * 100) / 100, def.min, def.max)
	body.scale = body.scale or {}
	body.scale[def.prop] = v
	if def.also then
		body.scale[def.also] = v
	end
	refreshScales()
	afterWornChanged()
end

for i, def in ipairs(SCALES) do
	local row = new("Frame", {
		Position = UDim2.fromOffset(0, 44 + (i - 1) * 52),
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = P.Bar,
		Parent = scaleFrame,
	})
	corner(row, 8)
	new("TextLabel", {
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(0.4, 0, 1, 0),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT,
		TextSize = 15,
		TextColor3 = P.Text,
		Text = def.label,
		Parent = row,
	})
	local plus = glossyButton(row, UDim2.fromOffset(40, 32), THEMES.Green, "+", 20, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0) })
	local value = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -56, 0.5, 0),
		Size = UDim2.fromOffset(70, 32),
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 16,
		TextColor3 = P.Text,
		Text = "1.00",
		Parent = row,
	})
	local minus = glossyButton(row, UDim2.fromOffset(40, 32), THEMES.Off, "-", 20, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -130, 0.5, 0) })
	table.insert(scaleRows, { def = def, value = value })
	plus.button.Activated:Connect(function()
		adjustScale(def, 1)
	end)
	minus.button.Activated:Connect(function()
		adjustScale(def, -1)
	end)
end

scaleResetRefs.button.Activated:Connect(function()
	body.scale = nil
	refreshScales()
	afterWornChanged()
end)

---------------------------------------------------------------------
-- TEMA
---------------------------------------------------------------------
---------------------------------------------------------------------
-- SALIN AVATAR PEMAIN LAIN
---------------------------------------------------------------------
local function setCopyStatus(text, isError)
	copyStatus.Text = text or ""
	copyStatus.TextColor3 = isError and P.Error or P.Muted
end

local copying = false
local function startCopy(userId, knownName)
	if copying then
		return
	end
	copying = true
	setCopyStatus("Memuat avatar...")
	task.spawn(function()
		local okD, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		local name = knownName
		if not name then
			local okN, n = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			name = okN and n or tostring(userId)
		end
		copying = false
		if not (okD and desc) then
			setCopyStatus("Gagal memuat avatar. Cek UserId / username-nya.", true)
			return
		end
		copied = { id = userId, name = name, desc = desc }
		table.clear(worn)
		table.clear(removed)
		body.skin, body.scale = nil, nil
		computeOriginals()
		refreshSkin()
		refreshScales()
		setCopyStatus("Memakai avatar @" .. name)
		toast("Memakai avatar @" .. name)
		afterWornChanged()
	end)
end

stopCopy = function()
	if not copied then
		return
	end
	copied = nil
	table.clear(worn)
	table.clear(removed)
	body.skin, body.scale = nil, nil
	computeOriginals()
	refreshSkin()
	refreshScales()
	setCopyStatus("Kembali ke avatarmu")
	toast("Kembali ke avatarmu")
	afterWornChanged()
end

local function submitCopy()
	local text = copyBox.Text:match("^%s*(.-)%s*$") or ""
	text = text:gsub("^@", "")
	if text == "" then
		setCopyStatus("Isi UserId atau username dulu.", true)
		return
	end
	local id = tonumber(text)
	if id then
		startCopy(math.floor(id))
		return
	end
	setCopyStatus("Mencari pemain...")
	task.spawn(function()
		local ok, userId = pcall(function()
			return Players:GetUserIdFromNameAsync(text)
		end)
		if ok and userId then
			startCopy(userId, text)
		else
			setCopyStatus("Username tidak ketemu.", true)
		end
	end)
end
copyGoRefs.button.Activated:Connect(submitCopy)
copyBox.FocusLost:Connect(function(enter)
	if enter then
		submitCopy()
	end
end)
copyBackRefs.button.Activated:Connect(function()
	if copied then
		stopCopy()
	else
		setCopyStatus("Kamu sudah memakai avatarmu sendiri.")
	end
end)

refreshPlayerList = function()
	for _, c in ipairs(copyList:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local n = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player then
			n += 1
			local row = new("TextButton", {
				Name = "Row",
				Size = UDim2.new(1, 0, 0, 46),
				BackgroundColor3 = P.Input,
				Text = "",
				AutoButtonColor = true,
				LayoutOrder = n,
				Parent = copyList,
			})
			corner(row, 8)
			local head = new("ImageLabel", {
				Position = UDim2.fromOffset(6, 5),
				Size = UDim2.fromOffset(36, 36),
				BackgroundColor3 = P.Card,
				Image = thumbUrl(plr.UserId, "AvatarHeadShot"),
				Parent = row,
			})
			corner(head, 18)
			new("TextLabel", {
				Position = UDim2.fromOffset(52, 0),
				Size = UDim2.new(1, -60, 1, 0),
				BackgroundTransparency = 1,
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = FONT,
				TextSize = 14,
				TextColor3 = P.Text,
				Text = string.format("%s  (@%s)", plr.DisplayName, plr.Name),
				Parent = row,
			})
			row.Activated:Connect(function()
				startCopy(plr.UserId, plr.Name)
			end)
		end
	end
	if n == 0 then
		new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundTransparency = 1,
			Font = FONT_REGULAR,
			TextSize = 12,
			TextColor3 = P.Muted,
			Text = "Belum ada pemain lain di game ini. Pakai kotak di atas.",
			Parent = copyList,
		})
	end
end
Players.PlayerAdded:Connect(function()
	if copyFrame.Visible then
		refreshPlayerList()
	end
end)
Players.PlayerRemoving:Connect(function()
	task.defer(function()
		if copyFrame.Visible then
			refreshPlayerList()
		end
	end)
end)

local currentTheme = DEFAULT_THEME
local swatchStrokes = {}

local function refreshSwatches()
	for name, s in pairs(swatchStrokes) do
		s.Enabled = name == currentTheme
	end
end

local function loadTeamThemes()
	local list = {}
	local ok, folder = pcall(function()
		local salon = workspace:WaitForChild("SALON MUSIC BY OCTA", 5)
		return salon and salon:WaitForChild("TEAMS", 5)
	end)
	if ok and folder then
		local order = {}
		for i, t in ipairs(TEAM_FALLBACK) do
			order[t.name] = i
		end
		for _, g in ipairs(folder:GetChildren()) do
			if g:IsA("UIGradient") then
				table.insert(list, { name = g.Name, color = g.Color })
			end
		end
		table.sort(list, function(a, b)
			local oa, ob = order[a.name] or 99, order[b.name] or 99
			if oa ~= ob then
				return oa < ob
			end
			return a.name < b.name
		end)
	end
	if #list == 0 then
		list = TEAM_FALLBACK
	end
	return list
end

local function buildThemeSwatches(list)
	for i, theme in ipairs(list) do
		local button = new("TextButton", {
			Name = theme.name,
			BackgroundColor3 = WHITE,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = i,
			Parent = themeGrid,
		})
		corner(button, 8)
		new("UIGradient", { Color = theme.color, Rotation = 90, Parent = button })
		local kp = theme.color.Keypoints
		local mid = kp[math.min(2, #kp)].Value
		new("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = theme.name,
			Font = FONT,
			TextSize = 15,
			TextColor3 = lum(mid) > 0.6 and rgb(35, 25, 10) or WHITE,
			ZIndex = 2,
			Parent = button,
		})
		swatchStrokes[theme.name] = new("UIStroke", {
			Color = WHITE,
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Enabled = false,
			Parent = button,
		})
		button.Activated:Connect(function()
			if currentTheme == theme.name then
				return
			end
			currentTheme = theme.name
			applyPalette(makePalette(theme.color))
			refreshSwatches()
		end)
	end
	refreshSwatches()
end
task.spawn(function()
	buildThemeSwatches(loadTeamThemes())
end)

---------------------------------------------------------------------
-- TAB UTAMA + BUKA/TUTUP
---------------------------------------------------------------------
local currentPage = "Katalog"
local function showPage(name)
	currentPage = name
	katalogPage.Visible = name == "Katalog"
	temaPage.Visible = name == "Tema"
	setTheme(tabKatalog, name == "Katalog" and THEMES.Tab or THEMES.TabOff)
	setTheme(tabTema, name == "Tema" and THEMES.Tab or THEMES.TabOff)
end
tabKatalog.button.Activated:Connect(function()
	showPage("Katalog")
end)
tabTema.button.Activated:Connect(function()
	showPage("Tema")
end)

-- warna yang dihitung di script (bukan dari tema) ikut diperbarui saat tema berganti
table.insert(themeListeners, function()
	showPage(currentPage)
	refreshTabs()
	refreshCells()
	refreshWornList()
	toastLabel.TextColor3 = P.Text
end)

local firstOpen = true
local function setOpen(open)
	main.Visible = open
	openRefs.button.Visible = not open
	if open and firstOpen then
		firstOpen = false
		refreshPreview()
		runSearch()
	end
end
openRefs.button.Activated:Connect(function()
	setOpen(true)
end)
closeButton.button.Activated:Connect(function()
	setOpen(false)
end)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or input.KeyCode ~= TOGGLE_KEY then
		return
	end
	setOpen(not main.Visible)
end)

-- karakter respawn: item buatan kita ikut hilang, jadi dipasang ulang
player.CharacterAdded:Connect(function(char)
	table.clear(stash)
	table.clear(mine)
	table.clear(overlays)
	baseModel = nil
	savedColors, origScale = nil, nil
	playingEmote = nil
	char:WaitForChild("Humanoid")
	task.wait(1.5)
	baseDesc = fetchBase()
	computeOriginals()
	refreshWornList()
	refreshScales()
	if anyChange() then
		refreshPreview()
	end
end)

buildSubRow()
refreshTabs()
showPage("Katalog")
refreshWornList()
refreshOutfits()
refreshSkin()
refreshScales()
task.spawn(function()
	baseDesc = fetchBase()
	computeOriginals()
	refreshWornList()
	refreshScales()
end)
