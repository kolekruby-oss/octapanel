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
local PIANO_MODES = { "Loop (kiri - kanan - kiri)", "1x  (kiri -> kanan)", "1x  (kanan -> kiri)" }
local piano = { mode = 1, hold = 0.08, running = false, runId = 0, input = "touch" }
local songPauseRef = function() end -- diisi oleh kolom Lagu

-- Data lagu MIDI ada di script ke-2 (LAGU TAMBAHAN) lewat _G.PianoSongs. PACKED hanya dipakai kalau ada lagu { packed = "nama" }.
local PACKED = {}

--[[ DAFTAR LAGU
Lagu dari MIDI: taruh di script ke-2 (LAGU TAMBAHAN) sebagai { name, bpm, tpb, data = "<data padat>" }.
Lagu teks (pendek), format notes dipisah spasi:
  C4        = nada C oktaf 4, 1 ketukan
  C4:0.5    = setengah ketukan (boleh pecahan: C4:1/2, C4:1/4)
  F#4 / Bb3 = nada kres / mol
  [C4 E4 G4]:2 = akor (dibunyikan bareng), 2 ketukan
  R:1       = jeda 1 ketukan
  |         = pembatas birama (diabaikan, cuma penghias)
Rentang nada: A0 sampai C8 (88 tuts). bpm = ketukan per menit. ]]
local BUILTIN_SONGS = {
	{ name = "Twinkle Twinkle (contoh)", bpm = 100, notes = "C4 C4 G4 G4 A4 A4 G4:2 | F4 F4 E4 E4 D4 D4 C4:2" },
}
local SONGS = {}
-- LAGU PIANO (digabung dari script PianoSongsData)
_G.PianoSongs = _G.PianoSongs or {}

-- Golden Hour - JVKE
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Golden Hour - JVKE", bpm = 94, tpb = 384, data = [==[Ii)#QtZtT##Ud_dT##Xdbd".!d2."<c&J/PtXtT##S$.!W$<!S$J*.s$J#OrX"J?$PQSd_dQ""OQQ"#N$N#%QdZ$`%!`"Z&(n%&."<k$J!se"JCQ""MQQ"#LtWtT##PdX$s%"V"!P$X&*."<c&J19jPdT##@d"'!I$'8.!N$J5kdT#"@dT#"I<*X"m"!j{"H!8$H!?$:!G$'8."c$!8$c$+?dT#"G<*X"m"!j(H!7i"H!6$H!=$:!E$'8."c$96jidT#"=dT#"E<*x#m"(B!4$o"!;$W"!D$',.9jT#";dT#$4jPd"O-e"J"u1:J)jT#"D$,!N$J'LjZt&X"0g"'#DdS*,;9dLv9"Qv9"UuQ"JN.#"9*X.%IdU(q,+$IdQdW$`-7Qw9"Um9"XwQ"4N"!tN"q")$IdQj0s"%PjX,u.1dPj9"Wil"$r+!G$p#1?dT#$GdPj"b%".+8dPpSp<m.0S-A8dKj9"Pi9"Sh9"Wf9V"x"##7"Q"!Oo"Q"=6dN{9"Sbl"#=dQzDg.#"6P"U/@>'$EdL$f'7=dT#&6dIjLjN$n#&@%NjQ2."e&S"=dT#%8jDjHtKt9"Psr$#8jDjZ%&'5&8jDjItPtUt*4(;+?dDdLt$cD#"8$n4#Dd>,r"'<t?tDtNtTtZtu-(-}9}_d_rdng~k~T#"bdT#"du(*+_nT#"Z"*!rS#>-%DtItLt$D!n*D!d*D-dT#)ItL"s%/XtZd_jdp4s"*V"+_dT#(E"L!W"J#ft4J,y"KhT#$-j9jZdQ"#bQgQQ""nQ*,)$@jHj.0m"<%BjN$</`QiQQ""l,,-%EjHjLj.2o">1'(t4t_pf~&m)5XdT#%GjKjPj$|'!u40!X"w8'u@uW(.Z"N"'PpSp*N"&o*-tT#$PjS,F%%Kp@H":!j2J)$(r4r>H"*)$4j@j"8+WdT#%;"z."h*>M$r")*t6tgR"B),t8tiP"B)(-r9re"y0&o/R"O1!%$k/T"D$f0HU1"D)'-j9j"m")tdtc'$S?"r8l"9uT#&@tDtWt_tftu-$EnbQgQA"Lm1"nQ1"TkA>_/",%$Ed..'%LdT004>1'BnEnHnLn<P/:,'%EnQR"H=T#'@zLz_pfzgzkz4x)!u0x)"^,0>*r8$k/%tStHu-&P1'tKtPT"D"q.*B".*F'$@jL.X1)DtGtKV"q"'6nBn4B1&BnEnInNn6J%8nD8J-DnKnNnP8J#9d2uQ"%$@d&SX"$700"pN"79dEd_d9"kbl"$iS"#@d"yK"ZR".,g"}"!jU#N"##80VS"%$?d&pX"$sR"00"}$%8dD,}$"YR"#?d"kM"hS".,"JZ"}"(uT"#$7s"N"##6$<!9$<!=(_&!B:0"}$56dBdZd9"ibl$XT"%#=d"d5!B6,"Ja$}"&L##4$Z"$T)#$;(_&$Sg"$0$`V"5l""V99%4d@d&n_"_"T"#T#&P"#XsDP"!j"p("O(/@dNdl""Y&W#&N`"!8:u""."PS"".#-d@T`""Z&*S0$jZ"#-d,U_"!E$gW"!I$WT"BV`"8P"!tR"u"'$EdQ$|_"&w"%PjZ*m$#,d8_`"!D$v#+GdT#$D0`Z"!%"L.a`""eU"!G.ve""g^"#,dFc`"J|"%$+dFe`"LS"+*d6dN|,g`"!{&w-$r&"*"e8#*d,x_"m"@#%B"Z`"*m`"%'*d:o`""D&q`"(T"#dN"r-?%=dG}L}P}T##(d4d&vk"$`,"w'"*"N8U#@'#@dN*ho")(d4dL*Pn"$f0(F*kn"Q'f/2w",sn"$g.%jZi(r+)DdPjWf#f/)#,d8ds"d/)#+d7d{&b/#$B0}n"@`/#$B(Oo"&P"0Oo"%,j80Oo"!?$dn"$''&,j8,Oo"4;m"Oo"!$,yn"%p9pi"}^")pIpLpR"V^")$UjXj*B)$PjUj*F$<*J%LjP$."<'IjLj*U_"$<*We"$k$1T##_tdpZ%$C'@jDj*eo"#$@"kL-T#&1j=j2eo""I*Za",.(mo""gf#&t_"%#9d2Po"#dE00##<q">%6dB$0$W_"%#Ed.h_"##H2.4<!<Loo"%r4r6oo",e`"-%8n;n?n4k`"##S$Ul""Y('PjSj*ba"(:/WdT#$KjP.H+GjKj_t(.*<,P`"%(j4,P`"Hy`"@z_"$Vo")8t;t?X"Vo"%j6j*Vo"'$6jB.jb"%+j7.xq"',j8j*ao"!$"YP#*J%,j8,J)(-j9jN"i1'$9jE,y/V"m1"Z0*sO#'$DjI&k.!u&<,J!@*Y$-nT#$=j@Bh/'dT#&$UN#8{O#)#9ddn"NA$.!u"L%@tD_"}O#I#9jZdA"@h1#bQnQ1"HgA""W0+bQnQQ"0,%#9d..'$@dH004>&tN#"2&c0!Q0c0V"UP#!BT"UP#%n4nJf1$ij#V"xm"2vq"##S.jo"*jN#!_"oQ$.{-%KjP.H%GjK.{-6jR#o"bq"1rGrKrWdZ%6i1'$*n6.v59gtT#&6n9n=nBn6J%8nD.J4zO#Fbq"+&9d_~d(R("fF,OR""tM/LdT#%E}I"pS"=cG%9zEzUtdtu-#W"^}"e##@zbtA"Byd""EyA"Hy|*#`tltu-%4z@z_|k|l:%@zDzGzJzl:#4x@xi)&b"!'(9N#Xtgtu-#Ztitu-$9xEx_~A"d~d""g~A"k~g3%E|I|L|P|TC<N$3&@zBzGtHzb"lP#!t$y#`"$4y@y_|A"k|s7%@yDyGyKyf8#4y@yf8.`$;&E~I~L~_tktu-#$T$=$PzUzdzl:&D~G~J(=&h&/Szbzl:&C";&Q%#Qt&=$e$7"`tu-&E}H}L}$B'#Vte"}"!t$B-&@}C}G}&m&%Stb,t#3&B}F}I{^tj,X'="Rnc'"I~c'"Nnc'"/C#N~Znc'"Unc'"anc'""/#d~]==] }


-- Moonlight Sonata Mvt 3 (bagian awal)
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Moonlight Sonata Mvt 3 (awal)", bpm = 173, tpb = 384, data = [==[b"!"1dT#"8dT##8d=dT#"@dT##1dDdT#"=$8+@dT#"D$8!I*D!8$D!I$8!L*D!8$D!L$8!P*D!8$D!P$8!U*D!8$D!U$8!X*D!8$DIXdT#'1j=jPjUjXj_jZ%&8.-#"0(^%?$8d<d<dT#"?dT##0$i$!<$o"!?*i$%0dH*D&`%!H$8!K.`%"D!K$8"i$"D!8$D"i$%0dT*D&`%!T$8!W.`%"D;WdT#'0j<jPjTjW,`%(-#"/.S)!A*|#!/$_(!A8S)%/dM8S)!M$80S)"D/PdT#$/dU$a("F0U)%/dY8U)!Y$8!_*D!8$D?_dT#'/j<jUjYj_jd$`%,-#"-*`%99dBdT#"EdT##-$i$"Z$/9dNdT#"Q$8"d#"U#A9dZdT#"`dT#%-dUjZ"t"#%9*+2O#"h/!C<O#"e.!O<O#"V.!^(O#!^,O#$+A&,j8jTj_jcjZ%$D~H"a'##_"q&!#$."l&'#IdR*,!K$g+",!L$e#",!N$^,.D(m"0:0R"!Q$l&",!P$v$R"P"0p#%IdQ(y%*S%$:F,%$IdW#b%T"Z$P$`%!d0u$#DdS%<InHnPnT#"_jo+$,x8xDx`6f'x=!X$8"d5AddT#%1j=jXjgjZ%$8&)%".j(P$%=dC*Y#!:$Y#/CdT#$=dI.R$%:dO*F!=.h3!:.R$!=$D"R$!:$R$"D!=,}@/#:d^dT##$O:##=,m4'#:dd*F!="F$W%%.j:(W%(c%%"+j(u@%?dF*a$!7$N@!F$8"U%"N@!7$v0"D!?$D!R$8"a$"D!?$D/UdT#$7dW$i/"F!?$F!W$R"!a*N&!?$D!a$8"U%",&8"D&P""_"&k""w"'8dSp&^%#";.`E#Wv:6"f.<J#Sn06;#?dPQQ""OQQ"#=$,-RQQ"#?d"c0!:*Z"%=dO*p#*6"U0$@%:dO*q(%=dW*,08%;dR>W%%;dP<64@.e",}"08!7.W'!7*Z"!7.f#*64@.e"*}""B&g+'#8dS(P"+$;dWjf*F*u(g"8+$8dSjb*.);dPj_*.!:2.)=dOj^*s"*S)g"8#$:2l#4<);dRjaDz#,W)g"86z%4<!72X&!70l#,h)g"8#$72^#4<)6dTpc*r+,r1!6<V2-$4dUvdv(b0"8"*!4***4z"$6dReaad""baA"=dA"aad"#3d_ad""aaA";dA#Stbqd"$b#"g'!3**T"4!2(*-$2dPp_p(8"P$4B,45$1dQp`pT#"9*8"*"uD44E$1dOe^ad""_aA":dA"^$Y%+Yad""^$4-#Pt_qd"$eZ""j&"u$"*i"4E)1v4v9v=vQvUvXv`vQ2"e@!"*nL"rV"#"b*r@+IrLrQr"0":X$N")dLdQd>N"&:LT"7edT#"ghT#"fh&*&:*0"O"$Y"!`$nP")_rT#""b8"eJ"*"zC:4MA"bgd"#Udagd""bgA"OdA"a$4/bgd""agA>H"9'd""_(*5%LkPkSk_j|**c)3EvIvLvQvQ2"hJ!""kb""t#"fQ""y#"jD"*"4*H-%=t@tEti"N""y"-%=r@rErR"N"+%=d@dE$ne"4O#&:h#T"-%=y@yEy>e$8`%!VZ"h-!""X,!f$`>'Xrgr&Tj""hS"$*"_844)$>dPr"`,!G(_o"$*!>***4+$?dSrb*L"bX""*"Y;44I%3iCrIrOrZ%"?iT#">iT#J*A%8mDiGiPiZ%$DiKiSk")7FiKiRiZ%$GiK"b"7%?mIiKiOiZ%%$)!W{"+$n""+$R#/WiZ%$8mS")!#f'g$!w$g$1%DnGnSnWn4+9GnKnPnSnZ%"=r";)InUnX$F*+9InLnPnUnZ%"?mc"o"/?mZ%$CnF"9*)A&CkFkKkOkRkZ%%,n8"X77Z%&8k?kSkWkb^#-?:k?kRkUkakZ%&;k?$W91kZ%'3q=o?"i#;^kZ%&?kIkXk^kgb#--GkWk^kf$-;FkUk^kdkZ%&,n8"k#`#a%W'n%9',n8vSk_k_kbj&n+%_nb(y+$++$Dnbnf"t-!v*9!d,D!d$D%dng"y,"D-dKd_dbd2+3#bdgdZ%";v]==] }

-- Cornfield Chase - Interstellar
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Cornfield Chase - Interstellar", bpm = 115, tpb = 384, data = [==[9!"XdT##TdYdT#$,1Yd`dT##QdO#:!S$:!V2:!b^#:L^#!O":!"08!^DR""Du"W#"R"V#$OpXp^pi)$5jQp`pd""9jd""<jd""Ajd""Ejd""Hjd"$MjXvgv&.$8"B5<jA"9jT#"5j"b"+A"<jT#4<0R#%A"E"D"c"#w#0P#'T#"H"@,O#(X$BP#&=d"$7jSpbpd"";jw##>jCjd""Gjd""Jjd"$O(S%!J*8"B9>jw##7j;jw#">.6"l"4z"(8&}"+A"JnT#&|"+T#"JjA2{"(T"!7**>S#9%9j<nTpcpw#"@2Q)-"Ljd"$Q(P%!L*8"B"L,Y'"*,c"*>-$9jTpcp<BR$U#)7jVpeBc'_"c)R"e'!k(4W&njQ""ljQ""ijQ""ejQ""bjQ""`jQ""ZjQ""VjQ""SjQ""QjQ""NjQ""JjQ""GjQ""EjQ""BjQ"">qy)"5hA#Q~`~A"9hd""<hd""Ahd""Ehd""Hhd"#AjM$,$S0!E$4"_')<jA"L"P1+d"#5jM(n/!Q&N1'#AjT(H!X,H!Y(H!`,H!c$d()A"gjA$b))MjA"h&-'#Ejl$U2%A"n(U"'9jnh"Z2+A#X~g~$R#@w5##A$d$$r3$v3Q'_%17jA#S~b~AJm-'#CmO(,'"GmA"m41Cjd"#>jLm&O-'#7jO*,'>jSm&j"'#>jX.D!^.D!b*D'Gjgm(T#-OjA"jmA(O0'A"nm$d##">&-&U0(b)O'P%(q#%Gjn.m"","T<+9jT~c~N"y7'#EmQ(,%"Hm&@##@${$&s*!Q*,%@jT.D"{$&D!`.D!c*D!H${$"`#%Qjl*,!H$m$&k"",&u;%X~gc(y$+7jV~e~N"i=6v,,_*c$s,%#Oj_"q,)7jS~bN(y$"k$d"~RM$-p9pTdT#"SdT#"QdT#"LdT#%EpHpL_&:)$+p7p"3"=!V(VV"+%CpGpJ_&:'$)p5${$*3"gY"%&Ap.j%o"<"s"43#"^0T"47#"`0<47)"bdT#"b+!c(.$8"n%$R"u":"n)"3"=+edT#"g,`'u":##S$kc"%Tdc$Ud"-edT##Xd}&<%{g{]==] }

-- Mrs Magic
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Mrs Magic", bpm = 105.0001, tpb = 384, data = [==[W"!"fjZ%"ejZ%"cjZ%"ajZ%"^jZ%"_(*n&#VjYjZ%#TjWjZ%#RjVjZ%#PjTjZ%#OjRjZ%#MjPjZ%#KjOjZ%#JjMjZ%#HjKjZ%#FjJjZ%#DjHjZ%#CjFjZ%#AjDjZ%#?jCjZ%">jZ%"<pi)':vAvDvHvKvOvQ2':pAp(/7i)":jZ%"AjZ%W%H*/r"i)":pi)'7~:p?tCvJvM~i)":vZ%"?vZ%#CzJjZ%""Y&#:p"Y&I?pHtZ%":tZ%"?tZ%#CtFz*1)vZ%"C"@Z${"!t,{"'Z%"?`%j'`+e(!(0t%"u2"Y3"k3!j"@.P'#h|S#}'R$V#!(,^)%Mvf(`)!(0b'!V*T7%:va"P'7vejZ%$CzJjc|b#m)0X#!zk"X##M~w4z)]==] }

-- Main Serong
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Main Serong", bpm = 125, tpb = 384, data = [==[1!#>pAdT#"4%/#=p@dT#"4%/#<p?dT#"4%/#;p>dT#"6%I9pZ%"9jZ%"<jZ%"=jZ%">*%"/"9T&H#>p(45AjZ%"BjZ%"C*%"/"9T&H5EpZ%"EjZ%"H@/)jZ%"D"W"!p(_"!F@/*x"e$}(]==] }

-- MBG Mas Bahlil Ganteng
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "MBG Mas Bahlil Ganteng", bpm = 120, tpb = 384, data = [==[S&Z%$<pHpTpa)$<oHpTei)%<sCsHrLsx-"Ep+"Mp_)"Ms*"Er`)"QjU%"Ov*#GvScQ2$<jHjTjV%#HjTj*"<jU%$<wHpTd{'"Cbc""Ls*#CsHsq-"Mp*"E"r"v(j2"EpO%"Mpi&"Qjt#"Op*#GsSW`)"Okj%#GhOtV%"Ew+"TwP6"Osa%"Lrb%#HsTiU%#EmQo*"AsU)#HjTda%%@xHwOxTg="<WO3"<`t##>sMp`)"Lm|&"Lot##>lJm*"Clj&&>aCbHfJdTet#"Gm*"SbN"">e2"CeU%%<}H{TnXiq,"Tl]==] }

-- Rivers Flow In You
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Rivers Flow In You", bpm = 70.0001, tpb = 384, data = [==[M!#Bj`jZ%#Ij_jZ%#Np`jZ%"",!>$:1EjXjZ%#L|":;Vzl:"QdT#"UdT#P$a"9dT#"`jT#"NpT#$B,4#>j&4'#EjX*6!L*6'>jVd(,A9jUjZ%#@jVjZ%$IpQ"v#O""UjZ%$DjPtStZ%"GjZ%"LpZ%$`#!P$R$1QrZ%"IjZ%${#!L(w"#"S$X#+UtZ%"E*^"+UdT#"V$j#;XtZ%"@jZ%"IpZ%"6$N&'@jSv(g#'Ppi)S%b&##I$V)%9jd$5+bjZ%#G$5/IpbjZ%"`(b#-$BjXt`t,f&(Q'(a&$}*!L"}*#pQ"^(0e&$U#"?%IpU"o+0i&!p&i&%#Lp"i#!b"e%(s#%#Bj","`%!I$R&",!N$8!b.D"P"!>.P"&U'",!L.P"&D"P"!9.8/@jddT#"e$b#+gdT#"d$D*^$##@$r0%GjS"}$2a"k(O%;`dQ""bdQ""@jQ"(Y)'Q"#6.T$!=.T$+Bj`jW$"S"(DX"W%*P"f#W%!6$W%!;$W%!DF|#4O%!Zf#O%u"Y)!Gg"O%#vP$W8#i)Lm<"T-$W2.Z7Fv$"8&v$X"s<!j$s<&7#$@N"u<)$BjLr"w<'Gtc'>r<!d:X=$b7!L$V$2n7*8!@.8&d2"8!9$}$(O8*8!G.8%LpS"N>%jZ%BN>*Q=!B.6m$P>!L$..Z7Z"R>*o%#Ej@s'&BU#s'!4.s'%;jP*l#!D.T0!4Ju22w62R8##6$t0R"z2!J8U"l#O3*W%!;$X#0f%0c$v+k%"s#c"N<&f%a$N<P"j(q"r)m"Z@w"r)HdD!4(a%"z6#Dp$b@/jZ%$BvIv*z_"!"**'$BjU$T"!J$e7!N$Z:!B$e"!@$p8!I$..S^"'#LvS"_B(i;;%6jIpLpQpZ%"=t&l#JeU"!N8eU"Jqc"+%>jUjX2uc"&l$!>$^$@_<#"d$zB&i;"zB"g#,zB=6jLtQtZ%"=jZ%"BP"^Y"!JT"^Y"!B$?2f;"u&$k)=Lpi)#6jQjZ%#=jE"R"!v$t>"X$!v]==] }

-- Vivaldi - Summer Storm (Mvt 3)
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Vivaldi - Summer Storm (Mvt 3)", bpm = 150, tpb = 384, data = [==[=!$7jCdOjT##7dCdN$'+$5jAdMP$r"(y")3j?dKc$y")2j>dJn#k"7NA$>jJdVdT##&r"x#'+$<jHdTc$y"):jFdRc$y")9jEdQn#k"U$i)"VdT#"TdT#"RdT#"QdT#"OdT#"NdT#"LdT#"JdT#"HdT#"FdT#"EdT#&+j7jCdFpJpT##C"t)!%$4"S(!C"a&!',F"t$%CdO,H!N$2!L.q"!n&q"!H,F#Fj"2@j#!^,F!Y$o"!W4j#"R-$W$&H"o)!C"z'.H!O$6!M,H"y1!C"j'=&0j<jCpHdKpT##H$l#)0j<jH$l#!H$l#,F"l#$|-&H"l#!H$l#*H!n"l#!H$l#$H#Kj"2@l#!a,F!`$X"!^4l#.R$&H.N$.H.R$&H.N$A'3j?jCpHpKdOpT##K$n#)3j?jK$n#!K"n#!(0H"p#!K$p#$J"p#!K"p#0J!n"r#!K$r#$J"q=!KFr#!e,H!c$Z"!a8r#.Z$&J!Z$2!X8J.Z$&J.T$3'7jCjFpJpK$}&!O$r#)7jCjO$r#!O"r#*H!O$}&!O$p#$H"p#!O"p#.H"n#!O$n#$H"n#!O:n#+jT##Oj,n#!jBn#!j$n#!j,n#!j"h)8n#!j$n#!j,n#!j8n#$l##RpX"n#)JpOjR$O)R"n#"H!n>n#"v%$T,"vH$S'$N84')%>jJd&t-@@!$R">=(2j>d?dJdNpQjVp"O"5NnQnT#%>d?d$b)'$JdQ$g27>d?dNpQpRdVn"8!T"h%"L%VjZ$L!X$p1&L5nVjZj`jT##J$U")>d?dQ$0!N.x#5pNjQjTpT#$H>x#"w4.y"'pRdT"k*)$HdTn,z#"V.#$H8z##Tp&z#$R7,z#!H"z#!&"NK9pOpRjT#$FdOnR$s$$k#'$FdR"X"!'&F#pT"W6#$F(g#%>dW"g#'$FdZ"g1(J1n^jajT##F(hK"h+!F"d)!'*i&1pQpT#$EdN"l,&g&#Xd"4!Q"U#"f%$J!R$`#%EdT"`#&g&!a$4!X"t4,N"1nZjejT##E6g&!E2d)=jNjQpVjT#$JnNnV,d)"z#!J0z#(_,"z#!J2z#!j"z#!J0z#(a,"z#Ha,!d,a,"Y/P"a,8Y/!H>Y/:_,*Y/!H6x#T,_,5+j7jFzJpOzR"e"##V"P#"nO"#Jp$-!#$;&4d#H!j2H"TP""r#(P@!R,J!O$`K!J";"kP"&xQ"S#F$tA$db"(sR""a"-T##FjJj&_"*{T"#Oj*bU"`#F"+&l??'+j7dGdJjOjSjT#%"Q"+jSnT#%(8}$6'dOdS&SS"7dHdKjOjTjT#%&+'nT#%*8n#6$^5!K8J%$Hd&`S"C-j9dIdLjOdQzUjT#%E"-)UnT#%(:}$6'dOdU(w45JdMjQjVjT#%&+$a:$-}$6#dQ$l/--j9dJdL(N$!E$+$Q%$8}$6&N$"R*!:"l'#Qj*R*-QjUnT#&,:`%8#dQ&_*?p>pJjMpQpVpT#"Jn(Np"!M*ep""op"1SdT#"UdT#$`q"@4?XdT#"YdT#"^dT#"`R"97bdT#"ddT#&>p$t#'epo+$<"%!d*%!g*%!l"O:#pl*E#Jj&*'#JpjB6!hB6"q"i"LD{"l#z#1$Jp`pgpo+$d'"%"d'"%,u&!e$e"!e*E"e""`@%JpcB6!aB6,v)_"L"^):6l#z#1$JpVp`po+"Q+$%"q'"%"e'"%!f*%"g#"%"X#"%"|""%,f'"Y."%,T(!W*%,u("qP#,vP#,{P#"%!P"S%5}QjZ%"PjZ%"6*5MjZ%"OjZ%"K*/#Jt(/`"IjZ%%>jAjEzJpZ%%9j:j@jIjZ%$>jAja"4j#a""T_"-JjMwQvY"WW""i6)$EjHd"j)+FdT##E"|I!""rb##Ad$O`"#"@&pW"-jMjVjYj&g7%$Md&k"CLdT#)+j7dJpOxRv^j`"oV"(i"/FjJpT#"?$RT"/FjJtT#"<"g_#%dRn"U#!9(}N"!R"U##^j&X)%%Od*q"=MdT#(0j<dLpOvRx$yX""kY#-$FdHjLp&oY#U"$CdHjLrT#"AdT#%@dOpTjXjT#">(hR#%LjX$W#"j`##Hd&o"9FdT#()j5dHpMp*h'+AdT#$@"4&g"5$<dHtMtT#":"}a#GdQnTjT#"7dT#&)j5jQjT@j'=KdT#(.j:dJpMpQx&6!F$XI%FjJ$U#)CdT#%"x'!r"0!?"f=+dMpRjT"mF"N(+&.j:jJ(x)&u&&u"!E$^R#-FpKpOvW$V&(f)%pKp,f)'FtKt&f)5$7dOnRjT#"5$_Q#)OjRjW(`)%$Kd&k";JdT#(,j8dHpKvP(Q#!D$`)'DjHp(t'+?dDjHr&t'-%<dKpPp"h'7:dT#&,j9jHjT$U#+FdT#$D(U#=CdT#(/j;dJpOvVx&6!G$kd"!G$P.&a.'GjJr&x%/%>dMjOpS(b'3'/j:j;jJjS$W#"d'%GdV$q"!E(_0/GpJpMxSv&Z(&d))GjJpK(x'#%>,0)<dT#%"c$%jSp&|'"q_"#Gd&^#&Y/&s"!A(a0!C$YX#"Wl"!#"WW")#$FdJ"t^#%$Dd$yX#+$CdMdP$w%$yZ"#$?(ym"%>dS$ZR"'0j<j$Y^""f#"mK!K(xm#1%CpKjOpTu$O0/dKnT#%:d(`#/%8dDdKuO$b`"(d#/%5dAdOrS"V,!d"h#+jT#%2d(j#"he#q&f#$de#)jKdOz"P."ya"$4"YA.0"T"}"@?dT#(5jAjDjJzMdPx,Y#$6,i"$0"YT"J@'MdPp00!P,Y#!&&P`#!r,U#$2"^U".0!O*e""0!j$@,Ns"&t1"tj"$`p"*xV"'&0j<$b.)dT##<"lw#z#',QP$X$y"%8jD"S-Z$y"$Wg#S#Z""cv#;ji)&<jOpTjWn^z&u)1#HdWjT##G$To#!H&@(>!<$j0"<(_"*Z",<#&7"z*!V${")SnT#""dB"r+"qQ"_"*q$e$9%:pRjVnYzT#"R*c$"m0"r#_"*#&3:c$!?$c$#>~"U#!?6t#!3.t#(_"*Z".</7pRpWpap2NY"!_*%,yY",`Z",tZ"!f$Ns#'KzRz"a^""eU#$eX$##A$}@#Cj,:!7"bu#"sZ"##7.8!C,8/&8pHpKpP"ZQ$.f_"_"N$$%5hdT#%9jMzTz"va""ix#!E$i}#&l^$#Ej,:!9"e{#"Xa"##9.8!E,8-%:pJpRp"k$s"|#$%!j"WH)jOzVz"Ye""cj"%Gdb$`$"k'#Gj,:#;j"pq""8!;.8!G,8"xH-HdKzOzT"^)X$P71%8jDdKzPrHG#DdR"<!pF<E'/j;dGdJzMzPzT##;dG"P&v#'"ZQ$1JzOrT##:d"^e"4'#CdR"<!pF<"fS#'EdHz"Q)%##9"Rl$z#'?%5jAdHzMrT##8dDd:'#AdR"<!pF<"hf#/CdGzJzMzF{U$^#')%?jHp$lh$DjX$'KdOj(>&ti#,{i#)$KdTpJ_"A'6jBdNdQzTzWzT##B$Vu$x#'1%?jJdQzVr$}'&T(.'#JdR"<!pF<A'4j@dLdOzRzVzT##@"Oy$z#'!%"Xr$%zTr"lB"ow$4'#HdR"<!pF<)$2p>~"N`#$%(Yk"$fO%"*,%"ST"64"fF64"cN#64$UR#4%"rO#64!Z>4"v?64$_Y#4%"g@64"q@64,aV#}"OU%!$"Wz#"s0,T}#!C"Qn$!#$Ob"&2$wT%$rq#$2$wT%!j"Y+$2"WX%#Cj,uT%!j&n:8`#,qT%$Qq$!C"}3&2$un$$}p$$2$mT%"y#&2$P4"bd"&2:iT%)zHdKyN"iT%<dQ%<eT%<`Q%<aT%&qY""jT",ZT%${x$!H$V&$2$r#$V&$2$r#$V&$2$r#$V&$2.r#5&3j?jFzKdOyN"PT%&2R"zS%<mP%<tS%"d#+HzKdQzN"rS%Jv#.lS%c"v#$^m")zOdRyN"dS%&2R"`S%&2>YS%,z}$)'7pCp"fQ%"q`$-"OnT#"C(Su")'6p7p"hW%"PB$l3,>37p8pCpJpNp"{64>-&7pCpKp$gQ%6{""<%JpM$tY">X"Fh#"<(Zi%8T$U'u$,o("j).WO$*Wx".WN$"^$,WN$,gq#,Zq#,Pq#i"m<%'.j"yP##zO$UG&n|%&PT"&cN&$DU#>$jT$+pKdNnQ*jT$!N(mm#.`$,o$,N%,`%,o%,N&"`&"X'"o&"`',N',`'"VR#,xGd%n###>$Qt#"yo$$`t###F$R}%!E$o=#Fd$}r$!$"0$Qa#!J$`P%#Bd"na%%#$@"Xn$"Qa#$sQ%'$<dJ${N"5.d:dJjOrT#$$+&4!F,+!C,+u"J!pT"J"Qd#'d<dE"{n$)QzT#&,/e&-"p'!*$ZX%=EdJdMzNdRzTzT#',5!N"t/d'/%+d7"S)"qX%##%&/'nT#$$+&4!C$+x3h+!j&h+%jRr"TT%$-"rr#*+26"L,lU%"+46!r*6%OjR$T`"!C,+46(Vi%"n_$'wRjV$nV"#Cd*+!7,+'CdRw*6%Vj^$^P"!C,+46!r*6!J,6*+46!d$+"`P$!F&^l%$ce%"m&&+!7,+,6-&7dCdOp$e%#$C&n%"wy#<4!J&UX&$P($+46(Xr%++z7zCz]==] }

-- Vivaldi - Winter
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Vivaldi - Winter", bpm = 130.0001, tpb = 384, data = [==[+!"Mji)a"%+$MjOjRr#)!%$)!Ua$+!&(+;aMQ""cMQ""acc'N(7!Ly(7/%MjPjTj_"0)MQ""_l'5"X%3MQ""WMQ""Ul'5'QjTj"0!Y":l'5)OjSjV*V%!Vh'5!N@V%^'5'$OjT6T%`#3I%CjOjSMVMQ"#TMWMQ"#Sc_$9S"$0|<|TdT#"ccT#"WcT#"^cT#"T*/!O*/#Hc{"H+acT#"_*M!Y*M!V*Mk"H,R#"9d#4G%<jCjH`Kjd""J`d""H`e**&4l%D!&"D-jKjOji)i"-"s*+WdT#"f*x'T"R*u"H!e*H+bcT#"`>R*k"H,R#"9d#4$a(;jK`d""M`d""K`e**&4l%D`#s*+^dT#"j*}'T"R*u"H!h_"R*k"H,R#">f#41T`d""V`d"g"*-Z%"Tji)"%##T6tJQ#1+$RjTjX*TA!Xf#3%&Aj&wQ"AjZ%"MjZ%%AjHjMdPdo"0)IjMdR^#0#&?"s"%QdTl#2%=jF"{"!Up#2)DjMdSn#2)'0j<j$a`"1TjZ%$TcXc"w-'OcT#T".?jXj^jZ%%OdTdXd^dH+5$5jYd_dZ%$A"O+^#2+'.j:jM"Sd"1YjZ%$RcUc"R='McT#T".&S"!%$U(#YdH+'$3jW$}$!?"R'^#2'',j8"f:5TjWjZ%$OcTc"j5'KcT#T".&S"1%KdOdTdWdH+%$1j&}$!="o2^#2+'+j7jI&m(?Z%$McRcUcT#"IcT#T".&S"%%Id(u/D+3$0jTdXdZ%$$r.^#2%#5j"b++XcT##D$,'^cT#(8",%DjX(OI%#4j*^I##C$,!_.8",!C2k"*fT"##D$,!a.8",!D._"#7j*nU"##F$,!c.8",!F2_"7crZ%"KjZ%"Dj(B%Kjd(nC%#Dj"zC{"8",&8"DR$8,`'!K4f%)cT#"d$8"uG!hS#P"'Fjdr&u:%"Fj(N"!M.N"!C$N""8!Ko"8&`#*Nb"T$8"y5"X.!K2|-,R,0Z*{"P":U-"N"!K.N"!A$N""8!Io"8",&8"DN$8!@$r%"`'!I.h3!?.x'!H.8!>$U-"_"!H.n5!=2t3*8-$<jHjXd(pV"!R(zV"%#Hj,cj"06"r7,yb""j#!H$O#:6"Lq${",Pp"&s&De""W#"a?"i#!U$6!L*wh"!M*aK70dLdRdT##<cH"0)cLcRcf%03&5jAjHdMdP<v)#"P<v'$R&_"H7$AdWd`dT##Mc$0'cWc`"{7^%05&:jFjRdVdad2Xy""*"`%64"S%_"H7$CdYdbdT##Oc$0)cYcbcf%0/%<jHjWdc*i*,WN#6_s",4,_m"JH"U(%:cP"W#%#Fc"bV"d%01&3j?jKdOd"^|"4s2.Q{"}"4#$8&VW"##D$g#t%0T&f(&0$m(7pOpWpi)#?jKj8')$?jKj"yS$L)!%$)!Pc"+!&(+;RMQ""TMQ""Rcc'z#7%>jJq$7"_%!OZ$5"c%$YP$'Z%"U$zt"Q#2-%DjKjPj"{""f|"'Tcc'l#5"Q|""Nq#/jZ%"WjZ%W#2#%F"gj"6xp#j#53':jAjFjVjY$kO#'_jZ%f#49%?vFvKv^jZ%"f*%3aj^%"ajZ%""9"%"qr"3CvKvWpi)"^"X3Evapi)"dpi)#8|cjZ%"h*%"/"%!`*%"Ox"f"EvMvYpi)"`pi)#Avcpi)"fpi)#:|ejZ%"j*%"/"%!b*%h"^jZ%$GvOv^pi)"bpi)#Cvepi)"hpi)$<jcc*oa#!#.,#$TX$:'Mjcc"Rb#"oX".,_$:%Oja$."x#.,g$:"Pg#&:*,_$:%Hj_.:.,_$:'Jj_c"|r""g(.,_$:%Kj^.:.,c$:Hd/Z$:'Mjcc"qm""ye".,N":%Oja.:.,N":'Pjac$fr#$:*,R":!_.:.,N":'Jj_c"lk""`g".,N":%Kj^.:.,N":'Mj^c"um"!P$:*,R":!Y.:.,N":%GjY,Ol#!#.,N":%HjW.:.,N":%IjW,ij#!#.,R":.pk#!#0|k#L:'HjTc"ft""x#.,V":"e""`'.,L:!%$q"F_s#a">0l)2.a">0Y-2.a">m"n#0W-V$Z&2U/!HHr/''<jH"n{#$lz#b;r{#!<"iz#&yF+%CjFjL,i`#u$>"hZ#!T&sc"%%5c(r2%#Ac"f4e"2*d"1'5dAdPdTd$q/V"/).j:jO"N/"w2!."j/"vL#:c"z5e"2*d"+'.d:dO"P0!^"R#R"/%0j<"S/&m5#0c(V6##<$|"e"2*d"''0d<"O/$o6V"/#5j(Oo$"l4)5cHcM"a('#AcD$z(a"2#jH(z/+5dAdDd$mg#Z"/).j:jC"|0!O$_)%IcM"k%'#:cC$z(a"2*d""n(-CdIdMdO(}(L/#0j$vN%$}Z$+%0cHcL$|"!<$|"e"2*d""n()CdHdL&R#R"/7)v5vAvDvHvMv]==] }

-- Banda Neira - Sampai Jadi Debu
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Banda Neira - Sampai Jadi Debu", bpm = 120, tpb = 384, data = [==[U&gR#"Vv#"C~#"J~O2"Q~VT"#B~Qv""XwO2"N|$"Q|fN""Zlq&"Zv$"@~N2"O|#"L|gN""`~q&"B~#"E~|1"N~&"L~TT""nw#"CvO2#O~S~XT""lv""BvR2$@I#L~Zv#"@~'"Ov{1"S~YT""S$z">vO2"L`""J~N""N~VS"#C~`l&"Vli&"Qlq&"Vlp&"Olr(/7mp&"Xmp&"Qlp(/)nn&"N$M7q&#B~Xnm&"Nm(T"%Xnp&@S$Qlo&"V|SC"Zn#"C~p&"Qmo&"Xxr7"Onn&"Znr&"brr&"Jvn&"dlp&"glo&"`u""B~R2"Lmn*d$"P#q#o&"Zlp&"^mq&"Zlo&"^ns&"byo&#@~LuQ2#L~O|TC"Oln&"Smr&"Vln&"Z~%"E"r&7v""JvQ2"Q|e=$k%d"Q~#"BvQ2"Nv&"Jv}1"L|b="Umq&"Cv""S"O&9~f,#J~L~RT""N"l*_#%"4~}1"O|jN""Glp&"@~""C~""J~#"9~Uh""E~#"@~"#9~I~Yh""O$Z'"n%)o&"On"s((}%-Ono&"Ql(N%%Onm*/1o&"i{""Ol"B!o*c"*r"#op2B6g"5s&"Vnp&#Oli$W#,e""v*!p&_,%ir#$}'.^$$/!s$B,e""S">z#)p#"Ol*k#"z#,e"#noLe"(z#%`v$(S""b%3m&"Z~$"Oll*x"#o&(_(H|##|":|#,y&-ln&"`w$(n'(g"+Z~""Ol*p1)lp&"N$Y*"N$)l&"No"Q"(g"!N$k#)o&"Vo"/'#"Xv*c"1oo&"^s%"N$h%"T#!$$l%!N$o#(Q''Nlip,m#"m"2N*"Q'"U0"b#!m"Q')'"Onk.R*8T%0k(,c."c6">+n&"Qms&r6$c("Q7!l"^*#Xr*13np&"Uv$"Nm"S((_8+No#"Xv0|/'#NlV"W""o$!v,d%&N*)#Nmip,Q.,w&"c"'p&"N,U:#lo<u&Gw#"Cl#"7~o&"Elq&"Jll$j(;Clp&"Elp&"Jlq&P"/1p&"Cl""7~"3!o*B!q>/"Q"1o&"Xv#"Cm,g";n&"^v#"Bl%"6~m*73m&"Zx#"Bls*o"#o&2/'q&"B,N#!m">%$"6$l%5o&"Jmp&"Blr*Q"6/,c"(>-Vv""Cl$(S'!r&S'%Xv$&a%#mn&J%Sv"2a%1p&"V~#"Cm,b("^'3$"7~n&"Els&W&:b(,w#+o&"Vr$2g"/n&#BlU~%2r%6v&,r%(x"LU'"x"!m4v&"B*c"3mq&">v_,"N"w-Iz""7|$">|#"Jz$"Gz^="L"m2-x$"E|p7$OEINlr&"Lz"#6~B~&#EzIz`=$S$'Ezd=$p"Q"Lr##@|Jr("Gs$"4|S,"Nrb,"L"x/"V3Is""Ls#"@|#"9|1"Gr{+"N"NL"p$'|#">"cC5$"2~}B"dfh=$^%f"Cv""7v#"Ls*"GsP,"Nss&"Evn&"Lmo&"No"_25#"C|m&"SvR2$o3!S"U-E|""Qz##IzLz""6|b="L"}8Q"z""Jz$#;|B|""E|b="Nmo&"Lm"l$?#4|Cm'"Gog&"NvP2$X'p"Nlr&#@|Ly#"C|""9|""Jx-"Gxd7"Gmp&"Jsp&"2"OP"#l&"OHMB~%"Ez`,">vP2"EvQ2">v`,$`6;Cv$#7vL~("G|y1$C-C|%"G|a&w(96v#"E~O2"=vP2$jK'Evb,$|,%Lv""_'=4v("Gvv1"Nl%";v"b%!n&i8#Lz$S(1@vN2"Gva,$^'EQv#"6v""Iv}1"Sn#"=v"W:"yA=q&#B|Qx%"Ixp7"E"q'"o"Km##@nJm$"Gm#"4vi&"Nve,&i#%lq&$U(CQv$"@|""C|-"G|d7"L"Z'v"ln&"Ls##@|C|'"9|3"Gsu+"Nsb,"Lrb,"Jv"">v#"2"sP"E,"Eup1#V|Z|#"Q|VC"9"m(b"c)"bqi)"Z{%"7vO2"Cv'"GvW,"Xnq&"`"E/Q2"Cv#"J";!f&w@!Z"QV"Gv&"6vN2"Jv#"Bv'"EvW,$OIt"Qv$"6vQ2#BvJv%"EvX,"Zmq&"Xs$"4v_,"Zrr&#@v$h#!g(fV"Enr&"`s%"9v^,"Zys&"@"Q*/&"IvU,"X"QW"=v""Uv#"2v$">a}1"W#)&#9~>"nV"=v1"U{e="emq&"gy$p1O"jvO2"G|o&"ion&"lmq&"nvS2${1b"lnq&"nlo&"lv%"6vP2#@vBvP2";vP2"N"n&-R2"4vO2"}$/)"Gv}1"9(0Q"%"IvX,"nmr&">v""2vO2$B~E~"me"/N{""V{c="Xe";$CvSzZz#"Vz""7$_/!`(V)'y""L"h#!w"xH'o&"Z"RIU"{""Qz&"6v}1"Bva,"Vpq&"Qz#"E"x^"W"N2"Nva,"Znp&"Xs""Ss%"4vZ,"Zs*V(!m*v")r&#Ur,|(#vs(U1'^,"X"}`"f"v#"Uv""Qv##2v>vP2#>~IvO2"dvP2"`re,$mO""b#'r$"7"b#%rr&&w-!i&vM!Z"s%7m#"Jvo&"bvb,$x%=`lo&"bmr&#Xv`|$"{--#BvEv_,&h.#w#"y-3;vQ2"Bv""E"U#"|%S"n""Sn%#4vOlk&"Zvd,"@v#"Cvl*x/7r&"Xx""Ov$"9$o01""@vl&"Sm&uj"E#N~V}"#>lQ}%"2ln&">"yC$V4'o&"B"X+?mr&"2lo&">ln&"Bm"pC">U"n&"Zl$">mn&"X~#"S}#"7mo&"Cl,mD!rHNO"*YN"-mo&"Vs"$Q"16nm&#BmQ~"VG*P$$S"(vI&/(kJ!B"e"#l#$x"CXv""Sv#"Ov""4mn&"@"Q>+ln&#Ll$R6'n#"@"W%'m$"C"W%1y""Lmq&"@"yC"Z;%lq&$F#`l&SM+Bl""`v$rr"#6m,aQ""T+!"$}#7`l%"Elj&"Zm%$;%`v"$_(,SL#Qv"/"n=b"o&">~##7~Ll"#C~O~%"Jl*"Gma&"NvS2&ZE"zb"+vr7"Xn(Pf"j"Xs#"Qs"#@|E|&"9|X,"Zrb,"Xrb,"V|"#N|Q&}Hd"2~PC"ZvR2"JvO2"n~%#7vj~P2"C~%"G~P"^x"p$$"6vO2"B~WT""io&"4vj&"jmp&"i}t&#@~C~QC"iyT2"6vl&"lsd,"Bv#"@vQ2"@vP2">vn&"nrc,"7v""jo"V#-("G~OT""p9"x0+@vR2";$p>/""GvS2"4$_:'CvS2"n9#"C"m>7|1"n`Zh"#BvQ"X7%'"6"9/x1$>vLvO"5I#"4v$"Gv{1#C|Lv"#JvOv(UO"5N2"IuN2"Qv""uF$v8+#">v|1"s2!G"QD(k"#|1"O39Jv"#@vOv%"9vz"3"/'"#9v"y7CQv##6vJv##>vEvN2#>"M!G"dK&p"!O"W&3|1"@v"#CvO"uA)P2"&~]==] }

-- Billy Joel - Piano Man
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Billy Joel - Piano Man", bpm = 120, tpb = 384, data = [==[k%Ym"%>~A~E~H~k+"Qdd""Tdh""Xd`""^dS$"ZdS$"YdO$"XdN$"WdO$"VdP'"TzRE%A~D~G~J~P'"Qd`""Rdp""Sdh""Qdh""Rdg""Sde*/Y(j$"Odx""PdT#"QdO$"Odi%"Lni%"O|QE$0t<t^u&"cu|&$CdHdLdP'$CnHnLnP$#Yd`d{#"/u%$;t^pcpp&"Cd%#GdJdx##Yn`nN$$CnGnJnc$#Xd^dN$%-u9uYd`dO$#X|^|{#"Ed&#HdMd|&#EnHn%"Mn|&#+u7uP'&m#^"}&"Cn%#HnLn|&#)u5w%#O{T{|&%AdE"C+Q'%AnE$e$C'"4v|&#CdHd%"Ld|&%"N%U"jSd&"Vd{##TdXdO$$2wSyVyO'$B"h"f"|&#BjEj%"Hn}&#+t7uP'&CdGdJdTnXnP'&$i%CVnYn{&"0u&$<tXu^u{:a'#o#"a';c$%/u;uXj^jl&$$n"/%#VpYp|&,Y'+TdXdo#"Y'AVdYdb$#T{X{k#"Ed%8Y'#Y'4Y'!T(h#C|&")u%$5uQvTv|&$Ed$Z"U*$EnHnMnT'%+u7uVnYn|&"Ed%%HdMdTpXp|&#EjHj&"Mdu&"0t(#<pCr%$HdLjOj%#OtTd%"Tvt&"HjO$"LjN$"O{{#"Tom#"<u+%<uEuHjMn%"Qn&"Tvs&"Hj_$"Mjo#"Qda$"Tqe#"0v+%<uGuHjOt%"Sn%"Tut&"Hpb$"Omo#"Sjb$"Tdx#"Aj(%<jEjHjMj&"Tju&"@n(%<d$e&z"%"Tdq&">n,%<dAdJdTdu&"<u(#<rCt%#HjLn&"On%"Tn*Q%$b1;{#"Tdw#"Hu-%<t&Q%+#QnTnx&I'MdO$$c2"I=<v)%<rGrHjOn%#S&I!p"p"+O$"SjN(}$9n($<nEjHj%#Mj(}$'$<dC0{$K-%<jAdJjTjh&"<v,#0t<tx(u-f"T'$CpHnLpq&"Gv("/u%";t_'#CdGd%"Jdl(l-=y&"Ev(#-t9t|&#E"k1$N,ApHnMny&"Cv(#+u7tO(`-O"|&#CpHp%"LnR'"Av(#)t5tU'*j3!P,j3=x&"@v)#(r4p|&"C"o5#Ld*i1Y$x&">v)#&r2rP'#LdQd|&"Lj%"Qdo#"JdS$"7n)#+t7t%"Vjk#"QdW$"9n)#JnOnx&";n{&"<r."o&*x9+v&"<j+&s&7w&";r*#/t;t{,s9+t&";d)"R8"f3?#":jc$"9v)#-u9ts({1#Q'&{1+p&"7r-"Z3*^#+w&"7j*&a3AW$"6do#"5r)#)u5u{(f"Ey&"5n($EpHpMnY'"7r("o%!l"h3"g5;U'"7n,$EnHpMpu&`+!u.n%!Q(m5Kt&"4d-#0u<us#"5dN$"7d**c;^"b#"9dc$":d*%CjHjLjXd%"^dq#";d+"f91i#"<v+$0u(t@#T'"U'$j+$w'(v@Gt#";r,$/u;t^n%"cn|&%$k:7Yp%"`pm&";n0&P.#|#"{@5t#"9v,"-u%$$QA1{##X{^{O$&O'!P2h(!2"h(*t,5n$"@dT#"4n-,a&%5v,"h(-&#OvTvx,z'.d<?p&"7v-$+t7uVd%"Y"NA%pXp*m#I|&"En%%HnMnSnVnp&"<r)"X>7%"0u%$<uO~T~*W)+t&"<d.&z#GL"Zds""<dO$"<t/#0u<|.qC/n&"@d0#C"Q$KLnl#"CdO$$<rTzYz0"0tP'&{#Am&"<d0"En&#HnMnk#&w"#r1"a+*HCo#"_dN$#<dYn&"`n-$$T<7l&"<v%#Xv^v2"t15c""^dh""cdh$*&X%)%"cdd*<-g""^dV"$cGS"ncdP'";u)"Vv%"Yv)#/u;tc""b$g"!d&*/Cd%$GdJd,2%^dO(yKAp#";dO$#9vTv&"Xv*"Z3!&(l##O$"q#!%$j%&f$+g""cde&^$P#Ep%$HpMncdm&"7n%"Xd&"^d'"+u%"7t&"Vdi&"<n%#VnYn,&s%#N$"z01#@nTd%"Xd"T7W"pLpw#"bdu#"Av%#QuTu/#)u5t*"c$|S"!d*c'#g""w<+&#Mdcd"O(!i.O(!%$s/%cdi"s'I%$@vTvXv2#(u4th""jde%"W'?HdLdgdd""jdh""gd"<'h"#C"hA#Lj&<j"U%">r%#VpZp0#&n2n%"ed{#"cdN$$LdQdbdm$Y3#3""f5d$>n&#Zd`d2#LjQd%"bd{##Jdcdj#"Cr)#^dbd*"+t%$7tQjVj%"edw##Odbd^#"`j&"cj-"Jp&"^jb$"w"^"#;jbd&"ed2"bd|#"cdm#"<v-#cvgv'"z7&y&#l"(z*%l"%$U)&Y',R(#h"&g8?%"cdl&";v%#bueu."y-/-"jdY""e(O'"*&w8*0-"jdd""e"X#"P.;jdj&"9r&"`v%"c$O.!u&w*!l*Z1!l6T.!l$T."*+S""9j3*y*"43t$$7n^ucu3"z9/)"jdS$"l"m&#n3$X6?#Ldjj{#"gjm#"@n3&t2EhdO$"jdm##ArYu%"`u."k:&{30Z$-d""Ed&$$_$"<"T.?l""ldN""Ad4"En%$&a$?#"AdO$#Crbu%"eu0"c$+%"hj|&&w%/gji&"Cn9&W>O"%"ejd&"<r%"^z%"cz-"0u%"<"Q$"X1"e#"O7"O).p*,X8+R""<d4*p7"N",w1?>"<r4"0r%#<pcd`'$r0A"Ljh&";d5$/j;dCj&"OJAT&"9n5#-t9vh&"Ln5&h@%Ld}$oZ"ALnO'"7j6"7vT&"Lj6*pO"#"C"V=CLnv&"6j6"6vX&"Jn7%$tc"+Ldc'$B"OX"d"%"Ljf&$5jVnYn7"5vg&"Hj)#`ncn/"Ad%"Y>CLdg&"Gj)#^nbn.#AjE&eg"Eg&$9n`xcx6"9v_&"Ln6&Q"!_$vE7Ljg&"7n6"7wk0m$(PKCjf&"6n;"6vf&"Jj7"B*i#'p&%B$bS"S"jv&$6nVnZn7"2vf&"4n)#Xn^n3*m%=S&"6j-"Zn%"`n+%$y%ALnk&$7v^}b}6"7w_'&Wg""c'$mQ"=h&"Av6"5v%#SvVv"bF%GdJ"th"5pGpJnk&"@v%&R3%/$4"c;!{0Pl"&WG+k&">r&"m5-0$2uVuY$}g"!J$TJ-CjJj%"M$b^"!5"OQ"!Q(_Y""c#$d('";v:"N7*P$"l'"W6)&"9v7"}5$mh""UL&m,/Mni&"7n8"f1"}A!7&P#+f&"@n<&lA+e&"Av8"W4*uH#P'$YU"-pe&"@r="Z@*^O"-h&"@j9$$fS"+i&">r9"g?=|&"Ld%"Qdd&">n9$-P#j{#"Jdg#"Cn8$+t7tQj&"Vj{##OdSdg#"7n:#JdOdb&";n?(+%<r;&c4!}(m#)e&"<j"N%?nLnN&";r<"/u&";u&jd"Q"&"Jd`&";n=#CnGn%"Jn`&"9r>"b'*x%I_&"9j?"Ep%#HpMn^&"7r?4Tq"+b&"7j@&P++Z&"5vD"b'!p,Wf"!W(rU"!b&c"'t7t{,k)-_&"7n>"$g2/Mn`&"<v>"qP".Og"%"Cp$V3/_&"<n>"0"zm"+_&"8d=(P$%#"9"OZ"#j=&o^"$gKMW$#VdYd^#"<vA%0u<uXu^u}4^/0i^"=a#";v>%/u;tXr^r&kh"1GdJd{&#Cp$q'"xo")b#"9v"v'#tO$Nx"!N(iX"!Q&x,-n|%"7t>"w'!c(l%+d&"<j>$Y.9nc&"Av=%)u5uO"Tx"2Um""{'5d&"Cr=$+p7r$}Z"!|6}Z"+_&"CnA"_BASn&"VnY&"<v=#<uCu"^t"$dx"U"vy&"Hjo#"Ljb$"OwP$"ToY#"HuD(`x"1j%"Qj%"Tt"Wu"Q"N$"MjP$"Qda#"Cd?"Td`#"<v?(dx"-n&#SnTj"bt")N$"Oj"bt"#P$$I+An?$<p,bt"G_&"@n?$CdLdTjZ&">nD$$Wx"n"y%"<vA$<uCuHj&#LnOn)"TjT'"HjP$"LjP$"Od"`v"+V#"HuG,Y|"##Q&w#.Ux"=Z#"CdC"TdZ#"<vC*w$)%"Sn)&Sz"-p|#"OjN*y$+Y#"AnD2^x"1V&"@jD%<j"r*%j%""3!>"3$`x"+W&"<vD$y4,On"*}:+Z&";vD"}:.lr"#p&*o4+^&"9vF"v-!U(o4#|&$k41nMpW&"7rC&W_"*R#+^&"<dC&O;?Z#">d{#"AvG#)v5u*{T#*}s"1Z&"@vD"4t"w0*yH$w25Y&">pE#&p2p&ex"+U&">dI"{X"=X#"@dD"JdU#"CnD.sX"&P;+Y#"EnD"u:+Y&"GjE"++V&"<vJ&Tt"<`4+X&";vF"T'"Q7$}D*R'!T*R'>o?+T&"7nF&P'+U&"<nE*T#+T&"@jF&v:+X&"AtF"v:!t(Q'!X(Q'5W#"5dO$"7vF"xb#!O(^#!}"np""s:;T&"0r%"T|%"X{p(V6+X&"0dG&e%5U#"0d{#"0pL&QN#*u(+Q&"4dI&R$=T#"7dO$$0uTyYyI"m<.e=*V7+V&"0rH"?+V&"^nG&_$/S&"0d%"Y"_L!C&Qp"!V(s#!v$Ov"!B$x=<Xp"4jV"({_")^dU"%$nQ#"|Y"I^du""cdR#"/v%"Sv&"VvA"_*3&"ed`""bdi&Oc"!b"ni"1dGd%#Jded"Sq"0<7"Cn%$GnJnede*<3S#$-vQvTvI"m1(j$!h(t$&s^"!h$wf"!i*:%l"%$X,%hde"05$"+r%#TuXuH&kc"'gdw#$q"%ejY(iu"7^$"gjQ#"0dL%$|29hdQ#"4dL"jd}""fR")QvTvL&lc"%hd`*Y$&f'&f)#%"&^$4x$&^$"L,x$G;$4vOuTuK#(u4u%"gdv#$ip""c",Uq""2!d&Uq"'cdg"&Y5)&"gdc&w";gdw""2n*#QvVvI"sO"!)(Zq""Z&)="4nI"Q6CO$"gdP#"5nL$LjQdhj"Rq"/Md%"jjQ#"x`#)OnSn@.c6a#)"lds#$OdSdndU#$9nQnTnH"Jd%"cj{#"jdU#$;nSdVdG"ldP$"ndQ$y.)TvXvG"T0'Q""j$Tq"!x$No"*Ul""n$"co""j%!j"f/"_3&:+n$$/uS"x%//u;uh""n*Sq"%ndd,SN#,2%jdi$F$t8%#Jn&<;9"/dN$#-vQv%"T&U9)*"ld`&T*"Vn"!h,q."Yq"8:"c+'ldP&*l.&T:#u%$f%9gdk#"hjl""Cd)"Y75S$"jdS#"0dJ&_l"IldS#"4dJ"ndS#$5rQvTvJHZq"!g6jt"(q.-ld="5nI$j^#%#Mn"Uy"/ldo$$7rO"m3-+t7u%"e,Uq"9cjs#"Xd_#"7jN"rO#+pMnnjP"W<"NR"!F"m*!)$|#!j*o.$R*,k8"h(&*!g,tW#"0"Qq""a"7<"0rN"$0r<pc"`B$sV"O"&"/dJ%/j;jCjGj%"JdQ&"-nJ"i7+P&"@pN$P4"hC$}p"+S&"+nJ"nr#+U&"@nI0Oq"$pY"EQ&"*nI"*t%"6tR&">pH&zS$)%"Ldo*hm"O"ne&")n*#TnYn?#)t5uR&"<j*"Wq"'?"Ad$cC"nm"7;j%"^n%"bn?$$_t##%""S$5-n%"`u*"cu:"nv#+X&"@nF&Y"!}(jg#/LnT&"+nF"Q%!X&yE4in#KS&"*nG"*v%"6uS&">rG#Bd(ov"!|,O%CW&$*jZn`nG"2wS&"(d$jq"!>.lr"7T&"*d*#Zn`n=$_Y$"Y'7U&"+v%#^pbpB"Q$"Of"6pq"At%#5vOu%"SuC#)u5j"}_"(rq""on";S&"4v%"Qv&"TvA"N<!p,OM!X(o%?X&"2r%#StVtB#&t2$kH!&"t5"nG%CjG&tq"'S&"0$k8$Z$4rb$-pR&"/tH&XO$*{^$!c&V$7pU#"/dO$"-vH"p-*Sc"$m-"md")V&"+n"^C-tV&"0jG&Y#+S&"4jG*q-+T&"5uG"ce#*ON"*`s#?s""5db$"4vF"(u&".Vr"#P'&S1)X&"2v$OU"!}&`O$9jz#"JjZ)"7rF%$uq"#Vj(OV$"vQ#'+dN$$_%#0v"s4#tp(|"!c(lZ"+T&"/uJFlw"!V*q&!G&q&2yu#7pHp&"MpR&"+r$s&*{(+R&"0nL,_//5rH")t%".QO$+V&"5jH"i"=%"MpS&"7pH#+r7v*kp"+S&"7jG*Tu#1S&"0uG#0{.Z+"ZX"$?/t%"0rG"<,bm"%P'&(}p"AXdz#"Vd&"YdR#"0vK"ng#+Xu%"^u*V^$!Q(V^$!O$}p"+U#"/uH$Rk$(}p"$Od"*Nk$*V-!u"V-!u8{p""Yd"A&#HpMpQ#"-dO$"+vH&TB*bz"*pm$-Q&")tN"*Qq"!{>Qq"'T#")"k"9tI%+r7rVdYdN$"Tq""xs$$Y*+R&"+jG"/Y"MdSj%"VjO&"0u*"T{%"X{:$0u<vCv"W`$$eq"-xh&"Hjb(qg$/x|#"LdU#&k(7%$CuHdLj&"Tw"im"x"N$"LdV#"4dG"OmV#"7dH"HdT#"0u-#TxYx<%<rArErH"W5!&$sr"+dp&"Hd,yn"'N$"H$Y#?H%<vAuEuHd%$MdQd$K5jd##Yd_dD"M"G#d%"wy$%H"Q$^k$;U#"0v%"Tu%"Xu@"g1!)s"eh##h"$d)Ep%"cdv%"/v&"Su%"Vu?$NS##t-(r_"!g.S_"(qv$#"e*YO$&<"QG$p_")X&#-v$|n#!C"h3#%"&e^""VN"(*!E"hW"#Md*SY"(jY"#i"&P:?%"hdP&#+nXp%"^pG"g4%%"g$^W"+R#"0jK&}%%edR$v|$+K"gdN#"ge#'VdYd(nk"+%"hd|"$pP%5""jdN#"5v&"$o$1B")u&"5t%R"lR"(i`"&*!U(uO$%ldb$tA-Xv&"^vF"g`#!&$}M%gde&{W"!g0vW"&XS"&lN""O`"&PV#;jdQ&#2rVp%"ZpI"_=r"*"idw#"jd{#"Lj&#Qjldo"#Xj^jN"#JjidZ#"2j%"rFCK"Hd)"jdw#"ldN#"7r(XK!G&^b#A%"Vj*"jds##Odld}""eL+O"#Jdn$zx#S"N#$+dbdedO""ldz""-dR""nd{""{.$T9!F&S|"(jT$"y.P"VS".x_")Q&#/u${_$"u_"+t)"nda*U_"&l"*s.%nd`.t_""wT"&s:+&"ndz""w:'#-tT"l)!K&z.%lde&qg""l*"y(.V+"QX$!l$R*!c*``$!p&_&"o;(W&(mm""k('gdO$&O&&nO$#N$*s_""bf"#x""S.!T"|%!L"fT"&||#&s_"!U$o#"u<!*"W`$"vO$,bS$*Nc"=cd}"")dN$#+rVv&"s"1+r7v&"jjx"u@"Pm"/jnx%"+jQ"qs""iK`"%"hju%#0uT{*"X{H#0|<t*"jdf#"jdx$T/&c%%jdg.ga$$X'!C"tR$%Lnj*W(&r030"0tV"#<uj"dC*jD"j07x%"-nV"$-t9r"cp#?Td{""@rQ""Vdh""W$Rl%`"P'"^d|""+nQ"$+u7t`dO$"cj|""@rn$$_a$b"Xj}%"*nR"#*t6t%"Znx%">tR"#ZdedP'"';x%"AnS"")r%#5r"_o"1^jz""<nS"$Rn%1Tdy"";nS"(RX%r"z""-nS"$-u9uTj{#"Vjy""@rX""Wd{#"XdO$#^dc$eo%-x""+nT""Tc%Q"_d`d&"cnf#"^da#"@tS""Xd{#*Xp%"_Y%r"""*nT""*u%$6uTdZd{#"Qdy"">rT"#TdZdP'#TjZ$Qh#-l""AjU"(}e%?jTj%"Yjx%"<nV""T"|L"d"Ew"";nV"#TdYdw%"-nW"&gn#E"Qdr""@rZ""Tdk#"Vdc&gs%/Xdv""+nW"{(Mu^j%"cds%"@rW"#^jcnO$"`"v'*Mt$*jW""*t%$6tTnZjb%">tX"#QdXjc'"Vdw%"2pY"%&t2tMnQn%#TnXjh&#MdVjU&"2jY"#QdTdv%"7vY"#+v7ul,|O"O"_'#CpGp%"Jpp%"5v*#^vbvQ"&jN%)SvVvl(gQ%`"Mdc'%CpGnJpMnp%"4t*#`vcvU"$(u4u"kv$#uh8QY"%ps%"gc"AbvevW"$&u2uVt%"Yt"J$i9'Md_'.nc")o%#0v$R9#W""fJ!Y,SR"'"Lp1"Oc%IS&#/vSv%"VvK";u*"/uh&*Ve%v"p&#GnJp%"Cne&"-v%#TvYv="9u)"-u`&"Hd)#EdMdT(rw#3l&$+nTvXvE&qT"e#Q&"0n=#CdLd)"HdY&"4j=#HpLp)"Cpy%"5w%#TwYwQ"")u)"5tP'"Hd%"z"=Q'"Mp%#EpHnt%#4&{|$3I"4t)"(ux&"I!C0y5Q"|%$2rVpZpE#&n2px&"Lj*"QjS$Tw$5N""JdO#$4dZ"d|%"Q`%7$7v^nbnC"+r-"TE"xD/dP#"Sjv#"rDS"A"Odc$"Jdz"#bded|&$0vXu^uC&YV$"ib$$UW%"y%A%"CpO&"/v%#Vv^vS"*pk"'"Cd*"j-Y"s&#CnJp&"GpV&$-v`vcv;"-u*"9ux$lO&5%"EdP'"Ep%"$Sf"5Q&$+n^vcvQ""oAW"}%"0nJ"Cd%"Hd*"Lds%"4nH"Cn%"$Wd"1R&$5vYu`u$xV$!Q,r(#P'*|_%Ex%"7p&#Yv`vR""+t)"7,|m#9{%"7nO""Mn%"E"{"5v%$0zX{^{Q""xf"&x"!C0se%)|&"<w*dg"7h&"Hp-#CnLnE"TS"!{"q6?""0vu""<t&#Xu^us:sf"!N$sf"-c""/vm""`g%-Xr%"^rx,O0%}&%"}i$!p$ST$+_%"-vn(_9Jxf"+_%"+vn"X(,Tk"*rf"9_%")ts"$)t5uO"gZ#!x(N'*Vs"#a"&rf"%vo""fQ"2|V$.uf"*b{#9%#SnVnY%"0vr"(QS$-"Ln%"On$QW$(SV$-Ld{#"Oy"QW$-Z""<ur""mf")EvHdM"WU""Uj%$RW$$_e"5_""7dr""ThW$l(&ZS$"mh"%nTj"ce"!W*aO&"`D/_""5nq"%$YS$!M"vR$-Y%"4nq"&k}%1&"TdT%"2n"|i%9%#AdJdV%"0vt"$Z^$'$HjL"gU$,eV$&U#5s#"Tdd""<ut&V%%uHd*`^$!d(jR&#Mj"X%5Y""7du""TdXBX%(tQ&$pW&$X%-Y""5nt"*uU&"QW$'%"4j"4'CjLd"0'2nx"(eW$*V%:dt$"V,-U%";vy"4vz"*sS#+Y%"9vu"b.$ft$,ag&&Vy"+T%"7tv6Z.+T%"9d{&pk"%nQ""SN$)"5vx"$zz"!t2gW$"|T"-U%"4vy""|U#6NU$7dHjLjU%"2pz""u<`"P'#LjQjO""4dN#"JdN""5d{""HdR""6"}R$%n|"$_R&)#QjVd"{_&-`""9n|"(XQ#'P"";$/-N%"0vQ#0sW$,`x")%"/v|(b'*_p#!O"Uk&"N5/OnR%"9v|$z4*uW$(z`$3pMpN%"7v|"8{`$*ib#-}$"5uQ#"aX&<s`$!?$wV#17vN##+r7r4eS#!C"rg&-Ln{$#0t$|y"1{"#0v<vP'2^c&=N""0dS#"VdJ"0vO"^v"Q"$<uOdXd|&"Ojo#"Tda"#TnXnO$lU"1"YdO""0r)"Vw"7Yur"%0v<vQdT"j7M%"`dt&"TdN$"YdQ""0d|""`**3cdP""0r&"T"zL!s$a"!Y"NW"%hd|&lT"!`"F+j}""cd"TS#!h"1/v*#^ncns"e0/u%#OdTd&"tG=%"cdY""^jj%#OdX"bP#u%dcj^#"^dB#Xd^j9"`dX""bdV""Od#"cd$"XdJ";v-"evw"%/v;uOdSd%#Vd^d&"ejs#"bjN$#Jd^dO$#OdejO$#JdbjO$%JdOdSd^dM"9v%"`"|V&#y""xr&$v<3QjTj*"hjs#$cO$!M"^'1|##QdhjO$&aO#l"%#YdcjF"fdS#"`dJ"7v)"gn{"%+v7uLdOj%#T"oZ&O"gjw#"cjJ"jtS##Ld^dk##Odg$|S#!&"_&'|#"O"m^&KD"5v-#hvlvz"")v%$5uMjQ"o"'Yj%""{x#Q"`jO$#MjYdO$#QdcjN$$MdTd`j"s+EE"4v)"gv%"jv}"%(n4n*T$$^_"1#"^jO$#Lj"gd"!O$e"'LdTd$7b"dXdI"2v%"ep%"ip|"%&n2pXd`d)"cjv#$c`"q#Xn%#Zd`j:"jjR##VjcjW""ldR#"Td%"`jG"ndR#"Qd%"ZdF"7r*"jtz"#+p7r&"g6!)(f*IO$$QjVd^jN$#SjejJ"7nS"j{%%j{#"t^%-^dF"0v*"hz"'cnv"&v^&%LdO"S(!X"zX$1w#"^j{##C$|-b"HdcjV#"YdG$JdOd^j4"^dX""`dU""bd,"H3J";v%"euN#"Se#"SL"O"'bng#"pm"'#JjV$j'.s-`"Vd%"^ny#"cd#"VdK"9v-#edhdv"%-v9$cQ%"g}$!*.o*)HjYdz$U.+cj{##Q"o*?#HdYdK"7v)#cugu{$Sf""`z#'j%#O"Pk""g""W*!H$q*+Ldcjk#"kR"+Oj^nb$"Wv"%XdF"t-)cnhn{"Xg#"_K$Q1))"cjo.P$'O$#M"Z,+#Qj`jP$N$!J"`^"9ev%"hv{"%+r7w&N$!n"e"5nr#"`j|#"Hj&gh&%Ld`"l*3R#"Gd%$LjO"TY'!e$^-EK"0z)"cz%"gzw"$0|<|$Sv%$u"*v%!P2v%/{#"Oj%"^"_#"ib%#{#"bP$)&$OdT$A*}&!N$T"7O$$HdOj^jO$%"VG1dXdE"-nW#"fH+x$"@tS(YS".qW$-n$"+nX#&yg"-y$"@tY#<Ts#Ev$"*nT##*u6uz$">rT#&uW$#Q'*oS$'u$")"sp"'YnQ#&fI+u$"<n*&Q:#{"*x}&+w$";j%"O{%#P#*SN'3{$$-n`vcvS$P%-w$"@tV#8r^$-|$"+nR#"dc$+|$"@rQ,|$*gQ#+i$"*nR$|$-_%">rR#*Zz%!P,N%Gx$"2n&#VnZnQ##&t2uy$*b{%#x".vW$+{$"6n%&e{%%w"$$e"?%"Lp|$"7v&#^tbty&dg"0rw#"sm%O"GpJp|$"5v%"^u*"buq"$)u5u$Vr"*bR".N"M}$"4v)#`ucuu""(u%$4uTvX$L0yd"-n|$"2t)"su"%z"%"su"#uY$XQ"$u}$!M"xd""qu"/MjO%"0v%"uP#!{"c9!"$Wr#!Z8^d#!&$Z#!O2Xs$"*)B"^dC"N-5&$LnOncd2"`$yq#+Y""cdM"Oo"%eu{"zP"-u%"nj}&&ll''Odcj*ll')OnejI(cT$-%#cdhdQ$Y,4{`#&_`#*ne"!Q(Pc&(y$$>"NW"'%#Qn&>5g#$+rcvgvQ#"O*"u%+t#"gd`*Zx&?#Odhj_$"jdK"0dR#$t1"fl%Q"%"ldC"4dS#"ndI#5v`n&"cnN#$mO#(_s$(Zb&P"yi&!d0Pw&9v$"4v%#^vcvP#"rZ")*"jd`4tb#*vl#:ac#.xq#/v$"2p%"Z"^u##P#"{q#O"%"idk#"jd^$$LjQjldI"4dT#"vq#Q"I"5dT##HdjdI"6dS#"ldJ"7n%"k0#O#"}S$)QjVj-$nq#;SjldF"+nV##Odn$vt&7jdK"-nR#"Jd%"WQ%5ld{#"ndJ#0v$WS"!O"r_"(sy$4Z."`):iq#-d""Cp&$$ba%#g$"Q|"+bueuO#"v-&bO$%nds&sN$!n,ns&*0(:.`O$1}$$9vcnhnP"Z.$PZ$"Xn#6P}$#h"$yh""}|$/y$$7ucng"e:"^O$"vy#1gdK#bnenR(o:%%"h$fz#3C"cj%"gdO#&`T$%)"l$xP%)E"5v&"wF!O$P.!*2Pa%8_d%(Q(.:"_d"&0!_"p{#+#evhvT$h1'&"hj*Py"5%"gju$"7jU#&X"7ejy$$0yc{g{U*e*$or#$Rp'*rg&#P'$Vt'+$"+dU#"Nj"5H"-d{#".dZ#&W{#$_X&->"/dW#"$zz"+B"0vW#$XR""fR("Qh'$f9#Q'&X"#On&ih$-9"/u`#$$ih$)%"^rP&}u'"pv%"{U($r8!D(p8!Z$Z+!N$tO#$W}""`Y$!Q&Yg'9p%#MpQnq$"+tZ$T'#O'*y##P'&iz#%On@$fr$1)rZ#")u&$(yh$&O(-t$")jZ#&s9+t$"+vZ"x2%tVd"}g"/Tp%"Xp{#*|i$!{&pX%EjSn%"Vnq$"0vY#%<uCv*PY&+j&"Tvl2ON#?vO$"ToC"<uZ##<uE"RZ&&sU"!s,ZU&"Pr#E>"7db#"Td>"0vb#%<vG(O#.ZV&&Po""VW&+C"5nZ#2TY&-l$"4ja#$UY&7dp$"2jZ#"<d&&ZY&-p$"0vZ#&WT#"hR"$hS(!j,hS(#{#(y}"$R%%"<v"{O#4jS(O"o#"Mdb$"QdC"7dZ#"Td?"0va"R%6wO#$SV#,RT#9D"5n&#QnYnS#&(|O#+Tjs$"4"V"'XnX#"kY&+LdTdr$"g`$3MnVnT#"<d%&g%d"r$#0}L}%"T}T#"0|a%"<{B"@{="C{1"Hz]==] }



-- Gabung lagu bawaan + lagu dari script ke-2 (_G.PianoSongs). Return true kalau daftar berubah.
local function mergeExternalSongs(): boolean
	local ext = _G.PianoSongs
	local byName, order = {}, {}
	if type(ext) == "table" then
		for _, s in ipairs(ext) do
			if type(s) == "table" and type(s.name) == "string" and (s.data or s.packed or s.notes) then
				if not byName[s.name] then table.insert(order, s.name) end
				byName[s.name] = s
			end
		end
	end
	local list = {}
	for _, n in ipairs(order) do table.insert(list, byName[n]) end
	for _, s in ipairs(BUILTIN_SONGS) do
		if not byName[s.name] then table.insert(list, s) end
	end
	local same = #list == #SONGS
	if same then
		for i, s in ipairs(list) do
			if SONGS[i] ~= s then same = false break end
		end
	end
	if same then return false end
	table.clear(SONGS)
	for i, s in ipairs(list) do SONGS[i] = s end
	return true
end
mergeExternalSongs()

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

-- Input ASLI lewat VirtualInputManager (sama seperti PianoAutoPlayer lama). Kalau environment menolak,
-- otomatis cuma efek visual (vimBroken = true).
--   "touch": tiap tuts punya jari (touch id) sendiri -> akor dan tuts tertahan bisa bareng, tidak saling tabrakan.
--   "mouse": cuma satu pointer, jadi satu tuts sekali (tuts sebelumnya dilepas dulu).
local okVIM, VIM = pcall(function() return game:GetService("VirtualInputManager") end)
if not okVIM then VIM = nil end
local vimBroken = false
local PRESS_COLOR = Color3.fromRGB(255, 70, 55)
local PIANO_MIN_PRESS = 0.035 -- minimal ditahan (~2 frame) biar tidak terlewat oleh script piano
local firesignalFn = rawget(getfenv(), "firesignal")
if type(firesignalFn) ~= "function" then
	firesignalFn = nil
end

local function keyScreenPos(key: GuiObject): (number, number)
	local pos, size = key.AbsolutePosition, key.AbsoluteSize
	local parent = key.Parent
	-- tuts hitam lebih pendek dari tuts putih: klik di tengah tuts hitam, tuts putih di bagian bawah
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

-- Efek tuts menyala (dihitung, supaya nada beruntun di tuts yang sama tidak bikin warna nyangkut)
local pressState = setmetatable({}, { __mode = "k" })
local function visualDown(key: GuiButton)
	local st = pressState[key]
	if not st then
		st = { n = 0, image = key:IsA("ImageButton") and key.ImageColor3 or nil, bg = key.BackgroundColor3, bgT = key.BackgroundTransparency }
		pressState[key] = st
	end
	st.n += 1
	if st.n == 1 then
		if key:IsA("ImageButton") then
			key.ImageColor3 = PRESS_COLOR
		else
			key.BackgroundTransparency = 0
			key.BackgroundColor3 = PRESS_COLOR
		end
	end
end
local function visualUp(key: GuiButton)
	local st = pressState[key]
	if not st then return end
	st.n -= 1
	if st.n <= 0 then
		pressState[key] = nil
		if key.Parent then
			if key:IsA("ImageButton") then
				key.ImageColor3 = st.image
			else
				key.BackgroundColor3 = st.bg
				key.BackgroundTransparency = st.bgT
			end
		end
	end
end

local engineDown = {}   -- [tuts] = { x, y, rel, touch }  tuts yang sedang ditekan
local enginePending = {} -- [tuts] = hold   tekan ulang (nada sama beruntun) setelah dilepas
local repressNext = {}  -- [tuts] = hold   dimulai di frame berikutnya (kasih jeda 1 frame)
local touchIds, nextTouchId, mouseKey = {}, 0, nil

local function touchIdFor(key: GuiButton): number
	local id = touchIds[key]
	if not id then
		nextTouchId += 1
		id = nextTouchId
		touchIds[key] = id
	end
	return id
end

local function inputBegin(key: GuiButton, hold: number, now: number): boolean
	local x, y = keyScreenPos(key)
	local touch = piano.input == "touch"
	local ok = pcall(function()
		if touch then
			VIM:SendTouchEvent(touchIdFor(key), 0, x, y)
		else
			VIM:SendMouseMoveEvent(x, y, game)
			VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
		end
	end)
	if not ok then
		vimBroken = true
		return false
	end
	engineDown[key] = { x = x, y = y, rel = now + hold, touch = touch }
	if not touch then mouseKey = key end
	visualDown(key)
	return true
end

local function inputEnd(key: GuiButton)
	local d = engineDown[key]
	if not d then return end
	engineDown[key] = nil
	if mouseKey == key then mouseKey = nil end
	pcall(function()
		if d.touch then
			VIM:SendTouchEvent(touchIdFor(key), 2, d.x, d.y)
		else
			VIM:SendMouseButtonEvent(d.x, d.y, 0, false, game, 0)
		end
	end)
	visualUp(key)
end

local function enginePress(key: GuiButton, hold: number): boolean
	if not VIM or vimBroken then return false end
	hold = math.max(hold, PIANO_MIN_PRESS)
	local now = os.clock()
	if mouseKey and mouseKey ~= key and piano.input ~= "touch" then
		inputEnd(mouseKey) -- satu pointer: lepas tuts sebelumnya
	end
	local d = engineDown[key]
	if d then
		-- tuts yang sama masih tertekan: lepas di tick berikutnya, lalu tekan ulang
		enginePending[key] = math.max(enginePending[key] or 0, hold)
		d.rel = now
		return true
	end
	return inputBegin(key, hold, now)
end

local function engineTick()
	if next(engineDown) == nil and next(repressNext) == nil then return end
	local now = os.clock()
	for key, hold in pairs(repressNext) do
		repressNext[key] = nil
		if key.Parent and not engineDown[key] then
			inputBegin(key, hold, now)
		end
	end
	for key, d in pairs(engineDown) do
		if now >= d.rel then
			inputEnd(key)
			local p = enginePending[key]
			if p then
				enginePending[key] = nil
				repressNext[key] = p
			end
		end
	end
end
game:GetService("RunService").Heartbeat:Connect(engineTick)

local function engineReleaseAll()
	for key in pairs(engineDown) do
		inputEnd(key)
	end
	table.clear(enginePending)
	table.clear(repressNext)
end

local function pressPianoKey(ui: Instance?, key: GuiButton, hold: number, async: boolean?)
	local event = ui and ui:FindFirstChild("KeyPress")
	if event and event:IsA("BindableEvent") then
		event:Fire(key, true)
		task.wait(hold)
		event:Fire(key, false)
		return
	end
	if enginePress(key, hold) then
		if not async then
			task.wait(math.max(hold, PIANO_MIN_PRESS))
		end
		return
	end
	-- Cadangan (input asli ditolak): efek visual + coba picu handler tuts kalau firesignal ada
	visualDown(key)
	if firesignalFn then
		pcall(firesignalFn, key.MouseButton1Down)
		pcall(firesignalFn, key.Activated)
		pcall(firesignalFn, key.MouseButton1Click)
	end
	local sound = key:FindFirstChildWhichIsA("Sound", true)
	if sound then
		sound.TimePosition = 0
		sound:Play()
	end
	task.wait(hold)
	if firesignalFn then
		pcall(firesignalFn, key.MouseButton1Up)
	end
	visualUp(key)
end

local pianoPage = new("ScrollingFrame", {
	Name = "PianoPage",
	Position = UDim2.fromOffset(8, PAGE_TOP),
	Size = UDim2.new(1, -16, 0, CONTENT_HEIGHT),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 2,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = P.Accent,
	ScrollingDirection = Enum.ScrollingDirection.Y,
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
	Text = "Sapu tuts (kiri - kanan)",
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

local pianoStartRefs = glossyButton(pianoCard, UDim2.new(1, 0, 0, 40), THEMES.Green, "START", 18, { LayoutOrder = 10 })
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
	LayoutOrder = 11,
	Parent = pianoCard,
})

local inputRefs = glossyButton(pianoCard, UDim2.new(1, 0, 0, 32), THEMES.Off, "", 14, { LayoutOrder = 9 })
local function refreshInput()
	inputRefs.label.Text = piano.input == "touch" and "Input: Sentuh (multi-touch, bisa akor)" or "Input: Mouse (satu tuts sekali)"
end
refreshInput()
inputRefs.button.Activated:Connect(function()
	piano.input = piano.input == "touch" and "mouse" or "touch"
	refreshInput()
end)

local function refreshPianoStart()
	pianoStartRefs.label.Text = piano.running and "STOP" or "START"
	setTheme(pianoStartRefs, piano.running and THEMES.Red or THEMES.Green)
end

local function pianoStop(message: string?)
	piano.running = false
	piano.runId += 1
	engineReleaseAll()
	refreshPianoStart()
	if message then
		pianoStatus.Text = message
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
local function decodePacked(name: string, data: string?)
	local key = data or name
	if packedCache[key] then return packedCache[key] end
	local z = data or PACKED[name]
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
	packedCache[key] = events
	return events
end

local function pianoPlay()
	songPauseRef()
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

for i, refs in ipairs(pianoModeRefs) do
	refs.button.Activated:Connect(function()
		piano.mode = i
		refreshPianoModes()
		if piano.running then
			pianoPlay() -- mulai ulang dengan mode baru
		end
	end)
end
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

---------------------------------------------------------------------
-- KOLOM LAGU: daftar ke bawah, mode Biasa/Tahan, kecepatan, bar putar
---------------------------------------------------------------------
local sp = { song = 1, tap = true, speed = 1, playing = false, pos = 0, runId = 0, seek = false }
local SPEEDS = { { name = "Pelan", value = 0.75 }, { name = "Normal", value = 1 }, { name = "Cepat", value = 1.5 } }
local TAP_HOLD = 0.045 -- mode Biasa: tiap tuts cuma ditekan sebentar
local songDataCache = {}

-- Ubah lagu jadi event dalam DETIK: { t, keys = {nomor tuts}, durs = {detik} }
local function songData(i: number)
	local c = songDataCache[i]
	if c then return c end
	local s = SONGS[i]
	if not s then return nil end
	local events, total = {}, 0
	if s.packed or s.data then
		local raw = decodePacked(s.packed or s.name, s.data)
		if raw then
			local spt = 60 / (math.max(s.bpm or 120, 1) * (s.tpb or 384))
			for n, e in ipairs(raw) do
				local durs, longest = table.create(#e.durs), 0
				for k, d in ipairs(e.durs) do
					durs[k] = d * spt
					longest = math.max(longest, durs[k])
				end
				events[n] = { t = e.t * spt, keys = e.keys, durs = durs }
				total = math.max(total, e.t * spt + longest)
			end
		end
	else
		local spb = 60 / math.max(s.bpm or 120, 1)
		for n, e in ipairs((parseSong(s.notes or ""))) do
			local d = e.dur * spb
			events[n] = { t = e.t * spb, keys = e.keys, durs = table.create(#e.keys, d) }
			total = math.max(total, e.t * spb + d)
		end
	end
	c = { events = events, total = total }
	songDataCache[i] = c
	return c
end

local function fmtTime(s: number): string
	s = math.max(0, math.floor(s))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function firstIndex(events, t: number): number
	local lo, hi = 1, #events + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if events[mid].t < t then lo = mid + 1 else hi = mid end
	end
	return lo
end

local songCard = new("Frame", {
	Name = "SongCard",
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = P.Card,
	LayoutOrder = 2,
	Parent = pianoPage,
})
corner(songCard, 10)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10),
	PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = songCard,
})
new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = songCard })
new("TextLabel", {
	Text = "Lagu", Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
	Font = FONT, TextSize = 20, TextColor3 = WHITE, LayoutOrder = 1, Parent = songCard,
})

-- Daftar lagu (ke bawah)
local songList = new("ScrollingFrame", {
	Size = UDim2.new(1, 0, 0, 150),
	BackgroundColor3 = P.Input,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = P.Accent,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	LayoutOrder = 2,
	Parent = songCard,
})
corner(songList, 8)
new("UIPadding", {
	PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
	PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4),
	Parent = songList,
})
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = songList })
local songRows = {}
local selectSongRef = function(_: number) end -- diisi di bawah
local function buildSongRows()
	for _, refs in ipairs(songRows) do refs.button:Destroy() end
	table.clear(songRows)
	for i, s in ipairs(SONGS) do
		local refs = glossyButton(songList, UDim2.new(1, -8, 0, 34), THEMES.Off, s.name, 14, { LayoutOrder = i })
		refs.label.TextXAlignment = Enum.TextXAlignment.Left
		new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = refs.label })
		local d = songData(i)
		new("TextLabel", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = FONT_REGULAR, TextSize = 13,
			TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right, Text = d and fmtTime(d.total) or "",
			Parent = refs.label,
		})
		refs.button.Activated:Connect(function() selectSongRef(i) end)
		songRows[i] = refs
	end
end
buildSongRows()

local function caption(text: string, order: number)
	new("TextLabel", {
		Text = text, Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
		Font = FONT_REGULAR, TextSize = 13, TextColor3 = P.Muted, LayoutOrder = order, Parent = songCard,
	})
end
local function optionRow(order: number, labels: { string })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, LayoutOrder = order, Parent = songCard })
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = row,
	})
	local n, list = #labels, {}
	for i, text in ipairs(labels) do
		list[i] = glossyButton(row, UDim2.new(1 / n, -math.ceil(6 * (n - 1) / n), 1, 0), THEMES.Off, text, 14, { LayoutOrder = i })
	end
	return list
end
caption("Cara menekan", 3)
local tapRefs = optionRow(4, { "Biasa", "Tahan" })
caption("Kecepatan", 5)
local speedRefs = optionRow(6, { SPEEDS[1].name, SPEEDS[2].name, SPEEDS[3].name })

-- Bar putar
local barRow = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 7, Parent = songCard })
local timeNow = new("TextLabel", {
	Size = UDim2.fromOffset(40, 26), BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR, TextSize = 13, TextColor3 = WHITE, Text = "0:00", Parent = barRow,
})
local timeTotal = new("TextLabel", {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(40, 26),
	BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right,
	Font = FONT_REGULAR, TextSize = 13, TextColor3 = WHITE, Text = "0:00", Parent = barRow,
})
local barHit = new("Frame", {
	Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -88, 1, 0), BackgroundTransparency = 1, Active = true, Parent = barRow,
})
local barTrack = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 8),
	BackgroundColor3 = P.Input, BorderSizePixel = 0, Parent = barHit,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = barTrack })
local barFill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, Parent = barTrack })
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = barFill })
new("UIGradient", { Color = P.Primary, Rotation = 0, Parent = barFill })
local barKnob = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(16, 16),
	BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, Parent = barTrack,
})
new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = barKnob })
stroke(barKnob, P.Stroke, 2)

local function refreshBar()
	local d = songData(sp.song)
	local total = d and d.total or 0
	local a = total > 0 and math.clamp(sp.pos / total, 0, 1) or 0
	barFill.Size = UDim2.fromScale(a, 1)
	barKnob.Position = UDim2.fromScale(a, 0.5)
	timeNow.Text = fmtTime(sp.pos)
	timeTotal.Text = fmtTime(total)
end

-- Tombol putar
local transport = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 8, Parent = songCard })
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder, Parent = transport,
})
local backRefs = glossyButton(transport, UDim2.new(0.2, -4, 1, 0), THEMES.Off, "-10s", 14, { LayoutOrder = 1 })
local playRefs = glossyButton(transport, UDim2.new(0.4, -4, 1, 0), THEMES.Green, "PLAY", 18, { LayoutOrder = 2 })
local stopRefs = glossyButton(transport, UDim2.new(0.2, -4, 1, 0), THEMES.Off, "STOP", 14, { LayoutOrder = 3 })
local fwdRefs = glossyButton(transport, UDim2.new(0.2, -4, 1, 0), THEMES.Off, "+10s", 14, { LayoutOrder = 4 })
local songStatus = new("TextLabel", {
	Text = "Pilih lagu lalu tekan PLAY. P / Spasi = jeda.",
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
	TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT_REGULAR, TextSize = 13, TextColor3 = P.Muted, LayoutOrder = 9, Parent = songCard,
})

local function refreshSongUI()
	for i, refs in ipairs(songRows) do
		setTheme(refs, i == sp.song and THEMES.Green or THEMES.Off)
	end
	setTheme(tapRefs[1], sp.tap and THEMES.Green or THEMES.Off)
	setTheme(tapRefs[2], (not sp.tap) and THEMES.Green or THEMES.Off)
	for i, refs in ipairs(speedRefs) do
		setTheme(refs, SPEEDS[i].value == sp.speed and THEMES.Green or THEMES.Off)
	end
	playRefs.label.Text = sp.playing and "PAUSE" or "PLAY"
	setTheme(playRefs, sp.playing and THEMES.Red or THEMES.Green)
	refreshBar()
end

local function songPause(message: string?)
	sp.playing = false
	sp.runId += 1
	engineReleaseAll()
	refreshSongUI()
	if message then songStatus.Text = message end
end
songPauseRef = function()
	if sp.playing then songPause("Dijeda.") end
end

local function songPlay()
	local data = songData(sp.song)
	if not data or #data.events == 0 then
		songStatus.Text = "Lagu ini belum ada notenya."
		return
	end
	pianoStop(nil) -- hentikan mode sapu tuts kalau lagi jalan
	if sp.pos >= data.total - 0.05 then sp.pos = 0 end
	sp.runId += 1
	local id = sp.runId
	sp.playing = true
	refreshSongUI()
	task.spawn(function()
		local keys, ui = getPianoKeys()
		if not keys or #keys == 0 then
			if id == sp.runId then
				songPause("PianoUI belum ada. Tuts dicari di PlayerGui.PianoUI.PianoContainer.KeyFrame.")
			end
			return
		end
		local byName = {}
		for _, k in ipairs(keys) do byName[tonumber(k.Name)] = k end
		local events = data.events
		local idx = firstIndex(events, sp.pos)
		local last, lastStatus = os.clock(), 0
		while id == sp.runId do
			local now = os.clock()
			sp.pos += (now - last) * sp.speed
			last = now
			if sp.seek then
				sp.seek = false
				idx = firstIndex(events, sp.pos)
				engineReleaseAll()
			end
			while idx <= #events and events[idx].t <= sp.pos do
				local ev = events[idx]
				for i, kn in ipairs(ev.keys) do
					local key = byName[kn]
					if key and key.Parent then
						local hold = sp.tap and TAP_HOLD or math.max(PIANO_MIN_PRESS, ev.durs[i] / sp.speed * 0.95)
						task.spawn(pressPianoKey, ui, key, hold, true)
					end
				end
				idx += 1
			end
			refreshBar()
			if now - lastStatus > 0.5 then
				lastStatus = now
				songStatus.Text = string.format("Memutar: %s%s", SONGS[sp.song].name, vimBroken and "  [klik asli ditolak, cuma efek visual]" or "")
			end
			if sp.pos >= data.total then break end
			task.wait()
		end
		if id == sp.runId then
			task.wait(0.5)
			if id == sp.runId then
				sp.pos = data.total
				songPause("Selesai.")
			end
		end
	end)
end

local function selectSong(i: number)
	local wasPlaying = sp.playing
	songPause(nil)
	sp.song = i
	sp.pos = 0
	refreshSongUI()
	songStatus.Text = SONGS[i].name
	if wasPlaying then songPlay() end
end

local function seekTo(seconds: number)
	local d = songData(sp.song)
	if not d then return end
	sp.pos = math.clamp(seconds, 0, d.total)
	sp.seek = true
	refreshBar()
end

selectSongRef = selectSong
tapRefs[1].button.Activated:Connect(function() sp.tap = true; refreshSongUI() end)
tapRefs[2].button.Activated:Connect(function() sp.tap = false; refreshSongUI() end)
for i, refs in ipairs(speedRefs) do
	refs.button.Activated:Connect(function() sp.speed = SPEEDS[i].value; refreshSongUI() end)
end
playRefs.button.Activated:Connect(function()
	if sp.playing then songPause("Dijeda.") else songPlay() end
end)
stopRefs.button.Activated:Connect(function()
	songPause("Berhenti.")
	sp.pos = 0
	refreshBar()
end)
backRefs.button.Activated:Connect(function() seekTo(sp.pos - 10) end)
fwdRefs.button.Activated:Connect(function() seekTo(sp.pos + 10) end)

do
	local seeking = false
	local function seekX(x: number)
		local d = songData(sp.song)
		if not d or d.total <= 0 then return end
		seekTo(math.clamp((x - barTrack.AbsolutePosition.X) / math.max(barTrack.AbsoluteSize.X, 1), 0, 1) * d.total)
	end
	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	barHit.InputBegan:Connect(function(input)
		if isPointer(input) then
			seeking = true
			seekX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if seeking and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			seekX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then
			seeking = false
		end
	end)
end
-- jeda darurat: P atau Spasi
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not sp.playing then return end
	if input.KeyCode == Enum.KeyCode.P or input.KeyCode == Enum.KeyCode.Space then
		songPause("Dijeda (" .. (input.KeyCode == Enum.KeyCode.P and "P" or "Spasi") .. ").")
	end
end)
table.insert(themeListeners, refreshSongUI)

-- Dipanggil script ke-2 (LAGU TAMBAHAN) setelah menambah lagu ke _G.PianoSongs
local function reloadSongs()
	local cur = SONGS[sp.song]
	if not mergeExternalSongs() then return end
	songPause(nil)
	table.clear(songDataCache)
	local idx = 1
	for i, s in ipairs(SONGS) do
		if s == cur or (cur and s.name == cur.name) then idx = i break end
	end
	if SONGS[idx] ~= cur then sp.pos = 0 end
	sp.song = idx
	buildSongRows()
	refreshSongUI()
end
_G.PianoSongsRefresh = reloadSongs
refreshSongUI()

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
