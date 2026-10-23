--[[
	Piano Panel (LocalScript) - panel piano terpisah, tidak nyambung ke PlayerUtilityPanel.
	Letak: StarterPlayer > StarterPlayerScripts
	Gaya UI sama dengan PlayerUtilityPanel (palet & tema yang sama).
	Lagu: tambah lewat _G.PianoSongs (sama seperti sebelumnya).
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

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

---------------------------------------------------------------------
-- SHELL PANEL PIANO
---------------------------------------------------------------------
local PAGE_TOP = 58
local CONTENT_HEIGHT = 430
local PANEL_HEIGHT = PAGE_TOP + CONTENT_HEIGHT + 10

local old = playerGui:FindFirstChild("PianoPanel")
if old then
	old:Destroy()
end

local gui = new("ScreenGui", {
	Name = "PianoPanel",
	ResetOnSpawn = false,
	DisplayOrder = 101,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local main = new("Frame", {
	Name = "Panel",
	Size = UDim2.fromOffset(340, PANEL_HEIGHT),
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 380, 0.5, 0),
	BackgroundColor3 = P.Bg,
	BackgroundTransparency = 0,
	Parent = gui,
})
corner(main, 14)
stroke(main, P.Stroke, 2)

local top = new("Frame", {
	Name = "Top",
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	ZIndex = 3,
	Parent = main,
})
new("TextLabel", {
	Name = "Title",
	Text = "Piano Auto Player",
	Position = UDim2.fromOffset(14, 0),
	Size = UDim2.new(1, -70, 1, 0),
	BackgroundTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = FONT,
	TextSize = 22,
	TextColor3 = WHITE,
	ZIndex = 3,
	Parent = top,
})

local closeButton = new("TextButton", {
	Name = "Close",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -10, 0, 25),
	Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = WHITE,
	Text = "",
	AutoButtonColor = false,
	ZIndex = 6,
	Parent = main,
})
corner(closeButton, 8)
redGradient(closeButton)
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

local openRefs = glossyButton(gui, UDim2.fromOffset(110, 40), THEMES.Yellow, "Piano", 18, {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 10, 0.5, 0),
	Visible = false,
})

local function setPanelVisible(visible: boolean)
	main.Visible = visible
	openRefs.button.Visible = not visible
end
closeButton.Activated:Connect(function()
	setPanelVisible(false)
end)
openRefs.button.Activated:Connect(function()
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
-- LAGU (disalin dari PlayerUtilityPanel, tidak tergantung panel lain)
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
-- Dr. Dre - Still D.R.E.
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Dr. Dre - Still D.R.E.", bpm = 120, tpb = 96, data = [==[O"Z)"@fr##-f9f9#H`L`("Q`X"V"+!W$+!)4+-@#/f;f8D;-(f4f8#G,;P"+!OF+4j"*;)("O`@e"`%DR%U%`%'@":`,P%/@"(f8$@f>c%)X"$Ef(w$)9"Hd@U#c%-W"$EfHf<`%/"(f8$CfG,;U#p).Z%$O%c"Z%a"O%d%Z%U"9"G@'"(f9#G`L`""H@'"O`:"G@?22'9"L@,Z%%9"G..?8"G@)#T`X`)"``W"Y#+'$(fS,86+)("``X(+!^F+.g"!^,g"!^b#Y$Q#}$2r$H}$2e$'%(fLDO%%$Qf(a#)8"Td@^#n$'QfTf>8+%(fOfS,:}(X%H}$2X%4p,.n$0f-%$@`.-#C`.{#!@0-N":!dO#r-R$Y%{$r1$W$Z"}$Hr$c&g-$n$a"g-}&X%&c$_"X%<f>LX%)9"S@?&P+)""T@((4!#02'8"X@,W%%8"SJ.w"r-Z"}-s"g%m$}1:r$D}$@r$k"g)*u-V"i)%%9f.U./#S@T`@$:*W:-8"S@@$8.j:FS.$S"9("``:"T@?&8`;&|")""S@'$8%d?#$23V@'"``9"X@]==] }
-- Blood Orange - Champagne Coast
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Blood Orange - Champagne Coast", bpm = 120, tpb = 96, data = [==[d"!#-r9r`-$*262S2D"Q2D"N2C$*262Q2D"$4$0IN2D"L2D$-292I2C"G2D"E&0)B2D"E$4&@1D"L2C$/2;2{"%/2;.{"U"D$/2;2N2C"L2D$22>2I2D"G2C"E&00{"(@%L2D&y$!C&{"$0%Q2C*{"$y$${"(V$$y$!C.y$%D"G&0({"$y$,{",y$!C.y$$x%,y$${",y$!D.y$T%i"%*c6cS2b2D#Q2`2C#N2Z2D%*c6cQ2`2D#S2b2C#Q2`2D%*R6RN2Z2D#L2X2C%-c9cI2U2D#G2S2D#E2Q2D%-c9cB2N2C$0$<G%-R9RI2U2C#L2X2D%/c;>n#%/c;.n#&<'%/R;.n#+D%2c>c$o"0n#%2c>>n#/2R>RIRUR:W&-D#N2Z2C6W&(i#4W&$q%,W&&V#*W&$y#&U$*W&(i'4W&$n#,W&!C.n#!D*W&(i'(W&4n#(W&&j&$<*W&Cj""62C#=2Q2D#B2QRD>0=D#=2Q2C"92D#@2Q$n"9RC"92D$@2JRQR$m-Q"92IRQRD"@2D";2C$B2J2Q2D$G&89;2D$B2I2Q2C$G&X"$45J2Q2C"22D$9&T"+>2JRQR*4;RSRD">2D$22JRU$r#+"62D$=&s"!B&W#(4!P>41Q2D"92C$@$,#$E&@E92C#@2JRD"E2D#92IRC&`%(e$!D&y$!C*4!P>4-Q2D"22C6`%%D"2$Q%N#2S2i"$22J2U2i"#*c6cD%Q2U2Z2`2D%QRURZR`RC$BcEcIB<1D$BRERIRC,<'#-c9&Ld"X2`2C%QRURXR`RD$ERIRLRD%SRURXRbRC(2I$URXRdRD$E2I2L2D#&c2c.w".f#)>cBcEH<'RBRE2R$1/c;cD%Q2V*L!V$p%C%;R>RBRGRD$JRNRVRD*2MC$IRNRURD%;2>2B2G2D#*c6Fj#$^'F<)RERIR,z'!C.^'8y(8^'(p'!CB^'.w":^'F<)RBRER,{&!CJ^'.y&+%JRNRS2`'!D&`'!C,`'Fe@%BcE>X;%BREBX;2t=#$=<r=#$=Z"T;!Ci"j#c"T;&V$#$2P"_@,Q&4n=(g#(n=B_@&Q&4e#0Q&,eE&gGu"j#'2l>l.SH1"Q2%"E3?#:V@!#$R@c(bN"$z#,WV"!C.y$,{"_"WV"!C*{"(@,y$HWV"$0({"(V$({"DWV"e#i"#62b2D#=2`2D#B2Z2C#ER`2D"b2D#E2`2C#B2Z2D#=2X2D#92U2D#@,`-'#IRN$u###I$z2n"RU2D"X2C#;2b2D#B2`2D#G2Z2D#JR`2C"b2D#J*6GC#B2X2D#>2U2D#E2S2C#$wC1NRD"Q2D#N$4'RURj$x$!C.x$%D#E*x"!E.6)=2X2C.x$(z0(x$%D#I$a%&x$!D.x$!C.x$)D"b2C.x$-D#B2X2C.x$!D*x$!C*x$N#D#JRU2C"X2D(>rErJrUlZl`ldlV'%SiViZibim%#URdRi"&iO"3_2D#E2X2C#$q2z"8RP2D"U2C#=RX2D"_2D#@Rd2C"g2D#DRk2D"d2D#Ipgp]==] }
-- Mozart - Rondo Alla Turca
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Mozart - Rondo Alla Turca", bpm = 120, tpb = 96, data = [==[7}""S77"Q77"P$(`"#EMTMN"#HMLMM$HMLMV77"T77$HMLMS$,'#EMX4E)Y77"X&E=W78"X77#EMb77"`&6!_$,*6!866?ccM#HMLMN"$HMLM`&|"n"cMM#@M^7,"`,,"b77%GMLMZM`MN"%GMLMXM^MM*55M#@M^B,"`,-2M$B+XM^MM$$4#N"*K4{"Y"M$;MXM^MN"$GMWMZMM#@cXc|""S78:m'2N%Q#m')7"X78V"m'(6!86m'$s"!`(t#`#m'),"b78@m'6L!-Jn'!M&m'#N"&n'##T$f&-VMYMM$<&E!H&n(5#@M`77"^77#,O'5CMSMVMM"OMN$b"!M2a"#N"&b"!M>a"78$CcScVc|"#Q$m0=SMVMM$9MTMXMM$E$('#<MY&w/!H*h*5@MPMSMM"LMN$a"!M2`"#N"2a"!72a"-8$@cPcS$N-(n3!86N-(m3!8B},2u-<},LT3@f-CAMccN"#EMKMM$EMKM`&(!b$^)9cMM$EMLMbMM#>$n-?AMGM_MM#<M`MM$@M&Z05>MYMM$AMGMV&7T#TcM#@MEMN"$@MDMSaM#@MDM7"Q,,"S,,$9cEcQc}"#SMWMM#U$O(!;$j3*r3z"?M_77"Z78#KMX77"W77$BMRMUMM"NMM#SMWMN"#UMXMM6`"#N"*a"!70a"^"cRcUc}"#PMSMM#RMUMN"$8MSMWMM$D$(##;(P"h"#GMU78"S77$?MOMRMM"KMM#PMSMN"#RMUMM6`"#N"6a"!7$a"1cOcRc}""R&V8!O$(##D$n"1GMKMM$GMK*R")GMKMR$r#+#DMWMM.D$S#-8$GMKMV&b#-DMa77"_&Z"-^77"_78B6f"7#@MbcM#DMJMN"$DMJM_MM$DMJMaMM#?Mb$7=KMaMM#=M_MM$@MF$W5/;M_MM$?M$Y$!=$s*)@MFMU&7d$ScM#?MDMM$?MCMRaN"#?MCM7"P,,"R,,#8cPc}"#QM`MM#SMbMM$9,Ucdc,"=,,"@,-"DXX"$DMQM`&m(5bMN"$9,UMdM(F),"DX,&c",KV#PM_MN"$2,NMZM,"6,,"9,,";X,#PM_MM$3,QM`M,"6,-"9,,"<*h"I4,PM_M,"8,,";,,"@X,#L(|%$S##@M@y$/,"EXY"$E&E!E&E98,UMdM-"<,,"?O#x$@^$%-"=&^$3M%2,Zi`iei,V"S">XY"">MM">MM#9,e''$XH`HdH&.r$#,",8-H#EMe'&2.(<=G%4,Xg_gbg,"8,-&Q'AX""@MM#@MgMN"#9,U.w)GEX,"XMM#EM`MN"#EMdMMg"C7e7,"=,,#@,d7$E9b78"d77#EMe77&*!b$*:h&)-">XX(h&?N"#9,e'&$Xi`idi'.q#Q"X""EMM"EMN"#4,d'&$XH_HbH'0P,'"d''&8'G#@M,.'H#@M,T"|"H#E7`c7"L77"I77"L78#E7X,,"`,,#L7dM7"I77#L7d774:#h8&R"%7"E&(&0+#E7X,-*H*8.H!8&H!e*O#%I7b.^#(8!888!i2u$>p#9e''"dH1"L77#I&.!2*<!&*.(<$J5@7bg8"L77"D&u"!@&u"'D7gM$W'w&W-(k0#"@f%W-5&9,QgUgXg`g4r8?"EMM$EMUMdMM$9,QHA%XMg*A!-:o$&e"'N"$9&g<.U(!#*P#.:+-"EX,#&y"O"cQc`c}")9i=i@iEiQiUiXi`i]==] }
-- Pirates of the Caribbean - He's a Pirate
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Pirates of the Caribbean - He's a Pirate", bpm = 120, tpb = 96, data = [==[3!"JQ^""J==())>"JQZ&)0$*5<P"#=>$1-=>$&h2h:l")$&b2b(X"$-W"=>"E=>"H=>&2Q>QAQEQJQZ"&2=>=$-|">#2Q>Q>$A=E=J=>&0=<=E=H=L=>&.Q:QFQJQMQZ"&.=:=$-x">#.Q:Q>$F=J=M=>%.=:=J=O==&-Q9QEQHQLQ^"&-=9=$-f">#-Q9Q>#E=J==%-=9=C=H=>%2Q>QE=H=>#&P$%=>=$V$5="E=>$2=>=H&N$-AQFQJQ^$N$$-!=$N$'#F=J&|#9F=L=>&)Q5QEQH$P%')=5=$-p">#)Q5Q>#H=M=>%)=5=H=O=>%0Q<QHQLQZ"%0=<=8z$1>$-=9=H==.T(#^".u$)>"E==*u$0E:|(!=$u"/%2=>=E=M.x(!O(w%$-(w%%J=O*v(IQ=>&+Q7QJQOQRQZ"&+=7=$-I>#+Q7Q>#M=Q=>%+=7=L=O&v(+M=Q=="4t(%>"J&t(%L==.u+.z#.u+(X$#=:.v"!>6v"$r/-2=>=M=>&j,!I0j,)IQLQ=&m($l---=9=G=J(O"7=I=L=Z"#-=9=&i)#"Q&g)!T&o()MQQQV(n0$-(n0)M=Q=V&n0)Q=T=X&v%)RQVQY(v%$-(v%=R=V=Y==%.=:=V=^&O$)QQTQX(Q%$-$U$)=#Q=V&Q%%O=T&|&+Q=T=>#&P$'=>==&w(!Q&N'!T&t+%MQR$T%'.=:=$-&N$'#R=V&t+%R=X&n0)QQTQY(n0$-(n0%T=Y&n01T=^==%0Q<&|$)%0=<=,z$->#Q=V==>T(2n0!=2u$0E.|(&s%&r&-2=>=Q=Y&w%)RQVQ^(w%$-(w%%V=^&w%%V=`&n0)VQ^Qa(n0$-(n0%Y=`&n0?X=^==%2Q>QY=`=>"(t((n0!V&m4!X.z#Bu+#=$*X$*n04v"(m*!V&u&!Y*j,)UQXQZ(j,!U,m(#"V&r/!U(f,)QVQZ"*++^"&0Q<&N.!Z$-!T&j$1$0Q<QY=>"8P(/%-Q9QV=`$;.W2)=#Q=Y&O/9Q=V=>$-Q9QQ=^$O3${3&-&w(7=^=a=Z"#+=7=(q(%R=^&q(5R=V=>$+Q7QR4E!^$-9=%-Q9QI=L=>#I$s=9=9=>%-Q9QCbJb(q5$T6)bIbMb(u#$z$#"M&b'!O&U.)JQMQQ(U.$-&^)!$$.&k+$M;=M=R=>$J=M=Q==(U,8&!&(iA)OQZ"&(kA3OQ>#0Q<Q>$*.3=<==&5QAQH${=7$H=M=Q=>#5=A2&!=$,H{$&Q3Z"{$*Z.:{$)-Q9QI&{$/%-=9=IQM,iE,O)2nLJhA32Q>QEdJdMd6_F!O&o2!Q*PH!O(b8$NI)0=<==.cH10=<=>&5QA&PJ9^"&5=A=EQHQOQ(U'(2#QQ&v'2i)$g"$&+$0=<=M&(!O&}"/HQMQQQZ"0^)+$5=A=O&(!M(O/'QLQ^2a'$T/%=9=&mD6e'6^<!L.tO"'2Q>Q$`S"&E&N*)$2=>=(b7!X&I)QQVQY.V)*I!X,^8&w?!^(hO"$u@)0=<=>&0!^*u(;5QAQYQ`Q^"%5=A&;)5=A=>&0!Y*q(,wC#^"$f;-#.=:==$$q>)>$.=:6q$&u/+QQVQ^Q&s%/%2=>=VQ`*w/7+Q7QRQVQaQZ"$m7'QVQ>$d7&0!^*0$U=#YQ,rK#=9&g6!^&(!X&_*&mD8G!X&iE!U&s$!V&o&.g(2j2.eC(f:(y:,&7&5QAQTQYQ`QZ$r/$-/>#5QAQ>$*.*n/1T=X=`=="^(k/:&!=*Y'!^(p#0j#&|#&YC$S).Y&&Z/.z=%QQY(a0%QQ^(N0&0!X2v6+MbQbVb(m.8c/*}E12Q>QVbYb`X"K$lS"+VbYbab(q-6k-${-!Y2`(&R70O(1=%5=A=YQc>b(!>*b(!=<h(.b(,xD:R+,b(4h.0n(@b(0s7%QQX,s7%b>b$b(!{2{6&p'+&k2kJk]==] }
-- Grieg - Morning Mood
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Grieg - Morning Mood", bpm = 120, tpb = 96, data = [==[K!$@pGpbbl""_bl""Zbl""X**'_bl".B3E3"`E3"_EE0I#EE$2$()$@iGi(J%bEE${";bbl"&=kDnIkUkd*e#5dbl"%@oGnSo4z#t"#GeXel""Dbl""Bbl"%@wLnPhSbl""Pol""Nbl""Lr(*)Pil""$>3b3"QE3"PlE&E5il""NEE"PbE$(1EE$@kLkPh$J+SEE"Ph&c"!%$:'Ubl"$5i#Ubl"%DrPpThWbl""Tql""Rbl"#KbPnl""Hbl""Fbl"$DpKpfbl""cbl""a*n%!a(4.B3E3"dE3"cEE0I#EE$2$()$DiKi(J%fEE${"!f(o$%Xkg*c#5gbl"%DoKnWo4x#)#Ke_e0o$)%DqPn(h%!o&h%%"Pk(*!T*D!e$D3b3"UE3"TlE0K+EE"TeE$(1EE$DkPkTh$JU"WEE"Thl""Wbl"%DkPkUhXbl""Uh&i-;%GrSpWhZbl""Wq&z(M#NbSnl""Kbl""Ibl"$GpNpi(b&#"d(}-/"dEE"fEE(()%GrSn(q"!n&q"9"Snl""UEE"WeE((-%GiNiZi,w"1bbl"%GiSi(b"!e&h,/'GiQiSiW:N"/(;iGkNbQ$T"o#il"#KbWel"#GrSbl",(p4p;p@pDpGwLnSpXp_hbpl"#Pb_ol"#NbZbl"#LiXi,.%Pb_6_"!t&_"!e$_"?E_b3#QE`E3#PE_lE8j"3EZEE#PE_bE,,O"EE,4i;i@iDiG~LiPESiXi_hb*m"r"ShbhE#Pb_el"#Sbbbl"+4i=i@iDiIiLiUiXi_hdi$j$n"el"#Ubdbl"+6i=nBiEnInLnUnXn`hdnl"#Qb`k*i%-&1b=bIb$q$t"$-b9bEbl"$,b8bDbl",*p6p=pBpEpIpLpUpXp`hdp$i"!o*i"4c''#Qb`F_"!e$_"?E`b3#SEbE3#QE`lE8j"1E_EE#QE`b&d';#QE`EE+6i=iBiE*e&I`hdbE#UidhE#Qb`el"#Uw&j&C?iBiEiKiNiWiZi`hfi$b$Eel"#Wbfbl"+8i?iDiGp(E=bhfbE#WhfhE#Sbb2J*W*1iXi_ibhgi$u);el"#Xbgbl"+9i@&e$$E=dhgbE#XhghE#Und,J#*9&b%o%NiQiZidiiil"#Uzdel"#Zbibl"+8w?uDuHuKtPo_hcefbksE#_ifiE#WEceE#TE_hE#WEchE#_hfbE#_ifoE#WEciE#TE_kE#PkWEE#TE_$V"!b._"9bE#PEWEE#KiTE(,%TE_*&&>/ETEE#HEP*,$8'EtIt(_7'UnW$<*-l"#EiIi*E!~*W)EHiKiPi_hcifbkiE#_hf$f%*c$5WEcEE#_EfEE(h"'XeW$n#c"h"'8t?tDeHbKeTEE#HePEE#DsKeE#HkPEE#Kh,N&&o&$J-oPEE#KkR"l'!e8>O&WEcEE*7i8i=i@iFiHiTiXiciE#Th^EE#OEXeE#Tb^EE#XEcEE#^EgEE,5v<uAuEuHtMoTeYb`icbhsE#YeciE#Te`kE#QEYeE#Th`nE#YbcbE#Yeco4>IMkTeE#QEYhE#Tb`hE#Te`$2'bE#M$h+%iQE(,%QEY*&&>/EQEE#EEM*,$8'BtFt(yI'RbW$<*-l"#BiFi,EAl",5i<iAiEiHiMiTi&t%+iE#Yec6e$9TE`EE#YEcEE#@$j"!U_$j"h"'5t<tAeEbHeQEE#EeMEE#AsHeE#EkMEE#Hh,_&&}&$J-oMEE#HkR"z'!e8>T%TE`EE)4i9i=iCiEiQiUi`iE#QhXEE#LEUeE#QbXEE#UE`EE#XEdEE,2x9x>xBxExJxQiVbZi`belE#Ve`iE#QlZiE#NEVe(,/Ve`eE#ZiO%D!i*DU"%JqNhZeeeE#Vb`bE#QEZEE#NlVE(,1VE`EE#ZEe*,&D!e6D/%KqMhYEd*s&&g(#lU*,$8>D!k6DO"%0wHe`EcEE#YE`EE&EbHbQbT&e*5TEE%CbMbTbY(B%$Ab0P"!C:P"!E6P"!H2P"}"S#!E*P"%$EE&R"!E&R"=$EEYE`EE'0kAiEh6`#!e8`#!H4`#7'-iAiEhJb`Ee.V")JbQbV&V"1VEE%JbMbV.V"/0rArErHh.b#%%Hq2`#!$2^#!#.J!#.F&,$n#n"MqTeYb`EclE#Yb`EE#TbYeE#QETbE#TiYbE#Ye&q"P"DW"E`EE%LpXb_EclE#Xb_EE#TbXeE#P&H;XbE#Xe_EE#_EciBDm#EXEE#XE_EE)/s;nGrLhPeSbXEbEE#SE_EE%DbPeXE_EE#LiSEE'BbNbPhXE_.D%@bL0T"-&BbNbPE&V"1ESEE&DbPb2T"%)/pT$f#%ENE&f#5%DELEPESEE',6/bEE%DEPE&p#1k;i@iDhGk6p#!e$m$&}$+'GtPES6O%9,k8i@iDhIiUbX&q48_"9UEE'IbPEUbXE_,D5)/o;p@oDoGv*n#)e_EE$.l'%eE%*{$$>!#&J!b$uJ$R>!S*,._$)oDhIk6_$!lZ"_$-'/i;iGs2X$,^#!bT$^#)e;iGze"^#1',o@oDoIp.W#.h'#UE(h'*>$vC&,(y"!U*,KUE_EE"Dku%"Iku%%/kDkG}&}{"&d|"+$1k@kL(.3"Pbl"$/kDk$F!E&v|"!E$v|")$-iEi$M$r|"((w#%,kGxLpSku%#+kRku%$*qKqQpl*)(w/wDwGoLbPbUEXe3"SeW"#GrNbl"#LEPEl"%u"=!oP"=!y0=B`$7pQql*)(p/pDp<`$R"P#!u0='*qGt(p"-i/iDiGi8P"!n.P";'*kGnKkLbPbQkl6=i"e"?iGiKiLbPbQil"#Gx*=W"W,&/eBpEpGtKpl*&/eBiEiGpKiu%(-7zLiu%%(e@xDxR"z^#$c}"8>4o^#)#GrSi0SZ#-$@bIkUk&./"Dbl"#GtJD+EE"DEE((y#(;oDoG~LpPpSpbpl*(8o@oDoLpPpUpdpl*.(x4x;x@xDxG^LxPxSxXx_xbxgxW4";e]==] }
-- Choi Yu Ree - Wish
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Choi Yu Ree - Wish", bpm = 120, tpb = 96, data = [==[_#!%InPnUnYnr'"PdY#"UdY#"YdY#%HnNnRnYjg%"WdY#%BnKnQnZdZ$@t""TdY#%FnMnPnUnr'"HdY#"IdY#"MdY#&BjGjKjNjS(y"d$#PdWdY#%=dGdNdZjY#&AdDdGdIdPdY##IdYdY#"RdY#%DjFjIjTdY##RdUdY#&BnEnKnQdWnY#"TdZ&IU$AhDhHhPha$&AdEdMdTdWhY#"ATT"&DdFdIdMdUjY#"AjY#"WdY##?dYnY#"FdY#"BdY##DdR$w#+TdY##M$g#$`"'KdUn&G#"D$EAWpY#"Kfv#"Pda$"_o]==] }
-- Dexter - Blood Theme
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Dexter - Blood Theme", bpm = 120, tpb = 96, data = [==[M!#,s8sd""Dad""Gad""DaS(26!F*6%(s4>L06,L',j8j6LIw#$,j8jPad""Sad""Pad"2I&b"0I!R*I%(j4>u"%(j48u"0I,u"*I1Rgw##,A8A&D-$GaZgig,.'Xngn6_##d"6R"%Wgf.R"%Vne>R"%(A4LW#%mgm:R"/%(A4A_gk.H%amm<H+$Gabgn(F!"y"f%2P"a"d%!"N"b%#gg..0o"#4A.k$4J'#Wjf8T+]==] }
-- Rush Of Life
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Rush Of Life", bpm = 120, tpb = 96, data = [==[5!"Q99"X99"V&(!T&(!S&(O%@?#A9Q99#E9X99#H9V*,%A9T.8!S.8w"P"=C9Q99#G9X99#J9V*,%C9T.8!S.8w"P"=E9Q99#H9X99#L9V*,%E9T.8!S.8w"P"-<9O99#C._&$,%<9T.8!S.8u"P"+$A9Q9`(p'#$H*.!V2<!T2<!Sd#X"!C&.-G9X99$J*.!V2<!T2<f#X"!E&.-H9X99$L*.!V2<!T2<f#X"1<9OQ^Q9"C$i&;Q`Q9"L99$O9SQb&,)H9TQc&D)<9VQe*P"%XQg*D%YQh*D`"^QjQ9"799$59`dld9"<99"A99"E99$H&4!E&4!<LH%QlQ$,+A9cQoQ(L%bQn&,!A.D!H&n#$P"$8$P"$8$P"$q$$P"$Y%$P"$t%)<99$9&R$!@$N$+"H99$L&4!H&4!@LH%QlQ$,!E&}$)@99$0&}$)799$<.8)C9gQs&,(8!7R"P"$8$P"*}(+%59`dh8T(#%H*6.Q)LL#Qh(a(+%A9cQl(W)+%59bQj(Y)#%A2J)H9^Qg(`).<$X"(<$X"%YQe(f)+%H9XQc(h)+%A9VQb(j)+%99`dc8q(#%L*6.n)LL#Qc(r)+%E9cQg(V(+%09bQe(s(#%<2<)C9gQj(z).<!7Z"X"(<$X"%^Qb(T*/#59Q99#<&o>!V*,%59T.8!S.8w"P"179Q99#>9X(z9&,%79T.8!S.8w"P"-99Q99#@.QA$,%99T.8!S.8w"P"d"09O99#79^99#@9T99#79S99#09S99#79b*J$k$!0&D5c99#@9^99#7&k"@P"]==] }
-- ICARUS
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "ICARUS", bpm = 120, tpb = 96, data = [==[j$!"Te`#"Te_#"Te^#"Tea##8;Te6"?;9"D;@"H;9"8;<"?;<"D;<"H;;"^e""8;7"?;C"D;2"H;?"8;&"a*X"_#:"H;?"Ve#":;;"A;8"F;<"J;8":;<"A;@"F;;"J;7":;%"^e9"A;<&4l&;"ae"":;9"A;:"F;?"J;7"We#"<;>"C;9"H;?"K;7"<<:"C<;"H<="K<9"Ye""<<="C<?"H<6"K=;"<<#"^e="C<8"H<;"K<>#3<Ve8":<;"?<="C<="3<""Ve;":<7$4W&=8"We""3<>":<:"?<6"C<?"3<$"Ve5":<="?<;"C<=#8SPe%"Te7"?S@"DS7"HS9"8S>"?S8"DS@"HS6"8S$#We^e<"?S="DS:"HS6"ae%"8S""^e="?S5&N"u)9"Ve%":S""Re6"AS>"FS9"JS>":S;"AS8"FS>"JS8"^e#":S""We8"AS;"FS@"JS8#:SYe""Ve8"ASB"FS8"JR9"<R$"Te""We="CS9"HS<"KS:"<R9"CV7"HV?"KW8"Ve$"Ye$"<W7"CT="HW<"KR9$<WWe^e="CW="HW;"KR9"Ve""3R#"Re8":W="?W:"CW9"Re"&<m#8":W?"?W;"CW;"3R#"Tk""Wk5":WB"?W9"CW9"3R:":W@"?W8"CW9"8W#"T;$s"s#V;#"DW9"HW$"W;7"Y;""Y;#"KT4"HW>"Y;%"DW7"?W#"W;<#8WY;:"^;#"?W:"_*a"R/=#KT_;#"^O2"HW$"^A=#DWY;8"?W$"W;:"T;#"5V6"<W<"V;&"AR9"W;""DW7"Y;%"HV;"DV;#AVY;8"W;#"<W;"5V$"Y;7#<W^;@"AV""_;<"DW6"_;#"HW8"DW#"^;:#AWY;9"<W%"W;6"0VA"7W#"f;:"h;""<W8"fS%"?V7"CV<"?V""e;8"<W""f;:"eb%"7W:"0V>"7W5"^h$"<W;"?W>"CW8"?W:"<W>"7W:":W<"AW$"f;8"FW#"h;7"fS%"JW9"MU:"e;#"JW8"f;$"FW7"AW#"eb9":V?"AW8"Y;#"FW;"JV="MU:"JW$_&y%FW#"f;<"V;""e;""AV4"T;#"8V$"c;<"?W7"DW$"V;$"e;6"HW$"f;""W;8$KWY;h;;"HW9"DW##Y;h;9"?W&#W;f;5"8V)#Y;h;6"^;"#?Wj;8$y*d$V#"k;>"HW7#KWk;$"_;4"j;""HW'"^;7"h;"#DWY;9"f;#"W;$"?W5"T;$"5W""c;;"f;#"<V5"AV#&U%h";#DVW;$"f;:#Y;h;""HV5"DV="Y;##AWh;>&S%n,#"<W2"h;%"5V#"Y;6"<V$#^;j;9"AW""_;#"k;:"DW;"m;#"HW$"a;6#DV_;""k;:"^;""j;#"AV8"<V#"Y;%"h;4"gR""0V#"XS:"7V%"H;7"<V%"L;9"@V""O;6"CW&"P;8"@W%"T;4"<V*"X;5"7V#"^;<"_;""0W5"7W&"c;9"<W$"g;7"@V#"j;9"CV$"k;>#@Vc;8#<rm;<"7q$"j;7"0q%"g;8"c;?"a;7"^;;"X;="T;8"R;<"O;<"L;@"H;5"F&dCQ"F;9"D;="C;9"D;<"C;a#"C;^#$*j$O;:"M;8"K;A"J;;"8;""He8"?;?"D;8"H<>"8;8"?;="D;9"H;;#8;Oe>"?;:"D;;"H;<"8;#"Re9"?;;&sEt"9"Je$":;8"A;>"F;8"J;:":;>"A;9"F;>"J;9"Oe#&_E!:&D1="Re$":;7&_El"<"J;:"<;""Ke:"C;<"H;:"K;<"<;;"C;:"H;>&0M""Me7"C;?"H;;"K;<#<;Oe8&V"A;"K;:"Je$"3;:"C;:&cG5:"3;$"Je;"C*h#h"8"3;$"Ke9"C;>"F;6"H;<"3;%"Je8"C;;"F(P$3U#"8;9"Wb%&hJ9;"H;9"Wb$"8;;&4$L-8;#"Wb:.a(1%"Wb:"8;:&|'1""We9"H;;&wKd"=#F;Wb="K;7":;;"Wb%"A;;"F;;"K;8":&u")A;="F&l#$8U"="A;8"Vd%"F;9"K;;"<;:"C;;#H&u"39"<;<#C;Wb(i(+?#<;Wb({()7"Wb#&Z"'<"C;$NK$aM)8"?;<&h#5%"K;7"O;?"?&x#S$F;8"K;9"O;?#?;^b:"F;="K;9#O;Vb>"?;9"F;;"WS#"K;:"O;<#8;RS7"?;>"ab"#D;Wb:&a.-:#Wbab#&d'A;"H;8"8;""ab""Wb<(w(/$H;Wbab=&c(n"8"D;#"WS""aS9"H;>":;""VR9"A;9#F;eb""Yb$`R"$Q)#""$4$_(=J;9"eb"":;#"Yb;&c09<"J;""Yb""eb<.VU"$kCY"J;""h;;#<;WS="C;7"H;#"fb#"^b:&W)9:"^b#"fb$"C;8&i0=8"^b#"<;""fb;"C&u.!K*_"!7&j));"j;#&w0$Q<^$m;8"k;;"k;<"j;="j;8"h;;"h;@"f;7"f;;"e;<"e;<"c;9"c;?"^;="W;7"V;:"8;$"T;9"?;>*T6%8;=&i($d/5^;""8;%"j;7&X8A9"H;9"a;$"m;""8;9&`_";9"H;="Ve"#:;ee(YZ")="J;=&lZ"!=.w^"!"(p@K;?"F;:"J;:"a;""m;#":;:&h1M""T;7"V;%"J;9"f;""<;""W&a6$R(!:&N8!;&u0$`L%Y;#&t1!=&8$h%5<;""j;7"C;@&897"V;$#?;e;;"F&e"l"O;;"?;""V;#"e;<"F;6"K;<"O;="f;""?;""W&u,-K;="O;8&xF)$"?;8&r1=<"O;8"Te"#_ece#&Nf");"D;7&je"(N(=="H;7"je##^efe#.N@$r%7je#"ae"#8;me(p));"H;7$U1/e"#aeee;&m>':"J;(z/(}0?:"fe"":;""je$"^e(P@=:"J;8"ee$#Yehe"&V"(u*'7"We$v'5ce#"fe8"C;>&^/!8&`)(U95>%<;Yeeehe;.^)=8"je""^e$#<;fe7&c"99"K;;$Veaeee$&T8K:"K;?"O;8"ae""We"#?;fd(y(E;"O;9"?;""Ye##aehe=*l=f"O;:"j;"#?;^;;"Y;"#F;h;9"W;#"f;""K;$X`"AO;""e;6"T;$#8;c;$&}(A""?;:"e;""D;"#D;V$X6%#H;&fT"3"K;""K;#"Y$S7K"H;""H;8#D;Y;#"D;""h;7&w,s#""?;#"f;7"8;#$8;Y;h;9#?;j;#"?;""^;;$D;_;k;""D;6"H;#"H;9"k;""_;"&b#-9#H;^;#$eU"';8"D$g$&x#/8"?;$#W;$f/;7"5;#"TS##5;cR$P*!A$h/3#A;V;7"f;"$v=1;""D;:$H;&qU"#;7&}"d";"A;$"Y;"#A;h;7#<;f;%#<;W;7"5;""h&m&?5;:"<;##^;j;6"A;(}U"'""A<$fG$du"#"#$N&)H;8"j&U%a#D;""^;7#A;Y;#"h<#"A;7"f;$"<;"#<;W;8"0;""0;#"T;""c;7"7;${Y"97;8#<;W;;"?;$&h5?8"C<$"c;""T;9#?;$d)$yb"1<;""<;8"7&e&U"7;8"T;#"0;##0;c;:"7;##7;Y;7&Z8I;"?;"#?;Y;:"C;""c;""C$O##"^&d+c#?;7"_;#"<;#"<;7"^;$"7;""7;7#:;c;%"T;7"A;""V;$"A;8#F;W;#&a4K""J;$"V;6#M;T;""M;#"c;$Zl")J;:"F&y(Y"F;7"A;$#A;W;:":;"$:;T;c;9#A;Y${"v""F;#"^;#"F;8#J;_;#"J;8"M;""M;""c;$#T;^;7"_&l#AJ;7"F;""F;$"a;9"A&N&'A;8"$Z2$|A!_&R&%e;&$zY"';""f&^-9K;$"K;""h;9"H&X0$v/5#"D;$"h;6"?&P"9?;:"h;$"8;9"j&i>$QE$ud"$_"):"k;#(r1#"H&Ye"-H;6"D;%&N4!6&v39;#5;c;#"5;8"_$h-#"<&S)!A$UA%#D;$j1#9"$^1E#"H;6#D;_;$"D;:"h;#&P"!6&O+A#"f;8"h;#"5;""5;8&xCE#"<;8#A;k;""A;<"D;#$Wm"&S'!m(t7K<k<%"D;7#A;j;$"A;9"<;"$ct"*$)7#<;g&Zj"g#C;<"c;""H;9#L;e;<"g;#"O;7"L;#"^;<#H;c;<#C;e;8"g;""<;>#C;^&e*Q"H;<#L;e;7"g;""O;:"L;$"^;;$X"%"C;$ov"%j;$&wH/#"c;6"H;$ni"h"h;""L;=#O;j;8"c;%"L;7"g;$"H;8"C;#"h$W?;"<;:"c;$"C;;"g&z+$a"5;"O;#"j;8"L$c<+"H;#"j&OK5C;7"k;$"A;;&v+-9"k;$"M&{"X#P;7"T;$"h;:"P;;"h;$"M;7"f;#"H;:"F;$#V;e;;"M;;"e;""R&m8Y"V;8#Y;h;="V;""Y;8"a;$"R;8"R;%*S#-?;7"^;&&{_"K#"m;=#O;a;8"R;""m;:"a;$wm"%j;"$QW"';$"F&oP"!D&aV"-W;:"c;#&w$%#"T&s*$rQ#$g"O$P;:"K;#"R;7"Te##>;Ye""_e""ce:"J;="M;:"P;7"VW""ee%$T;Yb_e8"Vb:"YY="_=9$y"d"e#"fe""_P7"_c>"Y;9"V;;"_e""Ye""he$u:T#P;="M;9"J;;#beee##^eje#"+;7"2;;"7;:";p@">p<"Cp;"G&XV"U"O;="S;<"V;7"^;:"b;@"e;;"f;;&N,O"b#"^hk%"O;_#"O;c#"O;Z#"O$ht"!=&ht"-;"J;="H*TR"&_s"#<<&QS"(zQ"):"^e#&qe"!:*l^"%ae"6`l#+9#:;Ve$Ul"(lj#-:;?"A;7(Y^"+#:;^e7&Zu")9"J;<.ak#);"F;@&ZR"(p1!:*Zs"$qk#${i"1K;;#<;Ye<&2%="K&o$,^^"G;"K;7"3;%"Ve:":;="?;$_s"+3;""Ve$aa"!?$v^"?#3;We8":;?"?;;"C&xt"$Z"$P&1C;8"Pe#"T*{&)8"D;?&zd"!;&^'!=&Wr#)#"We".v''="H;$}i#58;""ae<"?;7&ms#!8&zd"#Re(^Y"$v+,yc"/;"J;;#:;${"(F;;"J;9"Ye"#:;Ve0dY"!9&T()""Te7&gX"!;&a{"!8&mc"78"K;:"Ye#"Ve$|I$gs#$a(1<;""^e""W*c"$^d"%Re#&Y'%<":&u&=C;;"We""Te#"3;;&t'58"C;;#3;Ye$$gs#9;9"?;="C;8#3;$vj"$Ty"$WU"!9$Oj#;;""j;8#C;h;$"Y$bt"'#W;f*_{"/$"Wb""fb$V,78;9#?;fb#"Wb*_}"+#8;fb$&gu"=7"D;<"Wb$#H;fb;&Z{#5<"R;#"D;:"T&g<I:;&"V;:"A;:#F;fb""Wb8&ae"9:"Wb""A;$"fb:*g0#Wb$ie"%fb9&iu"1=$J;Wbfb?&O1=8"W;%"F;:#J;V;<&|S"$z/#""(W#?K;="<;9"Wb##C;fb(QT#'9"fb&tn"#b8&n)3<#K;Wb#"fb$jv"+C;:#H;$hh#19"R;#"a;#&z1!>&S%'##?;$vv"-8"3;<#:*e"$U199"j;$"3;;#:;a&|G-?;8"e;%&T"Y"""^;=#:;V;8"e;&"?;7#C;W;<"R;$&g(5""W;<"D;""a&gN")R;<"8&Op"#a;$xh"!R&hM#W;$oe#!a*pf"%%"R&aP"!W&b'Q"a;7"8;&"R;6"?;&"W;7"D;#"a&y*-H;:"V;"&l_#`"%"a;:"F;""e;7#J;V;>"a;#":;8"e;#&OP#$6-""J;6":&b#!A&tU"%f;#&|39""Y;9":;$"a;8$V,);;"W<$uX"$@!>&Z_"!7&|^"$X(!H&u0=K;<"a;""<;9"j;#&hP#)$"^;;&pl"=8"j;%"<;8"^;#"C&fz"!H&P"$XQ#7%"^;7"C;#"a;$eu##H;$eu#${y"+="j;9"$io#t":"a;;"^;:"Y;;"W;;"V;;"T;="R;<"P;<"O;7"M;;*}BS$?q""8q""He""Dql%"Oea#"ReZ##FqJe#":q""Aqm%"Oe`#"ReY#"Ke""Fq"#<qCqm%"Me_#$W"P#Aq""Cq"#7qJe"#>qFqY#"Je`#"Keb#"JeY#"Dq$",q""Hq"&s#!Z$gc$9"^e`#"aeZ#"Jq$T#E.q:q#"Aq^#"VeZ#"^ec&Bl"Kq"#<qFq##0qCqZ#"We_#"Ye`#"^e_#"Re""J&`U$W":}"#.}Oe^#"ee`#"feZ#"ees%"jz]==] }
-- Lord Huron - The Night We Met
_G.PianoSongs[#_G.PianoSongs + 1] = { name = "Lord Huron - The Night We Met", bpm = 120, tpb = 96, data = [==[l$!"`q^*"_lb&"XrR+"Ukx%"Xkh%#>aZsi""E`j""Jbm""Naj""J``""Eaf"">ai""Eai""Jai""Nad""Jag$R"G#Qq`q#"Baf""=ai""Bag&N"P#Bae""=,j""Pb""_b$"@ae""GYh""Pah""Xv""Lv#"Ead""@*Y#IIae""Eae""@af""Eag""@$y"!h*>Mh""@`f"#IpUp#"Bad""=ah"$O$%Ead(u#-bi""Xj$$3KLgf""E*g"">a""Zqd""E_c&j%MNmb""J`c""E`g"">`d""E`h(e&#`c(>`$ag""Bab""QD$"=_a""QC#"BX`""Ea""Qae""B`c""=a#"Qah"#@aSgg""G_d""Lb""Qak"#E`Sgb&P&%Um&$Q)!I$l#O"a""@`b""E`f""@Xc""E`d""I,4#`e&P)c#=a""QGc""Ba#"QHc""E`$"Qf_""B`d""=a$"Uaj"#E`Sfa""@`d""Qa(w&$t+V#h""J`d""Nfb""J^`""EXh"">^b""E^e"">ah""B_^""QF#"JZb&Z#g#4e""Ba""Qfd""=`e""B`b""Qj""E`c""B`e""=`c""@a""Sfe""GZb""L&Z'1"E_""Sf_"$},%Uj%$f)%I^`&e"?@a#"Sak""Um#"EZ`$V,&FG_`""Q?""EZb""@`""Q=g&W$!b*W$`"^`""Ea#"Qgg""B_d"#=`Uah""E`""Sf&u"1#E*Qah"">$c,f"e""Jad""Nmd""J_c""E_d"">Zb""E^f"">$k.!b$w##N?(Z"C_"#N`Q`f"#BaQe""Ie(q&-Bac""Ij2`'Ka""=`g"#E_Sg""Lf^""@`i(Y*^"f"#>^Sf^""E_e"#JaUkf""Nae""J`b&j0$m#s#Ze""Jaf""N`_""UF""J_`"#EaU;k"#BaUH""QHd""U/$"=aB#QkUkG"BYY""E__(R$5a$"SHf""Sg$(g)W"c""Ua%"E*c"">^#"S`Z""Ea("Qp`(j#A^a""J^a""EXc"">Xd(k3#ae&k-5>`%"QF$"NCa$a)MQaj"#BaQg""Igg""=ad""B_(>5j""Ijc""BS_$e'-"E`"#Lf$q0G^c""E)""Qag"">`""Sfa&y87Ub#"J2e""N`f(u*3a""Sbm""Ue&Y$n$EV`"">ag""B_`"">Z""U?`""E^#"U6f"$BaQMUMa""U3%"=b@"Uk""QkI"BZZ""E_`""BZb"#=aSHi""Sf#&p;#_`(q'3a""Sa$">`a&O3!p(W9$q'#_`*R:!b&y.T#>aw#"IG"#>_UFb""@0""U/f""Ba##NHZHb""Z/$"=a@#NbZbF$X%GEa$"ZIe""XA""LA""BZY$W+g#X?b""@a"#L1X1b""U>'"GNW""I3""@)""U1d""Eb$#I-U-E#G1S1D"Qq#$e%/E`c""I_^*b@!e&iC!@$m=+e""IY^$w#`"QId""QH#"@+e"$BaIfQfg""=ae""B^a(P>W"d""Bad"#=aI8#"U7h""Ea$#GcScb(X;+6""E5i(X'#_d&n1/Nl_""Jae(T5$n(U"g""J`a""NBd"#IIUI"">2e"#@0I2P(k%MZMe""Z0$"=a>"Na""ZaF"B`a"#EaZDf""LE##B`XD`"#=_XBe"$@aLDXDf""UI$"G`a"#@)IL""UKe""I.""U-F#G0S0D"Qr$"E%""@$_$+c""I`a*z'+d""Eaj*z'Ct#"I%""QI$"E`b""QF&j&;Ii##BaQif""=`b&pG1Ia"#EaQaf.q5%UHi&U1#dd(RD5)""Q6h""Bq#&_'!a*}'#mc&eB%Eai&z;%Eag(oHY"`e"#>aQFd"#EaQ`""N`i""Qf""If$&dJ$n;(VH+j""Ijd*P</f"#EaSgd(tLM)#"Qag"#>`Sfc""E``""Uq$$y*%Naf*fJ*t+#ah&j+$N<z"E%"J__"#EaUIh"$BaQPUQf""U/""Ia@"UkI"N^Z""Qgd&^L'Ia%"$V5#g#&`)C`c"#E,Uad"">a&"Sa_(x;!c&z4$PS"$cK!d(YN"$X'5e""N``""QE$&i./`##E`Q`i$v;!$&v;(^B+#IjQj#&YB!X&V'c#$EaLgSgi""@_e""Qa#"E*e"">a$"Sfb""E_b""Ua#"J2g""N`g""JZ^$P9=E`f"#>`Ufd""EWb*i*)b""UB*W91#"U4g""UO&nHINd""U1##IaQ/A"UkH"N_`*k'3a""Ia$"SFh&k'^"`d""L_f""Q*""Uaf"#>`S`c"#E_Qpd*NE*n*$t4!b&e1$e.W"3b"">S""IE$"UBa""Ia""Ua'"@W^$yQ"O"NL""ZKa""Z1%"=a?"Nb""ZbC$uB#Z>*QFO"""LD""XCb""=a##LFXFg""X4(t2|"D""G`""UB`""U3""@)g"#I-U-B#G0S0E"Qr#"E%$"@WY"$T4&}Z"*{2$lU"!d&Y<%I^^&S5O"_`""IH$#@*QEc""If"#B`Qfc(S<1`a"$E`I`Q$P,?f"#I8U8""=ag""Sd&d#E@`d"#E-Q?i""Br#">^^&o7&S5!b&i($ld"$t8(s(P#N3c"#>2UI""IHb""I/""U-#"@3f""Ba"#NKZKb""Z0&"=a;$X(MaG"B`_""ZB$"E`_""LF""XF${$v"#=_XFd""@`"#L?X?a""UE$"GX^"#IOUO""@*e""Eb$&b<9C"G+#"S)A"Qs$(t',`<!h*S<+f""@^b$`<I#IJQJ#"E`b"#@`QMe""If$W9&g8!b${B'"Qb#$wa"ABaf"#=aI;#"U9d""S,S*/b"#E*Q/d*c`"!g(_W"+ta""J3(yb"$PT"#ah(c`"$4!f0Qk"%Iaf&xl"%Q`d&f:%Iak&x"/Lag""Q*f*n"!i*p1(Y17EZd"">Qd""E`,>(W$%Eaj$P*'Qm`m*xR"*hl"&bh"Gh"#@a_e#"Pee""Gag""P$W/1""Xr#"Lrf0gm"$`h"${m"!d(T'$d#!f&n%$q.G+f""Ba$"Ul#"Ilc""=af<u#I^g"$E`LjXjc""@aj""E(h$bU"#Z~*e&#`b(t%+_g""E_*}m"!a*St"5xr""Jeb#"Ez]==] }

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

---------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------
pianoPage.Visible = true
refreshPianoModes()
refreshPianoStart()
refreshSongUI()
