--[[
	Player Utility Panel (LocalScript)
	Letak: StarterPlayer > StarterPlayerScripts
	Fitur: Fly, Swim, Speed, Super Jump, Noclip, Freecam, Hide GUI, Teleport ke player lain,
	Mini Studio (Explorer / Properties / Select, semua di client)
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
local KEEP_VISIBLE_GUIS = { PlayerUtilityPanel = true, MiniStudio = true, MiniStudioUiPick = true, TouchGui = true }

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
		selectUI = false,
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
		Size = UDim2.fromOffset(418, 40),
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
			local on = if name == "Select" then state.selectMode elseif name == "SelectUI" then state.selectUI else state.windows[name]
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

	-----------------------------------------------------------------
	-- SELECT UI: klik elemen GUI di layar (PlayerGui) -> Explorer + Properties ikut
	-----------------------------------------------------------------
	-- Lapisan transparan di bawah toolbar/window: klik tidak tembus ke tombol game,
	-- jadi UI bisa dipilih tanpa ikut menekan tombolnya.
	local uiPickGui = new("ScreenGui", {
		Name = "MiniStudioUiPick",
		ResetOnSpawn = false,
		DisplayOrder = 109,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = playerGui,
	})
	local uiCatcher = new("TextButton", {
		Name = "Catcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Active = true,
		Parent = uiPickGui,
	})
	local guiHover = new("Frame", { Name = "GuiHover", BackgroundTransparency = 1, Visible = false, ZIndex = 1, Parent = sgui })
	stroke(guiHover, C.HoverBox, 1.5, Enum.ApplyStrokeMode.Border, 0, Enum.LineJoinMode.Miter)

	-- GUI dianggap "kelihatan" kalau ada isi yang tergambar (latar, teks, atau gambar)
	local function hasVisual(o: GuiObject): boolean
		local any = o :: any
		if o.BackgroundTransparency < 0.99 then
			return true
		end
		if (o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")) and any.Text ~= "" and any.TextTransparency < 0.99 then
			return true
		end
		if (o:IsA("ImageLabel") or o:IsA("ImageButton")) and any.Image ~= "" and any.ImageTransparency < 0.99 then
			return true
		end
		return o:IsA("ViewportFrame") or o:IsA("VideoFrame")
	end

	-- true kalau urutan gambar a berada di atas b (DisplayOrder, lalu ZIndex / urutan anak)
	local function keyAbove(a: { number }, b: { number }): boolean
		for i = 1, math.min(#a, #b) do
			if a[i] ~= b[i] then
				return a[i] > b[i]
			end
		end
		return #a > #b
	end

	-- GUI paling atas di titik layar itu (koordinat GetMouseLocation). Elemen yang tidak punya isi
	-- (container transparan) hanya dipilih kalau tidak ada elemen berisi di titik yang sama.
	local function pickGuiAt(point: Vector2): GuiObject?
		local inset = GuiService:GetGuiInset()
		local bestVisual, bestVisualKey, bestAny, bestAnyKey = nil, nil, nil, nil
		for layerIndex, layer in ipairs(playerGui:GetChildren()) do
			if layer:IsA("ScreenGui") and layer.Enabled and layer ~= sgui and layer ~= uiPickGui then
				local p = point - (layer.IgnoreGuiInset and Vector2.zero or inset)
				local global = layer.ZIndexBehavior == Enum.ZIndexBehavior.Global
				local counter = 0
				local function scan(parent: Instance, prefix: { number })
					for i, child in ipairs(parent:GetChildren()) do
						if child:IsA("GuiObject") then
							if child.Visible then
								counter += 1
								local key = table.clone(prefix)
								table.insert(key, child.ZIndex)
								table.insert(key, global and counter or i)
								local pos, size = child.AbsolutePosition, child.AbsoluteSize
								local inside = size.X > 0 and size.Y > 0
									and p.X >= pos.X and p.X < pos.X + size.X
									and p.Y >= pos.Y and p.Y < pos.Y + size.Y
								if inside then
									if not bestAny or keyAbove(key, bestAnyKey) then
										bestAny, bestAnyKey = child, key
									end
									if hasVisual(child) and (not bestVisual or keyAbove(key, bestVisualKey)) then
										bestVisual, bestVisualKey = child, key
									end
								end
								if inside or not child.ClipsDescendants then
									scan(child, global and prefix or key)
								end
							end
						elseif child:IsA("Folder") then
							scan(child, prefix)
						end
					end
				end
				scan(layer, { layer.DisplayOrder, layerIndex })
			end
		end
		return bestVisual or bestAny
	end

	local function overOwnUi(point: Vector2): boolean
		for _, f in ipairs({ toolbar, explorer.frame, properties.frame }) do
			if f.Visible then
				local pos, size = f.AbsolutePosition, f.AbsoluteSize
				if point.X >= pos.X and point.X <= pos.X + size.X and point.Y >= pos.Y and point.Y <= pos.Y + size.Y then
					return true
				end
			end
		end
		return false
	end

	local function applySelectUI()
		uiPickGui.Enabled = state.open and state.selectUI
		if not uiPickGui.Enabled then
			guiHover.Visible = false
		end
	end

	uiCatcher.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			-- input.Position tidak termasuk inset topbar, pickGuiAt memakai koordinat layar penuh
			local hit = pickGuiAt(Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset())
			selectInstance(hit, "world")
		end
	end)

	local lastUiHover = 0
	local function updateUiHover()
		if not (state.selectUI and UserInputService.MouseEnabled) then
			guiHover.Visible = false
			return
		end
		local now = os.clock()
		if now - lastUiHover < 0.08 then
			return
		end
		lastUiHover = now
		local point = UserInputService:GetMouseLocation()
		local target = if overOwnUi(point) then nil else pickGuiAt(point)
		if target == state.selected then
			target = nil
		end
		if not target then
			guiHover.Visible = false
			return
		end
		local layer = target:FindFirstAncestorWhichIsA("LayerCollector")
		local offset = (layer and layer:IsA("ScreenGui") and not layer.IgnoreGuiInset) and GuiService:GetGuiInset() or Vector2.zero
		local pos, size = target.AbsolutePosition, target.AbsoluteSize
		guiHover.Position = UDim2.fromOffset(pos.X + offset.X, pos.Y + offset.Y)
		guiHover.Size = UDim2.fromOffset(size.X, size.Y)
		guiHover.Visible = true
	end

	function api.IsOpen(): boolean
		return state.open
	end

	function api.Get(name: string): boolean
		if name == "Select" then
			return state.selectMode
		elseif name == "SelectUI" then
			return state.selectUI
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
		state.selectUI = false
		applySelectUI()
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
			if state.selectMode then
				state.selectUI = false
			else
				hoverBox.Adornee = nil
			end
			applySelectUI()
			toast(state.selectMode and "Select ON: klik part di map" or "Select OFF")
		elseif name == "SelectUI" then
			state.selectUI = not state.selectUI
			if state.selectUI then
				state.selectMode = false
				hoverBox.Adornee = nil
			end
			applySelectUI()
			toast(state.selectUI and "Select UI ON: klik elemen UI di layar" or "Select UI OFF")
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
	toolButton("SelectUI", "UI", 330, 40).Activated:Connect(function()
		api.Toggle("SelectUI")
	end)
	local closeAll = toolButton(nil, "X", 376, 34)
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
		updateUiHover()

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
	Text = "Explorer, Properties, Select (part di map), dan Select UI (elemen UI di layar) seperti di Roblox Studio. Saat Run, semua yang ada di map (client) dimuat. Perubahan properti cuma terlihat di layar kamu.",
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
	Explorer = glossyButton(studioToggleRow, UDim2.new(1 / 4, -5, 1, 0), THEMES.Off, "Explorer", 14, { LayoutOrder = 1 }),
	Properties = glossyButton(studioToggleRow, UDim2.new(1 / 4, -5, 1, 0), THEMES.Off, "Properties", 14, { LayoutOrder = 2 }),
	Select = glossyButton(studioToggleRow, UDim2.new(1 / 4, -5, 1, 0), THEMES.Off, "Select", 14, { LayoutOrder = 3 }),
	SelectUI = glossyButton(studioToggleRow, UDim2.new(1 / 4, -5, 1, 0), THEMES.Off, "Select UI", 14, { LayoutOrder = 4 }),
}
local STUDIO_THEMES = { Explorer = THEMES.Teal, Properties = THEMES.Teal, Select = THEMES.Yellow, SelectUI = THEMES.Yellow }

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

-- Tab Utility | Mini Studio | Tema
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
	Utility = glossyButton(tabsFrame, UDim2.new(1 / 3, -6, 1, 0), THEMES.Tab, "UTILITY", 13, { LayoutOrder = 1 }),
	Studio = glossyButton(tabsFrame, UDim2.new(1 / 3, -6, 1, 0), THEMES.TabOff, "STUDIO", 13, { LayoutOrder = 2 }),
	Theme = glossyButton(tabsFrame, UDim2.new(1 / 3, -6, 1, 0), THEMES.TabOff, "TEMA", 13, { LayoutOrder = 3 }),
}
local TAB_THEMES = { Utility = THEMES.Tab, Studio = THEMES.Tab, Theme = THEMES.Tab }
local currentPage = "Utility"

local function showPage(name: string)
	currentPage = name
	content.Visible = name == "Utility"
	studioPage.Visible = name == "Studio"
	themePage.Visible = name == "Theme"
	for tabName, refs in pairs(tabRefs) do
		setTheme(refs, tabName == name and TAB_THEMES[tabName] or THEMES.TabOff)
	end
end
tabRefs.Utility.button.Activated:Connect(function() showPage("Utility") end)
tabRefs.Studio.button.Activated:Connect(function() showPage("Studio") end)
tabRefs.Theme.button.Activated:Connect(function() showPage("Theme") end)

-- GUI yang ikut ganti warna saat tema diganti
table.insert(themeRoots, gui)
table.insert(themeRoots, miniStudio.Gui)
table.insert(themeListeners, refreshUI)
table.insert(themeListeners, refreshStudioButtons)
table.insert(themeListeners, function()
	showPage(currentPage)
end)
table.insert(themeListeners, miniStudio.Refresh)

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