--[[
	Player Utility Panel (LocalScript)
	Letak: StarterPlayer > StarterPlayerScripts
	Fitur: Fly, Swim, Speed, Super Jump, Noclip, Freecam, Hide GUI, Teleport ke player lain,
	Mini Studio (Explorer / Properties / Select, semua di client), Piano Auto Player
	Semua jalan di client saja. Hide/show panel: RightShift
	Style UI: gelap + gradient merah (Workspace["SALON MUSIC BY OCTA"].TEAMS.Merah).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local DEFAULT_VALUES = {
	FlySpeed = 60,
	WalkSpeed = 50,
	JumpPower = 120,
	SwimSpeed = 40,
	FreecamSpeed = 40,
}
local VALUE_MIN, VALUE_MAX = 1, 500
local TOGGLE_PANEL_KEY = Enum.KeyCode.RightShift
local TELEPORT_OFFSET = CFrame.new(0, 2, 4) -- relatif ke target (4 stud di belakang)

-- true  = badan avatar ikut miring sesuai arah kamera (naik/turun/belok)
-- false = avatar hanya menghadap arah kamera secara horizontal
local FLY_TILT_WITH_CAMERA = true

local FREECAM = {
	LookDamping = 7, -- makin kecil = kamera meluncur makin lama setelah mouse berhenti
	LookPerPixel = 0.003, -- radian per pixel mouse (total, setelah inertia selesai)
	MoveSmooth = 7, -- makin kecil = gerak kamera meluncur makin lama
	ZoomSmooth = 10,
	ZoomStep = 0.88, -- tiap notch scroll
	FovMin = 5,
	FovMax = 120,
	FastKey = Enum.KeyCode.LeftShift,
	FastMultiplier = 3,
	UpKeys = { Enum.KeyCode.Space, Enum.KeyCode.E },
	DownKeys = { Enum.KeyCode.LeftControl, Enum.KeyCode.Q },
}

-- GUI yang tidak ikut disembunyikan oleh Hide GUI
local KEEP_VISIBLE_GUIS = { PlayerUtilityPanel = true, MiniStudio = true, TouchGui = true }

-- Asset yang diambil dari UI Inventory
local ASSETS = {
	Icon = "rbxassetid://87984575377587",
	Pattern = "rbxassetid://85409521137338",
	Studs = "rbxassetid://10509779001",
	Search = "rbxassetid://128971822092362",
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local enabled = {
	Fly = false, Swim = false, Speed = false, Jump = false,
	Noclip = false, Freecam = false, HideGui = false,
}
local values = table.clone(DEFAULT_VALUES)
local original = { WalkSpeed = 16, JumpPower = 50, UseJumpPower = true }

local character, humanoid, rootPart
local mover -- { attachment, velocity, align? } dipakai Fly & Swim
local noclipCache = {}
local controls

local freecam = {
	active = false,
	pos = Vector3.zero,
	yaw = 0, pitch = 0,
	yawVel = 0, pitchVel = 0,
	vel = Vector3.zero,
	fov = 70, targetFov = 70,
	prevFov = 70,
	prevType = Enum.CameraType.Custom,
	rmb = false,
	pinchBase = 70,
	frozenRoot = nil,
	wasAnchored = false,
}

local hideGui = { saved = {}, conns = {}, childConn = nil, core = nil, world = {}, worldConn = nil }

-- Ambil ControlModule bawaan Roblox (support keyboard, gamepad, mobile)
task.spawn(function()
	local ok, result = pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts")
		return require(playerScripts:WaitForChild("PlayerModule", 15)):GetControls()
	end)
	if ok then
		controls = result
	end
end)

---------------------------------------------------------------------
-- INPUT HELPERS
---------------------------------------------------------------------
local function anyKeyDown(keys)
	for _, key in ipairs(keys) do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

-- Vektor gerak relatif kamera (x = kanan, z = maju negatif), dari WASD / thumbstick
local function getMoveVector(): Vector3
	if controls then
		local ok, v = pcall(controls.GetMoveVector, controls)
		if ok and typeof(v) == "Vector3" then
			return v
		end
	end
	if UserInputService:GetFocusedTextBox() then
		return Vector3.zero
	end
	local x = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	local z = (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
	return Vector3.new(x, 0, z)
end

-- Arah terbang/renang: 100% dari kamera (termasuk pitch), jadi lihat atas = naik, lihat bawah = turun
local function getInputDirection(): Vector3
	if enabled.Freecam then
		return Vector3.zero
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return Vector3.zero
	end
	local dir = cam.CFrame:VectorToWorldSpace(getMoveVector())
	if dir.Magnitude > 1 then
		dir = dir.Unit
	end
	return dir
end

---------------------------------------------------------------------
-- MOVER (LinearVelocity) untuk Fly & Swim
---------------------------------------------------------------------
local function destroyMover()
	if mover then
		for _, inst in pairs(mover) do
			inst:Destroy()
		end
		mover = nil
	end
end

local function createMover(withAlign: boolean)
	destroyMover()
	if not rootPart then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "UtilityAttachment"
	attachment.Parent = rootPart

	local lv = Instance.new("LinearVelocity")
	lv.Name = "UtilityVelocity"
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = rootPart

	mover = { attachment = attachment, velocity = lv }

	if withAlign then
		local ao = Instance.new("AlignOrientation")
		ao.Name = "UtilityAlign"
		ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		ao.Attachment0 = attachment
		ao.MaxTorque = math.huge
		ao.Responsiveness = 25
		ao.Parent = rootPart
		mover.align = ao
	end
end

---------------------------------------------------------------------
-- FREECAM HELPERS
---------------------------------------------------------------------
local function freezeCharacter()
	if rootPart and freecam.frozenRoot ~= rootPart then
		freecam.frozenRoot = rootPart
		freecam.wasAnchored = rootPart.Anchored
		rootPart.Anchored = true
	end
end

local function unfreezeCharacter()
	if freecam.frozenRoot then
		if freecam.frozenRoot.Parent then
			freecam.frozenRoot.Anchored = freecam.wasAnchored
		end
		freecam.frozenRoot = nil
	end
end

local function addLookImpulse(dx: number, dy: number)
	-- makin zoom-in makin pelan rotasinya
	local scale = math.clamp(freecam.fov / 70, 0.15, 1.5)
	local impulse = FREECAM.LookPerPixel * FREECAM.LookDamping * scale
	freecam.yawVel -= dx * impulse
	freecam.pitchVel -= dy * impulse
end

---------------------------------------------------------------------
-- HIDE GUI HELPERS
---------------------------------------------------------------------
local function hideScreenGui(sg: ScreenGui)
	if KEEP_VISIBLE_GUIS[sg.Name] or hideGui.saved[sg] ~= nil then
		return
	end
	hideGui.saved[sg] = sg.Enabled
	sg.Enabled = false
	hideGui.conns[sg] = sg:GetPropertyChangedSignal("Enabled"):Connect(function()
		-- kalau script game menyalakan lagi saat Hide GUI aktif, ingat lalu sembunyikan lagi
		if enabled.HideGui and sg.Enabled then
			hideGui.saved[sg] = true
			sg.Enabled = false
		end
	end)
end

-- UI yang ada di dalam map: BillboardGui (nametag/overhead) dan SurfaceGui (layar di part)
local function hideWorldGui(g: Instance)
	if (g:IsA("BillboardGui") or g:IsA("SurfaceGui")) and hideGui.world[g] == nil then
		hideGui.world[g] = g.Enabled
		g.Enabled = false
	end
end

---------------------------------------------------------------------
-- FEATURES
---------------------------------------------------------------------
local features = {}

function features.Fly(on: boolean)
	if on then
		if not (humanoid and rootPart) then
			return
		end
		createMover(true)
		humanoid.PlatformStand = true
	else
		destroyMover()
		if humanoid then
			humanoid.PlatformStand = false
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
end

function features.Swim(on: boolean)
	if on then
		if not (humanoid and rootPart) then
			return
		end
		createMover(false)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
	else
		destroyMover()
		if humanoid then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end
end

function features.Speed(on: boolean)
	if humanoid then
		humanoid.WalkSpeed = on and values.WalkSpeed or original.WalkSpeed
	end
end

function features.Jump(on: boolean)
	if not humanoid then
		return
	end
	if on then
		humanoid.UseJumpPower = true
		humanoid.JumpPower = values.JumpPower
	else
		humanoid.JumpPower = original.JumpPower
		humanoid.UseJumpPower = original.UseJumpPower
	end
end

function features.Noclip(on: boolean)
	if not on then
		-- kembalikan hanya part yang tadi kita matikan collision-nya
		for part in pairs(noclipCache) do
			if part.Parent then
				part.CanCollide = true
			end
		end
		table.clear(noclipCache)
	end
end

function features.Freecam(on: boolean)
	if on then
		if freecam.active then
			freezeCharacter() -- dipanggil ulang saat respawn
			return
		end
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		freecam.active = true
		freecam.prevType = cam.CameraType == Enum.CameraType.Scriptable and Enum.CameraType.Custom or cam.CameraType
		freecam.prevFov = cam.FieldOfView
		local rx, ry = cam.CFrame:ToOrientation()
		freecam.pitch, freecam.yaw = rx, ry
		freecam.pos = cam.CFrame.Position
		freecam.yawVel, freecam.pitchVel = 0, 0
		freecam.vel = Vector3.zero
		freecam.fov, freecam.targetFov = cam.FieldOfView, cam.FieldOfView
		cam.CameraType = Enum.CameraType.Scriptable
		freezeCharacter()
	else
		if not freecam.active then
			return
		end
		freecam.active = false
		freecam.rmb = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		unfreezeCharacter()
		local cam = workspace.CurrentCamera
		if cam then
			cam.FieldOfView = freecam.prevFov
			cam.CameraType = freecam.prevType
			if humanoid then
				cam.CameraSubject = humanoid
			end
		end
	end
end

function features.HideGui(on: boolean)
	if on then
		for _, child in ipairs(playerGui:GetChildren()) do
			if child:IsA("ScreenGui") then
				hideScreenGui(child)
			end
		end
		if not hideGui.childConn then
			hideGui.childConn = playerGui.ChildAdded:Connect(function(child)
				if enabled.HideGui and child:IsA("ScreenGui") then
					hideScreenGui(child)
				end
			end)
		end
		-- UI di dalam map (BillboardGui / SurfaceGui)
		for _, inst in ipairs(workspace:GetDescendants()) do
			hideWorldGui(inst)
		end
		if not hideGui.worldConn then
			hideGui.worldConn = workspace.DescendantAdded:Connect(function(inst)
				if enabled.HideGui then
					hideWorldGui(inst)
				end
			end)
		end
		-- CoreGui (chat, leaderboard, backpack, dll)
		if not hideGui.core then
			hideGui.core = {}
			for _, coreType in ipairs(Enum.CoreGuiType:GetEnumItems()) do
				if coreType ~= Enum.CoreGuiType.All then
					local ok, state = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, coreType)
					if ok then
						hideGui.core[coreType] = state
					end
				end
			end
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.All, false)
		end
	else
		if hideGui.childConn then
			hideGui.childConn:Disconnect()
			hideGui.childConn = nil
		end
		for sg, conn in pairs(hideGui.conns) do
			conn:Disconnect()
		end
		table.clear(hideGui.conns)
		for sg, wasEnabled in pairs(hideGui.saved) do
			if sg.Parent then
				sg.Enabled = wasEnabled
			end
		end
		table.clear(hideGui.saved)
		if hideGui.worldConn then
			hideGui.worldConn:Disconnect()
			hideGui.worldConn = nil
		end
		for g, wasEnabled in pairs(hideGui.world) do
			if g.Parent then
				g.Enabled = wasEnabled
			end
		end
		table.clear(hideGui.world)
		if hideGui.core then
			for coreType, state in pairs(hideGui.core) do
				pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, state)
			end
			hideGui.core = nil
		end
	end
end

---------------------------------------------------------------------
-- UI HELPERS (style dari StarterGui.Inventory)
---------------------------------------------------------------------
local rgb = Color3.fromRGB
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local FONT = Enum.Font.MontserratBold
local FONT_REGULAR = Enum.Font.Montserrat

---------------------------------------------------------------------
-- PALET TEMA
-- Gradient tema diambil dari Workspace["SALON MUSIC BY OCTA"].TEAMS.
-- Semua warna UI diturunkan dari gradient itu, jadi bisa diganti kapan saja.
---------------------------------------------------------------------
local DEFAULT_THEME = "Merah"
local function teamGradient(c0: Color3, c1: Color3, c2: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, c0),
		ColorSequenceKeypoint.new(0.38, c1),
		ColorSequenceKeypoint.new(1, c2),
	})
end
-- Cadangan kalau folder TEAMS tidak ketemu (isi sama dengan folder TEAMS)
local TEAM_FALLBACK = {
	{ name = "Merah", color = teamGradient(rgb(255, 0, 0), rgb(255, 53, 26), rgb(185, 0, 0)) },
	{ name = "Kuning", color = teamGradient(rgb(255, 220, 78), rgb(255, 220, 78), rgb(255, 155, 67)) },
	{ name = "Biru", color = teamGradient(rgb(0, 255, 247), rgb(26, 244, 255), rgb(51, 185, 156)) },
	{ name = "Hijau", color = teamGradient(rgb(0, 221, 0), rgb(64, 185, 50), rgb(39, 104, 32)) },
	{ name = "Merahmudah", color = teamGradient(rgb(255, 116, 218), rgb(226, 118, 203), rgb(182, 106, 169)) },
	{ name = "Birugelap", color = teamGradient(rgb(0, 13, 194), rgb(0, 4, 255), rgb(11, 17, 120)) },
	{ name = "Ungu", color = teamGradient(rgb(145, 35, 255), rgb(153, 28, 255), rgb(105, 58, 185)) },
}

local function lum(c: Color3): number
	return 0.299 * c.R + 0.587 * c.G + 0.114 * c.B
end
local function scale(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end
local NEAR_BLACK = rgb(10, 8, 9)
local function dark(base: Color3, k: number): Color3
	return NEAR_BLACK:Lerp(base, k)
end
local function colorKey(c: Color3): string
	return string.format("%d,%d,%d", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
end
local function seqKey(s: ColorSequence): string
	local parts = {}
	for _, k in ipairs(s.Keypoints) do
		table.insert(parts, string.format("%.3f:%s", k.Time, colorKey(k.Value)))
	end
	return table.concat(parts, "|")
end

local PALETTE_KEYS = {
	"Bg", "Card", "Bar", "Input", "Section", "Line", "Hover", "Stroke", "Border", "Accent", "Placeholder",
	"Muted", "Text", "OffText", "TabText", "OnPrimary", "Selected", "Dark", "CloseHover", "SelBox", "HoverBox",
}
local function makePalette(seq: ColorSequence)
	local kp = seq.Keypoints
	local c0, c2 = kp[1].Value, kp[#kp].Value
	local c1 = kp[math.min(2, #kp)].Value
	local base = c0:Lerp(c2, 0.5)
	local bright = lum(c1) > 0.6 -- gradient terang (kuning, cyan) pakai teks gelap
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
		SelBox = c0:Lerp(WHITE, 0.15),
		HoverBox = c0:Lerp(WHITE, 0.5),
	}
	-- tiap warna dibuat unik (beda 1-2 angka, tidak kelihatan) supaya bisa dipetakan saat ganti tema
	local used = { ["255,255,255"] = true, ["0,0,0"] = true, ["225,225,225"] = true, ["255,95,95"] = true, ["120,0,0"] = true }
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

-- P = palet aktif (tabel ini diubah isinya saat ganti tema, jangan diganti tabelnya)
local P = makePalette(TEAM_FALLBACK[1].color)

-- Tema tombol: color = gradient, text = warna teks, transparent = tanpa background
local PRIMARY = { color = P.Primary, text = P.OnPrimary }
local THEMES = {
	Green = PRIMARY,
	Teal = PRIMARY,
	Purple = PRIMARY,
	Yellow = PRIMARY,
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

local themeRoots = {} -- ScreenGui yang ikut diwarnai ulang
local themeSkip = {} -- bagian yang tidak boleh diwarnai ulang (contoh: kotak pilihan tema)
local themeListeners = {} -- dipanggil setelah tema berubah
local THEMED_PROPS = { "BackgroundColor3", "TextColor3", "PlaceholderColor3", "ImageColor3", "ScrollBarImageColor3", "Color3" }

local function isSkipped(inst: Instance): boolean
	for _, skip in ipairs(themeSkip) do
		if inst == skip or inst:IsDescendantOf(skip) then
			return true
		end
	end
	return false
end

-- Ganti tema: warna lama di semua GUI dipetakan ke warna baru dengan nama yang sama
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
							return (inst :: any)[prop]
						end)
						if ok and typeof(value) == "Color3" then
							local mapped = colorMap[colorKey(value)]
							if mapped then
								(inst :: any)[prop] = mapped
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

local function new(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function corner(parent: Instance, radius: number)
	return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(parent: Instance, color: Color3, thickness: number, mode: Enum.ApplyStrokeMode?, transparency: number?, join: Enum.LineJoinMode?)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness,
		ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border,
		Transparency = transparency or 0,
		LineJoinMode = join or Enum.LineJoinMode.Round,
		Parent = parent,
	})
end

local function gradient(parent: Instance, top: Color3, bottom: Color3)
	return new("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = 90, Parent = parent })
end

-- Background putih + gradient tema (warna asli datang dari gradient)
local function redGradient(parent: Instance): UIGradient
	return new("UIGradient", { Color = P.Primary, Rotation = 90, Parent = parent })
end

local function setTheme(refs, theme)
	refs.theme = theme
	refs.gradient.Color = theme.color
	refs.button.BackgroundTransparency = theme.transparent and 1 or 0
	refs.label.TextColor3 = theme.text
end

-- Tombol gradient: rounded, teks tebal, tanpa studs (gaya panel musik)
local function glossyButton(parent: Instance, size: UDim2, theme, text: string, textSize: number, extra: { [string]: any }?)
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
-- UI STATE
---------------------------------------------------------------------
local toggleRefs = {}
local hintLabel
local statusActive = false
local HINT_DEFAULT = "RightShift = hide/show panel"

local function currentHint(): string
	if enabled.Freecam then
		return "Freecam: tahan klik kanan = lihat | scroll = zoom | WASD + E/Q naik/turun | Shift = cepat"
	elseif enabled.Fly then
		return "Fly: arahkan kamera untuk naik / turun / belok, tahan W untuk maju"
	elseif enabled.Swim then
		return "Swim: arahkan kamera untuk naik / turun / belok, tahan W untuk maju"
	end
	return HINT_DEFAULT
end

local function refreshUI()
	for name, refs in pairs(toggleRefs) do
		local on = enabled[name]
		refs.label.Text = on and "ON" or "OFF"
		setTheme(refs, on and THEMES.Green or THEMES.Off)
	end
	if hintLabel and not statusActive then
		hintLabel.Text = currentHint()
	end
end

local function setEnabled(name: string, on: boolean)
	if enabled[name] == on then
		return
	end
	-- Fly dan Swim saling eksklusif
	if on then
		if name == "Fly" and enabled.Swim then
			enabled.Swim = false
			features.Swim(false)
		elseif name == "Swim" and enabled.Fly then
			enabled.Fly = false
			features.Fly(false)
		end
	end
	enabled[name] = on
	features[name](on)
	refreshUI()
end

---------------------------------------------------------------------
-- LOOPS
---------------------------------------------------------------------
-- Noclip: harus sebelum physics step
RunService.Stepped:Connect(function()
	if not enabled.Noclip or not character then
		return
	end
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			noclipCache[part] = true
			part.CanCollide = false
		end
	end
end)

-- Fly / Swim: velocity + orientasi avatar mengikuti kamera
local function updateMover()
	if not (mover and mover.velocity.Parent and rootPart) then
		return
	end
	local dir = getInputDirection()
	local speed = enabled.Fly and values.FlySpeed or values.SwimSpeed
	mover.velocity.VectorVelocity = dir * speed

	if mover.align and mover.align.Parent and not enabled.Freecam then
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local camCF = cam.CFrame
		if FLY_TILT_WITH_CAMERA and dir.Magnitude > 0.1 then
			-- badan sejajar arah kamera: lihat atas = tegak, lihat lurus ke depan = rebah (perut ke bawah), lihat bawah = menukik
			mover.align.CFrame = camCF.Rotation * CFrame.Angles(-math.pi / 2, 0, 0)
		else
			local look = camCF.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.001 then
				mover.align.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
			end
		end
	end
end

-- Freecam: rotasi + gerak + zoom, semuanya dengan inertia (meluncur halus saat input berhenti)
local function updateFreecam(dt: number)
	if not freecam.active then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end

	-- rotasi: kecepatan sudut meluruh pelan-pelan setelah mouse berhenti
	freecam.yaw += freecam.yawVel * dt
	local maxPitch = math.rad(89)
	local newPitch = freecam.pitch + freecam.pitchVel * dt
	if math.abs(newPitch) >= maxPitch then
		newPitch = math.clamp(newPitch, -maxPitch, maxPitch)
		freecam.pitchVel = 0
	end
	freecam.pitch = newPitch
	local damp = math.exp(-FREECAM.LookDamping * dt)
	freecam.yawVel *= damp
	freecam.pitchVel *= damp
	local rot = CFrame.fromOrientation(freecam.pitch, freecam.yaw, 0)

	-- gerak
	local mv = getMoveVector()
	local wish = rot:VectorToWorldSpace(Vector3.new(mv.X, 0, mv.Z))
	if not UserInputService:GetFocusedTextBox() then
		local vertical = 0
		if anyKeyDown(FREECAM.UpKeys) then
			vertical += 1
		end
		if anyKeyDown(FREECAM.DownKeys) then
			vertical -= 1
		end
		wish += Vector3.new(0, vertical, 0)
	end
	if wish.Magnitude > 1 then
		wish = wish.Unit
	end
	local speed = values.FreecamSpeed
	if UserInputService:IsKeyDown(FREECAM.FastKey) then
		speed *= FREECAM.FastMultiplier
	end
	freecam.vel = freecam.vel:Lerp(wish * speed, 1 - math.exp(-FREECAM.MoveSmooth * dt))
	freecam.pos += freecam.vel * dt

	-- zoom (FOV) halus
	freecam.fov += (freecam.targetFov - freecam.fov) * (1 - math.exp(-FREECAM.ZoomSmooth * dt))
	cam.FieldOfView = freecam.fov
	cam.CFrame = CFrame.new(freecam.pos) * rot
end

RunService.RenderStepped:Connect(function(dt)
	updateMover()
	updateFreecam(dt)
end)

-- Speed / Jump / Swim state dijaga supaya tidak ditimpa script game
RunService.Heartbeat:Connect(function()
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	if enabled.Speed and humanoid.WalkSpeed ~= values.WalkSpeed then
		humanoid.WalkSpeed = values.WalkSpeed
	end
	if enabled.Jump then
		if not humanoid.UseJumpPower then
			humanoid.UseJumpPower = true
		end
		if humanoid.JumpPower ~= values.JumpPower then
			humanoid.JumpPower = values.JumpPower
		end
	end
	if enabled.Swim and humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
		humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
	end
end)

-- Input freecam: klik kanan tahan = lihat, scroll = zoom, touch drag = lihat, pinch = zoom
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if freecam.active and not gameProcessed and input.UserInputType == Enum.UserInputType.MouseButton2 then
		freecam.rmb = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 and freecam.rmb then
		freecam.rmb = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if not freecam.active then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		if freecam.rmb then
			addLookImpulse(input.Delta.X, input.Delta.Y)
		end
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		if not gameProcessed then
			freecam.targetFov = math.clamp(
				freecam.targetFov * FREECAM.ZoomStep ^ input.Position.Z,
				FREECAM.FovMin, FREECAM.FovMax
			)
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		if not gameProcessed then
			addLookImpulse(input.Delta.X, input.Delta.Y)
		end
	end
end)

UserInputService.TouchPinch:Connect(function(_, scale, _, state, gameProcessed)
	if not freecam.active or gameProcessed then
		return
	end
	if state == Enum.UserInputState.Begin then
		freecam.pinchBase = freecam.targetFov
	elseif state == Enum.UserInputState.Change then
		freecam.targetFov = math.clamp(freecam.pinchBase / math.max(scale, 0.01), FREECAM.FovMin, FREECAM.FovMax)
	end
end)

---------------------------------------------------------------------
-- CHARACTER LIFECYCLE
---------------------------------------------------------------------
local function onCharacterAdded(char: Model)
	local hum = char:WaitForChild("Humanoid") :: Humanoid
	local root = char:WaitForChild("HumanoidRootPart") :: BasePart
	if player.Character ~= char then
		return
	end

	character, humanoid, rootPart = char, hum, root
	mover = nil
	table.clear(noclipCache)

	original.WalkSpeed = hum.WalkSpeed
	original.JumpPower = hum.JumpPower
	original.UseJumpPower = hum.UseJumpPower

	-- pasang ulang fitur yang masih ON setelah respawn (Hide GUI tidak bergantung karakter)
	for name, on in pairs(enabled) do
		if on and name ~= "HideGui" then
			features[name](true)
		end
	end
end

player.CharacterRemoving:Connect(function()
	destroyMover()
	table.clear(noclipCache)
	freecam.frozenRoot = nil
	character, humanoid, rootPart = nil, nil, nil
end)
player.CharacterAdded:Connect(onCharacterAdded)

---------------------------------------------------------------------
-- UI BUILD
---------------------------------------------------------------------
local ROW_HEIGHT, ROW_GAP, FEATURE_ROWS = 36, 6, 7
local FEATURES_HEIGHT = FEATURE_ROWS * ROW_HEIGHT + (FEATURE_ROWS - 1) * ROW_GAP + 16
local LIST_HEIGHT = 84
local CONTENT_GAP = 8
local CONTENT_HEIGHT = FEATURES_HEIGHT + 24 + 40 + LIST_HEIGHT + 30 + CONTENT_GAP * 4
local PAGE_TOP = 100 -- di bawah header (58) + baris tab (34) + jarak
local PANEL_HEIGHT = PAGE_TOP + CONTENT_HEIGHT + 10

local old = playerGui:FindFirstChild("PlayerUtilityPanel")
if old then
	old:Destroy()
end

local gui = new("ScreenGui", {
	Name = "PlayerUtilityPanel",
	ResetOnSpawn = false,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

-- Panel utama (BG 18,28,48 / stroke hitam 3 / corner 10 seperti Inventory)
local main = new("Frame", {
	Name = "Panel",
	Size = UDim2.fromOffset(340, PANEL_HEIGHT),
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 20, 0.5, 0),
	BackgroundColor3 = P.Bg,
	BackgroundTransparency = 0,
	Parent = gui,
})
corner(main, 14)
stroke(main, P.Stroke, 2)

-- Panel mengecil otomatis kalau layar pendek
local uiScale = new("UIScale", { Parent = main })
local function updateScale()
	local cam = workspace.CurrentCamera
	if cam then
		uiScale.Scale = math.clamp((cam.ViewportSize.Y - 40) / PANEL_HEIGHT, 0.5, 1)
	end
end
updateScale()
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

-- Top bar (draggable): icon + judul
local top = new("Frame", {
	Name = "Top",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	ZIndex = 3,
	Parent = main,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 10),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = top,
})
new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = top })
new("ImageLabel", {
	Name = "Icon",
	Size = UDim2.fromOffset(40, 40),
	BackgroundTransparency = 1,
	Image = ASSETS.Icon,
	Visible = false,
	ZIndex = 3,
	LayoutOrder = 1,
	Parent = top,
})
local title = new("TextLabel", {
	Name = "Title",
	Text = "Player Utility",
	Size = UDim2.new(1, -110, 1, 0),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 22,
	TextColor3 = WHITE,
	ZIndex = 3,
	LayoutOrder = 2,
	Parent = top,
})

-- Tombol close (gradient merah)
local closeButton = new("TextButton", {
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -10, 0, 27),
	Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = WHITE,
	Text = "",
	AutoButtonColor = false,
	ZIndex = 6,
	Parent = main,
})
corner(closeButton, 8)
redGradient(closeButton)
-- teks di label terpisah supaya tidak ikut diwarnai gradient
new("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "X",
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextColor3 = P.OnPrimary,
	ZIndex = 7,
	Parent = closeButton,
})

-- Konten
local content = new("Frame", {
	Name = "Content",
	Position = UDim2.fromOffset(8, PAGE_TOP),
	Size = UDim2.new(1, -16, 0, CONTENT_HEIGHT),
	BackgroundTransparency = 1,
	ZIndex = 2,
	Parent = main,
})
new("UIListLayout", {
	Padding = UDim.new(0, CONTENT_GAP),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = content,
})

-- Container fitur (BG 8,14,28 transparan seperti Equipped/List)
local featuresFrame = new("Frame", {
	Name = "Features",
	Size = UDim2.new(1, 0, 0, FEATURES_HEIGHT),
	BackgroundColor3 = P.Card,
	BackgroundTransparency = 0,
	LayoutOrder = 1,
	Parent = content,
})
corner(featuresFrame, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = featuresFrame,
})
new("UIListLayout", {
	Padding = UDim.new(0, ROW_GAP),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = featuresFrame,
})

-- Hint / status
hintLabel = new("TextLabel", {
	Name = "Hint",
	Text = HINT_DEFAULT,
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	TextWrapped = true,
	Font = FONT,
	TextSize = 12,
	TextColor3 = P.Muted,
	LayoutOrder = 5,
	Parent = content,
})
local statusToken = 0
local function setStatus(text: string)
	statusToken += 1
	local token = statusToken
	statusActive = true
	hintLabel.Text = text
	task.delay(3, function()
		if token == statusToken then
			statusActive = false
			hintLabel.Text = currentHint()
		end
	end)
end

-- Baris fitur: label + (opsional) input angka + tombol toggle glossy
local function buildFeatureRow(order: number, featureName: string, label: string, valueKey: string?)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = featuresFrame,
	})

	local text = new("TextLabel", {
		Text = label,
		Size = UDim2.new(0, 120, 1, 0),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR,
		TextSize = 15,
		TextColor3 = WHITE,
		Parent = row,
	})

	local refs = glossyButton(row, UDim2.fromOffset(72, 30), THEMES.Off, "OFF", 15, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
	})
	toggleRefs[featureName] = refs
	refs.button.Activated:Connect(function()
		setEnabled(featureName, not enabled[featureName])
	end)

	if valueKey then
		local boxFrame = new("Frame", {
			Size = UDim2.fromOffset(60, 28),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -80, 0.5, 0),
			BackgroundColor3 = WHITE,
			Parent = row,
		})
		corner(boxFrame, 8)
		redGradient(boxFrame)
		local box = new("TextBox", {
			Text = tostring(values[valueKey]),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ClearTextOnFocus = false,
			Font = FONT,
			TextSize = 16,
			TextColor3 = P.OnPrimary,
			Parent = boxFrame,
		})
		box.FocusLost:Connect(function()
			local n = tonumber(box.Text)
			if n then
				values[valueKey] = math.clamp(n, VALUE_MIN, VALUE_MAX)
			end
			box.Text = tostring(values[valueKey])
		end)
	end
end

buildFeatureRow(1, "Fly", "Fly", "FlySpeed")
buildFeatureRow(2, "Swim", "Swim", "SwimSpeed")
buildFeatureRow(3, "Speed", "Speed", "WalkSpeed")
buildFeatureRow(4, "Jump", "Super Jump", "JumpPower")
buildFeatureRow(5, "Noclip", "Noclip", nil)
buildFeatureRow(6, "Freecam", "Freecam", "FreecamSpeed")
buildFeatureRow(7, "HideGui", "Hide GUI", nil)

-- Teleport section
local teleportTitle = new("TextLabel", {
	Text = "  Teleport to Player",
	TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 20,
	TextColor3 = WHITE,
	LayoutOrder = 2,
	Parent = content,
})

-- Search box (putih gradient + icon search seperti Inventory)
local searchFrame = new("Frame", {
	Name = "Search",
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundColor3 = WHITE,
	LayoutOrder = 3,
	Parent = content,
})
corner(searchFrame, 8)
redGradient(searchFrame)
new("ImageLabel", {
	Name = "Icon",
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.5, 0),
	Size = UDim2.fromOffset(24, 24),
	BackgroundTransparency = 1,
	Image = ASSETS.Search,
	ImageColor3 = P.OnPrimary,
	ScaleType = Enum.ScaleType.Fit,
	Parent = searchFrame,
})
local searchBox = new("TextBox", {
	Name = "Box",
	Position = UDim2.fromOffset(42, 0),
	Size = UDim2.new(1, -50, 1, 0),
	BackgroundTransparency = 1,
	Text = "",
	PlaceholderText = "Cari player...",
	PlaceholderColor3 = P.Placeholder,
	ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 18,
	TextColor3 = P.OnPrimary,
	Parent = searchFrame,
})

-- List player (scrolling, BG sama seperti List Inventory)
local listFrame = new("ScrollingFrame", {
	Name = "PlayerList",
	Size = UDim2.new(1, 0, 0, LIST_HEIGHT),
	BackgroundColor3 = P.Card,
	BackgroundTransparency = 0,
	BorderSizePixel = 0,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 5,
	ScrollBarImageColor3 = P.Accent,
	LayoutOrder = 4,
	Parent = content,
})
corner(listFrame, 10)
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = listFrame,
})
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 12),
	Parent = listFrame,
})

local function teleportToPlayer(target: Player)
	local targetChar = target.Character
	local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		setStatus(target.DisplayName .. " belum punya karakter.")
		return
	end
	if not (character and rootPart) then
		setStatus("Karakter kamu belum siap.")
		return
	end
	if enabled.Freecam then
		setStatus("Matikan Freecam dulu untuk teleport.")
		return
	end
	character:PivotTo(targetRoot.CFrame * TELEPORT_OFFSET)
	rootPart.AssemblyLinearVelocity = Vector3.zero
	setStatus("Teleport ke " .. target.DisplayName)
end

-- Kartu player: gradient merah + foto avatar + nama (gaya item playlist)
local CARD_COLOR = WHITE
local CARD_HOVER = rgb(225, 225, 225)

local function buildPlayerCard(plr: Player, order: number)
	local card = new("TextButton", {
		Name = plr.Name,
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = CARD_COLOR,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = order,
		Parent = listFrame,
	})
	corner(card, 8)
	redGradient(card)
	local avatar = new("ImageLabel", {
		Name = "Avatar",
		Position = UDim2.fromOffset(5, 5),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = P.Input,
		Image = "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=48&h=48",
		Parent = card,
	})
	corner(avatar, 6)
	new("TextLabel", {
		Name = "PlayerName",
		Text = plr.DisplayName,
		Position = UDim2.fromOffset(44, 4),
		Size = UDim2.new(1, -52, 0, 19),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = FONT,
		TextSize = 15,
		TextColor3 = P.OnPrimary,
		Parent = card,
	})
	new("TextLabel", {
		Name = "Username",
		Text = "@" .. plr.Name,
		Position = UDim2.fromOffset(44, 22),
		Size = UDim2.new(1, -52, 0, 15),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = FONT_REGULAR,
		TextSize = 12,
		TextColor3 = P.Placeholder,
		Parent = card,
	})

	card.MouseEnter:Connect(function() card.BackgroundColor3 = CARD_HOVER end)
	card.MouseLeave:Connect(function() card.BackgroundColor3 = CARD_COLOR end)
	card.Activated:Connect(function()
		teleportToPlayer(plr)
	end)
end

local function refreshPlayerList()
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("TextButton") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	local filter = string.lower(searchBox.Text)
	local list = Players:GetPlayers()
	table.sort(list, function(a, b)
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)

	local count = 0
	for _, plr in ipairs(list) do
		if plr ~= player then
			local text = string.format("%s (@%s)", plr.DisplayName, plr.Name)
			if filter == "" or string.find(string.lower(text), filter, 1, true) then
				count += 1
				buildPlayerCard(plr, count)
			end
		end
	end

	if count == 0 then
		new("TextLabel", {
			Text = "Tidak ada player lain",
			Size = UDim2.new(1, 0, 0, 38),
			BackgroundTransparency = 1,
			Font = FONT,
			TextSize = 16,
			TextColor3 = P.Muted,
			Parent = listFrame,
		})
	end
end

Players.PlayerAdded:Connect(function()
	task.defer(refreshPlayerList)
end)
Players.PlayerRemoving:Connect(function()
	task.defer(refreshPlayerList)
end)
searchBox:GetPropertyChangedSignal("Text"):Connect(refreshPlayerList)
refreshPlayerList()

---------------------------------------------------------------------
-- MINI STUDIO (Explorer / Properties / Select) - semua jalan di client
---------------------------------------------------------------------
-- Dibungkus satu fungsi supaya variabel-nya tidak menumpuk di scope utama script.
-- Perubahan properti / hapus instance cuma berlaku di layar pemain ini (client).
local function createMiniStudio()
	local CollectionService = game:GetService("CollectionService")
	local GuiService = game:GetService("GuiService")

	local api = { OnChanged = nil }

	-- Warna mengikuti tema panel (gelap + gradient merah TEAMS.Merah)
	local C = P -- palet tema bersama panel (ikut berubah saat ganti tema)
	local F = Enum.Font.Montserrat
	local FB = Enum.Font.MontserratBold
	local ROW_H = 22 -- tinggi baris Explorer
	local PROP_H = 24 -- tinggi baris Properties
	local NAME_W = 0.45 -- lebar kolom nama properti
	local SEARCH_LIMIT = 400 -- maksimal hasil filter Explorer
	local TOP_Z = 100000

	local state = {
		open = false,
		placed = false,
		selectMode = false,
		selected = nil,
		windows = { Explorer = true, Properties = true },
		zTop = 10,
		filter = "",
		filterAt = nil,
		dirty = true,
		lastBuild = 0,
		lastRender = 0,
		lastPropRefresh = 0,
		lastClickInst = nil,
		lastClickTime = 0,
		popup = nil,
	}
	local expanded = setmetatable({}, { __mode = "k" })
	local collapsedCats = {}
	local flat = {} -- daftar baris Explorer yang terlihat: { instance, depth }
	local pool = {} -- baris GUI yang dipakai ulang (virtual list)
	local propRows = {}
	local iconCache = {}

	-- Service yang bisa dilihat client, urutan seperti Explorer Studio
	local roots = {}
	for _, serviceName in ipairs({
		"Workspace", "Players", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage",
		"StarterGui", "StarterPack", "StarterPlayer", "Teams", "SoundService", "TextChatService", "Chat",
	}) do
		local ok, service = pcall(game.FindService, game, serviceName)
		if ok and service then
			table.insert(roots, service)
		end
	end

	local selectInstance, renderTree, rebuildProps, openContext -- dideklarasikan di bawah

	-----------------------------------------------------------------
	-- GUI DASAR
	-----------------------------------------------------------------
	local sgui = new("ScreenGui", {
		Name = "MiniStudio",
		ResetOnSpawn = false,
		DisplayOrder = 110,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})
	local adorns = new("Folder", { Name = "Adornments", Parent = sgui })
	local hoverBox = new("SelectionBox", {
		Name = "Hover",
		Color3 = C.HoverBox,
		LineThickness = 0.03,
		Transparency = 0.2,
		SurfaceTransparency = 1,
		Parent = adorns,
	})
	local selectBox = new("SelectionBox", {
		Name = "Selected",
		Color3 = C.SelBox,
		LineThickness = 0.06,
		SurfaceTransparency = 1,
		Parent = adorns,
	})
	local guiOutline = new("Frame", { Name = "GuiOutline", BackgroundTransparency = 1, Visible = false, ZIndex = 1, Parent = sgui })
	stroke(guiOutline, C.SelBox, 2, Enum.ApplyStrokeMode.Border, 0, Enum.LineJoinMode.Miter)

	local function text(parent: Instance, str: string, props: { [string]: any }?): TextLabel
		local label = new("TextLabel", {
			BackgroundTransparency = 1,
			Text = str,
			Font = F,
			TextSize = 14,
			TextColor3 = C.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = parent,
		})
		if props then
			for key, value in pairs(props) do
				label[key] = value
			end
		end
		return label
	end

	local function isA(inst: Instance, className: string): boolean
		local ok, result = pcall(inst.IsA, inst, className)
		return ok and result
	end

	local function safeName(inst: Instance): string
		local ok, name = pcall(function()
			return inst.Name
		end)
		return ok and name or "?"
	end

	local function childrenOf(inst: Instance): { Instance }
		local ok, children = pcall(inst.GetChildren, inst)
		return ok and children or {}
	end

	local function escapeRich(s: string): string
		return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
	end

	local function pathOf(inst: Instance): string
		local parts = {}
		local p = inst.Parent
		while p and p ~= game do
			table.insert(parts, 1, safeName(p))
			p = p.Parent
		end
		return table.concat(parts, ".")
	end

	-- Notifikasi kecil di bawah toolbar
	local toastLabel = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 54),
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.Bar,
		BackgroundTransparency = 0.05,
		Font = F,
		TextSize = 15,
		TextColor3 = WHITE,
		Visible = false,
		ZIndex = TOP_Z + 1,
		Parent = sgui,
	})
	corner(toastLabel, 6)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = toastLabel })
	local toastToken = 0
	local function toast(message: string, isError: boolean?)
		toastToken += 1
		local token = toastToken
		toastLabel.Text = message
		toastLabel.BackgroundColor3 = isError and rgb(120, 0, 0) or C.Bar
		toastLabel.Visible = true
		task.delay(2.5, function()
			if token == toastToken then
				toastLabel.Visible = false
			end
		end)
	end

	-- Drag umum (mouse + touch)
	local function onDrag(handle: GuiObject, begin: () -> any, move: (any, number, number) -> ())
		handle.InputBegan:Connect(function(input)
			local inputType = input.UserInputType
			if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
				return
			end
			local data = begin()
			local startPos = input.Position
			local moveConn = UserInputService.InputChanged:Connect(function(changed)
				if changed.UserInputType == Enum.UserInputType.MouseMovement or changed == input then
					local delta = changed.Position - startPos
					move(data, delta.X, delta.Y)
				end
			end)
			local endConn
			endConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					moveConn:Disconnect()
					endConn:Disconnect()
				end
			end)
		end)
	end

	local function bringToFront(frame: GuiObject)
		state.zTop += 1
		frame.ZIndex = state.zTop
	end

	-- Jendela ala Studio: title bar (geser), tombol X, pegangan resize di pojok kanan bawah
	local function makeWindow(name: string, titleText: string)
		local frame = new("Frame", {
			Name = name,
			Size = UDim2.fromOffset(260, 300),
			BackgroundColor3 = C.Bg,
			BorderSizePixel = 0,
			Active = true,
			Visible = false,
			ZIndex = state.zTop,
			Parent = sgui,
		})
		corner(frame, 10)
		stroke(frame, C.Border, 1.5)

		local bar = new("Frame", {
			Name = "TitleBar",
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			Active = true,
			Parent = frame,
		})
		corner(bar, 10)
		redGradient(bar)
		-- tutup sudut bawah title bar supaya rata dengan isi jendela
		local barFill = new("Frame", { Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10), BackgroundColor3 = C.Dark, BorderSizePixel = 0, Parent = bar })
		local titleLabel = text(bar, titleText, {
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -40, 1, 0),
			Font = FB,
			TextColor3 = C.OnPrimary,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})

		local close = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(24, 20),
			BackgroundColor3 = C.CloseHover,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "X",
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextColor3 = C.OnPrimary,
			Parent = bar,
		})
		close.MouseEnter:Connect(function()
			close.BackgroundTransparency = 0
			close.TextColor3 = C.OnPrimary
		end)
		close.MouseLeave:Connect(function()
			close.BackgroundTransparency = 1
			close.TextColor3 = C.OnPrimary
		end)

		local body = new("Frame", {
			Name = "Body",
			Position = UDim2.fromOffset(0, 26),
			Size = UDim2.new(1, 0, 1, -26),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Parent = frame,
		})

		local grip = new("TextButton", {
			Name = "Resize",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = C.Border,
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 20,
			Parent = frame,
		})

		onDrag(bar, function()
			bringToFront(frame)
			return frame.Position
		end, function(start, dx, dy)
			frame.Position = UDim2.new(start.X.Scale, start.X.Offset + dx, start.Y.Scale, start.Y.Offset + dy)
		end)
		frame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				bringToFront(frame)
			end
		end)

		-- Resize ala Windows: tekan tepi / sudut jendela lalu geser untuk membesar / mengecil
		local MIN_W, MIN_H, EDGE = 200, 140, 8
		local HALF = EDGE / 2
		local CORNER = 12
		local function resizeZone(left: boolean, right: boolean, topEdge: boolean, bottom: boolean, position: UDim2, size: UDim2)
			local zone = new("TextButton", {
				Name = "ResizeZone",
				Position = position,
				Size = size,
				BackgroundColor3 = C.Accent,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				ZIndex = 25,
				Parent = frame,
			})
			-- garis tipis menyala saat cursor di tepi, tanda bisa ditarik
			zone.MouseEnter:Connect(function()
				zone.BackgroundTransparency = 0.45
			end)
			zone.MouseLeave:Connect(function()
				zone.BackgroundTransparency = 1
			end)
			onDrag(zone, function()
				bringToFront(frame)
				return {
					x = frame.Position.X.Offset, y = frame.Position.Y.Offset,
					w = frame.Size.X.Offset, h = frame.Size.Y.Offset,
				}
			end, function(s, dx, dy)
				local x, y, w, h = s.x, s.y, s.w, s.h
				if right then
					w = math.max(MIN_W, s.w + dx)
				elseif left then
					w = math.max(MIN_W, s.w - dx)
					x = s.x + (s.w - w)
				end
				if bottom then
					h = math.max(MIN_H, s.h + dy)
				elseif topEdge then
					h = math.max(MIN_H, s.h - dy)
					y = s.y + (s.h - h)
				end
				frame.Position = UDim2.fromOffset(x, y)
				frame.Size = UDim2.fromOffset(w, h)
			end)
		end
		-- 4 tepi
		resizeZone(false, true, false, false, UDim2.new(1, -HALF, 0, CORNER - HALF), UDim2.new(0, EDGE, 1, -(CORNER * 2 - EDGE)))
		resizeZone(true, false, false, false, UDim2.new(0, -HALF, 0, CORNER - HALF), UDim2.new(0, EDGE, 1, -(CORNER * 2 - EDGE)))
		resizeZone(false, false, false, true, UDim2.new(0, CORNER - HALF, 1, -HALF), UDim2.new(1, -(CORNER * 2 - EDGE), 0, EDGE))
		resizeZone(false, false, true, false, UDim2.new(0, CORNER - HALF, 0, -HALF), UDim2.new(1, -(CORNER * 2 - EDGE), 0, EDGE))
		-- 4 sudut
		resizeZone(true, false, true, false, UDim2.fromOffset(-HALF, -HALF), UDim2.fromOffset(CORNER, CORNER))
		resizeZone(false, true, true, false, UDim2.new(1, HALF - CORNER, 0, -HALF), UDim2.fromOffset(CORNER, CORNER))
		resizeZone(true, false, false, true, UDim2.new(0, -HALF, 1, HALF - CORNER), UDim2.fromOffset(CORNER, CORNER))
		resizeZone(false, true, false, true, UDim2.new(1, HALF - CORNER, 1, HALF - CORNER), UDim2.fromOffset(CORNER, CORNER))

		return { frame = frame, body = body, title = titleLabel, close = close }
	end

	local function makeFilterBox(parent: Instance, placeholder: string): TextBox
		local holder = new("Frame", {
			Position = UDim2.fromOffset(4, 4),
			Size = UDim2.new(1, -8, 0, 22),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			Parent = parent,
		})
		corner(holder, 6)
		redGradient(holder)
		return new("TextBox", {
			Position = UDim2.fromOffset(6, 0),
			Size = UDim2.new(1, -12, 1, 0),
			BackgroundTransparency = 1,
			Text = "",
			PlaceholderText = placeholder,
			PlaceholderColor3 = P.Placeholder,
			ClearTextOnFocus = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = F,
			TextSize = 14,
			TextColor3 = C.OnPrimary,
			Parent = holder,
		})
	end

	local function makeList(parent: Instance): ScrollingFrame
		return new("ScrollingFrame", {
			Position = UDim2.fromOffset(0, 30),
			Size = UDim2.new(1, 0, 1, -30),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			ScrollBarThickness = 8,
			ScrollBarImageColor3 = C.Accent,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Parent = parent,
		})
	end

	local explorer = makeWindow("Explorer", "Explorer")
	local explorerFilter = makeFilterBox(explorer.body, "Filter workspace...")
	local tree = makeList(explorer.body)

	local properties = makeWindow("Properties", "Properties")
	local propFilter = makeFilterBox(properties.body, "Filter Properties")
	local propList = makeList(properties.body)
	propList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = propList })

	-----------------------------------------------------------------
	-- POPUP (dropdown enum + menu klik kanan)
	-----------------------------------------------------------------
	local function closePopup()
		if state.popup then
			state.popup:Destroy()
			state.popup = nil
		end
	end

	-- items = { { text, action, color?, current? } }
	local function openPopup(position: Vector2, width: number, items)
		closePopup()
		if #items == 0 then
			return
		end
		local holder = new("TextButton", {
			Name = "Popup",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			ZIndex = TOP_Z,
			Parent = sgui,
		})
		holder.Activated:Connect(closePopup)
		holder.MouseButton2Click:Connect(closePopup)

		local height = math.min(#items * 22, 264)
		local screen = sgui.AbsoluteSize
		local x = math.clamp(position.X, 0, math.max(0, screen.X - width))
		local y = position.Y
		if y + height > screen.Y then
			y = math.max(0, screen.Y - height)
		end
		local menu = new("ScrollingFrame", {
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(width, height),
			BackgroundColor3 = C.Bg,
			BorderSizePixel = 0,
			CanvasSize = UDim2.fromOffset(0, #items * 22),
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = C.Border,
			Active = true,
			Parent = holder,
		})
		corner(menu, 8)
		stroke(menu, C.Border, 1)
		for i, item in ipairs(items) do
			local base = item.current and 0 or 1
			local button = new("TextButton", {
				Position = UDim2.fromOffset(0, (i - 1) * 22),
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundColor3 = C.Hover,
				BackgroundTransparency = base,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				Parent = menu,
			})
			text(button, item.text, {
				Position = UDim2.fromOffset(8, 0),
				Size = UDim2.new(1, -12, 1, 0),
				TextSize = 14,
				TextColor3 = item.color or C.Text,
			})
			button.MouseEnter:Connect(function()
				button.BackgroundTransparency = 0
			end)
			button.MouseLeave:Connect(function()
				button.BackgroundTransparency = base
			end)
			button.Activated:Connect(function()
				closePopup()
				item.action()
			end)
		end
		state.popup = holder
	end

	-----------------------------------------------------------------
	-- EXPLORER (virtual list: hanya baris yang kelihatan yang dibuat)
	-----------------------------------------------------------------
	-- Icon asli Roblox: sprite rbxasset://textures/ClassImages.png (16x16 per icon, ikut terpasang di client Roblox)
	-- Index per class diambil dari ReflectionMetadata Roblox (ExplorerImageIndex)
	local CLASS_ICON_SPRITE = "rbxasset://textures/ClassImages.png"
	local CLASS_ICON_COUNT = 147 -- jumlah icon di sprite (lebar 2352 px)
	local CLASS_ICON_INDEX = {}
	for className, index in string.gmatch("Accessory=32,AccessoryDescription=104,Accoutrement=32,Actor=113,AdGui=145,AdPlacement=0,AdPortal=146,AlignOrientation=100,AlignPosition=99,AngularVelocity=103,Animation=60,AnimationController=60,AnimationTrack=60,Animator=60,ArcHandles=56,Atmosphere=28,Attachment=81,AudioAnalyzer=11,AudioChannelMixer=11,AudioChannelSplitter=11,AudioChorus=11,AudioCompressor=11,AudioDeviceInput=11,AudioDeviceOutput=11,AudioDistortion=11,AudioEcho=11,AudioEmitter=11,AudioEqualizer=11,AudioFDNReverb=11,AudioFader=11,AudioFilter=11,AudioFlanger=11,AudioGate=11,AudioLimiter=11,AudioListener=11,AudioPitchShifter=11,AudioPlayer=11,AudioRecorder=11,AudioReverb=11,AudioSpeechToText=11,AudioStreamReader=11,AudioStreamWriter=11,AudioTextToSpeech=11,AudioTremolo=11,AudioWindSynthesizer=11,AuroraScript=76,Backpack=20,BallSocketConstraint=86,Beam=96,BillboardGui=64,BindableEvent=67,BindableFunction=66,BlockMesh=8,BloomEffect=83,BlurEffect=83,BodyAngularVelocity=14,BodyForce=14,BodyGyro=14,BodyPartDescription=104,BodyPosition=14,BodyThrust=14,BodyVelocity=14,Bone=114,BoolValue=4,BoxHandleAdornment=111,BrickColorValue=4,CFrameValue=4,Camera=5,CanvasGroup=48,ChannelTabsConfiguration=141,CharacterMesh=60,Chat=33,ChatInputBarConfiguration=142,ChatService=33,ChatWindowConfiguration=141,ChorusSoundEffect=84,ClickDetector=41,Clouds=28,Color3Value=4,ColorCorrectionEffect=83,ColorGradingEffect=83,CompressorSoundEffect=84,ConeHandleAdornment=110,Configuration=58,Constraint=86,CoreGui=46,CorePackages=20,CornerWedgePart=1,CustomEvent=4,CustomEventReceiver=4,CylinderHandleAdornment=109,CylinderMesh=8,CylindricalConstraint=95,Debris=30,Decal=7,DepthOfFieldEffect=83,Dialog=62,DialogChoice=63,DistortionSoundEffect=84,DoubleConstrainedValue=4,DragDetector=41,EchoSoundEffect=84,EqualizerSoundEffect=84,Explosion=36,FaceControls=129,Fire=61,Flag=38,FlagStand=39,FlangeSoundEffect=84,FloorWire=4,Folder=77,ForceField=37,Frame=48,GeneratedFolder=77,GuiButton=52,GuiMain=47,HandRigDescription=53,Handles=53,Hat=45,Highlight=133,HingeConstraint=87,Hint=33,HopperBin=22,Humanoid=9,HumanoidDescription=104,HumanoidRigDescription=53,IKControl=53,ImageButton=52,ImageHandleAdornment=108,ImageLabel=49,IntConstrainedValue=4,IntValue=4,JointInstance=34,Keyframe=60,KeyframeMarker=60,Light=13,Lighting=13,LineForce=101,LineHandleAdornment=107,LinearVelocity=132,LocalScript=18,LocalizationService=92,LocalizationTable=97,MakeupDescription=104,MarketplaceService=46,MaterialService=131,MaterialVariant=130,MeshPart=73,Message=33,Model=2,ModuleScript=76,Motor6D=106,NegateOperation=72,NetworkClient=16,NetworkReplicator=29,NetworkServer=15,NoCollisionConstraint=105,NumberPose=60,NumberValue=4,ObjectValue=4,PackageLink=98,Pants=44,ParallelRampPart=1,Part=1,PartPairLasso=57,ParticleEmitter=80,ParticleEmitter2D=80,PathfindingLink=137,PathfindingModifier=128,PitchShiftSoundEffect=84,Plane=134,PlaneConstraint=134,Platform=35,PlatformLibraries=46,Player=12,PlayerGui=46,PlayerScripts=78,Players=21,Plugin=86,PluginDebugService=46,PluginGuiService=46,PointLight=13,Pose=60,PoseBase=60,Preloaded=70,PrismPart=1,PrismaticConstraint=88,ProximityPrompt=124,PyramidHandleAdornment=0,PyramidPart=1,RayValue=4,RemoteEvent=75,RemoteFunction=74,RenderingTest=5,ReplicatedFirst=70,ReplicatedStorage=70,ReverbSoundEffect=84,RightAngleRampPart=1,RigidConstraint=135,RobloxPluginGuiService=46,RocketPropulsion=14,RodConstraint=90,RopeConstraint=89,ScreenGui=47,Script=6,ScrollingFrame=48,Seat=35,SelectionBox=54,SelectionPartLasso=57,SelectionPointLasso=57,SelectionSphere=54,ServerScriptService=71,ServerStorage=69,Shirt=43,ShirtGraphic=40,SkateboardPlatform=35,Sky=28,SlidingBallConstraint=88,Smoke=59,Snap=34,Sound=11,SoundGroup=85,SoundService=31,Sparkles=42,SpawnLocation=25,SpecialMesh=8,SphereHandleAdornment=112,SpotLight=13,SpringConstraint=91,StandalonePluginScripts=78,StarterCharacterScripts=78,StarterGear=20,StarterGui=46,StarterPack=20,StarterPlayer=79,StarterPlayerScripts=78,Status=2,StringValue=4,SunRaysEffect=83,SurfaceAppearance=10,SurfaceGui=64,SurfaceGuiBase=64,SurfaceLight=13,SurfaceSelection=55,Team=24,Teams=23,Terrain=65,TerrainDetail=144,TerrainRegion=65,TestService=68,TextBox=51,TextButton=51,TextChannel=140,TextChatCommand=138,TextChatService=143,TextDocument=6,TextLabel=50,TextSource=139,Texture=10,Tool=17,Torque=103,TorsionSpringConstraint=125,TouchTransmitter=37,Trail=93,TremoloSoundEffect=84,TrussPart=1,UIAspectRatioConstraint=26,UICorner=26,UIDragDetector=41,UIFlexItem=26,UIGradient=26,UIGridLayout=26,UIListLayout=26,UIPadding=26,UIPageLayout=26,UIScale=26,UIShadow=26,UISizeConstraint=26,UIStroke=26,UITableLayout=26,UITextSizeConstraint=26,UnionOperation=73,UniversalConstraint=123,UnreliableRemoteEvent=75,ValueBase=4,Vector3Value=4,VectorForce=102,VehicleSeat=35,VideoDisplay=11,VideoFrame=120,VideoPlayer=11,ViewportFrame=52,VoiceChatService=136,WedgePart=1,Weld=34,WeldConstraint=94,Wire=11,WireframeHandleAdornment=113,Workspace=19,WorldModel=19,WrapDeformer=127,WrapLayer=126,WrapTarget=127", "(%w+)=(%d+)") do
		CLASS_ICON_INDEX[className] = tonumber(index)
	end
	-- class yang tidak ada di daftar: pakai icon class induknya
	local ICON_FALLBACK = {
		{ "BasePart", 1 }, { "Model", 2 }, { "LuaSourceContainer", 6 }, { "GuiButton", 52 }, { "GuiObject", 48 },
		{ "LayerCollector", 47 }, { "UIComponent", 26 }, { "ValueBase", 4 }, { "Light", 13 }, { "PostEffect", 83 },
		{ "Constraint", 86 }, { "JointInstance", 34 }, { "SoundEffect", 84 }, { "DataModelMesh", 8 }, { "Clothing", 43 },
	}
	local function iconIndex(inst: Instance): number
		local className = inst.ClassName
		local cached = iconCache[className]
		if cached then
			return cached
		end
		local index = CLASS_ICON_INDEX[className]
		if not index then
			index = 0
			for _, rule in ipairs(ICON_FALLBACK) do
				if isA(inst, rule[1]) then
					index = rule[2]
					break
				end
			end
		end
		iconCache[className] = index
		return index
	end

	local function toggleExpand(inst: Instance)
		expanded[inst] = not expanded[inst] or nil
		state.dirty = true
	end

	local function styleRow(row)
		local isSelected = row.inst ~= nil and row.inst == state.selected
		row.frame.BackgroundTransparency = (isSelected or row.hover) and 0 or 1
		row.frame.BackgroundColor3 = isSelected and C.Selected or C.Hover
		row.label.TextColor3 = isSelected and WHITE or C.Text
		row.arrow.TextColor3 = isSelected and WHITE or C.Muted
	end

	local function onRowClick(row)
		local inst = row.inst
		if not inst then
			return
		end
		local now = os.clock()
		local isDouble = state.lastClickInst == inst and now - state.lastClickTime < 0.35
		state.lastClickInst, state.lastClickTime = inst, now
		if isDouble then
			state.lastClickInst = nil
			if state.filter ~= "" then
				-- dari hasil filter: bersihkan filter lalu tunjukkan di pohon
				state.filter = ""
				state.filterAt = nil
				explorerFilter.Text = ""
				state.filterAt = nil
				selectInstance(inst, "reveal")
			else
				toggleExpand(inst)
			end
			return
		end
		selectInstance(inst, "explorer")
	end

	local function makeRow()
		local row = { hover = false }
		row.frame = new("TextButton", {
			Size = UDim2.new(1, 0, 0, ROW_H),
			BackgroundColor3 = C.Hover,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Visible = false,
			Parent = tree,
		})
		row.arrow = new("TextButton", {
			Size = UDim2.fromOffset(16, ROW_H),
			BackgroundTransparency = 1,
			Text = ">",
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = C.Muted,
			ZIndex = 2,
			Parent = row.frame,
		})
		-- jendela 16x16 yang menggeser strip sprite (lebih akurat daripada ImageRectOffset di layar HiDPI)
		row.icon = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(16, 16),
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Parent = row.frame,
		})
		row.iconStrip = new("ImageLabel", {
			Size = UDim2.fromOffset(CLASS_ICON_COUNT * 16, 16),
			BackgroundTransparency = 1,
			Image = CLASS_ICON_SPRITE,
			Parent = row.icon,
		})
		row.label = text(row.frame, "", { TextTruncate = Enum.TextTruncate.AtEnd, RichText = true })

		row.frame.MouseEnter:Connect(function()
			row.hover = true
			styleRow(row)
		end)
		row.frame.MouseLeave:Connect(function()
			row.hover = false
			styleRow(row)
		end)
		row.frame.Activated:Connect(function()
			onRowClick(row)
		end)
		row.frame.MouseButton2Click:Connect(function()
			if row.inst then
				selectInstance(row.inst, "explorer")
				openContext(row.inst, UserInputService:GetMouseLocation())
			end
		end)
		row.arrow.Activated:Connect(function()
			if row.inst then
				toggleExpand(row.inst)
			end
		end)
		-- HP: tahan 0.55 detik = menu
		row.frame.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			local inst = row.inst
			local startPos = input.Position
			task.delay(0.55, function()
				if inst and row.inst == inst and input.UserInputState ~= Enum.UserInputState.End
					and (input.Position - startPos).Magnitude < 12 then
					selectInstance(inst, "explorer")
					openContext(inst, row.frame.AbsolutePosition + Vector2.new(40, ROW_H))
				end
			end)
		end)
		return row
	end

	local function addNode(inst: Instance, depth: number)
		if inst == sgui then
			return
		end
		flat[#flat + 1] = { inst, depth }
		if expanded[inst] then
			for _, child in ipairs(childrenOf(inst)) do
				addNode(child, depth + 1)
			end
		end
	end

	local function rebuildTree()
		table.clear(flat)
		if state.filter ~= "" then
			local query = string.lower(state.filter)
			local count = 0
			for _, root in ipairs(roots) do
				if string.find(string.lower(root.Name), query, 1, true) then
					count += 1
					flat[count] = { root, 0 }
				end
				local ok, all = pcall(root.GetDescendants, root)
				if ok then
					for _, d in ipairs(all) do
						if count >= SEARCH_LIMIT then
							break
						end
						if string.find(string.lower(d.Name), query, 1, true) and d ~= sgui and not d:IsDescendantOf(sgui) then
							count += 1
							flat[count] = { d, 0 }
						end
					end
				end
				if count >= SEARCH_LIMIT then
					break
				end
			end
		else
			for _, root in ipairs(roots) do
				addNode(root, 0)
			end
		end
		tree.CanvasSize = UDim2.fromOffset(0, #flat * ROW_H)
		state.dirty = false
		state.lastBuild = os.clock()
	end

	renderTree = function()
		state.lastRender = os.clock()
		local first = math.max(1, math.floor(tree.CanvasPosition.Y / ROW_H) + 1)
		local count = math.ceil(tree.AbsoluteWindowSize.Y / ROW_H) + 2
		local searching = state.filter ~= ""
		for slot = 1, math.max(count, #pool) do
			local row = pool[slot]
			local node = slot <= count and flat[first + slot - 1] or nil
			if node then
				if not row then
					row = makeRow()
					pool[slot] = row
				end
				local inst, depth = node[1], node[2]
				local indent = 4 + depth * 14
				row.inst = inst
				row.frame.Position = UDim2.fromOffset(0, (first + slot - 2) * ROW_H)
				row.frame.Visible = true
				row.arrow.Visible = not searching and #childrenOf(inst) > 0
				row.arrow.Position = UDim2.fromOffset(indent, 0)
				row.arrow.Rotation = expanded[inst] and 90 or 0
				row.icon.Position = UDim2.new(0, indent + 17, 0.5, 0)
				row.iconStrip.Position = UDim2.fromOffset(-iconIndex(inst) * 16, 0)
				row.label.Position = UDim2.fromOffset(indent + 38, 0)
				row.label.Size = UDim2.new(1, -(indent + 42), 1, 0)
				local label = escapeRich(safeName(inst))
				if searching then
					label ..= '  <font color="#9a9a9a">' .. escapeRich(pathOf(inst)) .. "</font>"
				end
				row.label.Text = label
				styleRow(row)
			elseif row then
				row.frame.Visible = false
				row.inst = nil
			end
		end
	end

	-- Buka semua parent lalu scroll ke instance (seperti Studio saat klik di dunia)
	local function reveal(inst: Instance)
		if state.filter ~= "" then
			return
		end
		local p = inst.Parent
		while p and p ~= game do
			expanded[p] = true
			p = p.Parent
		end
		rebuildTree()
		for i, node in ipairs(flat) do
			if node[1] == inst then
				local viewHeight = tree.AbsoluteWindowSize.Y
				local y = (i - 1) * ROW_H
				local current = tree.CanvasPosition.Y
				if y < current or y + ROW_H > current + viewHeight then
					tree.CanvasPosition = Vector2.new(0, math.max(0, y - viewHeight / 2))
				end
				break
			end
		end
	end

	-----------------------------------------------------------------
	-- PROPERTIES
	-----------------------------------------------------------------
	-- Format: { class (atau daftar class), kategori, "Prop Prop! @Virtual" }
	-- "!" = hanya dibaca, "@" = properti buatan (lihat VIRTUAL)
	local PROP_SPEC = {
		{ "Instance", "Data", "Name ClassName! Parent! Archivable" },
		{ "Model", "Transform", "@OriginPosition @OriginOrientation" },
		{ "Model", "Pivot", "PrimaryPart! @ModelScale @WorldPivotPosition @WorldPivotOrientation" },
		{ "Model", "Behavior", "ModelStreamingMode" },
		{ "BasePart", "Appearance", "BrickColor Color Material MaterialVariant Reflectance Transparency CastShadow" },
		{ "BasePart", "Transform", "Size Position Orientation" },
		{ "BasePart", "Pivot", "@PivotOffsetPosition @PivotOffsetOrientation" },
		{ "BasePart", "Collision", "CanCollide CanTouch CanQuery CollisionGroup" },
		{ "BasePart", "Part", "Anchored Locked Massless RootPriority" },
		{ "BasePart", "Assembly", "AssemblyLinearVelocity AssemblyAngularVelocity AssemblyMass!" },
		{ "Part", "Part", "Shape" },
		{ "MeshPart", "Appearance", "TextureID" },
		{ "MeshPart", "Data", "MeshId! RenderFidelity! DoubleSided!" },
		{ "SpawnLocation", "Behavior", "Enabled Neutral AllowTeamChangeOnTouch Duration TeamColor" },
		{ "Decal", "Appearance", "Color3 Texture Transparency ZIndex Face" },
		{ "Texture", "Appearance", "StudsPerTileU StudsPerTileV OffsetStudsU OffsetStudsV" },
		{ "Light", "Appearance", "Enabled Brightness Color Shadows" },
		{ { "PointLight", "SpotLight", "SurfaceLight" }, "Appearance", "Range" },
		{ { "SpotLight", "SurfaceLight" }, "Appearance", "Angle Face" },
		{ "Fire", "Appearance", "Enabled Color SecondaryColor Heat Size" },
		{ "Smoke", "Appearance", "Enabled Color Opacity RiseVelocity Size" },
		{ "Sparkles", "Appearance", "Enabled SparkleColor" },
		{ "Humanoid", "Health", "Health MaxHealth" },
		{ "Humanoid", "Movement", "WalkSpeed JumpPower JumpHeight UseJumpPower HipHeight AutoRotate PlatformStand Sit MoveDirection!" },
		{ "Humanoid", "Data", "DisplayName DisplayDistanceType RigType!" },
		{ "Camera", "Camera", "CameraType FieldOfView CameraSubject! @CFramePosition @CFrameOrientation" },
		{ "Workspace", "Physics", "Gravity FallenPartsDestroyHeight" },
		{ "Workspace", "Data", "CurrentCamera! DistributedGameTime! StreamingEnabled!" },
		{ "Lighting", "Appearance", "Ambient Brightness ColorShift_Bottom ColorShift_Top EnvironmentDiffuseScale EnvironmentSpecularScale GlobalShadows OutdoorAmbient ShadowSoftness ExposureCompensation" },
		{ "Lighting", "Fog", "FogColor FogEnd FogStart" },
		{ "Lighting", "Time", "ClockTime TimeOfDay GeographicLatitude" },
		{ "Atmosphere", "Appearance", "Density Offset Color Decay Glare Haze" },
		{ "Sky", "Appearance", "CelestialBodiesShown StarCount SunAngularSize MoonAngularSize SunTextureId MoonTextureId" },
		{ "Clouds", "Appearance", "Enabled Cover Density Color" },
		{ "PostEffect", "Appearance", "Enabled" },
		{ "BloomEffect", "Appearance", "Intensity Size Threshold" },
		{ "BlurEffect", "Appearance", "Size" },
		{ "ColorCorrectionEffect", "Appearance", "Brightness Contrast Saturation TintColor" },
		{ "SunRaysEffect", "Appearance", "Intensity Spread" },
		{ "DepthOfFieldEffect", "Appearance", "FarIntensity FocusDistance InFocusRadius NearIntensity" },
		{ "Sound", "Playback", "SoundId Volume PlaybackSpeed Playing Looped TimePosition TimeLength! RollOffMinDistance RollOffMaxDistance" },
		{ "SoundGroup", "Playback", "Volume" },
		{ "ValueBase", "Data", "Value" },
		{ "Attachment", "Transform", "Position Orientation WorldPosition! Visible" },
		{ "JointInstance", "Data", "Part0! Part1! Enabled" },
		{ "WeldConstraint", "Data", "Part0! Part1! Enabled" },
		{ "Constraint", "Behavior", "Enabled Visible Attachment0! Attachment1!" },
		{ "ParticleEmitter", "Emission", "Enabled Rate Lifetime Speed SpreadAngle Rotation RotSpeed" },
		{ "ParticleEmitter", "Appearance", "Texture Color! Size! Transparency! LightEmission LightInfluence Brightness ZOffset" },
		{ "Beam", "Appearance", "Enabled Texture Width0 Width1 Color! Transparency! LightEmission FaceCamera" },
		{ "Trail", "Appearance", "Enabled Texture Lifetime MinLength Color! Transparency! LightEmission FaceCamera" },
		{ "Highlight", "Appearance", "Enabled FillColor FillTransparency OutlineColor OutlineTransparency DepthMode Adornee!" },
		{ "ProximityPrompt", "Behavior", "Enabled ActionText ObjectText HoldDuration MaxActivationDistance KeyboardKeyCode RequiresLineOfSight Style" },
		{ "ClickDetector", "Behavior", "MaxActivationDistance" },
		{ "Player", "Data", "DisplayName! UserId! AccountAge! Team! Neutral" },
		{ "Player", "Camera", "CameraMaxZoomDistance CameraMinZoomDistance CameraMode" },
		{ "Players", "Data", "LocalPlayer! MaxPlayers! RespawnTime! CharacterAutoLoads!" },
		{ "Team", "Data", "TeamColor AutoAssignable" },
		{ "StarterPlayer", "Character", "CharacterWalkSpeed CharacterJumpPower CharacterJumpHeight CharacterUseJumpPower CameraMaxZoomDistance CameraMinZoomDistance" },
		{ "Tool", "Behavior", "Enabled CanBeDropped RequiresHandle ManualActivationOnly ToolTip TextureId" },
		{ "BaseScript", "Behavior", "Enabled RunContext!" },
		{ "Animation", "Data", "AnimationId" },
		{ "SpecialMesh", "Data", "MeshType MeshId TextureId Scale Offset VertexColor" },
		{ "Shirt", "Appearance", "ShirtTemplate Color3" },
		{ "Pants", "Appearance", "PantsTemplate Color3" },
		{ "ShirtGraphic", "Appearance", "Graphic Color3" },
		{ "BodyColors", "Appearance", "HeadColor3 TorsoColor3 LeftArmColor3 RightArmColor3 LeftLegColor3 RightLegColor3" },
		{ "Terrain", "Water", "WaterColor WaterReflectance WaterTransparency WaterWaveSize WaterWaveSpeed" },
		{ "LayerCollector", "Behavior", "Enabled ResetOnSpawn" },
		{ "ScreenGui", "Behavior", "DisplayOrder IgnoreGuiInset ZIndexBehavior" },
		{ "BillboardGui", "Behavior", "Size StudsOffset ExtentsOffset AlwaysOnTop MaxDistance LightInfluence Adornee!" },
		{ "SurfaceGui", "Behavior", "Face AlwaysOnTop SizingMode PixelsPerStud LightInfluence Adornee!" },
		{ "GuiObject", "Appearance", "Visible BackgroundColor3 BackgroundTransparency BorderColor3 BorderSizePixel ZIndex LayoutOrder ClipsDescendants" },
		{ "GuiObject", "Transform", "AnchorPoint Position Size Rotation AutomaticSize SizeConstraint" },
		{ "GuiButton", "Behavior", "AutoButtonColor Modal Selected" },
		{ { "TextLabel", "TextButton", "TextBox" }, "Text", "Text RichText Font TextColor3 TextSize TextScaled TextWrapped TextTransparency TextStrokeColor3 TextStrokeTransparency TextXAlignment TextYAlignment LineHeight" },
		{ "TextBox", "Text", "PlaceholderText ClearTextOnFocus MultiLine TextEditable" },
		{ { "ImageLabel", "ImageButton" }, "Image", "Image ImageColor3 ImageTransparency ScaleType TileSize SliceCenter ImageRectOffset ImageRectSize" },
		{ "ScrollingFrame", "Scrolling", "CanvasSize CanvasPosition AutomaticCanvasSize ScrollBarThickness ScrollingDirection ScrollingEnabled ScrollBarImageColor3" },
		{ "UICorner", "Data", "CornerRadius" },
		{ "UIStroke", "Appearance", "Enabled Color Thickness Transparency ApplyStrokeMode LineJoinMode" },
		{ "UIGradient", "Appearance", "Enabled Color! Transparency! Rotation Offset" },
		{ "UIListLayout", "Layout", "FillDirection Padding SortOrder HorizontalAlignment VerticalAlignment Wraps" },
		{ "UIGridLayout", "Layout", "CellPadding CellSize FillDirection SortOrder StartCorner" },
		{ "UIPadding", "Layout", "PaddingTop PaddingBottom PaddingLeft PaddingRight" },
		{ "UIScale", "Data", "Scale" },
		{ "UIAspectRatioConstraint", "Data", "AspectRatio AspectType DominantAxis" },
		{ "UISizeConstraint", "Data", "MinSize MaxSize" },
	}
	-- Dicoba di semua instance (muncul di "Other" kalau ada dan belum tampil)
	local PROBE = { "Enabled", "Value", "Color", "Transparency", "Visible", "Text", "Texture", "Image", "Volume", "Size", "Position", "Brightness", "Speed" }
	local CATEGORY_ORDER = {
		"Appearance", "Data", "Transform", "Pivot", "Text", "Image", "Layout", "Scrolling", "Behavior", "Collision",
		"Part", "Assembly", "Health", "Movement", "Camera", "Physics", "Fog", "Time", "Water", "Emission",
		"Playback", "Character", "Other", "Attributes", "Tags",
	}
	local EDITABLE = {
		number = true, string = true, boolean = true, EnumItem = true, Vector3 = true, Vector2 = true,
		Color3 = true, BrickColor = true, UDim = true, UDim2 = true, NumberRange = true,
	}

	-- Properti buatan: CFrame dipecah jadi Position + Orientation seperti di Studio
	local VIRTUAL = {}
	local function cfPair(prefix: string, label: string, getCF: (any) -> CFrame, setCF: (any, CFrame) -> ())
		VIRTUAL[prefix .. "Position"] = {
			label = label .. " Position",
			get = function(inst)
				return getCF(inst).Position
			end,
			set = function(inst, v: Vector3)
				setCF(inst, CFrame.new(v) * getCF(inst).Rotation)
			end,
		}
		VIRTUAL[prefix .. "Orientation"] = {
			label = label .. " Orientation",
			get = function(inst)
				local rx, ry, rz = getCF(inst):ToOrientation()
				return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
			end,
			set = function(inst, v: Vector3)
				setCF(inst, CFrame.new(getCF(inst).Position) * CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)))
			end,
		}
	end
	cfPair("Origin", "Origin", function(i) return i:GetPivot() end, function(i, cf) i:PivotTo(cf) end)
	cfPair("WorldPivot", "WorldPivot", function(i) return i.WorldPivot end, function(i, cf) i.WorldPivot = cf end)
	cfPair("PivotOffset", "Pivot Offset", function(i) return i.PivotOffset end, function(i, cf) i.PivotOffset = cf end)
	cfPair("CFrame", "CFrame", function(i) return i.CFrame end, function(i, cf) i.CFrame = cf end)
	VIRTUAL.ModelScale = {
		label = "Scale",
		get = function(i) return i:GetScale() end,
		set = function(i, v) i:ScaleTo(math.max(v, 0.001)) end,
	}

	local function plainDesc(name: string, readOnly: boolean)
		return {
			key = name,
			label = name,
			ro = readOnly,
			get = function(inst) return inst[name] end,
			set = function(inst, value) inst[name] = value end,
		}
	end

	local function collectDescriptors(inst: Instance)
		local cats, seen = {}, {}
		local function add(cat: string, desc)
			if seen[desc.key] then
				return
			end
			seen[desc.key] = true
			cats[cat] = cats[cat] or {}
			table.insert(cats[cat], desc)
		end

		for _, spec in ipairs(PROP_SPEC) do
			local classes = spec[1]
			local match = false
			if type(classes) == "table" then
				for _, className in ipairs(classes) do
					if isA(inst, className) then
						match = true
						break
					end
				end
			else
				match = isA(inst, classes)
			end
			if match then
				for word in string.gmatch(spec[3], "%S+") do
					local readOnly = string.sub(word, -1) == "!"
					if readOnly then
						word = string.sub(word, 1, -2)
					end
					if string.sub(word, 1, 1) == "@" then
						local v = VIRTUAL[string.sub(word, 2)]
						if v then
							add(spec[2], { key = word, label = v.label, ro = readOnly, get = v.get, set = v.set })
						end
					else
						add(spec[2], plainDesc(word, readOnly))
					end
				end
			end
		end

		for _, name in ipairs(PROBE) do
			add("Other", plainDesc(name, false))
		end

		local okAttr, attributes = pcall(inst.GetAttributes, inst)
		if okAttr then
			local names = {}
			for name in pairs(attributes) do
				table.insert(names, name)
			end
			table.sort(names)
			for _, name in ipairs(names) do
				add("Attributes", {
					key = "attr:" .. name,
					label = name,
					get = function(i) return i:GetAttribute(name) end,
					set = function(i, value) i:SetAttribute(name, value) end,
				})
			end
		end

		local okTags, tags = pcall(CollectionService.GetTags, CollectionService, inst)
		if okTags and #tags > 0 then
			table.sort(tags)
			local joined = table.concat(tags, ", ")
			add("Tags", { key = "tags", label = "Tags", ro = true, get = function() return joined end })
		end
		return cats
	end

	local function fmt(n: number): string
		if n ~= n then
			return "NaN"
		elseif n == math.huge then
			return "inf"
		elseif n == -math.huge then
			return "-inf"
		elseif math.abs(n) >= 1e15 then
			return tostring(n)
		elseif n == math.floor(n) then
			return string.format("%d", n)
		end
		local s = string.format("%.3f", n)
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
		if s == "-0" then
			s = "0"
		end
		return s
	end

	local function formatValue(v: any): string
		local t = typeof(v)
		if t == "nil" then
			return ""
		elseif t == "number" then
			return fmt(v)
		elseif t == "string" then
			return v
		elseif t == "boolean" then
			return tostring(v)
		elseif t == "Vector3" then
			return fmt(v.X) .. ", " .. fmt(v.Y) .. ", " .. fmt(v.Z)
		elseif t == "Vector2" then
			return fmt(v.X) .. ", " .. fmt(v.Y)
		elseif t == "Color3" then
			return string.format("[%d, %d, %d]", math.round(v.R * 255), math.round(v.G * 255), math.round(v.B * 255))
		elseif t == "BrickColor" or t == "EnumItem" then
			return v.Name
		elseif t == "UDim" then
			return fmt(v.Scale) .. ", " .. fmt(v.Offset)
		elseif t == "UDim2" then
			return string.format("{%s, %s},{%s, %s}", fmt(v.X.Scale), fmt(v.X.Offset), fmt(v.Y.Scale), fmt(v.Y.Offset))
		elseif t == "NumberRange" then
			return fmt(v.Min) .. ", " .. fmt(v.Max)
		elseif t == "Instance" then
			return safeName(v)
		elseif t == "CFrame" then
			return formatValue(v.Position)
		elseif t == "Rect" then
			return string.format("%s, %s, %s, %s", fmt(v.Min.X), fmt(v.Min.Y), fmt(v.Max.X), fmt(v.Max.Y))
		elseif t == "Font" then
			return (string.match(v.Family, "([^/]+)%.json$") or v.Family) .. " (" .. v.Weight.Name .. ")"
		elseif t == "ColorSequence" or t == "NumberSequence" then
			return t .. " (" .. #v.Keypoints .. " titik)"
		end
		return tostring(v)
	end

	local function numbersIn(s: string): { number }
		local out = {}
		for token in string.gmatch(s, "[%-%+]?%d*%.?%d+") do
			local n = tonumber(token)
			if n then
				table.insert(out, n)
			end
		end
		return out
	end

	-- Teks dari kotak input -> nilai sesuai tipe properti (nil = tidak valid)
	local function parseValue(s: string, kind: string): any
		local n = numbersIn(s)
		if kind == "string" then
			return s
		elseif kind == "number" then
			return tonumber(s) or n[1]
		elseif kind == "Vector3" then
			if #n >= 3 then
				return Vector3.new(n[1], n[2], n[3])
			elseif #n == 1 then
				return Vector3.new(n[1], n[1], n[1])
			end
		elseif kind == "Vector2" then
			if #n >= 2 then
				return Vector2.new(n[1], n[2])
			end
		elseif kind == "Color3" then
			local hex = string.match(s, "^%s*#(%x%x%x%x%x%x)%s*$")
			if hex then
				return Color3.fromHex(hex)
			elseif #n >= 3 then
				return Color3.fromRGB(math.clamp(n[1], 0, 255), math.clamp(n[2], 0, 255), math.clamp(n[3], 0, 255))
			end
		elseif kind == "BrickColor" then
			local ok, color = pcall(BrickColor.new, tonumber(s) or s)
			if ok then
				return color
			end
		elseif kind == "UDim" then
			if #n >= 2 then
				return UDim.new(n[1], n[2])
			end
		elseif kind == "UDim2" then
			if #n >= 4 then
				return UDim2.new(n[1], n[2], n[3], n[4])
			end
		elseif kind == "NumberRange" then
			if #n >= 2 then
				return NumberRange.new(math.min(n[1], n[2]), math.max(n[1], n[2]))
			elseif #n == 1 then
				return NumberRange.new(n[1])
			end
		end
		return nil
	end

	local function openEnumMenu(button: GuiObject, current: EnumItem, commit: (any) -> ())
		local items = {}
		for _, item in ipairs(current.EnumType:GetEnumItems()) do
			table.insert(items, {
				text = item.Name,
				current = item == current,
				action = function()
					commit(item)
				end,
			})
		end
		openPopup(button.AbsolutePosition + Vector2.new(0, button.AbsoluteSize.Y), math.max(button.AbsoluteSize.X, 150), items)
	end

	local function makeCategoryRow(cat: string, order: number)
		local button = new("TextButton", {
			Size = UDim2.new(1, 0, 0, PROP_H),
			BackgroundColor3 = C.Section,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			LayoutOrder = order,
			Parent = propList,
		})
		text(button, ">", {
			Position = UDim2.fromOffset(2, 0),
			Size = UDim2.fromOffset(14, PROP_H),
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.Muted,
			Rotation = collapsedCats[cat] and 0 or 90,
		})
		text(button, cat, { Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -20, 1, 0), Font = FB, TextSize = 15 })
		button.Activated:Connect(function()
			collapsedCats[cat] = not collapsedCats[cat] or nil
			rebuildProps()
		end)
	end

	local function makePropRow(inst: Instance, desc, value: any, order: number)
		local kind = typeof(value)
		local editable = not desc.ro and EDITABLE[kind] == true
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, PROP_H),
			BackgroundColor3 = C.Bg,
			BorderSizePixel = 0,
			LayoutOrder = order,
			Parent = propList,
		})
		new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = C.Line, BorderSizePixel = 0, Parent = row })
		new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(NAME_W, 0, 0, 0), BackgroundColor3 = C.Line, BorderSizePixel = 0, Parent = row })
		text(row, desc.label, {
			Position = UDim2.fromOffset(18, 0),
			Size = UDim2.new(NAME_W, -22, 1, 0),
			TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = (editable or kind == "Instance") and C.Text or C.Muted,
		})
		local cell = new("Frame", {
			Position = UDim2.new(NAME_W, 6, 0, 0),
			Size = UDim2.new(1 - NAME_W, -12, 1, 0),
			BackgroundTransparency = 1,
			Parent = row,
		})

		local entry = {}
		local function current(): any
			local ok, v = pcall(desc.get, inst)
			if ok then
				return v
			end
			return nil
		end
		local function commit(newValue: any)
			local ok, err = pcall(desc.set, inst, newValue)
			if not ok then
				toast("Gagal ubah " .. desc.label .. ": " .. tostring(err), true)
			end
			entry.refresh(true)
		end

		if kind == "boolean" then
			local box = new("TextButton", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 0, 0.5, 0),
				Size = UDim2.fromOffset(16, 16),
				BackgroundColor3 = C.Input,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				Parent = cell,
			})
			corner(box, 3)
			stroke(box, C.Border, 1)
			local fill = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(10, 10),
				BackgroundColor3 = editable and C.Accent or C.Muted,
				BorderSizePixel = 0,
				Parent = box,
			})
			corner(fill, 2)
			entry.refresh = function()
				fill.Visible = current() == true
			end
			if editable then
				box.Activated:Connect(function()
					commit(not current())
				end)
			end
		elseif kind == "EnumItem" then
			local button = new("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				Parent = cell,
			})
			local valueLabel = text(button, "", {
				Size = UDim2.new(1, -16, 1, 0),
				TextSize = 14,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = editable and C.Text or C.Muted,
			})
			if editable then
				text(button, "v", {
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, 0, 0, 0),
					Size = UDim2.fromOffset(12, PROP_H),
					Font = Enum.Font.GothamBold,
					TextSize = 10,
					TextColor3 = C.Muted,
				})
				button.Activated:Connect(function()
					local v = current()
					if typeof(v) == "EnumItem" then
						openEnumMenu(button, v, commit)
					end
				end)
			end
			entry.refresh = function()
				valueLabel.Text = formatValue(current())
			end
		elseif kind == "Instance" or kind == "nil" then
			-- referensi ke instance lain: klik untuk memilihnya
			local button = new("TextButton", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Text = "",
				Parent = cell,
			})
			local valueLabel = text(button, "", {
				Size = UDim2.fromScale(1, 1),
				TextSize = 14,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = C.Accent,
			})
			button.Activated:Connect(function()
				local v = current()
				if typeof(v) == "Instance" then
					selectInstance(v, "props")
				end
			end)
			entry.refresh = function()
				local v = current()
				valueLabel.Text = typeof(v) == "Instance" and safeName(v) or formatValue(v)
			end
		else
			local swatch
			if kind == "Color3" or kind == "BrickColor" then
				swatch = new("Frame", {
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(0, 0, 0.5, 0),
					Size = UDim2.fromOffset(14, 14),
					BorderSizePixel = 0,
					Parent = cell,
				})
				stroke(swatch, C.Border, 1, Enum.ApplyStrokeMode.Border, 0, Enum.LineJoinMode.Miter)
			end
			local x = swatch and 20 or 0
			local field
			if editable then
				field = new("TextBox", {
					Position = UDim2.fromOffset(x, 0),
					Size = UDim2.new(1, -x, 1, 0),
					BackgroundTransparency = 1,
					Text = "",
					ClearTextOnFocus = false,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Font = F,
					TextSize = 14,
					TextColor3 = C.Text,
					Parent = cell,
				})
				field.FocusLost:Connect(function()
					if field.Text == formatValue(current()) then
						return
					end
					local parsed = parseValue(field.Text, kind)
					if parsed == nil then
						toast("Format nilai tidak valid untuk " .. desc.label, true)
						entry.refresh(true)
						return
					end
					commit(parsed)
				end)
			else
				field = text(cell, "", {
					Position = UDim2.fromOffset(x, 0),
					Size = UDim2.new(1, -x, 1, 0),
					TextSize = 14,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextColor3 = C.Muted,
				})
			end
			entry.refresh = function(force: boolean?)
				if editable and field:IsFocused() and not force then
					return
				end
				local v = current()
				field.Text = formatValue(v)
				if swatch then
					if typeof(v) == "Color3" then
						swatch.BackgroundColor3 = v
					elseif typeof(v) == "BrickColor" then
						swatch.BackgroundColor3 = v.Color
					end
				end
			end
		end

		entry.refresh()
		table.insert(propRows, entry)
	end

	local function propertiesTitle(inst: Instance?): string
		if not inst then
			return "Properties"
		end
		return string.format('Properties - %s "%s"', inst.ClassName, safeName(inst))
	end

	rebuildProps = function()
		closePopup()
		for _, child in ipairs(propList:GetChildren()) do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		table.clear(propRows)

		local inst = state.selected
		properties.title.Text = propertiesTitle(inst)
		if not inst then
			text(propList, "  Pilih sesuatu di Explorer, atau nyalakan Select lalu klik part di map.", {
				Size = UDim2.new(1, -8, 0, 44),
				TextSize = 14,
				TextWrapped = true,
				TextColor3 = C.Muted,
				LayoutOrder = 1,
			})
			return
		end

		local cats = collectDescriptors(inst)
		local query = string.lower(propFilter.Text)
		local orderedCats = {}
		for _, cat in ipairs(CATEGORY_ORDER) do
			if cats[cat] then
				table.insert(orderedCats, cat)
			end
		end
		for cat in pairs(cats) do
			if not table.find(CATEGORY_ORDER, cat) then
				table.insert(orderedCats, cat)
			end
		end

		local order = 0
		for _, cat in ipairs(orderedCats) do
			local rows = {}
			for _, desc in ipairs(cats[cat]) do
				if query == "" or string.find(string.lower(desc.label), query, 1, true) then
					local ok, value = pcall(desc.get, inst)
					-- inst.X bisa mengembalikan child bernama X kalau properti X tidak ada
					local isChild = ok and typeof(value) == "Instance" and value.Parent == inst and value.Name == desc.key
					if ok and not isChild then
						table.insert(rows, { desc = desc, value = value })
					end
				end
			end
			if #rows > 0 then
				order += 1
				makeCategoryRow(cat, order)
				if not collapsedCats[cat] then
					for _, r in ipairs(rows) do
						order += 1
						makePropRow(inst, r.desc, r.value, order)
					end
				end
			end
		end
	end

	-----------------------------------------------------------------
	-- SELEKSI
	-----------------------------------------------------------------
	local function updateAdornments()
		local sel = state.selected
		local target = nil
		if state.open and sel and (isA(sel, "BasePart") or isA(sel, "Model")) and not isA(sel, "Terrain") and sel:IsDescendantOf(workspace) then
			target = sel
		end
		selectBox.Adornee = target
	end

	selectInstance = function(inst: Instance?, source: string)
		if state.selected ~= inst then
			state.selected = inst
			updateAdornments()
			rebuildProps()
		end
		if inst and source ~= "explorer" then
			reveal(inst)
		end
		renderTree()
	end

	openContext = function(inst: Instance, position: Vector2)
		local items = {}
		if isA(inst, "PVInstance") and inst ~= workspace and not isA(inst, "Terrain") then
			table.insert(items, {
				text = "Teleport ke sini",
				action = function()
					if not (character and rootPart) then
						toast("Karakter kamu belum siap.", true)
						return
					end
					local ok, pivot = pcall(inst.GetPivot, inst)
					if not ok then
						return
					end
					local height = 0
					if isA(inst, "BasePart") then
						height = (inst :: BasePart).Size.Y
					elseif isA(inst, "Model") then
						local okBox, _, size = pcall((inst :: Model).GetBoundingBox, inst)
						if okBox then
							height = size.Y
						end
					end
					character:PivotTo(CFrame.new(pivot.Position + Vector3.new(0, height / 2 + 4, 0)))
					rootPart.AssemblyLinearVelocity = Vector3.zero
					toast("Teleport ke " .. safeName(inst))
				end,
			})
		end
		if #childrenOf(inst) > 0 and state.filter == "" then
			table.insert(items, {
				text = expanded[inst] and "Tutup (collapse)" or "Buka (expand)",
				action = function()
					toggleExpand(inst)
				end,
			})
		end
		if inst.Parent and inst.Parent ~= game then
			table.insert(items, {
				text = "Pilih Parent",
				action = function()
					selectInstance(inst.Parent, "props")
				end,
			})
		end
		if inst.Parent ~= game then
			table.insert(items, {
				text = "Hapus (client)",
				color = C.Error,
				action = function()
					local name = safeName(inst)
					local ok, err = pcall(inst.Destroy, inst)
					if ok then
						if state.selected == inst then
							selectInstance(nil, "explorer")
						end
						state.dirty = true
						toast("Dihapus (cuma di client): " .. name)
					else
						toast("Tidak bisa dihapus: " .. tostring(err), true)
					end
				end,
			})
		end
		openPopup(position, 170, items)
	end

	-- Klik di dunia: pertama pilih model paling luar, klik lagi = part di dalamnya
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local function pickFromScreen(position: Vector2, isViewport: boolean): Instance?
		local cam = workspace.CurrentCamera
		if not cam then
			return nil
		end
		local ray = isViewport and cam:ViewportPointToRay(position.X, position.Y) or cam:ScreenPointToRay(position.X, position.Y)
		local ignore = {}
		for _ = 1, 8 do
			rayParams.FilterDescendantsInstances = ignore
			local result = workspace:Raycast(ray.Origin, ray.Direction * 5000, rayParams)
			if not result then
				return nil
			end
			local hit = result.Instance
			-- part tidak terlihat (hitbox dsb) dilewati
			if hit:IsA("BasePart") and not hit:IsA("Terrain") and hit.Transparency >= 0.99 then
				table.insert(ignore, hit)
			else
				return hit
			end
		end
		return nil
	end

	local function isAltDown(): boolean
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
	end

	local function resolvePick(part: Instance, direct: boolean): Instance
		if direct or part:IsA("Terrain") then
			return part
		end
		local top = nil
		local a = part.Parent
		while a and a ~= workspace and a ~= game do
			if a:IsA("Model") then
				top = a
			end
			a = a.Parent
		end
		if not top then
			return part
		end
		local sel = state.selected
		if sel == top or (sel and sel:IsDescendantOf(top)) then
			return part
		end
		return top
	end

	local function pickAndSelect(position: Vector2, isViewport: boolean)
		local hit = pickFromScreen(position, isViewport)
		if hit then
			selectInstance(resolvePick(hit, isAltDown()), "world")
		else
			selectInstance(nil, "world")
		end
	end

	-----------------------------------------------------------------
	-- TOOLBAR (Explorer / Properties / Select / Tutup)
	-----------------------------------------------------------------
	local toolbar = new("Frame", {
		Name = "Toolbar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(372, 40),
		BackgroundColor3 = C.Bg,
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 5,
		Parent = sgui,
	})
	corner(toolbar, 12)
	stroke(toolbar, C.Border, 1.5)
	local toolbarTitle = text(toolbar, "Mini Studio", {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.fromOffset(84, 40),
		Font = FB,
		TextSize = 13,
	})
	onDrag(toolbarTitle, function()
		return toolbar.Position
	end, function(start, dx, dy)
		toolbar.Position = UDim2.new(start.X.Scale, start.X.Offset + dx, start.Y.Scale, start.Y.Offset + dy)
	end)

	local toolButtons = {}
	local function toolButton(name: string?, label: string, x: number, width: number): TextButton
		local button = new("TextButton", {
			Position = UDim2.fromOffset(x, 6),
			Size = UDim2.fromOffset(width, 28),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Parent = toolbar,
		})
		-- teks di label terpisah supaya tidak ikut diwarnai gradient tombol
		local labelObj = text(button, label, {
			Name = "Label",
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = FB,
			TextColor3 = C.OffText,
			ZIndex = 2,
		})
		corner(button, 8)
		local s = stroke(button, C.Border, 1)
		local g = new("UIGradient", { Rotation = 90, Color = C.Off, Parent = button })
		if name then
			toolButtons[name] = { button = button, stroke = s, gradient = g, label = labelObj }
		end
		return button
	end

	local function refreshToolbar()
		for name, refs in pairs(toolButtons) do
			local on = if name == "Select" then state.selectMode else state.windows[name]
			refs.gradient.Color = on and C.Primary or C.Off
			refs.label.TextColor3 = on and C.OnPrimary or C.OffText
			refs.stroke.Color = on and C.Accent or C.Border
		end
		explorer.frame.Visible = state.open and state.windows.Explorer
		properties.frame.Visible = state.open and state.windows.Properties
		if api.OnChanged then
			task.spawn(api.OnChanged)
		end
	end

	local function placeWindows()
		local cam = workspace.CurrentCamera
		local screen = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local width = math.clamp(math.floor(screen.X * 0.22), 220, 300)
		-- di bawah top bar Roblox supaya tombolnya tidak ketutup
		local inset = GuiService:GetGuiInset().Y
		toolbar.Position = UDim2.new(0.5, 0, 0, inset + 6)
		toastLabel.Position = UDim2.new(0.5, 0, 0, inset + 52)
		local top = inset + 54
		local available = screen.Y - top - 12
		local explorerHeight = math.floor(available * 0.45)
		local propertiesHeight = available - explorerHeight - 8
		explorer.frame.Size = UDim2.fromOffset(width, explorerHeight)
		explorer.frame.Position = UDim2.fromOffset(screen.X - width - 12, top)
		properties.frame.Size = UDim2.fromOffset(width, propertiesHeight)
		properties.frame.Position = UDim2.fromOffset(screen.X - width - 12, top + explorerHeight + 8)
	end

	function api.IsOpen(): boolean
		return state.open
	end

	function api.Get(name: string): boolean
		if name == "Select" then
			return state.selectMode
		end
		return state.windows[name] == true
	end

	function api.Open()
		if state.open then
			return
		end
		state.open = true
		sgui.Enabled = true
		if not state.placed then
			state.placed = true
			placeWindows()
			expanded[workspace] = true
		end
		-- "load": hitung semua instance yang ada di client saat ini
		local total = 0
		for _, root in ipairs(roots) do
			local ok, all = pcall(root.GetDescendants, root)
			total += 1 + (ok and #all or 0)
		end
		rebuildTree()
		renderTree()
		rebuildProps()
		updateAdornments()
		refreshToolbar()
		toast(string.format("Mini Studio dimuat: %d instance di client", total))
	end

	function api.Close()
		if not state.open then
			return
		end
		state.open = false
		state.selectMode = false
		closePopup()
		hoverBox.Adornee = nil
		selectBox.Adornee = nil
		guiOutline.Visible = false
		sgui.Enabled = false
		refreshToolbar()
	end

	function api.Toggle(name: string)
		if not state.open then
			api.Open()
		end
		if name == "Select" then
			state.selectMode = not state.selectMode
			if not state.selectMode then
				hoverBox.Adornee = nil
			end
			toast(state.selectMode and "Select ON: klik part di map" or "Select OFF")
		else
			state.windows[name] = not state.windows[name]
			if state.windows[name] then
				bringToFront((name == "Explorer" and explorer or properties).frame)
			end
		end
		refreshToolbar()
	end

	api.Gui = sgui
	function api.Refresh()
		refreshToolbar()
		if state.open then
			renderTree()
			rebuildProps()
		end
	end

	toolButton("Explorer", "Explorer", 96, 76).Activated:Connect(function()
		api.Toggle("Explorer")
	end)
	toolButton("Properties", "Properties", 176, 84).Activated:Connect(function()
		api.Toggle("Properties")
	end)
	toolButton("Select", "Select", 264, 62).Activated:Connect(function()
		api.Toggle("Select")
	end)
	local closeAll = toolButton(nil, "X", 330, 34)
	closeAll.Label.Font = Enum.Font.GothamBold
	closeAll:FindFirstChildOfClass("UIGradient").Color = C.Danger
	closeAll.Activated:Connect(api.Close)

	explorer.close.Activated:Connect(function()
		state.windows.Explorer = false
		refreshToolbar()
	end)
	properties.close.Activated:Connect(function()
		state.windows.Properties = false
		refreshToolbar()
	end)

	-----------------------------------------------------------------
	-- EVENT & LOOP
	-----------------------------------------------------------------
	explorerFilter:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterAt = os.clock()
	end)
	propFilter:GetPropertyChangedSignal("Text"):Connect(function()
		if state.open then
			rebuildProps()
		end
	end)
	tree:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if state.open then
			renderTree()
		end
	end)
	tree:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(function()
		if state.open then
			renderTree()
		end
	end)

	-- Pohon Explorer ikut update saat ada instance masuk/keluar di folder yang sedang dibuka
	local function onTreeChange(d: Instance)
		if not state.open or state.filter ~= "" then
			return
		end
		local ok, parent = pcall(function()
			return d.Parent
		end)
		if ok and parent and expanded[parent] then
			state.dirty = true
		end
	end
	game.DescendantAdded:Connect(onTreeChange)
	game.DescendantRemoving:Connect(onTreeChange)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not (state.open and state.selectMode) then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			pickAndSelect(UserInputService:GetMouseLocation(), true)
		end
	end)
	UserInputService.TouchTap:Connect(function(positions, gameProcessed)
		if gameProcessed or not (state.open and state.selectMode) then
			return
		end
		local p = positions[1]
		if p then
			pickAndSelect(Vector2.new(p.X, p.Y), false)
		end
	end)

	RunService.Heartbeat:Connect(function()
		if not state.open then
			return
		end
		local now = os.clock()

		local sel = state.selected
		if sel and sel ~= game and sel.Parent == nil then
			selectInstance(nil, "explorer") -- instance yang dipilih sudah hilang
		end

		if state.filterAt and now - state.filterAt > 0.25 then
			state.filterAt = nil
			state.filter = explorerFilter.Text
			state.dirty = true
			tree.CanvasPosition = Vector2.zero
		end

		if state.dirty and now - state.lastBuild > 0.15 then
			rebuildTree()
			renderTree()
		elseif now - state.lastRender > 0.5 then
			renderTree()
		end

		if now - state.lastPropRefresh > 0.2 then
			state.lastPropRefresh = now
			properties.title.Text = propertiesTitle(state.selected)
			for _, entry in ipairs(propRows) do
				entry.refresh()
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not state.open then
			return
		end
		-- kotak biru untuk GUI yang dipilih
		local sel = state.selected
		local outlineVisible = false
		if sel and isA(sel, "GuiObject") then
			local layer = sel:FindFirstAncestorWhichIsA("LayerCollector")
			if layer and layer:IsA("ScreenGui") and layer.Enabled then
				local pos, size = (sel :: GuiObject).AbsolutePosition, (sel :: GuiObject).AbsoluteSize
				local offset = layer.IgnoreGuiInset and Vector2.zero or GuiService:GetGuiInset()
				guiOutline.Position = UDim2.fromOffset(pos.X + offset.X, pos.Y + offset.Y)
				guiOutline.Size = UDim2.fromOffset(size.X, size.Y)
				outlineVisible = true
			end
		end
		guiOutline.Visible = outlineVisible

		-- hover saat mode Select (mouse)
		if state.selectMode and UserInputService.MouseEnabled then
			local hit = pickFromScreen(UserInputService:GetMouseLocation(), true)
			local target = hit and resolvePick(hit, isAltDown()) or nil
			if target and (target:IsA("Terrain") or target == state.selected) then
				target = nil
			end
			hoverBox.Adornee = target
		else
			hoverBox.Adornee = nil
		end
	end)

	return api
end

---------------------------------------------------------------------
-- TAB + HALAMAN MINI STUDIO
---------------------------------------------------------------------
local miniStudio = createMiniStudio()

local studioPage = new("Frame", {
	Name = "StudioPage",
	Position = UDim2.fromOffset(8, PAGE_TOP),
	Size = UDim2.new(1, -16, 0, CONTENT_HEIGHT),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 2,
	Parent = main,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = studioPage })

local studioCard = new("Frame", {
	Name = "StudioCard",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = P.Card,
	BackgroundTransparency = 0,
	LayoutOrder = 1,
	Parent = studioPage,
})
corner(studioCard, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = studioCard,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = studioCard })

local studioTitle = new("TextLabel", {
	Text = "Mini Studio",
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 20,
	TextColor3 = WHITE,
	LayoutOrder = 1,
	Parent = studioCard,
})

new("TextLabel", {
	Text = "Explorer, Properties, dan Select seperti di Roblox Studio. Saat Run, semua yang ada di map (client) dimuat. Perubahan properti cuma terlihat di layar kamu.",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	TextWrapped = true,
	Font = FONT,
	TextSize = 13,
	TextColor3 = P.Muted,
	LayoutOrder = 2,
	Parent = studioCard,
})

local runRefs = glossyButton(studioCard, UDim2.new(1, 0, 0, 42), THEMES.Green, "Run Mini Studio", 20, { LayoutOrder = 3 })

local studioToggleRow = new("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	LayoutOrder = 4,
	Parent = studioCard,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = studioToggleRow,
})
local studioToggles = {
	Explorer = glossyButton(studioToggleRow, UDim2.new(1 / 3, -4, 1, 0), THEMES.Off, "Explorer", 14, { LayoutOrder = 1 }),
	Properties = glossyButton(studioToggleRow, UDim2.new(1 / 3, -4, 1, 0), THEMES.Off, "Properties", 14, { LayoutOrder = 2 }),
	Select = glossyButton(studioToggleRow, UDim2.new(1 / 3, -4, 1, 0), THEMES.Off, "Select", 14, { LayoutOrder = 3 }),
}
local STUDIO_THEMES = { Explorer = THEMES.Teal, Properties = THEMES.Teal, Select = THEMES.Yellow }

local function refreshStudioButtons()
	local isOpen = miniStudio.IsOpen()
	runRefs.label.Text = isOpen and "Tutup Mini Studio" or "Run Mini Studio"
	setTheme(runRefs, isOpen and THEMES.Red or THEMES.Green)
	for name, refs in pairs(studioToggles) do
		setTheme(refs, (isOpen and miniStudio.Get(name)) and STUDIO_THEMES[name] or THEMES.Off)
	end
end
miniStudio.OnChanged = refreshStudioButtons

runRefs.button.Activated:Connect(function()
	if miniStudio.IsOpen() then
		miniStudio.Close()
	else
		miniStudio.Open()
	end
	refreshStudioButtons()
end)
for name, refs in pairs(studioToggles) do
	refs.button.Activated:Connect(function()
		miniStudio.Toggle(name)
	end)
end

---------------------------------------------------------------------
-- HALAMAN TEMA (pilihan warna dari Workspace["SALON MUSIC BY OCTA"].TEAMS)
---------------------------------------------------------------------
local themePage = new("Frame", {
	Name = "ThemePage",
	Position = UDim2.fromOffset(8, PAGE_TOP),
	Size = UDim2.new(1, -16, 0, CONTENT_HEIGHT),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 2,
	Parent = main,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = themePage })

local themeCard = new("Frame", {
	Name = "ThemeCard",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = P.Card,
	LayoutOrder = 1,
	Parent = themePage,
})
corner(themeCard, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = themeCard,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = themeCard })
new("TextLabel", {
	Text = "Tema Warna",
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 20,
	TextColor3 = WHITE,
	LayoutOrder = 1,
	Parent = themeCard,
})

local themeGrid = new("Frame", {
	Name = "Swatches",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	LayoutOrder = 2,
	Parent = themeCard,
})
new("UIGridLayout", {
	CellSize = UDim2.new(0.5, -4, 0, 44),
	CellPadding = UDim2.fromOffset(8, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = themeGrid,
})
table.insert(themeSkip, themeGrid) -- kotak pilihan tema tetap pakai warna aslinya

local currentTheme = DEFAULT_THEME
local swatchStrokes = {}

local function refreshSwatches()
	for name, s in pairs(swatchStrokes) do
		s.Enabled = name == currentTheme
	end
end

-- Ambil gradient dari folder TEAMS (urutan mengikuti TEAM_FALLBACK, sisanya di belakang)
local function loadTeamThemes()
	local list = {}
	local ok, folder = pcall(function()
		local salon = workspace:WaitForChild("SALON MUSIC BY OCTA", 10)
		return salon and salon:WaitForChild("TEAMS", 10)
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
-- HALAMAN PIANO AUTO PLAYER
-- Tuts dibaca dari PlayerGui.PianoUI.PianoContainer.KeyFrame:
--   tuts = GuiButton yang namanya angka nada (angka kecil = kiri).
-- Cara tuts "ditekan" oleh autoplayer:
--   1. Kalau PianoUI punya BindableEvent bernama "KeyPress":
--      KeyPress:Fire(tuts, true) saat ditekan, KeyPress:Fire(tuts, false) saat dilepas
--      -> script piano kamu yang membunyikan nadanya (paling disarankan).
--   2. Kalau tidak ada: Sound di dalam tuts (kalau ada) diputar + efek tuts ditekan.
---------------------------------------------------------------------
local PIANO_MIN_HOLD, PIANO_MAX_HOLD = 0.02, 0.5 -- lama tuts ditahan (detik), tanpa jeda antar tuts
local PIANO_MODES = { "Loop (kiri - kanan - kiri)", "1x  (kiri -> kanan)", "1x  (kanan -> kiri)", "Lagu (pilih dari daftar)" }
local piano = { mode = 1, hold = 0.08, running = false, runId = 0, song = 1 }

-- Data lagu hasil konversi MIDI (dipadatkan: LZ + varint). Dibuka oleh decodePacked di bawah.
local PACKED = {}
PACKED.RushE = [==[7!"LOZh""LOTC(%#Q2(%#i)<%#Z%g"%#T#,%'#LOX:'+$LOXOg0)5%@7L7X7g7Q"Y#+%&47e&-="9jZ%#<9@9Z%"4O&,AW$"4/1"6/0"8/1#-jBFEZ%#9dL9T#"L9T#$<9@9*.##4J:c$T"+bT#"Mb(:+bT#"Kb$T"%cZ%"51QcZ%#4dTi,S%?8dVcT#"VcT#$>9@9*.##4$:!T(:!S*:%9dT*:'<9@9*.##4$:!S(:!Q*:#;d"c"":%?9E$q"5ScT##6dNcZ%&5l"Z%$@9D9Pci)#(m4mc'"6NQ""8NQ"#9cLcT#"L"Q#%Q@Q*.##4,,6:!9J:Z"T"!M2:!K(T"#Z%"5,w%%9QX(5!`"v(#Qc"v(T#Q@QZ%#>QecT#"ccT#$AQEQbcT#"ecT##<QccT#"bcT#$@QEQ`(H##;$F!`"c)'QAQ_(H##9$F!X(d$"T)3QcT#$4Q@QY*<'6QBQ,z*'8QDQ"V)*J!P*u))9QEQQDT)!i.c'#c@,e)##40q)2:2^*N$T"$q)(:"q)#9c$q)%c@c$R1!c$R1/c@cZ%#;c.R1#c@,.##4$,$R1%c@c.R1!c.R1#c@,.##4$,$R1"g#*R1$c"$R1#cB,.%#6c$R1"5-Z%$@cDca"R1U%{(>a(!40a(*R1!c$R1%c@c$R1!c$R1$v(#>c.R1%cEc.R1!c.R1%cEc.R1$F$R1%cAc.R1$F$R1(c)$U0%c@c.R1#cB.z*%8cD$V)*J.R1%cEc"R1f"-m9mc'";NQ""=NQ"$2c>cVmZ%#AcEcU#"U$w#'VcZ%"f%!X${%!Y20.@#Yc"u&+XmZ%#@$f"*s-"v+!E"L)#<cXs&C'Z%"9(<"P0=@cSmZ%#DcGcU#"R(N.+Z%$DcG"k"##@$h#*0.@"R#$e#Q"#9dQdZ%#<dTdZ%#@dXdZ%#Ed`..&<$Jl%n&$c%!E$d"!`$g&"|&!>(p"+ViZ%";0N#"R+"P/%0c<$v""{$+cZ%$/c&t&?-c9cQcu-&(d4dLdP"T&5&-d9dQdTd`d>_43$9iLcXcT##$'!%$R2.2#$440<B#%9"0'g99".$!$>4!&(_"a"L!%$n#a$y"k$u$,f'!M"b50f'%KcW$r4!L"{*";!Q"P9)$4cTi.R9'$;cV"T9!#$'!%$OA.2#$4(0!T"f9"B!S"T9(B#9c$;(B$|8.2#$4(0$Y"*W$,B!;(w"&B$ZA.2!$"vA%cZ%*;%Z%%$zA!_@|A&m&U+m.,_&Jq,$n#.q,,g))9cXcg(;%`cl:bEf"$>cVdedT#$TdcdgdT#'AcEcSdbdedndT##$?%%<c(A!%,=7'@cEcQd`dcdl0g"#&;.e"!%,A7'>cDcPd_dbdk4m"#&9.k"+%LdXd`$T$?<cEcHdTdXdcdT#%E&k:"W#-MdYd`dh(R"!_$h$)JdVdY$N%,Y"7'4p@pGdSdVdb4k"A%DdPdSd_dT#%GdSdX"A)'9cEc(Em'i)l"$p%p&p'p(p)p*p+p,p-p.p/p0p1p2p3p4p5p6p7p8p9p:p;p<p=p>p?p@pApBpCpDpEpFpGpHpIpJpKpLpMpNpOpPpQpRpSpTpUpVpWpXpYpZp^p_p`papbpcpdpepfpgphpipjpkplpmpnpi)0yn"d$Q"4)-+-2-4-<->-@-A-C-L-M-O-Q-S-T-`-b-h-j--0+,-,/,2,4,;,<,C,E,T,V,`,b,h,j,.//-0"k"5;-<-C-E-T-V,a"!7$a"!02c"1M,O,Q,S,T"i")c,e,g&o"(Z$(o"%L-M,o"'/),+2k"%L,M,N$)5+---8R$,l%,Z$)l""49&v&5E(C,E,G,H,J"q"M.#C-E--#C,E,.(C-E-G-H-J"N$&6$B6X"!FHyv"p/}(#y"&r("Rx"!E_,t(&x&y$v0R0Q),z0)@9E9Ha,v($x&c$v(!%${"!L_,x(*z&c$z(!&*z(V,|('dZ%',|&!Te$P)!(0Q#!X_,T)!)4P'!`T$X)b"5$d%d&d'd(d)d*d+d,d9iLcQdTdXcXcX"Wk"!g&Yk"'cQcT"_p"!-$jp"@F1,LcQcQdTc";.9I5-d.d/d0d1d2d3d4c4d5dk$`#!6>p%<g"19gQld9"gQ&$%99&(m#6Wv"!.Bz#<c"!->W$<F!6e"w&V&g$t'N(q"x-'$McY"sO#N"v-#+K"7%WcW4T0e"s&)dldZ%"P#"R%-dXd`c`c,i"!(&5T"Q2+QdTdTi$G'cici$z"!*"z"6c":t"!7<q$M;cPdSdVcVdXc_c_dbdecedk"xP#'$Vce"xa#'/>c@N"H!,(;&7*9!7@Z%N"f#%Tcc2f#%cSd*H%cbdZ"f#Bf/.U-)c`dcc*N,%Tcc"tY#"y.HF!+&9!d"5*7B`5J`#%Scb.`#(y,6`,H`#@o*5ScSdWcWdZcZ"Y'%fdi$T(%Scb"Yi#!.$Pi#DF!+"9!d"5.78v.+d5d6cN$K!c"g"&K%Z%-*R#:i"!(&5*1>|.$^l#*k+$h,"O+>pl#m"S4e6mEq"q,f#SBk"m,R"SBFs6B_%*X8-dcdgcgc0P#(N#$|"%clcBbB!3HVD(TDs"RD!4<m$)>cQdV"tt#-`dededh4Ux##/A"px#!S&B!b*D-ncndT#*@`">_:!<"e$*N%#dg&W$!&&cy#"p"!/$R{#(N%(J%lcl*`)>f"!0BS?*z"I-)PcScVc_cbceckcncy"&&r{#$W).n|##ckDP"T"r"8WI#d5"X,Hd%!&&^N$!c"u($`N$(w%&Y.*l*%-Ed$l"(`-,W+'.;cM&P*!_&R*%hch&}I"W#!_&W#!&&eO$)ced-(:x%&wO$#cc>=!/(YP$!S"u+$sL,uL!&&tO$!c"YR$&nP$Kc_d2(SbVb_bbbebkbnbs"&&PQ$#cb>=119c9dEcEdHY&1i)$-m9m9p0T|$I(2c>c>dMmVnYmenZ%#AdE$vAv"UdXcddT#%McVdYcedZ%'AdEdOcXd^cgdZ%%QcYd`ch<:-(2m>d>m6Z"(O"-U#"<NQ""|#a%)-c9c<dThXfcbgQl99"gl9"cl9"`99"Xi9"Ti9"Q99"L99$@bEQH99"Ea9"@O9"<99&99SdVcbdec9"499"099"-99&QdTc`dcb"w")99"cJ&w")99"T9*w"!($w",g".O#%"994w"2q$)q9"cq&w")q9"ToR"q$8o"-%-m9m<d"m")g9"cQ&m"!a@g$/QjTi`jci2u")#99;N"w")#09>N"y"V%)4c;d@cPiSh_dbbk99"e99"bk9"_k9"V99"Sh9"Ph9"J99$;d@dG99"D99">99";99&89OdRc^dac9"299"/99",99&PdSc2w")J9"_9&w")99"P9"w"!($w"&f)!c2O#%"894w""^)%beQ"w")a9"bQp#w"-)4m;d@mw"w$,_,*}"'::#8"k()299#/"O)5,99)-c4d9cT$^FZ"c.1-d9d9dH9Q"la"/9"E99"@9Bq,-)0d<d<di"}"3)4d@b@dH9X$qH(O#!QBO##W#<cB>ka"'d7d8"z$W$:d;d<d=d>d?d@dAdBdBdCdDdDdEdEdFdFdGdHdHdIdIdJdKdKdLdMdMdNdNdOdPdPdQdRdRdS"s:1UdUdVdWdW"y@5YdYdZdZd^d_"N@-`dadadb"cB1ddddedfdf"hF=hdhdidjdkdldldm"pd"c"f%0h%4f%!@:j%$h%!G6h%!LBh%@j%!X6j%$h%Dj%(h%_"f%@N*$f%HN*g"|)0N*4f%P"N*4f%0N*P"f%^#g.Df%T"h%W#i.<f%!8"e%!9&g%!Q&RY"k#6>c>dA6E6MaVQVfYQYgeQedhQ9&)bA6E6J6l99)-9E6J6MNQN`Qh9lQ9&29"0E9eb9*59MfQ6VNVQYQ`9$a"y'99Q6VNY9YN9)>9QQV9VdYN`6`NlQ9&A9Q9Yb`9eN9.AcAdE9EbEcMbVdYb`6eNeQh6hN9&J9J9ebh9l69(EPMAQR`Rh6l6lO9$A:Q:l::+>9LcUdV9VQXcYQddeQhQ9#99Y99&59QQ`9`QlQ9#29e994)9-Q*x*!b(_W"3McVQVdYQYc&m&5#-bl99&2QQQ&a&1#59e99(99&R&5QhNl69%>9Y9"i$#)A"R&'`Ne6"k$=Q9&E9Q9`9e6h692"R&S"bEcJ9M9OcVNXdY6YN^c`6e6eQg"v'O"J9M9V9Y9`69)EOQ6Q9QNV6Y6"Y%U"&A9M6Q9V6V99*>9J6M6Q6VQY9YQ"a&#&9$_*-6`99)59$w*)QQ`Qe&k*1>9A9E9h99$k,4P1Q"9>6>cA6E6QcVQYQYd`ceQhQhb$_"&k,'a9)5&Y#"k,"a$!9$R$#9e"a$"_$)6VNYN"f'$z+E6V9Y9Y99)E9QQV6V9Y6(k,1J9Q9Y6`9e.f'!M$f')QXdYQ&d'%Ngd(s,%Q9e$W)%(EO"W)!Q"U)7N9$A9Y9l99'>,_*"k,!e(k,&U+%29l4ki#!9&f6)Q9b>d<m,!5"m,#9J,e"!>"m,!A6m,!E*m,!J:m,!M,m,!3,T&CQ9QaVNY6YNYQ`6`Ne6"^)=dlc9&J9V9V9YN`a"o,!J"m,%9YQ4o,!`4o,#Qe&^)(o,!h6o,+l9lQ9%(o,'98$Q&m,!b*{v"M6<6<N<c@6TQTgXQXfcQcbgQ"eZ"G&$b<a@6E6gf9)(Q@6E6H"{"9cdlQ9&-9E6H6L"_$K09H6L6Q6TQXQXacfgg9&49"2-9TN9)99"b1)QTNXN$m,u#<9L9TbXN`99.@9@b@cEQEQH9TdXQXb`6cNcQgQ9&EaEa`6cNgN9)@PH9QR`RcRgA"Z8R#%<:L:g7l::-99Q9SdTQVcXQbdcQecgQl6nd9#49T99&09QQX&c83-9`996$9-b@rq"/TQTcXQ`d$y&9l9ld9#(9g99&-"g8p"cJlQ9$09`9l99)49TQX9XQcNg6gNl69&99T9c9g"},)<9Q9Q"|+%c6g"},7@9L9X6`9c693"e&I9EQEcH9SdT6TNVcX6XN`6(^%U"nd9&EaH9Q6T9X99)@OL6L9Q6QNT&o8!<$b)+9Q99*9&z)+T9TQXQ$R(#49$s*7X99)09<6@6E6*_>3&-999<9@9c0o8!9.OS#"Q-DO-#-9,O-!0&Y#,O-!4.O-!9>O-!<.O-!@:O-!E0O-$},%cH9&O-!f0O-#L9*O-!O"Q))QcdgN"i8/%<9Tbgbl"zAAThXQXhcbgdl69#49`&u,&y$1#-9gb92-9&o8!Q&u,%b5d"rr"!d*No"/#0bgd9&4$m,+QlN9$9&m,!<"`)9XacNgNgQl69&@$m,%Jl6"t=6m,!H8m,"R&3L9QNT6TNTQ$m,"d/!h"zc#1&EaQ9QNTN(m,7QNQQT9Td`blh*m,#fX0m,&y00m,#c`2m,#Qg"_D(m,'l991@zO"%56>"VD$_:-)b96<6A&lO"#<6"yD(k>&oD-H6e99*5"P$!M"p;(ND%99H"T<'Y99)$qD)QNT6V&p/^"A9Q9Q9T6Y691AcE9EbM9MbT6VQVfVh(y>'eQeh$eJ;J9Yf`6c69)EJMo"y(-Qc6h6lN$o"","`#KVcVhYQedh6hQl69$99Yfl6:vO"%b90@vO"+;cVhYh.nO"!'*nO""w.'59eb"`#5*99VbYQ`9c6"b#"Z8->9YN`6c"SA"zO"!Q$}T"!c*zO"=T6Y9`992AcEbJ9M&W75VQY6YQYdYf`"vS"'hhld"zO"#6M"^-'9)EJ"c(79QQQh`dlh9&A(Y)"XD$t)$PN"-eQhd9&9&m*+`b9)59$U+0zO"35696<6h997<ZDM464c@NPgXQXdXf_Q_hgQgQk&XD+86;6@N$XD9;6@JD6SQbQc9n"i.)@6D6G&XD/D6G6L6XQ$Zb&!k"z/Q"G6L6PNT99)99L6PNQ9S6SNbQn&XDp"P9S9X9910c<c@9H9LdS6TdThX6XNXQ_6_NcjgQk"e(O"E9Xf_9b69)@9H9SQ_6b6bNg6&o"V#fb9g6k69*99Q9Xb_Qg6gQk6kNn69%49Tbk9n69'09SQXQbQn6n(cD!72k8!c(m8=>cMjVdVjXQYj_Qe"N$;l99$0bg9n69(4Q$y&5k6n6nN9&99`"x#In99*<9X9XQ_Nb6g6gNk6k"PD-T9_9b6g$xU")9SNX6"`%"}&x"H9L9S9X6_692/c;cH9JjL9P6S6SNSdVjX6XQ_QbdgQk$oD79L6P6Q9Sb9)@$}(/6ShT9bhn"O9&v)"i0$a*+XQ_Q`9$c(149;6@6D6c"oD"r+"f+!g&f+34686;6l99;>a_")c-d-j<UK;9jQcQj`clcu-u",X"!(R"ry"Lty"!A&qp"!E&mp"$ip"(dy",by"!S"Zp"!V*Vp"0Qy"!b"|o"!eFwx"0o$0at"<z%,ct"#9jg"o$(m$$Nt"(|s"$o$(m$$ps"(ns"$o$8OQ#%^&%(u_%!#*ma%S#pd%!,,k"!+(ua%b#rd%0q"0_$g"td%#,&,Xi%##10Pe%Dxd%5%(m(p4m4pQ&O#ld%%$6ODv_&18NQ"8$c%c6OZ$)69j9j"iJ+OHaLdL&RO$S(XdXd9$<7@7EP#"$b)"%a+"&X&$@7ELHL$"'X+"(X*")X$$E7H7L7("*X)"+X+/,XEdH7HdL7LPLdQ7QPQbTPTbXbXd)"-X*".X)$LaQaTa#"/X)"0X+"1X&$QLTLXL$"2X+"3X*"4X$$T7X7`7("5X)"6X+97X<d<"|^#%EdE"oR#!L""*b|#!7$Y%`$Xd`7`Pc7)"8X*"9X)$`bc7g7#":X)";X+"<X&$c7g7l7$"=X+">X*"?X$#g7l7("@X)"AX+-BXEc$W#,jN$|"Xdl7)"CX*"DX+"Ea)"FX+"GX)"HX+"IX*"JX+"KX)"LX+8Xm$&|7!E&S%%MXQ"jf$V#XdXd)"NX*"OX+"PX)"Q^+"RX)"SX+"TX*"UX$"l7("VX)"WX+.(e"*a$CXXdXdg7l7)"YX*"ZX)&|%V##"^X)"_X+"`<&$`Pc7g7$"aX+"bX*"c:$$X7`:cU("dX)"eX+9:y(!b"`#)PQbT7"W+%7XP*{(W$dfX)"gX*"hX)$QaTaXa#"iX)"jX+"kX&$LLQPTL$"lX+"mX*"nX$$H7L7Q::.E7EOH7HOL7Lc"Vq$#cT"pr$7Xc:$@6ENHa9$"|/%J9$$^Y"#99>yl$)69c9c"H%NHa$m"$i""`t$!%$:;g99%@6EJHJg99%$T_"n"g99/EdH6HdL6LOLdQ6QOQaTOTaXaXdg92"nX(%$X0%g:$"Y%!l"t%#$%$Z0%g:&"V&/iX)"hX#%$_07g:)"gK*"fX):w"_0)eXgG+"r)9c>(%`bcPg7g:$"g*AaX+"`X$%c8g7g:l7&"d+/^X)"ZX#$$4$_,%XX)4S-'cTdW$S-':l7+"z-5UX("g:$"Ta*"m.1RX$"g:&"Q&Y/+OX#"g:$p/%MX):Nj$.w0!X4S9#g:$P2!J&U#1IX*"HY+"G&U#7FX+"EX)"DX##$}$3CX*"BX)/AX:U1"S1$O%3@X)"?X(%c7$2!$"R6!="m6'$%`7$8!&"O73:X)"9X#%X7"8!:$|7)7X):6<Y9R"`1%g:+"k:'4X(%$`1%g:$"`;!2"x;#$%$b1%g:&"Z<//X)".X#%$d1#g:$W=?,X)0+XE7EPH7HPL7:P&#:+"{>1)X(%@7EPH"Y#%(X*"x?'&X$%"o@"Y#C%X+"$X+%9:<:@:g::9>aB)79d9d$vA!H$|%.X*!:$q"%Pg:2eB!%$eB#g:2gB!%$gB#g:*iB!0P"iB(a&%.X)*`32mB*`32oB*`3*qB!:{"qB(t+'9X)%$sB#g:2uB.n-.wB&`3*yB!.DyB,T0-DX)"g:#.OC!&"h1,SC)$"g:(Q%WC'-EdJ"V}#5QdVdXXY`YdY(UC!cX(UCG-E7EOGcH7KcKcL7QcScW""&SC!6:SC>qt#>SC(cd%!c&c"#N9$s"%N9$"Tm&%69$$kY#"eB-$L7Q7T72cB-$Q7T7X72aB&pQ"$Z&%fX).j'(x/!Q6x/)`7`P`$UW%%7eX*ZB!$$ZB2XB)$c8g76VB"pQ"*TB%#WX,nA$u,$jA!).fA!+(bAFO/GLXLjQjTjTjXj`ichcicj(`A$m0!H&SS".UA!".SA)$AXg7.m@%$c`$tU".k@-$`PcGg72i@)$X:`:(fW"'7X)00g@CHdLbQPT7TPX7XP`7`d*P@-$QPTPXa2N@&X.2|?&X.*z?%%+X$x;*d?-$@7E7H72b?$Qb"!7*`?!$$`?@^?7;d;d>7A7E7Mb${j%!X&hb%7eded:$A7E7J74qc")E7J7M6qc")J7M7Q,qc"+.,XM7M"}>5V7VPVbYP`be"w",oc"+QaVaYP4oc")VLYL`6oc")Y7`7e,oc"+:7X>d>"y(%DdJ"wq"!P"u8$W%$Y%!_"e6-e7ePedh.qc"%eah"S9.y>##h8oc""}:&q>%+BX$y:,Wq%#ed.ic"&X.Fic"FoP"+MXMdQc8S)X"a>$y2'WX+,$oH$_c"$Wn%#eb.cc""n%.V>)U&$eL$R&*V>1X$$`:e7h7&V>%A+:0k((m("}k%%PVb"m(%7YP$o("Wl%!N0X>+VaYP`74X>)Q7VLY6X>Q"M7Q7V7:-J7M7MOQ7QcVcVcYc`"{o&'ec:$"mV$%a9$$iV$#9$&_V$R"ac"$Xc"$Zc"%`c`"hP&&Z>!6"Z>)6H69$$Zc"79-H6L6LOQ6QO$Pc"$T(#cd&o>)aQPTa6o>"rMR"o>.Nc"4SK,hM(o>+c7cPcb*q>!X"q>!a:q>!LV"q>$g,&pb"(`%2S?*pb"BS?Fv/#LX*e..q{%u"U?'-AXJ(p-"TO&'bdcP6j?"06j?%7cL:j?"Sb"DQb"(WM+QPQbQd4WM#`7$qF2N@"YM}"N@!.(N@,W'(S)U#c@!7>c@/7;d;dKbN"v'!W"qt&!Z"z'-:$?7B7G6_@)B7G7K6_@)G7K7N2_@EK7KdN7NPS7SPSbWPZbb"w",_@)NaSaW6_@)SLWLZ6_@)W7Z7b2_@%?d?"zW%!G"dW%#Nd$S%$U%)WdZ7Z$^%/7bPbdbdf._@)bbf7i6PS#)f7i7n6PS#%i7n,c@',BXK&W#$O{&)bdbdn0NS#T"e@:rO")5d6d6"W%)MXN`N&{"/ZdZd)"Nc.c@&f30t`"!n,t`"+$XXi7n.jR#$f%.V@/X&$b7f7i(V@!C$V@)Z7bLf(V@%X+96e(EbNdSPSbSdW7WPWbZ7ZP"c(&i&0T@)SaWaZ6b`")NLSPW6T@-K7N7S::&Y-S":$B6G6K69$?6B6G69$;6?6B69:@hR'5@cDcDcJcLcP""!V"t?"tR'-c_ch#"n&_#$h>$O$$`>!+(U>!",R=$OF$z<$i'$r<!+(l<#"W&bHa"^Z")/(m(m:Y<+m4m5dL&b,Lu;!+(q;%"AX(X;$Z/$P;$}/$x:!+(p:%"6X&m9!a$v2$e9$i3$Z9!+(R9-$+X6P6P(n8${5&f8)#8P8P(d8!D@am#N"}x"!:{$am#!"(PI&em#A""mX("0X#"lX)"1X#._II$"2X#"jX)"3X#"iX("4X".kI9("5X""gX("6X#"sI{"dy"=eX)"8X#"dX("9X".oj"I#":X""bX(";X#"aX)"<X#.{j"I$"=X#"_X)">X#"^X("?X"*fJ9("@X""YX("AX#"i_#6Vz"*k_#$OHW$#"VX("DX""UX*"Ea""Ta("FX#"SX)"GX#"RX'"HX#"QX)"IX#"PX("JX""OX*"KX""NX("LX#e"U`#8wz"g##"KX("OX""JX*"PX""IX("Q^#"HY)"RX#"GX'"SX#"FX)"TX#"EX("UX"&`L9("VX""CX("WX#Hv`#2Nq#1#"@X("ZX"$tL*N|"A"">X("_X#"=X)"`<#(mn"&Z|"A#";X)"bX#":X("c:"(_M&i|"1""8X("eX#U#ka#$a=1#"5X("hX".oMI#"iX""3X("jX#"2X)"kX#.{MI$"lX#"0X)"mX#"/X("nX"@WN"!/P"Ub#2YN"%PHa>YN"!Lc"op"o&}a#"W72Qb#BY72`b#B^72lb#'""gK*`7!;O#`7#gG:b7*au#Jd7*mu#Jf7.ic#2h7!/Hh7(sc#0j7!(&{c#@n7!$&Wd#@r7!#&fd#2v7!8s"v7$Yx#0x7$R$D|7$R$FP8"sw#:R8!0LR8(v|#2T8*gk#JV8!%$V8#g:JX8!%$X8#g::Z8!;O#Z8$TS$2_8(Ry#!GJa8*ay#Jc8l%my#d%mN"!.$e8'JdL7"zp#'7QPV"co&!Y8kN")7QPT7R"kN"%7X7v)kN""po$$je"+QdSdWX${l"JiN"!X&x7!YV&iN")a#"H`U#iN"'%AXX"^n#P&RN"Ll}",j}"JRN"!bN"RN")PQPTSN"RN"%:L:w$_N#R"c6(X6$b}'%gdg(c66aN#(f#N"c6%%,X"U;!7:N6!7R"N6"mO$j#N6!H&q:8{O$;c7cPeXgPlbldld6N6!W"N6%QgPN"N6)SgPlLN"N6@QM)$BXWXBl5!X.l5O#Uf"!4Huc#'MXXh$uQ$%gflP"f5)X#"HXa"f5!PBf5)dgPlP>f5)`gPlb>f5!U&f5)ScPgS>f5!=&f5!:Bf5!1T"oS$BQ5"yS$P$Ve"}"dT$!5,nd"55%b&b'c(c)c&_g'97>d>dA7APE7JP"fd'#dY$th(x$dnd.#$X$c%"%c&"&b$$AaE7JP#"'b&"(a$")a&"*`&"+X&%,XE7JLML$"-X&#.XnX&#/XmX%"0X""lX%"1X""kX#&_U$n"##2XjX&#3XiX$"4X#"hX$"5X#"gX$#6XfX&+7X$Oz#9Xd`bc`eXgdld$&Q3n$$#9Xcc&#:XbX%";X""aX%"<X""`X#$Q7V7Y7##=X_X&#>X^X$"?X#"ZX$"@X#"Y?$#AXXX&&BXV7WXYP`P$&m2W$$#DXUX&#EXTX%"FX""SX%"GX""RX#$Y7`:e7##HXQX&#IXPX$"JX#"OX$"KX#"NX$#LXMX&2A"uk(-LXMXQbV&kW$!b"mW$1h7kdndnd$&g2)$#JXO&q"G%"Qb""HX%"RX""GX#$eb"ZS$f"#FXSX&#E`TX$"UX#"DX$"V`#"CX$#BXWX&"wF$uS$$a2)$#?XZ&o&9%"_X""=X%"`X""b9/l7##;XaX$V(S"$"cX#"9X$"dX#"8X$#7XeX&(6X$q,-fXh`nc$&^1+$#4Xhd$y*I%"jX""2X%"kX""1X%#0Xl&_,?$"na#".X&"-X$",X"`-?"*X$")X&"(X&"'XA>ck#$Z4%HdL2^CEld.#$9$X%#%0%X&#&'&"e"%&"(&u"!*&U##,XFb/!A*b/%"lPN"^/!?&^/E,7XVd_cbaeXedgPkdl8$u*.`/!H"T(!b6`/)R#$cG"UO")#=X_bB`/!X"`/1U&&BXWX`=$fO"c"`/)X:`7ce"`/!@,`/2h;(g(!lH`/!X4`/"T<!bF`/!X.`/5&AXL7QLTSXXe"b/$q<c"f/#+6&^=$q,3fXg^lc$"gd*l/&W+8l/!#&V>+##0Xlb*t/!X2t/%%+X(k>4z/!(,w>)F%A&=0w>547;P;b>dGdJ,`T)&YT)*w>E#%X%c&#&X&b$$87;a@7H{>+;L@7D7_"{>)@7D7Gc"{>1-7XD7G7L7"RX"*}>6O?!dBO?/a#$G7L7PP"O?$o0"O?/L7P7S7WXN"o0!>,o0+P7SPX:c"o0!>"bq$U"LXLdMXS8ScVdX7XP_7_PbPedkdki"o0+Xa_PbP"o0!b$_$&o0!Y6O?/&AXXX_Lb"dY%c"o0)b:g7kc"o0%-6X(S-;fXg7k7kPn7nPnb2b?Hs0)#kbna"q0,h?!^2q0)#+XnL:j?:SV#!5"Uu&!<"uR"0Rg"${,p#n?!>O#n?&Zn)!b$Rc"+gPgbl82|/&m(<NN"'cPga&n?P"|/(n?)PcPgLm"n?#:ce"|/3<d@dEcLXLb"tv"*r?$iq"%cdci$n?)PQPTLq"n?%:Q:g"|/#E7(nX#,^w)#fXe"|/$r?!b6N0i"r?)&"&X#&v?3#"%X&"$X3Ac"VY)%8d;$i8$hv*"e_%$Xa"1hd="nX%"m&w>%kX""ce")iX$"h"_>)#"fX$"gg"1dX""cX%"b&i.%`X""ei")^X$"Z"N.)#"XX$"Nk"!V"Zo"%%"T&h-%RX""pl"%PX$"Um#!N"jn"%$)L(W1&Qx"!#"_o")JX%"I&Z,%GX""np"%EX$"am"!C"Rm"!$"}q"!@"tl"%%">&Y+%<X""ys"):X$"9"q*)#"7X$"bv"!5"pj"%%"3&z)%1X""`x"5/X$".X#"-X#"N6b"+X#"*X"")X%"(X""'X%"&X""%X#"$X+($T($b;+edV#(M"qs#!Y&Ob*?T#.4k4n@j@nLdLhP"e})#Xf$ZT%!<Z$Q)!kw"Q)'J^Lj$rl%!Y"a0&Q)!di"Q)!ly"Q)!kp#Q)!sBmh'2Z1!iFTl'!i8eh'.Vl'!i<Vl'.Xl'!i,Xl'<Zl'4Xl''V#'G&d^-$rQ+!z_"z$4fl'JUp'$":T%2pl'>V%2tl',xl':X%d"cmcnc<"nb%"ma""la%"k`""j`#"i`$"hZS%l7"aU#v'^7;i%'-m-p9m9pEpQ2fd*3h"$a%&%2%?&PP#)&)2)?$O,m'.&.2.?1&121?5&525?:&:2:?:K:X=&=2=?A&A2A?F&F2F?I&I2I?M&M2M?MKR&R2R?RKU&U2U?Y&Y2Y?YKYXa&a2a?aKd&d2d?h&h2h?m&m2m?-3%?)?.?1?5?:X=?A?F?I?MLRLU?YXaLd?h?m?"""qR#!G"qR#%3%K>R"%KRK"R"!K$R".de"-A#3%D)LX"W#!$(Zf"-4%?)I,X&P"!L6U#!L(U#&vT"'CnX%$`%!@"P"!G*P"1@R@U?Y@a@&`%)#/Xm?.tg"!6"oU"l"3%3)3.:1:53:?=3A3F3I3M3R:U3Y3a:d3h3m::dV"x"4%.)..3135.:?=.A.F.I.M.R3U.Y.a3d.h.h3m3$"50.Yi"x"K%&%2)&)2...2121<525?7X:?:K=&=2A&A2F&F2I&I2$`+<Y+3a2a?d&d2eX"O+%2m3&lX"!:$lX"!%$l%%313"N((l%!?"Q)%?a?"{&)3"#:W*eY"!F*eY"M3%2)2.21255:L=2A2F2I2M?"`)!?"`)-2m2##==2SZ"!4*h#!3"i*2h#+ZXaEd8${&"zZ"1G$#A7XX&5*b#!2$o*#BX&d#=GU?WXYKa?d2h2m22k^"!C.|%-3:;=5A?&d#-?U@Y@a;"k*#3"(d_"!:.d_"!5.|%)2:2=2"s$)2M3R3"z+!2$f#*R`"!,&R`"A4%')'.'1'5':'='A."h#%'OX"X"1+a'd'h'm'2y`"'+&k"*{+Fp6$l6'=K=X$p6KAKAXF2F7F?FKI2I?IFIKLX$x63MSMXMXR2R="r,-.U2U?UK,P7#Ya4R7#dK$T7#hK$V7#mK4_c"&Y($Y4Y"?=XAXFLILMXRLULYaaLdLhLmL"#IW2Ud"!N"Ud"$Y(0_"!K"_"AUUKYaaKdKhKmK##FV"vd"$us"!N&X-.V"'DXFN&j#%VYY(j#6me"$X-(V"ALALALFKIKMLRKUKXX"Q8"f#'$"YI,^f"6|%-@A@F@I@"U8!@"U8+@h@m@"0Tg"!:*Tg"$|%$j.-3=:A:F:*U8!:,U8/;Xa8&#:3&ug"$X-1.1.5.9X:3"t4$W8).U.Y3$W8+m.$"d0.lh"!^N"X-#6X"{B)F=2=8o"yB'UKY)$x,"r,!A$p,#fX0yB&oj"!F"oj"(z3-?1?5L:?2}@7LYLa?dBhLm?"@hk"!A*n,%K5D._")KRKUK"c6)?hGm?.Vl"!D"Vl"&n,'.L1J"Y*<j#)?h?mL*}l"14%2)2+X.K&_+@^#%?mF&nm"!7"n%(sF,N"(`,$N"#?"(Y`#%3%2*l9$t*$WC$Z8!3$l9+-3%')3$o+#:..wB!."wB!.$m+#.h$_+'.)2-&_M#.K"eX""g+#1K&kX""o++5K5X5a0P8Ls+#MX$u+8oM(l7BoM13)3.L1L5a.t&-XR?U?Ya*t&,UR#!:$UR#3$3%?)2.K1KP"X"!#,NS##5#$oK)L1L5Y:R"!Y(R"!$(wS#-4%7)?,X"U#4x.!?"uM*P"/-X&$.DnX"wM13)=.G1@5@2_+!?"wM(h%-$/Xm?mF"yM%#lX"{M)="#kX"}M%2)2"}M!:Js+;?#$2XjXjX&$3Xi(QN"!5"y6$QN"FW,#h3${$C50##gXgX$$6XfXfX&LFWN"%&:2FWN":t+'a&a2$WN"#eX"RB"hJ58X##d:dF$$9"ps'2`N",|%!?"d')?a3dL"`N"'$:>b(wY#%#a9&dN"%#`X6fN"!?.fN"$e"%KdD"gI7$==_X_X&$>X^(jN"!5.SL!?.jN""Z"#ZX6lN"=#YGYS$$A7XXXX&6.SL!32pN"5?U?WXWXYLa8.rN"9#VXVX$$DXUCUD2vN"!3:vN"&W6)"$EXT(xN"%#SX&zN"%#R5N"|N")?U?Y7*|N"7$HXQXQX&$I,P(Ua#$y,>PO"+OXR?U;6RO"=#NXNX$$LXM+M7&l|#VO"#LX&VO"$XO"!=l#XO"1#KXKX$$JXq"_O"%$IW*ie#%#HX&cO"%#GXm"eO"%$FV"`f#%$EX*iO"$W.2iO"N"kO"1#CXCX$$BX"oO"$W.2oO"R"qO"1#@X@X$$?XBuO"!GBuO"%$>X*wO")#=:=A"yO"%#<X:{O"%?A?B{O"%$;X"}O")$:3:8&OP"$W.&OP"#9X&s3HQP"1#8X8X$$7X"UP"!_R"UP"36X:?:F:F=8k$WP"1#5F5S$$4X6^P"!QN"^P"%$3X*`P"%#2X&bP")#1A1M*m-!VR"dP"%$0X"fP"%$/X*hP"&m-'.L.XV"jP"3#-X-X$#,X,&V_"#+Xa"pP"3#*X*X$#)7)$T&!@Z"tP"1#(X(X&#'X&bq#)3%2)?X"|P";#"%1&"$X&3%3);Z"TQ"/j"$F%2%?*Oe$!.s$vP#!:"j9!S>xP#!:.XQ"!5JzP#!L*zP#(vg$%:%G&vg$!5N"PQ#%KYS"jv"!:u"TQ#*d#*TQ#!6R"TQ#!K&VQ#"Y#FXQ#!@y"XQ#$m/$XQ#:O,#Y:$Q,#h:V"_Q#JXQ":_Q#!Mp#RQ"!:0TQ"&h+T"cQ#@PQ"(cQ#!>*cQ#!9*cQ#,NO#<zP"!:&tR#%2h:V"gQ#>zP"#a?2gQ#!B&gQ#!7T"tP""t<"tP"#h:R"kQ#LrP"DkQ#0UT#:kQ#(nP"#h3}"oQ#!."jP"!.:oQ#!md%oQ#&y78vj#&fP"!:Y#sQ#!X"kM!GJsQ#4aO#4^P"!S"kk#!K"p#{"wQ#*n#6wQ#$k-N"wQ#&UP""j#T${Q#$T&F{Q#(OP"$x8x#OR#!`q$OR#"X->wO"*RDq"SR#!G"uO"!GJSR#(N-@SR#!?(TMQ#WR#!G:WR#"P_"JgO"(b#!:b#^R#"cO"!5P"bR#.aD4gO"_"nR#+j"%2%?^%nR#6k8JgO"HrR#!X,X'7$X%"%:&"&X$5N"lR#!S&T"(aO"g"pR#*^#*pR#!6T"pR#&f^",aO"R$tR#$t0FtR#.U,e$xR#!N,x7x#tO"#eX&_Cq$}R#X"PP""OS#"PP"v#QS#%BYG*QS#!8Z"QS#!K(SS#*_P"a$US#HiP""US#2iP"S#YS#4oP"4YS#!nh%YS#{"uP"o"`S#,yP"P"`S#o"OQ"S#dS#4UQ"4dS#$j.R"dS#:^Q"a$hS#4hQ"6hS#2hQ"a$lS#!au$lS#g"tQ"o"pS#,xQ"P"pS#(}-@pS#4NR"S#tS#,TR"0tS#"Sa"N"tS#4ZR"r#xS#!5P"xS#JeR"WN#|S#!(m"xS#|9aX%1K%&'d)&*d$ZO"+3d526d(ZO"+?cA&Bd$ZO"CKdM&NdNdR&R2U&WdY&$xt*$VO"3eXeXfdh?id._S#%-d:._S#-&)&.310"t0=&A&F3I&M&R3U&Y&*ZO"T"_X%/&)&.21&5"h/!A"_$!M"T$#Y&*uX&%$=06XS#%^#5&r#%&5)"Pc&2r#'ZYZY"XS#!&*XS#-.Y:$$A+&_X%(l#-&:3=2A2"iO"&n#"XS#-?a8d+h&:TS#%*U7*e&$a"$b+$p#$rT"%&h&N"TS#!4"_X%,v#)2=(A2&e"(_X%%&h&2PS#!+.PS#)&)&.'"Z"%'=&&qO"!&2_X%%&h&V<_X%3^"$d%&(d)&$W.70c1&124`5&52,pR#/<d=8=8@d(pk"/F?HdI&I2"NZ'%&M2$`E+TdU&U2&aw/%)Y2$dP";cdd2d?fXg^h&h2*bP"-c##5:5F"jR##ch(`5%?13"_B)3A3F?"n&!?"r?*WAFjR#!4"qZ&$e"$lP"E2A2F?I2M2R?U2Y2a?d5"|E)$0X0a:fR#"Z"&fR#!8Bv#%3h;:ZX%%&)&&fR#!="b=<j#%2h2.bR#!*"tP"!&"tP"$mn"@^#!3BZX%!&"bR#$mn"!2"X:)2M2R3"^#!3"^#)3#"%0q"^R#!hh%^R#_"S^'LWR#,S^'<WR#j'Y^'!Ga"OR#$|P"$OR#!=&Y^'!:*OR#1:=:A3F:I:"t7!:"Y^'!:Z"Y^'o"{Q#$s11.12527X:&"zL!&"eG!&"zL)&d&eX$iT&"xP#!-*xP#)&)&.&"kO"@V"13h3m'"#:2*xP#!-.ZZ'$_"!&"q{"8_"$_T&)&##=06tP#(V"!)"nL2V"#ZX"RW"%&m&&tP#).$#A+"ZZ'(V"!&"SN#%2BX,X"+WXY2a2"VO"!&2pP#!**|%$`L%3A3*V")3Y3a,"YL!&*pP#!..pP#!(.|%%&:&"|N"(sQ")2Y2a&$_"*lP#!+*lP#0V".xN"&ZZ'&X"S%ZZ'(jP##RX8pN"(U6'aXaah#ZZ'%LRX"ey%!aFZZ'$ep(DfN"%KRX"ky%!ay"ZZ'1LRXUVYLaYu"ZZ'%KRL"WN"%KaLe"ZZ'0SN"!GB`P#$ON"0ZZ'$Qj"$`P#%:M:"V7!:"V7DYP#%.).}"YP#!E$d.+.21&12$hM"},%2=88Pk#$qi"#U2({L$wL(uL&UO#!:"UO#,Od")35?:::dn"!5(tj#>UO#!4*yc"%?5?$g5"Yh#!2&z2!2"iL!2.QO#!8&QO#"h#"Y)!8FNq"%;m?.ZY'"_L#.?"ZL@^#)2h2m?&}N#$k7!3&VLHRs"!:2|T%%3%&2Qj#@S#!22RLe"UO#k$xT%0SO#8x6(r6!d2Re&FtT%%LR?&wa&!X:tT%DOO#%KR?&sa&"R"a"OO#6W#Z"OO#,U#!S.OO#!K2OO#%G5G6OO#!G"OO#!L*OO#%FmKN"OO#)?1?5:"TL,{5!?"{5)Kh:mKFOO#-3)3.;1?:W.!?"W.9Lh3h?hLm@$"5<6OO#(|R'!<"RP$4f.!?"f.!K"jS%!K*RN#%SdXV"dS%,p#!QY#dX'(t#%KdKy"dX'&r#&`S%!L.`S%!:.`S%HdX'"n#$`S%'a8dG>dX'%?U?FpO$$p#)Da3d;R"YS%-4R<#3%."v#!."r6!."z+!."Ug"$RN#!.6dX'4RN#)...1&"N7(WM!..US%%.d&$NA:RN##T"8SA(T^$'=?=K(OM$}L${L0n}"$j}"$uL,mg'@zg#BU}"(xA-3:3=LAL.yd#(Qh()?"$IK*kL(U}"!B*U}"$NB$j=-KAKF?IL*Wh((ih#%$FI"qL,U}"!A*bZ#*r#&U}"-@M?RIUL,a"BU}"6l#"{L%AI?"pZ$%IXX0a"#YH:U}"0p#%@AG"e&$ha$.Yi#R"U}"0v#w"U}"$Ye"S#U}"!F<bM$z|"#=8U#dM,W|"4hM!LN"hM_"W|"!2"W|"LnM4pP%$rM&m,&xN$P"tMP"W|"LzM%#*SBW|"LNN"@W|"!Gu"RN"_"W|"!i&W|"+&='c'd"im*)+*2*?&bg)K&.20d1&3d3d6&629d:&:2<$p}1!&"qg-'&B2E"`t#'HdI&"yg-'&N2Q"dt#"of)!&$iP,+YdZ&Z2"gf)%&a2"bR0#&f"Nx1Ii&i2ldm&m2-3%5*?.31&6"bt#!B"zn#9N3R3U&Z3a3d&i"hp$&Y|"$_O$$Y|"/?*?.21&6"pr"!B"qm"9N2R2U&Z2a2d&i"X',|p*!#$R"V"`#'$"*I(ZN"'*K,XX"U#&Y|"!7$XN"'*@.?X"f%'/Xm>.Y|"!)&Y|"-2*5.312N"b#!3.Y|"!,(Y|"!*"Y|"G6':'=&B'F'I&N'R'U&Z'"Rs#!X$p%*tt*7+fX&J%&'d*&*&WP%)3d626*WP%)?cB&B&p6$f+(xN$!W"Y+(vN$&S+#2i0QP%.V}"/*3.3106?By&%3i:JQP%)3%&*2"^)%::?:y&%?d2"f+4V}"%^#4&h##&6"`b#4h#+Z?a?d3$y&2bx*!5*b#"`b#'B2B?,d#%WXZ"bN$$t+8V}"*d#)3=3B?*d##3Z"^N$$x+>yO%"Yk"*j#%2=(&s$"zd#.e0>V}"+*'.'1&&x+"R9!N&uO%$z+!i,fY)!.&bl*#l"(y+Lv6$r6-?d?dAdA$z69cEdF2F7HbI2K`"va2IXMXMdN2N?QbQdR2R=TcU.$T7!W$fa2&X7(Z7(X7%fdh&_7$a7/$"NH#"Kd*X}"0^((s%!D8V3#I9"mN"1c""Hc%"R5&X}"0^($Z-)2N?R?2s7%#F="X}"-aTa$"U(2Z-"h#7DXF?I3N6R?U30y7*X}"!7"X}"2b#?AXB?F?I2N2R<U2XX0Q8.vq*"wB2d#)?F5I'<Z-.X}"!-.X}"0j#%2B3*u/%0Z3,|%/;Xa1&#:,*X}"*Z-$X}"#B..W8$|%"Z-2X}"!Z8Z-)c1&3a$Z-76?9d:2:?<d=2_"QC(OC=Z.Z2`da2a?cdd2f&u8&}B!c.VN#&Uv*.m')?::=,6y8!5$_6+"#3ci>6VN#"Sc#"m'%26?Bu>"d;'##0b&di+*VN##*3"VN#!3FbA%)i?"VN#!^(VN##*2"VN#LSA!3"VN#':$")$n%)?.?11N"fC*VN#!($o&V"jE!-$F,z7:uB3i'm'.i"%&'"iM"sx2"|}"&b}2+&122d3""%4d5""<P8<q+!MBs+0l74j72uM#&*P"z((uM$TO%%.%0*TO%%2*2R"R)$uM!a(ia+'#3%3_"`#'$"*<&uM%2*?"Q|#R"U#&RN#!C&RN#)+*?.@V"h%)$/Xm>&WP&(RN#!5*RN##&*"Y|#N"j#4TO%%,i8&RN#%&*)T"QN"%hXi$TO%!X*RN#!+(TO%+%2)d*&*dP&#d6"p|#&dP&%dB&*zf"%dN&(zf"+U?YdZ&(YP&#d?&TO%%di?.TO%%FdS0OO#!*"Rg"&aI!&"PB"oy$+Z&a3dQ"`N"V"OO#!*"Zm"!6"vi##B&"VB%&R2"e")KdDi-LOO#&r#).:?=?4r#"lN"'Ed?i,TO%-XYX$$AX(OO#&l#)&:3=?"YT"*n##WX&rN"#?i<TO%&^T'&p#)&:3=5&hG)&R3U@"iB"l#V"TO%,v#'2=2B"ye$!N"TO%"w,#3i4TO%2WT'7*&.'1'6&:'='(r#(OO#-Z&a'd'i,TO%%.N:"OO#)XMX&m"zq$,{B$f80XO",}g"6XO")cF2Hb&XO"%`Kd"jO#-XMdN?NK"ZO"%=Tc"fh"&_O"8ZO"&Sg3&r80ZO"3$"NM##KcKd0NP#'*3.&"`J!&"n4!+"_O"!1"n4!&"n4-&"$I9I>&aO"%#Hb"cO"!),NP##*2"e"!2"e"-2F&I?N?&n4!&"n4)&#$F0"gO"%$Ea*iO"!58r#"NP#)?I?N6"VM*v#2NP#%7BD$NP#0l#+AXAXBK"zP""Vr""qO"&r#"qO"0NP#(uO",p#!@&uO"!0"uO"*e&2NP#%-=94NP#.v#)?B:F("S:!&"{O"*e&"NP#)0&$:+0NP##*'"Z"!'(NP#'B.F&"W:!&.QP"!&BVO%BUP"!a$UP"+6K9d:?$VO%c$WP")#5X5X&|P#0^P"!LN"^P"%$3b*`P"0|P#!($mP$"dP"!?R"dP"%$0X"fP"6|P#$hP"'.L1?R"jP")#-X-^,|P#!*(oS'!=R"pP"1#*:*F$#)P&tP"!@Z"tP">|P##*D_"qz",|P##*8a"TQ"i$VO%:``&:|i$4zi$R"XO%!?&}d)!X&q|#k"XO%!?&Oe)%XdKi"XO%6`#Z"XO%(U#!L$U#Z"ZS'!?.Ui%g"g_+J}_#|#XO%!Jw"VS'.rP"#&Y&|P#$S+:e_+!SR"PS'8nQ$H|P#P"hQ$!?&hQ$g"|R'*dQ$"pY$,|P#!:>e_+>^Q$"aQ&"f#e"xR')3R3U@"ZQ&!@JxR'!4Ff^*!2*e_+!3T$e_+N$zP&<UP%(SP%#UX<bh%,X7(cj$}"WP%1LUXYXaXdX}"g_+%KRU*_"<WP%*mv&>WP%2j#m"WP%%KUL"dP&%LdLS)g_+!Zp#fR'6Sv$"VZ*0^R''dNdXQ#e_+!?"Wt$!?"Wt${"e_+!?"ft$$_"s"YR'0j#c"e_+,^#!La"UR'$fm'%?a?&fC4UQ%a"i_+y"PX)!in%UQ%Fkl'c"WQ%$fi's"WQ%&xk'q"WQ%*W#i"WQ%&fk'm"YR'0}M`'YR'$Wu"/)&-d..0d$^R'/7X9`:&<b$^R''EdF&$kg"+M&QdR&(s^$+Y&`ba&"_g6&mW)+fdh?ld6kW)"}d1Z"nP&1Lh?m'"$:2.RQ#!-"jN"!a"RQ#!aV"tP&!?"k_+!&N"YR'JxP&&qS((zP&@YR'JNQ&&xN"!2*PQ&@YR'@TQ&)?Y?a,$iS&.RQ#!.2RQ#!($QR$BZQ&$TR%!&$p#N"YR'>aQ&*YR'%&d'*cQ&4TR%N$ST(0YR'(WR'<iQ&0aO"V"kQ&c"^R'$oQ&!X*oQ&@^R'!XR"^R'$uQ&!X*uQ&w"^R'${Q&!X2{Q&k"^R'(QR&!L2QR&p)^R'r#NW)Y#`P"c"xV)8dP"O#k_+8jP"w"tV)8pP"g"k_+8vP"_"pV)8zP")#(K(W6k_+!Gi"NQ")8&3%Ng"^R'%2$?*ms.)3(3(?"qs.{'&+2+?,d0&020?4&424?7&727?<&<2<?<K<X@&@2@?C&C2C?H&H2H?L&L2L?O&O2O?T&T2T?TKTXX&X2X?XK^&^2^?^Kc&c2c?cKcXg&g2g?j&j2j?-3$:(?+?0?4?7?<X@?C?H?L?O?TXXL^LcXg?j?"#$>$K2`v.%3$KJX"%K^K$X"&PQ#!D$OT%'$@(LX"`#&PQ#5D&4$?(F+K,X&P"!L.P"!L"U#!L$P"(ci./%3$?(?+@&P"!@.P"-@X@^@c@$f%&Yj.!;2ay.j"3$3(3+:0:4373<3@3C3H3L3O3T3X3^3c3g3j$OT%!8*PQ#r"0#4$.(.+.03437.<.@.C.H.L.O.T.X.^.c.g.hXj(OT%!.(PQ#?$&$2(&(2+&+202074t+G@&@2C&C2H&H2L&L2O&O2$d+/X&X2^&^2(U+#eX"S+%2j?2Tm.#P%$j%-3034=7?2j%!?"j%+Tg?j5"8}m.!5$PQ#j"$2(2+202427?<?@2C2H2L2O2T?X2^2cKg7j2.nn.!8$PQ#*h#)373<?4h#;ZX^?cLg3j3$"@<*OT%%7&5.b#-2<<@?BX,d#?WXX?^?cKg2j2$"C<,Sp..|%$i*%?C?*d#/?^:c@g3j$PQ#!?:|p.0|%%2<2"s$$h#=3X3^2c3g2j2##H12mq.A4$'('+'0'4'7'<'@)"|%%'O'"S-/.^'c'g'j0PQ#++MX&j"2y+Ft6$p6N#@K@XC)C2C?CKCXH2H?HAHKL2L?LKLSLXMXO2O?OKOKT2T34R7#XX(T7#^X8V7#gK$X7!j4|P#,V-$R3O"?@XCXHLLLOTTXXX^XcXgLjL"0nu.!R,VS'&W(0_")QLKOK*_"%KjK*_v.*|P#<h#!D$j#!L0j#&|P#!T(|P#6b#-LAXCLHK"d#%LXL"P9)LgKjK&{S%!G(|P#6d#1@C@H@L@O@*Q8#@j$|P#!?6mx.!5*|%$h.-:@:C7H:"h.-:X:^:c:$Q82^y.!0*V--.4.7.9X"r4,S8$_9%.j..Rz.)+eX&YJV-?6X727?7K<2<=<?@+c"{B$t,+^2^3^?"j,+IcKcXf2wB'$"gH&yS%#Ch0k')L7G<?2r?%?^?"}),zP#!G2z|.,j,!G"z(,_"!K&_"-BjK##0I2k}.&j,'.X0L&U*<j#%?jD,zP#$Y#'+?0A:P"$^#"bC(PO/&n%(fE0N"!@"N"$`C%"(>$yS%#$22f9BOC'-3$'"F"k+DoB'j..g$X+-2(3+&+2&ul."a+#0K&{l."i+'4K5d$v7'7K7X0z7Ho+'OKOX,ZC#X?,d7#^a$f76kM$c+)L4L7X.r&!X"W>%ac?&kM%9$>0hf/'$3$?"_+%K4KLX"&pP#!8$uS%"eKH`#!Y$R"&pP#57&4$3(?+?,X"U#!L.P"!L"P"!L(P""pP#!X$pP#7$3(:+?0@4@7@.R"!@"R"!@&h%'$/Xm$oM!B*pP#!X(pP#"u-)30:4:N"sM-$2Xj8j=.pP#%0#5"s6V"wM%hXj(uS%%.g:,zS'+$&(&+&"gEK&72<&@&C&H&L&O&T&X&^&c"UT)$_&"sO#!X&zS')*c7%3&a"!+"q/<_"!?"VM%$:X.sO#!X"ZM!)(xR%&e"%&40"`H<e"-7j(#$=X*sO#!+&cM!5*Z"!&"r'2Z"#ZX"eM1;g+j&$"@0.xR%%+X7*e&5&4&7&<2@2BX,a"#WX&kM1.g&j&$"C/.sO#$oM0a"!0"e*(p#/?^:c&g&j$sO#%2T>"qM0sO#!X"uM0e"!&"tR"$e")?X:^-$e"'#$H0&sO#!X,sO#6Z"$yM9&O&O3O?T?X.^&$a"2sO#!+"xR%V$ON""QN""ON"'OKT38QN"<Vg"#caBON"0mO#T"SN")L^Lca"SN"%$IX.mO#!R4mO#N"YN")K^Kca"YN"%$FX6mO#%X#5@`N".bN")L^LcY*bN")#CTCT,mO#<fN"2hN"%KXL"hh"(hN"-#@G@G$%$mO#&R90r#%GCD>nN"!%"oO##?m$qO#'$=X="V9/`X"$<5<<*X9(zN"%?@?BzN"!%"uO#3Xj8&%:X:Xb"_9'c0#64RO"+9X<?@8<TO"$Zi"KdX#$8X8Xg.$%7+77eXfX&F(w/)024&4"SU'"SO")=<=@+Dai""_i"32^3c2c?eXf.Zi"CgH#$5X5XdX$%474CcA"oN"$U#!3"oN"<Y>3?gDj5"%3X3"t%1%"j:"$2X2"`:-kX"$1X10b:-24G7:<2.qi"!2"qi"$lDA%0=0I_XlX&%/X/X^8&SO"&T9#.X"UO"!;<_A&h:/6j?&$-X-"f:',X,X,f:&dO"$ig".t#&f:32g2j7&$*X*"d:%)P),d:%?05>mN"%?^:$yC9"$(2(>T>&$'X'"ta"!&(^:%L+?*Sj",j#):X:^2"h#92##%XQ=&#$+PX"|H!@@XP"#OX"Oj"&ZP"3&"NX$"M+&i"RP#$PP#"VV'%.)2&io/#&-"W:53d3d5&9&929"U:"xn%"k^#9E&E2E?EKEXH&H"Sp&$Tm$;Q2Q?QAQKQXT2T3"nn%"mk#5`&`2`?`K`X`"gP""jn%w#&h2l&l2l?lK&"Kd$"JX%3$:)3-3035&9?<3A?EXH3M?QXT3Y?`ac3h3lL"$$9$>IX$aP#)""H9%"eP#&wi"-?)2-202"e"!2"e"-?M:QXT2"e"?2h2lK##'bFX&#(aE$rS$)4$?)?0n##DX"X"!3&p#!Y$p#%$"*&|q07+XBX&5$3)?,X0d#3AKELH8M2QL"f#!L$f#'$"-<"vl$'$.X?&X9')=-?*f#1@E@H3M3Q@"d#!@"d#+@"$/X>$`Q"-:"#=Xl:$`Q"#<4$R9W")2-30:5&93<:A3E3H2M2Q3T2Y3`3"n#+:#$2X;&PT$!:*PT$'$.).&X&W".93<3A3E.H.M'Q.T.Y'`.c.h'h3l$_T%##8&PT$!7&`Q"`")&-)02526X7X92<2A&E&H&M&Q&T&Y&`"bQ"%h2l$pU)'#5:d"al%+97c*%3"a"1&0+5?9?<1:Z"+3h3l,""u$(`Q"$}71<)"#1X`(#(e"%&55>r#!2"e&)&#$00"qP#"R((XV&$Z"+.X0353"e&2_"1ZX`3c3h&l&SS$/-.Y.$$,X"TV)"e&!+$v+'+9.<"US$,a"/WXY2`2c.$a"'CX##&y7!*&OQ#!&*Q1)&<0A3.n#A3`1c&h&l&"$(XE2T2$`Q"!'*`Q"(O8"Q1!("e")&A2E2&e")2Y2`&$e"7#$%XH0Q0&$$+.YQ#-3)3-+0&&Z"'.E3H"SS$+Q3T3Y+(_"6_T%)5$2)."{($V")&E2H2(Q7#T2$t+$X"4}Q%#$3&V*(X"!'"Z6%3T',T"*NO#)0""H/.NO#!-6_"-&H2M:Q2(Z."P&(NO#%+T+&NO#(q,&V"#DX"N&!3"|%.q$4}Q%8V""g(12M&Q2T2XX0X"#Y/$T6*bN"4Z"93E3H,M&Q+T3Y3*N&"Ud$&`N"9#=Xl-%"`)"#<("T60e")2A2E-&W+!-"z--&h&l2#$"WN"#X&"oe""UN"!((o0$Z"&T60N."m0$T6#dX(T6#7X"ON"$T6"_"!6<R6/)`2c2eXf&T6"cN$!-$T6%c7h"gi"&a"%393:T6)0c=h?$T6&VM*T6"cN$4T6%292&l+BT6-_Xl0&$/"R($cN$2T6({,8T6'3l3&$P6##,"|n'2N66V"*|5'.l2&$x5%#)*:v54`#(v5/3"#(XT2&"p5,nL2l5,X",l5!("nL!0,nL2d5&R"8d5*nL#D$"QV++)?-&-2(PO#*zm0&kQ%*y0%&H&0z5,i8%&"K"Z8"v5$eH!L&u0%&H&&v5,u09#$9IX%"%X""H-$}f0$kf"#)?"o($h#!2&v5#(T.`#'##'X"}J%XE+"pP&)4$3)L0h#*v5$s(*k4!*&v5&}J%2)I&}J&d##A?"x5!2"X"*f#*}J!%$}J"x5%')?"OK!G"Z"!?"x56f##"%$OK&QK-$=Xl-l9"SK%$<(&hN#1&)?-:0:5?"N6!?"N64v#%?#%$UK'jX&%$WK&YK!6"a")3035?2R62N$;h3h?l?$"5I#$8X"cQ%!%$`K'fX&7"e"))025K*bK"r+0z#$Yb/&Pm1%$5I"vN#!%$fK$xN##)?"hK!L"hK8z#!?"a6"S%*zN#%$2X*|N#-$1X`(`4&{&)&0&5D>N$%?c?"g6!%$nK!_"le".}S'${&$k6!?<{&/ZXZX`?c;*tK%$-."SU)%%,X&UU)"{&&w6!?"xK!?&xK"z#$WU)#`=.zK%$*X"_O#%%)C,aO#&d/!?"NL!?.z#!D*NL!%$NL&cO#%$'X*eO#%$&X(gO##)G"h7!?"g.!:"TL-2Q&T?Y7*X2!%$TL'Q=&%$VL*kO#%3)?"t7$a"!3$a2/OXOXQ?T?0e22aQ%)7MD&6"{4!&*_""`G"cN#-KMSQ?T30k2<OO%"p#,a"!3"gL%GQ52n7,b}"-0"#H/H92b}"!-6v#%&H?"V:0t7,b}"%+E8&qL!5*t-&r#+DXDXE?"zd"!30_J@OO%6_"-2A?ABE?"Ne"$yL.e&#Y<8OO%'$&)6"a"!6&P8!:"P8)+T3Y60{L.OO%!X"RN$"{L!<$|1!)"e"))9&<?&z7!)2{L(TR'"{L&XN$:{L'9?<?@}L#l&({L"OO%-U7UeX&:0{L36X7S7S9?<=*XD!P$SM/^P`2c2fX$i"$SM#5:&i}$,Ze"!&BZe"!0"ZJ!&Ji}$!X"V}#,e"<SM%&c0(SM#0=$SM*Z}#*SM+.X0?58<UM"f)&SM#-:&i}$!9$SM/+X-?0?5+(lv",Z"(eZ""b)&^M,uS)"`-%?05"Qp",V"!3"T"!3,^M4vP'"V"!7"YM!7.V"$`#$p+=(#"%=&"$+&3$S);&UM!+.N"!+"N"!+$q,Z0OR+W#QV-l%tP'H^b1U#Qb0a"^b1{"yU-T"ua0"wU-p#uU-@^b1@uU-&sU-X$qU-a6^b1*t|"e"vP'$t|"!F(xN&&R}###<,Nk&X"|P')$;Xa8"t|"!3&t|"6xN&HPQ'$h2$xN&.t|"T"h`0R$pb1$_N#"T-%2m3,zN&#dI"gN#c"vb1!L(zN&2gN#!F(zN&*j9H|b1%KdD(zN&"j}#$gN#6zN&Df`0"{o**qW.#YS(gN#P"}U-"Wz0.h`0"gN#!7&yt._"OV-'#(XT"VO"%SX&(f9@{Q'):U:Y7,zN&/QX&"PX&4D^V-*{p-&|N&.O}#Z$hV-<Xl'0go*T"jV-,yO#e"rV--$$9$XIK$eU*"O9"yO%&Q9<pR'!K:|V-)#'XFI"OP#&O}#8tR'+DXFLI@@RW-0OP#<|R'#AK"Vo*>ZW-&OP#!D(OP#6TS'!@BcW-$OP#(VS'%$=:*XS'%$<X>ZS'%:A:BZS'4OP#!3,OP#,aS'>`9<cS'<OP#BPY.%6X7JOo+u"Ve1%$5F"mS'%%4X:vW+!B.yo*8Z`/%%3X.vV)%$2X*xV)%$142|W+$_5Hce1%%0X&|V)6NQ#$|#&xo+_"e`/%$-X"ke1.NQ#&a9$Zp+c"oe1,NQ#!7.k`/,pp*H^R"#%("Qy$&bR"8NQ#(ye1!3Z"ye1%%%1&`T'%%$X2gW)%3)3b#}e1&xn't'nX-!5Y+nX-.pR%e"bT'$pR%(iS")$=:=A*pR%!X>mS"HhT'$pR%)8jX&%$jT'&qS"$a;Z"lT'*sS"$pR%%X$%$pT'!fX"i^.V$bf1ByS"5$5F5SdI$%4X:}S"Dhf1$}S"0rS%"R<*QT")$1A1M.ST"Dnf1(ST"%%0X&UT"$rS%(WT"$R<N"rf1.YT"$rS%!S&rS%*`_.e"bT",rS%#7)(t;_"Sa/%$(X"hT"0rS%$h;@Ya/4lT"##%"xo&#$X"pT"Bq^+JpT"!k_$SV#,pT"4Np"k"ha/.tT"c"pa/)$$X$c"tT"%:%G&tT"(vS%@za/$Xp(8za/%#'b"xT"$zS%%A#48vV#&xT">Pb/.xT"!7<NW#&xT"FXb/&NT%!C$NT%6ZW#(zT"4ZW#$NT%&V`*$Pp"#16&Pp"4gb/6tT"2gb/0RT%!3*UZ(*kW#P"tT"&mW#4RT%Dzf0y"oT"P"tb/'#5Fd"yp#6|W#DmT"*iv+*NX#%#2X&PX#%#14.Nc/@gT"4Nc/!$$kT"4ZU%X"gT"2_X#)#-XYB"ZU%!7(zf0P"aT">Zc/(aU%"aT"i"_T"!$$_T"$l`*2aU%$gc/@VT"<gc/!$$ZT"#&$$XT"&{X#FVT"X"kc/x#PT"{$kc/LNT"l)kc/R$WY#o"sc/a$^Y#T"Wf0V$}c/&dS"$g-S#bY#!G"bS"&Wf0JbY#X"Yd/%KdD,Wf0y"fY#!G6fY#!G&fY#(Rq"HQS"!K.s_1n#jY#0_:F}R"2Yf08QS"s"tY#!k_$|`)R"tY#a"Qk12QS"_"Yk1!#"vY#!"&tY#(t^%@fk1(rY#4fk1w"vY#2lk12{R"V"vY#8tk1o$zY#4Pl1LSS"y$NZ#!Oc$`S":_l1u$SZ#X"lS",il1V$WZ#!B2X`%!9a"WZ#<ul1u$^Z#HRT"<Om1^#bZ#V"Sm1d%bZ#n#Sm1c"eT"P*Sm1e$nZ#o"^m1u$rZ#!bj%hm1F`U"w"vZ#,dU"_"vZ#X"tm1,jU"^#zZ#0pU"$zZ#!G*zZ#&hr"m"vU"V$N^#HZn1_"NV"s"R^#a$Qi+R"R^#V"Zf%e"N^#,ef%P"N^#@of%(N^#,of%w"zZ#2uf%2ud$T"zZ#2}f%_$vZ#4Yg%Dmd$e$rZ#8Vn0!a"|R.!d(aU"s"Xn0+fdh2id.kZ#%:d-.kZ#(Vn0"fR-:Vn0&{T##3bBkZ#!(.Vn0$pg%8Vn0&hv5"gZ#!02gZ#*Vn0.NO06Xn0"PO0*Om,#-X0td'*US/%25+@Xn0#Y24Vn0.td',fS/!1:Vn0$b+&Vn0JcZ#$zi*"qa-6Vn0${Q0*Vn0#%0*_Z#,Rn-$ST":Vn0*Zh%,Tn02Zh%`%_Z#^#Zh%c"Yc$`1Zh%T"fm0$|Y#'<d=2`#dm0!`$RV-"fm0&iP&,fm0/dF$$4ccc"bR"(fm0!?B_h0!B(fm0BvY#!4*R:(k)8yj0(nE%$0a>rY#&fm0&yp"6t#&wp"&fm0!Y"li&(zU0Hdm0"wR+.fm0&rh'$qR+0e<,`#$gT&*fm06Xh%!&"N-8fm0(la$&fm0*Xh%!&f3Xh%!K6^Y#!Ga"^Y#!F*^Y#!AR"Xh%,rp/4yn0P"WY#!.l#WY#!7,`o0$|X##=2@bo0'eXh?*SX#!:"Uq10SX#({l+%?:3"NQ"4c"!?"{l+)%3X:92SX#$Om+)X"$1(.`q1!&"TQ"@Qm+!?"Qm+!%$TQ">OX#$X^/,Uh"T"Wm+%$-X"Ym+!%$_Q""Tt#$b8!2"aQ"L`m+,cp0,{W#"eQ"*p8!3"gQ"@dm+$kp00{W#!.:{W#(jm+(mQ"@jm+$wp0!%$mQ"&wW#0nm+#3)"Yf-N"nm+,Qq0U%Yg%Lnm+`#lm+@}Q"8^q0^#lm+,dq0S#lm+4jq0_"Yg%!SN"pq0s"kW#,vq08kW#!AJYg%$pu#$kW#<Rr0LgW#.Zr0U#gW#v#n|5c"Nn+N"Wg%"`U(R"aW#8Tn+^#Wg%(pk+!K&Zn+O#ZW#&P$"XS"$cn+8ZW#LWg%"t#&kj7$in+@VW#!GBmn+%GYD*mn+@VW#!<&Wg%8bG:RO1#%8Y'RW#DPW#@NW#'hKhXe"RW#!G._d%!XU#RW#$`_0!K"db"!Xq"RW#$lv7*p#m"RW#0f#!LJRW#,Zt1(O_0,RW#!@*RW#&Os,$T:#1=*qn"%:):Z"R-a$RW#$tN"Z"ZS"*ot1@UV#LTS"$st1!$$TS"*UV#$wt10UV#HNS"(yt1<UV#*ml,LzR"2Ou1DUV#JtR"6Uu1@UV#@nR"0Yu1,UV#!.6UV#$bu1@hR"4bu1LUV#{"fu1N$^R"L^s-(Y8!^"ue#@gY.,WR"'mXmae"WV#(^^&!X"aO"!a}"^s-(QZ.%Kmaq"hu1!L"{Q"$j#!Yq"^s-0uQ"!LZ"WV#DqQ"4WV#(mQ"4WV#T"pu1DWV#a"tu1FWV#>hv0s"zu1(eP"$aq#$hv0"YU#(ZP"T"Pv1!B(|}%2YU#!9:YU#HVv1$su""aq#.YU#6hv0DZv1&Qn"&hv0:YU#Bcv1*SZ-$hv0DYU#8{b.!?0hv02zc%,Vm"8jv0$^U#*OX(#%0`#vc%#g"m$`U#@^U##^j4}v1q"^U#,`Q#*}s."nc%!02nc%$v28UU#!K"_"!K"ki.DUU#!3BUU#6j#:UU#!2FUU#6f#BUU#!+2tw1$hO",UU#!G2UU#$vw1DUU#!&.zw1<sk"!?"zw14UU#!8.UU#!&(Nx1*qk"4VZ$!?2Px1DUU#&Tx1"xO"%?=8:jU1"Zw/*Vx1%$5F"Vw/4UU#<^b%,z#$lt.c"dn'$R$4^b%(N$Ldn'!a*UU#@Wb%*O8&bs$0Wb%6eq)#%&FWb%&`8&jr("Pu(>Sb%!7"Rh&0Ta10ku.!G.sx1T"Sb%$yx1%&):.|8%:F:&mr#4dn'0UU#!36UU#0X9<}x1&jg-@}x1%2).R&}x1!3p#}x1!(_(}x10XT#c"Oy1c"gm'c"Uy1LXT#e"Yy1N"XT#!Gn#by1:yP")$5:5F$f{%:}P"Dhy1$}P"@ZS#$QQ"%$14&mr(P"ny1(SQ"<ZS#$WQ"$n'N"ry1.YQ"$ZS#!:.ZS#R"xy12bQ"%$*S(al"#)7&fQ"DNz10fQ"@ZS#$jQ"@Tz1T"jQ"g"ZS#%.$"$S^,*ez14cz18hd1!6"Zl"0Zc0/B&B2B?BK"RS0%bI&(dd1/N2N?NKNP"`d1*Nc0-Z&Z2Z?Z&Rl"4mz0%i?i"Nl",^r+*oz1$Zp1!L"y}/!L"y}/!L"y}/%Lm3&_S#!2*NY$!c2_S#(yz1$PS0!K"Ym0!K"UN0!K"UN0%Km2"_S#!=*_S#%a#4*}z1&n#&Sd16p#'$"*I*vQ"%P&5.U{1"d#'AXBL"Ud16f#._S#!7&_S#%3*B"`{1$f#!G"`b0!@"d#!@"d#!@$f{0!>(b{1%#=-&d{1*vk"/*:.:126:"lo0!:"_S0!:"n#!:"n#<_S#!3(_S#&j{1&vk"9B.F.I&N.R.U&Z$lp2,l{1(_S#!+"_S#%H%&2d{0!`&p{1(zk"Ff{0+YdZ&^c.{k'%di2.^_%!d2yk'!&&xu0"zk".kx0!3"`{0!?&fa0Lyk'$e"%21?"v{10`{0#2Z"TY$$`{02uk'!`(ST#!*&zk""|{10b{013Z&Z3a?d8,`{0'-XY^"ST#&p8!*&Pl">b{012WXZ2a8d2,`{0#*-"r8%XDX$r8&bY18`{0!?&UQ2a"^_%&bi1(`{0!:"r#%:U3&{f08^_%.mk''*3.."`{0!.0`{0&Y)!."^{0$`Q",c|1/`"%2'd*+X"a|1$r8#Ec(}S#(Z|1%LXM"v8#Qb$el"(V|1)Z&Z2^&be1"Sn0"t8,be1"nQ"4x{1$`R1,yv1!L"iz0!?"th0!?$yi02x{1!b"fQ"$r8!("_-(zh0"iW#!N"hW&"UX2$Qa1(kS#%aT`*x{12h#"^Q")3N6RI"Zz0&j#.kS#!D&x{1.b#"Tz0!K"x{1!?&Tz0&f#*x{1'$?XZ$Rf24f#%@F@"Rz0!?"Rz0(N&$kS#$Nv-&r8.kS#0r#%2B:*`X2%0Z:"W:!2:kS#!3*Rz0)&..1&Br8$Sn%&r8:kS#'W"%&"df2:V|1#6K8V|1!B"fx"0|y0!N"xV$(|y0/Z.Z2Z?^c"v,#`d"Uv+(Ng2#iF.aT#!X$d9#cd>zy0$Ub2!?"p?+?a5d?i$aT#)cbXiK:aT#&jo#2a|1$vd2$hV1)?a?d5"wD%$0b*aT#!`8zy0"X<$s/.t##ZL"cg2!@&aT#"uv.(ag2&k|1:h#'WXZK"ag2"S{0#*:"aT#!P&_g2$q|18`#(OX2!?6aT#(Vg2!:&Ul2%2=&*kD%:U2*kD!20m^%#*8$j,':.=&(h,&k8"_D!i6Qj'!&k"XT#H{n#0ZT#0wn#0_T#<sn#Don#.cT#!&&cT#!L"xk#!L"zj",_{3&qQ*"q^%!W$l}1:q^%(iT#!K"e"$bl",q{3%KhKR"iT#&n#"iT#:p#N"iT#!K"kn#!K"Ul"$OW#.f#N"iT#!@"iT#$Ql"!@*S{/!?"kn#<q^%@|u)!&:q^%!3"iT#(Ql"T"{i'!&c"^V$N"q^%!I.d{/!c(ib&"f{/%2<b$ib&<f{/$gb&#^c$f{/,pO6*b{/0h_%%dcX2f{/T"h_%!cBh_%!a&h_%!bm"h_%!a6h_%)`$"?aQ#h_%!^S-h_%!ci"WX$4jU#'FKFXHnU#4^r$,}W$<tU#'mKmXZ"S_%)?ALFX*m{&!?&zx&!XBxU#Dbu))?AKFX"xU#!U*Rk;%?mX>Rz-!A6S_%!?&xU#!X&nr$!L,v#Z"S_%!?"xU#%SFL&rr$$xU#$r#!LFxU#4r#%GF@*xr$!G&}{&,S_%$vR"g"S_%!3"`q#!3"`q#!3S%S_%!Y"j`4N$Q_%$O_%$VS"}"Wu)$iT$<}^%$cd#o"Wu)$vx#<}^%(_c*@}^%!`*}^%"|#F}^%(gx;DZh'!6$rr#F}^%(kx;@Wu)$m&D}^%!@"}^%0Vh'!K:}^%!&"}^%!3"nG!3.nG(iu'$}^%!0"|z-!8"OT"Bw|/'OXRJ0}q#*OT"!Xa"|z-$zz-(y|/$|z-%E&E"wV.#H?(tz-'Q2Q?$pf/$nz-#^d$|R,'c2c?$fz-%l&l,OV#!C$`z-1-?030?3c5$c^,%L<X"iIn"3E?H?HLKcM3Q5Q?T?TLWcY&`3`?c?cLfch&l3l$OT"0P{-!R:P{-%?0?"ZU,EXA&E?HQM2Q?TKY&`?cK"qx,,P{-!D.P{-.V"7DXELHLM.Q?TL"X"'Lh&l:Q_%&P{-(X"!L"OS-)FHKM&4f#'$"-H>P{-!E&X"-@A3E?H@"V"!@"V"'@h&l(Q_%$RN0)#=Xl?&P{-!5*P{-E:085&98<8A2E8H3M&Q8"ui-!8"je,s"P{-9,M&Q.T,Y&`.c,(ye-:Q_%AJ$&%d)&)2-).d021b(jo(/92:a<2=c$sX-)FdH&I"b|&-Q&RdT&U"lV.3^c`&abc&d`$kN,)l2mdm$i|=)#5Fdd2{{-!3"cN-!BBcN-!3(tf-#:b.vV#!b&{{-!b&tf-!2*ng,8ZN-0{{-!b8vV#$r#+.Y0358@VN-&tf-,{{-"iq#"nt)#6$"v8"PN-!2@PN-#Y?"|f-!26{{-!7*{{-$wV-!3:z},!?"z},"Sm,V"{{-!:"t},!26t},!2&t},"e&R"{{-!..{{-!.&gg-!."_"!.:{{-!O"_9''d).@|8(we.#E2"x6"z8(nn"(|8$ie.,z80_e.&u^%(WV#)C$:)&:P9E3<??cA3E?ELH5H?KcMG"P9-3T?WcY3"P933c?fch3l?l,wN0)G""HF0wN0#)&*f69?A2EKHKM?QKT?*pZ-,wN0%QTD(wN02V";3DXESHEM3QDTLY"s;$}e.6v}-6b#+A?EKH?"a;!F"zN-&f#"zN-4v}-4f#%?E@"gQ-)?T?Y?&d#(h_%,v}-1:%"`6"#<:&z8%&-3"z8(}e.!8"}e.58Y3`8c8h2l8>v}-!0"z81&-,0.5&9,&j2!,"}e.%,T.&vN-&}e.:v}-#H$$jn"(U-!a$NN.+9?<2<=0PE"hn""_w,7T2WdY)^c`2`<(|}./fdh2l2l86mN.)Ah7%C"r|,,},%39?*},$PE!3"},%&Q3*},0PE!?$PE"{V#@`O.!A&WP-)?0?52"d)!&"{Y-!&"d)5&`KcGh2l?#$"cN/!I&{V#0WP-+?.X0L5$uU-2_"'ZX`J$Y-'&#-G:`O.)K0A5+8V""`O.-?c?h.lA._`%!P&p>!D*S-0`#$j/#&l$kg'!?._`%$z%%2-8"iC!8"Rk.(vD%8Y2&vD-8##%=Q8*`O.=S)3-.0,5&9.<,A&$lD/OXQNT@Y+$nD!l,OQ",wU)o"SW#,Ob&(ju$$q`"#FK8UW#D{w%8ym"4i`%'mKmX>^s)-L:X=LA?"gT#!G*xj"!L"qm"!#"UW#8^s),ug'-K:X=KA?"mw%$iQ3!?&kQ2!X"QW#!VBug'&h#&mw%,em""j#N"ug')K:L=K"St"!K&ld&,f#"el?FSs))G5G:@*ow%$WT3!?&WT2!@:Ss)T"ug'(ck(8Zm"T"ug'j#QW#BzT3P"Ns)*XZ$.zT3(xN,Q#tr),fa%j#zN,0fa%&^u$u"pr)4fa%!8$Rm'Ffa%Hpr)4fa%"^{$Jfa%@lr)$fa%$lr)"{&a"fa%8lr)8fa%$hr)!8V"fa%!'.fa%0zN,).d.h'Bfa%!bm"`d&8UW#<SW#(hh'@d{&D`s#Z"QW#%LAL"yR#0cw%"js#R"|a%0eT#!K"}7!L(Ub+*js#<Wh'8QW#0|a%!L"|a%.ps#V"QW#$|a%%SFK&`z%!I"bd&*vs#i"Wh'(dz%!G,xs#i"fN,(Wz"(|a%4xs#T"qq)j#QW#T"iW3^#SW#$QW##aKt#`N,(hU#$ov(DSW#!Ri"Sh')?Y?aQ`#`N,,SW#$bg#{"Sh'$SW#$`g#@SW#P"Sh'*Ye)6vb%%$&X*bN,!G2jq&$rG$UW#$rG+3#$%8%&}w$&|b%s"YW#+X&c"$d(pu>(ru>8X_G(xu>(v_5!6&Vm?%<d<&du4!B"tT@'HbHd&jW##dN*PeA&b_6*jZC&kt4#di"Wn?(lW#5&"IX&"Hc&"G"Vi?I&"Ea&"DX&"CX$"BX&"AX&&qn3!n"vz-)mX&#="Of3+<XkX%#"uP#/#:XiX&#9"Od?"k2!#&v`'`"d)d.d1b5`6X:d=dAdFdIdMdRdUdYdab"{N#;dhdmd&#5cdd$#4"bn?=3XbX&#2Xac&#1b`"ve@!_"oe1/^X&#.`ZX2Xl$)#+XWX*fb""wm?6|p&"Q^#*il%%"OX*s)35$d'd-d0d3"s(/?dEcHbK`$ya?!W${W@#df$v'!c"jZ"?00c3c9c<c?cEcHcK"SmC!W"}lC)fclc"S%i(!*"i(16X6d:d=dB"i(!N"i(!Z"i()ddeXi$i(%Xdc$i(+%00a3Y>O%!a&O%%#3c.Y)-a`b%#0a2Y)!`P$Y)'J$d)"Y)30d3d5d5h5n(Y1"lU5%eAn,W1+LXMdMl,U1'YdYj(S1!c"S1y"O1!lf#f)!'"f)#3a$f)!?"f)!K"f)!W"f)+adeXfd&f)#jd"c}5"O1(s()b&#1X:O1!Y&s(!hp#s(%e&P"dsG,ha?@hsG*qq/%h5i<lsG*pa?%eAi&ra?AcEdFcGbHbIaIdJ`K`"ga@%dMi8c}E(`sG"YsG!i0na?(la?,na?8i}E&P+-d&"Ic&14`4<b4/&"Gb%"Fb&q+)`&"C^&q+!g"q+;"?X&">X&"=X&"<"ue"S"&":X&"9X&"8X$"7X&/$d-d0c6X0n^@$d.Gld&"5b$"4X&"3X&10c2XP"k79&"1X%"0b&"/X&$lO@$SU6>UPA%&"&"Qx/"^O@!fJl*!.""(n*,ak?"XR6*bo?("6x*2SWF("(hVH,bWF$k}G$P+!R&"(T+.V+.yk?!a*"(_+0a+0ap?!m"e+Ek)(.m.p:m:p:pFpRpc'$fvH/>NQ""WcT$kqL"OyL8/!R>/*m}L$/S"McT#"IcT#"FcT#C$d0d9c<c<dA"_RI'KdMc"bI"`p5$bI)WdYcY"zvI%`da*hI)icici"Q%%T#.&tF"sO@1adddhchch&='6.d:"j7!K"cUE!R$rfI*`K-cdfcfcf"WK#-'0T-%y"/&XA#cU"M#ad$Ns5!h"x88M=C-d5p5p9dApApEd"h%)dMdMn({xB*j%)dYdYn"z="lgI(TN"$gXI!1&a;'cRdU$e;+cacadd"NzI3mcmdT#:$d0&Q2!I$Y#!i$}iI!T"S"'YdYi(UjI%ddh"gZIC2'TbWb`bcbfblbs"-H*Rq@&lV@#dc"y#8I=I.d:c:c:d:dFcFc(t/!I"QO"!M"p$$"$Y/!U&U/$N%!a"u)!d"|#!h"V%k)mdi)R#$~%i%~&~'~(~)i)~*~+~,~-~.i.p.~/~0~1i1~2~3~4~5i5~6~7~8~9~:i:p:~;~<~=i=~>~?~@~AiA~B~C~D~E~FiFpF~G~H~IiI~J~K~L~MiM~N~O~P~Q~RiRpR~S~T~UiU~V~W~X~YiY~Z~^~_~`~aia~b~c~did~e~f~g~hih~i~j~k~l~mim~n~]==]

--[[ DAFTAR LAGU
Format notes (dipisah spasi):
  C4        = nada C oktaf 4, 1 ketukan
  C4:0.5    = setengah ketukan (boleh pecahan: C4:1/2, C4:1/4)
  F#4 / Bb3 = nada kres / mol
  [C4 E4 G4]:2 = akor (dibunyikan bareng), 2 ketukan
  R:1       = jeda 1 ketukan
  |         = pembatas birama (diabaikan, cuma penghias)
Rentang nada: A0 sampai C8 (88 tuts). bpm = ketukan per menit.
Tambah lagu: tambah baris { name = "...", bpm = ..., notes = "..." } di bawah. ]]
local SONGS = {
	{ name = "Twinkle Twinkle (contoh)", bpm = 100, notes = "C4 C4 G4 G4 A4 A4 G4:2 | F4 F4 E4 E4 D4 D4 C4:2" },
	{ name = "Rush E", bpm = 100, tpb = 384, packed = "RushE" }, -- data MIDI ada di PACKED.RushE
}

local function getPianoKeys()
	local ui = playerGui:FindFirstChild("PianoUI")
	local container = ui and ui:FindFirstChild("PianoContainer")
	local frame = container and container:FindFirstChild("KeyFrame")
	if not frame then
		return nil, ui
	end
	local keys = {}
	for _, k in ipairs(frame:GetChildren()) do
		if k:IsA("GuiButton") and tonumber(k.Name) then
			table.insert(keys, k)
		end
	end
	table.sort(keys, function(a, b)
		return tonumber(a.Name) < tonumber(b.Name)
	end)
	return keys, ui
end

-- Klik mouse ASLI lewat VirtualInputManager (sama seperti PianoAutoPlayer lama), jadi handler tuts
-- dari script piano ikut terpicu. Kalau executor/environment tidak mengizinkan, otomatis cuma efek visual.
local okVIM, VIM = pcall(function() return game:GetService("VirtualInputManager") end)
if not okVIM then VIM = nil end
local vimBroken = false

local function keyScreenPos(key: GuiObject): (number, number)
	local pos, size = key.AbsolutePosition, key.AbsoluteSize
	local parent = key.Parent
	-- tuts hitam lebih pendek dari tuts putih: klik di tengah tuts hitam, sedangkan tuts putih di bagian bawah
	local isBlack = parent and parent:IsA("GuiObject") and size.Y < parent.AbsoluteSize.Y * 0.8
	local x = pos.X + size.X * 0.5
	local y = pos.Y + size.Y * (isBlack and 0.45 or 0.85)
	local sg = key:FindFirstAncestorOfClass("ScreenGui")
	if sg and not sg.IgnoreGuiInset then
		local inset = GuiService:GetGuiInset()
		x += inset.X
		y += inset.Y
	end
	return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function realDown(key: GuiObject): (boolean, number?, number?)
	if not VIM or vimBroken then return false end
	local x, y = keyScreenPos(key)
	local ok = pcall(function()
		VIM:SendMouseMoveEvent(x, y, game)
		VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
	end)
	if not ok then
		vimBroken = true
		return false
	end
	return true, x, y
end

local function realUp(x: number?, y: number?)
	if VIM and x and y then
		pcall(function()
			VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
		end)
	end
end

local pressState = setmetatable({}, { __mode = "k" })
local PRESS_COLOR = Color3.fromRGB(255, 70, 55)
local firesignalFn = rawget(getfenv(), "firesignal")
if type(firesignalFn) ~= "function" then
	firesignalFn = nil
end

local function pressPianoKey(ui: Instance?, key: GuiButton, hold: number, instantUp: boolean?)
	local event = ui and ui:FindFirstChild("KeyPress")
	if event and event:IsA("BindableEvent") then
		event:Fire(key, true)
		task.wait(hold)
		event:Fire(key, false)
		return
	end
	local realOk, rx, ry = realDown(key)
	if realOk and instantUp then
		realUp(rx, ry) -- lagu cepat: tekan dan lepas langsung, biar tuts berikutnya tidak tertahan
	end
	-- Tuts piano ini ImageButton dengan background transparan -> warnai gambarnya biar kelihatan ditekan.
	-- Hitung berapa kali tuts yang sama sedang ditekan (nada beruntun/akor) supaya warna asli tidak hilang.
	local isImage = key:IsA("ImageButton")
	local st = pressState[key]
	if not st then
		st = { n = 0, image = isImage and key.ImageColor3 or nil, bg = key.BackgroundColor3, bgT = key.BackgroundTransparency }
		pressState[key] = st
	end
	st.n += 1
	if st.n == 1 then
		if isImage then
			key.ImageColor3 = PRESS_COLOR
		else
			key.BackgroundTransparency = 0
			key.BackgroundColor3 = PRESS_COLOR
		end
		-- Picu handler tuts dari script piano (hanya jika firesignal tersedia)
		if firesignalFn and not realOk then
			pcall(firesignalFn, key.MouseButton1Down)
			pcall(firesignalFn, key.Activated)
			pcall(firesignalFn, key.MouseButton1Click)
		end
		local sound = key:FindFirstChildWhichIsA("Sound", true)
		if sound then
			sound.TimePosition = 0
			sound:Play()
		end
	end
	task.wait(hold)
	if realOk and not instantUp then
		realUp(rx, ry)
	end
	st.n -= 1
	if st.n <= 0 then
		st.n = 0
		if firesignalFn and not realOk then
			pcall(firesignalFn, key.MouseButton1Up)
		end
		if key.Parent then
			if isImage then
				key.ImageColor3 = st.image
			else
				key.BackgroundColor3 = st.bg
				key.BackgroundTransparency = st.bgT
			end
		end
	end
end

local pianoPage = new("Frame", {
	Name = "PianoPage",
	Position = UDim2.fromOffset(8, PAGE_TOP),
	Size = UDim2.new(1, -16, 0, CONTENT_HEIGHT),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 2,
	Parent = main,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = pianoPage })

local pianoCard = new("Frame", {
	Name = "PianoCard",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = P.Card,
	LayoutOrder = 1,
	Parent = pianoPage,
})
corner(pianoCard, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = pianoCard,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = pianoCard })
new("TextLabel", {
	Text = "Piano Auto Player",
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 20,
	TextColor3 = WHITE,
	LayoutOrder = 1,
	Parent = pianoCard,
})

-- Pilihan mode
local pianoModeRefs = {}
local function refreshPianoModes()
	for i, refs in ipairs(pianoModeRefs) do
		setTheme(refs, i == piano.mode and THEMES.Green or THEMES.Off)
	end
end
for i, modeName in ipairs(PIANO_MODES) do
	local refs = glossyButton(pianoCard, UDim2.new(1, 0, 0, 32), THEMES.Off, i .. ".  " .. modeName, 14, { LayoutOrder = 1 + i })
	refs.label.TextXAlignment = Enum.TextXAlignment.Left
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), Parent = refs.label })
	pianoModeRefs[i] = refs
end
refreshPianoModes()

-- Slider lama tuts ditahan
local pianoSpeedLabel = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 18),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR,
	TextSize = 14,
	TextColor3 = WHITE,
	LayoutOrder = 7,
	Parent = pianoCard,
})
local sliderHolder = new("Frame", {
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	LayoutOrder = 8,
	Parent = pianoCard,
})
local pianoTrack = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 9, 0.5, 0),
	Size = UDim2.new(1, -18, 0, 8),
	BackgroundColor3 = P.Input,
	BorderSizePixel = 0,
	Active = true,
	Parent = sliderHolder,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = pianoTrack })
local pianoFill = new("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Parent = pianoTrack,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = pianoFill })
new("UIGradient", { Color = P.Primary, Rotation = 0, Parent = pianoFill })
local pianoKnob = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0, 0.5),
	Size = UDim2.fromOffset(18, 18),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Active = true,
	ZIndex = 2,
	Parent = pianoTrack,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = pianoKnob })
stroke(pianoKnob, P.Stroke, 2)

local function refreshPianoSpeed()
	local a = (piano.hold - PIANO_MIN_HOLD) / (PIANO_MAX_HOLD - PIANO_MIN_HOLD)
	pianoFill.Size = UDim2.fromScale(a, 1)
	pianoKnob.Position = UDim2.fromScale(a, 0.5)
	pianoSpeedLabel.Text = string.format("Tahan tuts: %.2f detik / tuts", piano.hold)
end
refreshPianoSpeed()

do
	local sliding = false
	local function setFromX(x: number)
		local a = math.clamp((x - pianoTrack.AbsolutePosition.X) / pianoTrack.AbsoluteSize.X, 0, 1)
		local v = PIANO_MIN_HOLD + a * (PIANO_MAX_HOLD - PIANO_MIN_HOLD)
		piano.hold = math.clamp(math.floor(v * 100 + 0.5) / 100, PIANO_MIN_HOLD, PIANO_MAX_HOLD)
		refreshPianoSpeed()
	end
	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	pianoTrack.InputBegan:Connect(function(input)
		if isPointer(input) then
			sliding = true
			setFromX(input.Position.X)
		end
	end)
	pianoKnob.InputBegan:Connect(function(input)
		if isPointer(input) then
			sliding = true
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then
			sliding = false
		end
	end)
end

local pianoStartRefs = glossyButton(pianoCard, UDim2.new(1, 0, 0, 40), THEMES.Green, "START", 18, { LayoutOrder = 9 })
local pianoStatus = new("TextLabel", {
	Text = "Siap. Tekan P untuk stop.",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR,
	TextSize = 13,
	TextColor3 = P.Muted,
	LayoutOrder = 10,
	Parent = pianoCard,
})

local function refreshPianoStart()
	pianoStartRefs.label.Text = piano.running and "STOP" or "START"
	setTheme(pianoStartRefs, piano.running and THEMES.Red or THEMES.Green)
end

local function pianoStop(message: string?)
	piano.running = false
	piano.runId += 1
	refreshPianoStart()
	if message then
		pianoStatus.Text = message
	end
end

-- Pemilih lagu: < nama lagu >
local songRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = 6, Parent = pianoCard })
local songPrev = glossyButton(songRow, UDim2.fromOffset(40, 34), THEMES.Off, "<", 18, {})
local songNext = glossyButton(songRow, UDim2.fromOffset(40, 34), THEMES.Off, ">", 18, {})
songNext.button.Position = UDim2.new(1, -40, 0, 0)
local songLabel = new("TextLabel", {
	Position = UDim2.fromOffset(46, 0),
	Size = UDim2.new(1, -92, 1, 0),
	BackgroundTransparency = 1,
	Font = FONT,
	TextSize = 15,
	TextColor3 = WHITE,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = songRow,
})
local function refreshSong()
	local s = SONGS[piano.song]
	songLabel.Text = s and string.format("%s  (%d/%d)", s.name, piano.song, #SONGS) or "(tidak ada lagu)"
end
refreshSong()
local pianoPlayRef: () -> () = function() end
local function shiftSong(d: number)
	if #SONGS == 0 then return end
	piano.song = (piano.song - 1 + d) % #SONGS + 1
	refreshSong()
	if piano.running and piano.mode == 4 then
		pianoPlayRef()
	end
end

-- Parser notes -> daftar event {t = ketukan mulai, keys = {nomor tuts}, dur = ketukan}
local NOTE_SEMI = { C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 }
local function noteToKeyName(note: string): number?
	local letter, acc, oct = note:match("^([A-Ga-g])([#b]?)(%-?%d+)$")
	if not letter then return nil end
	local midi = 12 * (tonumber(oct) + 1) + NOTE_SEMI[letter:upper()] + (acc == "#" and 1 or acc == "b" and -1 or 0)
	return midi - 35 -- tuts bernama 1 = C2 (MIDI 36); A0 = -14; C8 = 73
end
local function parseBeats(s: string?): number
	if not s or s == "" then return 1 end
	local a, b = s:match("^([%d%.]+)/([%d%.]+)$")
	if a then return (tonumber(a) or 1) / math.max(tonumber(b) or 1, 0.0001) end
	return tonumber(s) or 1
end
local function parseSong(text: string)
	local events, bad, t = {}, 0, 0
	local i, len = 1, #text
	while i <= len do
		local c = text:sub(i, i)
		if c:match("[%s|,]") then
			i += 1
		else
			local names, dur
			if c == "[" then
				local close = text:find("]", i, true)
				if not close then bad += 1; break end
				names = {}
				for n in text:sub(i + 1, close - 1):gmatch("[^%s,]+") do table.insert(names, n) end
				local d = text:match("^:([%d%./]+)", close + 1)
				dur = parseBeats(d)
				i = close + 1 + (d and #d + 1 or 0)
			else
				local tok = text:match("^[^%s|,%[]+", i)
				i += #tok
				local n, d = tok:match("^([^:]+):?([%d%./]*)$")
				names = { n or tok }
				dur = parseBeats(d)
			end
			local keyNames = {}
			for _, n in ipairs(names) do
				if n:upper() ~= "R" then
					local k = noteToKeyName(n)
					if k then table.insert(keyNames, k) else bad += 1 end
				end
			end
			if #keyNames > 0 then
				table.insert(events, { t = t, keys = keyNames, dur = dur })
			end
			t += dur
		end
	end
	return events, bad
end

-- Decoder lagu padat (MIDI): alfabet 91 karakter, varint basis 45, kompresi LZ77 sederhana.
--   token: h genap = literal sepanjang h/2+1 ; h ganjil = salin (panjang (h-1)/2+5, jarak varint+1)
--   hasil: event {t = tick, keys = {nomor tuts}, durs = {tick}}
local PK_VAL = {}
do
	local n = 0
	for c = 33, 126 do
		if c ~= 91 and c ~= 92 and c ~= 93 then
			PK_VAL[c] = n
			n += 1
	end
	end
end
local PK_DUR = {}
for i = 0, 90 do
	PK_DUR[i] = i <= 60 and i or math.floor(60 * (1920 / 60) ^ ((i - 60) / 30) + 0.5)
end
local packedCache = {}
local function decodePacked(name: string)
	if packedCache[name] then return packedCache[name] end
	local z = PACKED[name]
	if not z then return nil end
	local out, n = {}, 0
	local pos, zl = 1, #z
	local function vdec()
		local v, mul = 0, 1
		while true do
			local c = PK_VAL[string.byte(z, pos)]
			pos += 1
			if c >= 45 then
				v += (c - 45) * mul
				mul *= 45
			else
				v += c * mul
				return v
			end
		end
	end
	while pos <= zl do
		local h = vdec()
		if h % 2 == 0 then
			for _ = 1, h // 2 + 1 do
				n += 1
				out[n] = PK_VAL[string.byte(z, pos)]
				pos += 1
			end
		else
			local len = (h - 1) // 2 + 5
			local off = vdec() + 1
			for _ = 1, len do
				n += 1
				out[n] = out[n - off]
			end
		end
	end
	local events, p, t = {}, 1, 0
	local function vd2()
		local v, mul = 0, 1
		while true do
			local c = out[p]
			p += 1
			if c >= 45 then
				v += (c - 45) * mul
				mul *= 45
			else
				v += c * mul
				return v
			end
		end
	end
	while p <= n do
		t += vd2()
		local cnt = vd2()
		local keys, durs = table.create(cnt), table.create(cnt)
		for i = 1, cnt do
			keys[i] = out[p] + 21 - 35 -- MIDI -> nama tuts
			durs[i] = PK_DUR[out[p + 1]]
			p += 2
		end
		events[#events + 1] = { t = t, keys = keys, durs = durs }
	end
	packedCache[name] = events
	return events
end

-- Mainkan lagu padat: tiap frame, semua nada yang sudah jatuh tempo (terhadap os.clock) ditekan sekaligus.
local function playPacked(id: number, keys: { GuiButton }, ui: Instance?, song)
	local events = decodePacked(song.packed)
	if not events or #events == 0 then
		pianoStop(string.format("Data lagu '%s' tidak ketemu.", song.name))
		return
	end
	local byName = {}
	for _, k in ipairs(keys) do byName[tonumber(k.Name)] = k end
	local spt = 60 / (math.max(song.bpm or 120, 1) * (song.tpb or 384)) -- detik per tick
	local total = #events
	local idx, lastStatus = 1, 0
	local startClock = os.clock()
	while idx <= total do
		if id ~= piano.runId then return end
		local now = os.clock() - startClock
		while idx <= total and events[idx].t * spt <= now do
			local ev = events[idx]
			for i, kn in ipairs(ev.keys) do
				local key = byName[kn]
				if key and key.Parent then
					task.spawn(pressPianoKey, ui, key, math.max(0.06, ev.durs[i] * spt * 0.9), true)
				end
			end
			idx += 1
		end
		if now - lastStatus > 0.25 then
			lastStatus = now
			pianoStatus.Text = string.format("%s  %d:%02d  (%d/%d)%s", song.name, math.floor(now / 60), math.floor(now % 60), idx - 1, total, vimBroken and "  [klik asli ditolak, cuma efek visual]" or "")
		end
		task.wait()
	end
	task.wait(0.6)
	if id == piano.runId then pianoStop("Selesai.") end
end

-- Mainkan lagu: tiap nada dijadwalkan di waktu absolut (os.clock), jadi tempo tidak melenceng.
local function playSong(id: number, keys: { GuiButton }, ui: Instance?)
	local song = SONGS[piano.song]
	if not song then pianoStop("Daftar lagu kosong."); return end
	if song.packed then
		playPacked(id, keys, ui, song)
		return
	end
	local events, bad = parseSong(song.notes or "")
	if #events == 0 then
		pianoStop(string.format("Lagu '%s' belum ada notenya (isi notes di daftar SONGS).", song.name))
		return
	end
	local byName = {}
	for _, k in ipairs(keys) do byName[tonumber(k.Name)] = k end
	local spb = 60 / math.max(song.bpm or 120, 1)
	local startClock = os.clock()
	for idx, ev in ipairs(events) do
		local at = startClock + ev.t * spb
		while os.clock() < at do
			if id ~= piano.runId then return end
			task.wait()
		end
		if id ~= piano.runId then return end
		local hold = math.max(0.03, ev.dur * spb * 0.9)
		for _, kn in ipairs(ev.keys) do
			local key = byName[kn]
			if key and key.Parent then
				task.spawn(pressPianoKey, ui, key, hold)
			else
				bad += 1
			end
		end
		pianoStatus.Text = string.format("%s  %d/%d%s", song.name, idx, #events, bad > 0 and ("  (" .. bad .. " nada dilewati)") or "")
	end
	task.wait(events[#events].dur * spb)
	if id == piano.runId then pianoStop("Selesai.") end
end

local function pianoPlay()
	piano.runId += 1
	local id = piano.runId
	piano.running = true
	refreshPianoStart()
	task.spawn(function()
		local keys, ui = getPianoKeys()
		if not keys or #keys == 0 then
			if id == piano.runId then
				pianoStop("PianoUI belum ada. Tuts dicari di PlayerGui.PianoUI.PianoContainer.KeyFrame (tombol bernama angka).")
			end
			return
		end
		if piano.mode == 4 then
			playSong(id, keys, ui)
			return
		end
		local n = #keys
		local function step(i: number): boolean
			if id ~= piano.runId then
				return false
			end
			local key = keys[i]
			if not key.Parent then
				pianoStop("Tuts hilang, autoplayer berhenti.")
				return false
			end
			pianoStatus.Text = string.format("Tuts %d/%d  (nada %s)", i, n, key.Name)
			pressPianoKey(ui, key, piano.hold)
			return id == piano.runId
		end
		local mode = piano.mode
		if mode == 1 then
			while id == piano.runId do
				for i = 1, n do
					if not step(i) then
						return
					end
				end
				for i = n - 1, 2, -1 do
					if not step(i) then
						return
					end
				end
			end
		elseif mode == 2 then
			for i = 1, n do
				if not step(i) then
					return
				end
			end
		else
			for i = n, 1, -1 do
				if not step(i) then
					return
				end
			end
		end
		if id == piano.runId then
			pianoStop("Selesai.")
		end
	end)
end

pianoPlayRef = pianoPlay
for i, refs in ipairs(pianoModeRefs) do
	refs.button.Activated:Connect(function()
		piano.mode = i
		refreshPianoModes()
		if piano.running then
			pianoPlay() -- mulai ulang dengan mode baru
		end
	end)
end
songPrev.button.Activated:Connect(function() shiftSong(-1) end)
songNext.button.Activated:Connect(function() shiftSong(1) end)
pianoStartRefs.button.Activated:Connect(function()
	if piano.running then
		pianoStop("Berhenti.")
	else
		pianoPlay()
	end
end)
-- stop darurat: P atau Spasi (tidak aktif saat sedang mengetik)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not piano.running then
		return
	end
	if input.KeyCode == Enum.KeyCode.P or input.KeyCode == Enum.KeyCode.Space then
		pianoStop("Berhenti (" .. (input.KeyCode == Enum.KeyCode.P and "P" or "Spasi") .. ").")
	end
end)

-- Tab Utility | Mini Studio | Tema | Piano
local tabsFrame = new("Frame", {
	Name = "Tabs",
	Position = UDim2.fromOffset(8, 58),
	Size = UDim2.new(1, -16, 0, 34),
	BackgroundTransparency = 1,
	ZIndex = 2,
	Parent = main,
})
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = tabsFrame,
})
local tabRefs = {
	Utility = glossyButton(tabsFrame, UDim2.new(0.25, -6, 1, 0), THEMES.Tab, "UTILITY", 13, { LayoutOrder = 1 }),
	Studio = glossyButton(tabsFrame, UDim2.new(0.25, -6, 1, 0), THEMES.TabOff, "STUDIO", 13, { LayoutOrder = 2 }),
	Theme = glossyButton(tabsFrame, UDim2.new(0.25, -6, 1, 0), THEMES.TabOff, "TEMA", 13, { LayoutOrder = 3 }),
	Piano = glossyButton(tabsFrame, UDim2.new(0.25, -6, 1, 0), THEMES.TabOff, "PIANO", 13, { LayoutOrder = 4 }),
}
local TAB_THEMES = { Utility = THEMES.Tab, Studio = THEMES.Tab, Theme = THEMES.Tab, Piano = THEMES.Tab }
local currentPage = "Utility"

local function showPage(name: string)
	currentPage = name
	content.Visible = name == "Utility"
	studioPage.Visible = name == "Studio"
	themePage.Visible = name == "Theme"
	pianoPage.Visible = name == "Piano"
	for tabName, refs in pairs(tabRefs) do
		setTheme(refs, tabName == name and TAB_THEMES[tabName] or THEMES.TabOff)
	end
end
tabRefs.Utility.button.Activated:Connect(function() showPage("Utility") end)
tabRefs.Studio.button.Activated:Connect(function() showPage("Studio") end)
tabRefs.Theme.button.Activated:Connect(function() showPage("Theme") end)
tabRefs.Piano.button.Activated:Connect(function() showPage("Piano") end)

-- GUI yang ikut ganti warna saat tema diganti
table.insert(themeRoots, gui)
table.insert(themeRoots, miniStudio.Gui)
table.insert(themeListeners, refreshUI)
table.insert(themeListeners, refreshStudioButtons)
table.insert(themeListeners, function()
	showPage(currentPage)
end)
table.insert(themeListeners, miniStudio.Refresh)
table.insert(themeListeners, refreshPianoModes)
table.insert(themeListeners, refreshPianoStart)

refreshStudioButtons()
showPage("Utility")

-- Tombol buka kembali saat panel disembunyikan
local openRefs = glossyButton(gui, UDim2.fromOffset(110, 40), THEMES.Yellow, "Utility", 18, {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.5, 0),
	Visible = false,
})

local function setPanelVisible(visible: boolean)
	main.Visible = visible
	openRefs.button.Visible = not visible
end
closeButton.Activated:Connect(function() setPanelVisible(false) end)
-- Tombol kecil bisa digeser; kalau habis digeser, lepas klik tidak membuka panel
local openDragged = false
do
	local dragging, dragStart, startPos = false, nil, nil
	openRefs.button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			openDragged = false
			dragStart = input.Position
			startPos = openRefs.button.Position
			local endConn
			endConn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					endConn:Disconnect()
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			if delta.Magnitude > 6 then
				openDragged = true
			end
			if openDragged then
				openRefs.button.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + delta.X,
					startPos.Y.Scale, startPos.Y.Offset + delta.Y
				)
			end
		end
	end)
end
openRefs.button.Activated:Connect(function()
	if openDragged then
		openDragged = false
		return
	end
	setPanelVisible(true)
end)

-- Drag panel lewat Top bar
do
	local dragging, dragStart, startPos = false, nil, nil
	top.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = main.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			main.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
end

-- Hotkey hide/show panel
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == TOGGLE_PANEL_KEY then
		setPanelVisible(not main.Visible)
	end
end)

---------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------
refreshUI()
if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end
