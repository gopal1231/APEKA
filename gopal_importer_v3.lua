--[[
    GOPAL IMPORTER V3  (PREMIUM EDITION)
    1. RBXM binary parser (LZ4 pure Lua, INST/PROP/PRNT/END) + parser XML
    2. File scanner rekursif (depth 4) untuk .rbxm/.rbxmx/.rbxl/.rbxlx
    3. Loader: getcustomasset -> rbxasset:// -> temp file, mapping service, inject source
    4. Safe Anchor system
    5. Hook system (namecall, require, GetObjects, LoadAsset)
    6. UI gradient pink+merah, profil Roblox, efek animasi, marquee, jam WIB
]]--

local function GOPAL_ShowError(err)
    local msg = tostring(err)
    pcall(function() if setclipboard then setclipboard(msg) end end)
    pcall(function()
        local sg = Instance.new("ScreenGui")
        sg.Name = "GOPAL_ERR"
        sg.DisplayOrder = 1000
        sg.ResetOnSpawn = false
        if not (gethui and pcall(function() sg.Parent = gethui() end) and sg.Parent) then
            if not pcall(function() sg.Parent = game:GetService("CoreGui") end) or not sg.Parent then
                sg.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
            end
        end
        local f = Instance.new("Frame", sg)
        f.Size = UDim2.new(0.92, 0, 0, 170)
        f.Position = UDim2.new(0.04, 0, 0.05, 0)
        f.BackgroundColor3 = Color3.fromRGB(40, 12, 18)
        Instance.new("UICorner", f)
        local t = Instance.new("TextLabel", f)
        t.Size = UDim2.new(1, -16, 1, -16)
        t.Position = UDim2.new(0, 8, 0, 8)
        t.BackgroundTransparency = 1
        t.TextWrapped = true
        t.TextXAlignment = Enum.TextXAlignment.Left
        t.TextYAlignment = Enum.TextYAlignment.Top
        t.TextColor3 = Color3.fromRGB(255, 200, 205)
        t.TextSize = 11
        t.Font = Enum.Font.Code
        t.Text = "GOPAL ERROR (sudah dicopy ke clipboard, kirim ke Claude):\n" .. msg
        local x = Instance.new("TextButton", f)
        x.Size = UDim2.new(0, 30, 0, 30)
        x.Position = UDim2.new(1, -34, 0, 4)
        x.Text = "x"
        x.BackgroundTransparency = 1
        x.TextColor3 = Color3.fromRGB(255, 255, 255)
        x.TextSize = 18
        x.MouseButton1Click:Connect(function() sg:Destroy() end)
    end)
end

local ok_main, err_main = xpcall(function()
local RECREATE_SCRIPTS = true   -- true: script di dalam rbxm dibuat ulang sebagai instance baru berisi source
local NAME = "GOPAL"   -- ganti dengan namamu (tampil di tombol toggle samping & marquee)

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local CoreGui          = game:GetService("CoreGui")
local InsertService    = game:GetService("InsertService")

local LocalPlayer = Players.LocalPlayer
local genv = (getgenv and getgenv()) or _G

-- ═══════════════════════════════════════════
-- STATE (dipakai ulang kalau script dijalankan lagi, supaya hook tidak dobel)
-- ═══════════════════════════════════════════
local state = genv.GOPAL_LOADER_STATE
if not state then
    state = {
        scriptCache   = setmetatable({}, {__mode = "k"}),  -- Instance -> source
        moduleResults = setmetatable({}, {__mode = "k"}),
        registry      = {},                                -- asset url -> tree hasil parser
        hooksOn       = true,
        anchorOn      = true,
        hooked        = false,
        log           = function() end,
    }
    genv.GOPAL_LOADER_STATE = state
end

-- pecah kerja berat jadi potongan kecil per frame (hanya di thread yang didaftarkan, supaya tidak patah-patah)
state.sliceThreads = state.sliceThreads or setmetatable({}, {__mode = "k"})
local sliceT = os.clock()
local function slice()
    if state.sliceThreads[coroutine.running()] and os.clock() - sliceT > 0.004 then
        task.wait()
        sliceT = os.clock()
    end
end

local COLORS = {
    BG      = Color3.fromRGB(10, 14, 22),
    HEADER  = Color3.fromRGB(14, 20, 32),
    CARD    = Color3.fromRGB(20, 28, 42),
    CYAN    = Color3.fromRGB(0, 220, 255),
    CYAN_HV = Color3.fromRGB(90, 235, 255),
    GOLD    = Color3.fromRGB(255, 196, 64),
    SUCCESS = Color3.fromRGB(65, 220, 135),
    DANGER  = Color3.fromRGB(255, 75, 95),
    WARNING = Color3.fromRGB(255, 185, 65),
    TEXT    = Color3.fromRGB(240, 246, 255),
    SUB     = Color3.fromRGB(140, 156, 180),
    BORDER  = Color3.fromRGB(36, 52, 76),
}

-- ═══════════════════════════════════════════
-- 1. RBXM PARSER
-- ═══════════════════════════════════════════
local SCRIPT_CLASSES = {Script = true, LocalScript = true, ModuleScript = true}

local function u32(s, p)
    local a, b, c, d = s:byte(p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function readStr(s, p)
    local len = u32(s, p)
    return s:sub(p + 4, p + 3 + len), p + 4 + len
end

-- referent array: byte-interleaved, big-endian, zigzag, delta
local function readRefs(s, p, count)
    local refs, acc = {}, 0
    for i = 1, count do
        local b1 = s:byte(p + i - 1)
        local b2 = s:byte(p + count + i - 1)
        local b3 = s:byte(p + 2 * count + i - 1)
        local b4 = s:byte(p + 3 * count + i - 1)
        local v = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        local d = (v % 2 == 0) and (v / 2) or -((v + 1) / 2)
        acc = acc + d
        refs[i] = acc
    end
    return refs, p + count * 4
end

-- LZ4: pakai fungsi bawaan executor kalau ada (jauh lebih cepat), kalau tidak pure Lua
local function nativeLz4(src, outSize)
    for _, name in ipairs({"lz4decompress", "lz4_decompress", "LZ4Decompress"}) do
        local f = genv[name]
        if type(f) == "function" then
            local ok, res = pcall(f, src, outSize)
            if ok and type(res) == "string" and #res == outSize then return res end
        end
    end
    local z = genv.lz4
    if type(z) == "table" and type(z.decompress) == "function" then
        local ok, res = pcall(z.decompress, src, outSize)
        if ok and type(res) == "string" and #res == outSize then return res end
    end
    return nil
end

-- LZ4 block decompressor (pure Lua)
local function lz4decompress(src, outSize)
    local nat = nativeLz4(src, outSize)
    if nat then return nat end
    local out = {}
    local i, o, n = 1, 0, #src
    local tick = 0
    while i <= n do
        tick = tick + 1
        if tick % 64 == 0 then slice() end
        local token = src:byte(i)
        i = i + 1
        local lit = bit32.rshift(token, 4)
        if lit == 15 then
            local b
            repeat
                b = src:byte(i)
                i = i + 1
                lit = lit + b
            until b ~= 255
        end
        local done = 0
        while done < lit do
            local cnt = math.min(4000, lit - done)
            local t = {src:byte(i + done, i + done + cnt - 1)}
            for k = 1, cnt do out[o + done + k] = t[k] end
            done = done + cnt
        end
        i = i + lit
        o = o + lit
        if i > n then break end
        local offset = src:byte(i) + src:byte(i + 1) * 256
        i = i + 2
        local mlen = bit32.band(token, 15)
        if mlen == 15 then
            local b
            repeat
                b = src:byte(i)
                i = i + 1
                mlen = mlen + b
            until b ~= 255
        end
        mlen = mlen + 4
        local from = o - offset
        for k = 1, mlen do out[o + k] = out[from + k] end
        o = o + mlen
    end
    local parts = {}
    for a = 1, o, 4000 do
        parts[#parts + 1] = string.char(table.unpack(out, a, math.min(a + 3999, o)))
        slice()
    end
    return table.concat(parts)
end

-- zstd: tidak ada implementasi pure Lua di sini, pakai fungsi executor kalau ada
local function zstdDecode(raw, ulen)
    for _, name in ipairs({"zstd_decompress", "zstddecompress", "zstdDecompress"}) do
        local f = genv[name]
        if type(f) == "function" then
            local ok, res = pcall(f, raw, ulen)
            if ok and type(res) == "string" then return res end
            ok, res = pcall(f, raw)
            if ok and type(res) == "string" then return res end
        end
    end
    local z = genv.zstd
    if type(z) == "table" and type(z.decompress) == "function" then
        local ok, res = pcall(z.decompress, raw)
        if ok and type(res) == "string" then return res end
    end
    return nil
end

local function newNode(class)
    return {Class = class, Name = nil, Source = nil, Children = {}}
end

local function parseBinary(data)
    if data:sub(1, 8) ~= "<roblox!" then return nil, "bukan file rbx biner" end
    local p = 33 -- header 32 byte
    local classes, inst, roots = {}, {}, {}
    local skipped, scripts = 0, 0

    while p + 15 <= #data do
        slice()
        local cname = data:sub(p, p + 3)
        local clen, ulen = u32(data, p + 4), u32(data, p + 8)
        p = p + 16
        local cd
        if clen == 0 then
            cd = data:sub(p, p + ulen - 1)
            p = p + ulen
        else
            local raw = data:sub(p, p + clen - 1)
            p = p + clen
            if raw:sub(1, 4) == "\40\181\47\253" then
                cd = zstdDecode(raw, ulen)
                if not cd then skipped = skipped + 1 end
            else
                local ok, res = pcall(lz4decompress, raw, ulen)
                cd = ok and res or nil
                if not ok then skipped = skipped + 1 end
            end
        end

        if cname == "END\0" then break end

        if cd then
            if cname == "INST" then
                local cid = u32(cd, 1)
                local className, q = readStr(cd, 5)
                q = q + 1 -- object format
                local count = u32(cd, q)
                local refs = readRefs(cd, q + 4, count)
                classes[cid] = {name = className, refs = refs}
                for _, r in ipairs(refs) do inst[r] = newNode(className) end

            elseif cname == "PROP" then
                local cid = u32(cd, 1)
                local pname, q = readStr(cd, 5)
                local ptype = cd:byte(q)
                q = q + 1
                if ptype == 1 and (pname == "Name" or pname == "Source") then
                    local cls = classes[cid]
                    if cls then
                        for _, r in ipairs(cls.refs) do
                            slice()
                            local str
                            str, q = readStr(cd, q)
                            local node = inst[r]
                            if node then node[pname] = str end
                        end
                    end
                end

            elseif cname == "PRNT" then
                local count = u32(cd, 2)
                local childRefs, q = readRefs(cd, 6, count)
                local parentRefs = readRefs(cd, q, count)
                for i = 1, count do
                    local node = inst[childRefs[i]]
                    if node then
                        local pr = parentRefs[i]
                        if pr == -1 then
                            roots[#roots + 1] = node
                        elseif inst[pr] then
                            table.insert(inst[pr].Children, node)
                        end
                    end
                end
            end
        end
    end

    for _, node in pairs(inst) do
        node.Name = node.Name or node.Class
        if node.Source and SCRIPT_CLASSES[node.Class] then scripts = scripts + 1 end
    end
    return {roots = roots, scripts = scripts, skipped = skipped}
end

local function xmlUnescape(s)
    return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

local function parseXml(data)
    local roots, stack, scripts = {}, {}, 0
    local pos = 1
    while true do
        local s, e, closing, tag, attrs = data:find("<(/?)([%w_]+)([^>]*)>", pos)
        if not s then break end
        pos = e + 1
        if tag == "Item" then
            if closing == "" then
                local node = newNode(attrs:match('class="([^"]*)"') or "Instance")
                local top = stack[#stack]
                if top then table.insert(top.Children, node) else table.insert(roots, node) end
                if attrs:sub(-1) ~= "/" then table.insert(stack, node) end
            else
                table.remove(stack)
            end
        elseif closing == "" and (tag == "string" or tag == "ProtectedString") then
            local pname = attrs:match('name="([^"]*)"')
            if pname == "Name" or pname == "Source" then
                local val
                if data:find("<![CDATA[", pos, true) == pos then
                    local ce, cend = data:find("]]>", pos + 9, true)
                    if ce then
                        val = data:sub(pos + 9, ce - 1)
                        pos = cend + 1
                    end
                else
                    local xs, xe = data:find("</" .. tag .. ">", pos, true)
                    if xs then
                        val = xmlUnescape(data:sub(pos, xs - 1))
                        pos = xe + 1
                    end
                end
                local top = stack[#stack]
                if top and val then top[pname] = val end
            end
        end
    end
    local function fix(n)
        n.Name = n.Name or n.Class
        if n.Source and SCRIPT_CLASSES[n.Class] then scripts = scripts + 1 end
        for _, c in ipairs(n.Children) do fix(c) end
    end
    for _, r in ipairs(roots) do fix(r) end
    return {roots = roots, scripts = scripts, skipped = 0}
end

local function parseAny(data)
    if data:sub(1, 8) == "<roblox!" then return parseBinary(data) end
    if data:find("<roblox", 1, true) then return parseXml(data) end
    return nil, "format tidak dikenali"
end

-- Cocokkan tree parser dengan Instance hasil load, simpan Source ke cache
local function injectSources(nodes, insts)
    local count, used = 0, {}
    for _, pn in ipairs(nodes) do
        for _, ins in ipairs(insts) do
            if not used[ins] and ins.Name == pn.Name and ins.ClassName == pn.Class then
                used[ins] = true
                if pn.Source and SCRIPT_CLASSES[pn.Class] then
                    state.scriptCache[ins] = pn.Source
                    count = count + 1
                    if setscriptsource then pcall(setscriptsource, ins, pn.Source) end
                end
                count = count + injectSources(pn.Children, ins:GetChildren())
                break
            end
        end
    end
    return count
end


-- Buat ulang script hasil parser sebagai instance baru (Source terisi) di posisi yang sama
local function writeSource(scr, srcText)
    if setscriptsource and pcall(setscriptsource, scr, srcText) then return "setscriptsource" end
    if sethiddenproperty and pcall(sethiddenproperty, scr, "Source", srcText) then return "sethiddenproperty" end
    if pcall(function() scr.Source = srcText end) then return "Source" end
    return nil
end

-- Studio Lite menyimpan source script di TextBox anak bernama SL_CodeTextBox (RichText, berwarna) lengkap dengan
-- anak SaveChangesTo (ObjectValue) dan SL_ColorizeAndEditLocal (LocalScript). Script yang punya anak ini
-- dibuka dalam mode edit, yang tidak punya dibuka read only.
local LUA_KW = {}
for _, k in ipairs({"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "continue"}) do
    LUA_KW[k] = true
end

local function xmlEsc(t)
    return (t:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function plainFromRich(t)
    t = t:gsub("<[^>]+>", "")
    t = t:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    return t
end

-- pewarna sederhana: komentar hijau, string merah, keyword biru, angka oranye (format sama seperti Studio Lite)
local function colorizeSource(src)
    local out, i, n, cnt = {}, 1, #src, 0
    local function push(color, text)
        local e = xmlEsc(text)
        if color then
            out[#out + 1] = '<font color="' .. color .. '">' .. e .. '</font>'
        else
            out[#out + 1] = e
        end
    end
    while i <= n do
        cnt = cnt + 1
        if cnt % 3000 == 0 then slice() end
        local c = src:sub(i, i)
        if src:sub(i, i + 1) == "--" then
            local lvl = src:match("^%-%-%[(=*)%[", i)
            local e
            if lvl then
                local _, e2 = src:find("]" .. lvl .. "]", i, true)
                e = e2 or n
            else
                e = (src:find("\n", i, true) or (n + 1)) - 1
            end
            push("#00ff00", src:sub(i, e))
            i = e + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" then j = j + 2
                elseif d == c or d == "\n" then break
                else j = j + 1 end
            end
            push("#ff5555", src:sub(i, j))
            i = j + 1
        elseif c:match("[%a_]") then
            local w = src:match("^[%w_]+", i)
            push(LUA_KW[w] and "#7777ff" or nil, w)
            i = i + #w
        elseif c:match("%d") then
            local w = src:match("^%d[%w%.]*", i)
            push("#ffaa00", w)
            i = i + #w
        else
            push(nil, c)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- cari kotak kode asli buatan Studio Lite (berisi LocalScript editor) untuk di-clone
local function findCodeBoxTemplate()
    if state.codeBoxTemplate and state.codeBoxTemplate.Parent then return state.codeBoxTemplate end
    local function usable(d)
        return d.Name == "SL_CodeTextBox" and d:IsA("TextBox") and d:FindFirstChild("SL_ColorizeAndEditLocal")
            and d.Parent and d.Parent:IsA("LuaSourceContainer")
    end
    local rs = game:GetService("ReplicatedStorage")
    local slf = rs:FindFirstChild("StudioLiteFolder")
    for _, root in ipairs({slf and slf:FindFirstChild("New"), slf}) do
        if root then
            for _, d in ipairs(root:GetDescendants()) do
                if usable(d) then state.codeBoxTemplate = d return d end
            end
        end
    end
    if not state.codeBoxSearched then
        state.codeBoxSearched = true
        for _, d in ipairs(game:GetDescendants()) do
            if usable(d) then state.codeBoxTemplate = d return d end
        end
    end
    return nil
end

local function findEditorLocal()
    if state.editorLocal and state.editorLocal.Parent then return state.editorLocal end
    if state.editorLocalSearched then return nil end
    state.editorLocalSearched = true
    for _, d in ipairs(game:GetDescendants()) do
        if d.Name == "SL_ColorizeAndEditLocal" and d:IsA("LocalScript") then
            state.editorLocal = d
            return d
        end
    end
    return nil
end

local function attachCodeBox(scr, srcText)
    pcall(function()
        for _, c in ipairs(scr:GetChildren()) do
            if c.Name == "SL_CodeTextBox" then c:Destroy() end
        end
        local rich = colorizeSource(srcText)
        local tpl = findCodeBoxTemplate()
        local tb
        if tpl then
            tb = tpl:Clone()
        else
            -- tidak ada contoh asli: bangun dengan properti yang sama seperti kotak kode asli
            tb = Instance.new("TextBox")
            tb.MultiLine = true
            tb.ClearTextOnFocus = false
            tb.TextWrapped = false
            tb.TextXAlignment = Enum.TextXAlignment.Left
            tb.TextYAlignment = Enum.TextYAlignment.Top
            tb.AutomaticSize = Enum.AutomaticSize.XY
            tb.Size = UDim2.new(1, 0, 1, 0)
            tb.Position = UDim2.new(0, 52, 0, 0)
            tb.ZIndex = 4
            tb.RichText = true
            tb.Font = Enum.Font.Code
            tb.TextSize = 14
            tb.BackgroundColor3 = Color3.new(1, 1, 1)
            tb.TextColor3 = Color3.new(0, 0, 0)
            tb.ShowNativeInput = false
            local sv = Instance.new("ObjectValue")
            sv.Name = "SaveChangesTo"
            sv.Parent = tb
            local el = findEditorLocal()
            if el then el:Clone().Parent = tb end
        end
        tb.Name = "SL_CodeTextBox"
        tb.Text = rich
        local sv = tb:FindFirstChild("SaveChangesTo")
        if sv and sv:IsA("ObjectValue") then sv.Value = tb end   -- pada script asli menunjuk ke SL_CodeTextBox miliknya sendiri
        tb.Parent = scr
        local st = state.boxStats
        if st then
            if tpl then st.tpl = st.tpl + 1 else st.manual = st.manual + 1 end
            if not tb:FindFirstChild("SL_ColorizeAndEditLocal") then st.noLocal = st.noLocal + 1 end
        end
    end)
end

local function recreateScripts(nodes, insts, stats)
    local used = {}
    for _, pn in ipairs(nodes) do
        for i, ins in ipairs(insts) do
            if not used[ins] and ins.Name == pn.Name and ins.ClassName == pn.Class then
                used[ins] = true
                -- proses anak dulu selagi masih di bawah instance lama
                recreateScripts(pn.Children, ins:GetChildren(), stats)
                if pn.Source and SCRIPT_CLASSES[pn.Class] then
                    local okN, fresh = pcall(Instance.new, pn.Class)
                    if okN and fresh then
                        fresh.Name = ins.Name
                        pcall(function() fresh.Disabled = ins.Disabled end)
                        pcall(function() fresh.RunContext = ins.RunContext end)
                        local how = writeSource(fresh, pn.Source) or "SL_CodeTextBox"
                        if how then
                            for _, c in ipairs(ins:GetChildren()) do
                                if not c:IsA("PackageLink") then
                                    pcall(function() c.Parent = fresh end)
                                end
                            end
                            attachCodeBox(fresh, pn.Source)
                            local okP = pcall(function() fresh.Parent = ins.Parent end)
                            if okP then
                                insts[i] = fresh
                                state.scriptCache[fresh] = pn.Source
                                state.scriptCache[ins] = nil
                                pcall(function() ins:Destroy() end)
                                stats.made = stats.made + 1
                                stats.how = how
                            else
                                pcall(function() fresh:Destroy() end)
                                stats.failed = stats.failed + 1
                            end
                        else
                            pcall(function() fresh:Destroy() end)
                            stats.failed = stats.failed + 1
                        end
                    else
                        stats.failed = stats.failed + 1
                    end
                end
                break
            end
        end
    end
end

-- ═══════════════════════════════════════════
-- 4. SAFE ANCHOR
-- ═══════════════════════════════════════════
local function isCharacterPart(part)
    local cur = part.Parent
    while cur and cur ~= workspace do
        if cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid") then return true end
        cur = cur.Parent
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character and part:IsDescendantOf(plr.Character) then return true end
    end
    return false
end

local function safeAnchor(part)
    if not part:IsA("BasePart") or part:IsA("Terrain") then return end
    if isCharacterPart(part) then return end
    pcall(function()
        part.Anchored = true
        part.AssemblyLinearVelocity = Vector3.zero
        part.AssemblyAngularVelocity = Vector3.zero
        for _, d in ipairs(part:GetChildren()) do
            if d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("WeldConstraint") then
                d:Destroy()
            end
        end
    end)
end
state.safeAnchor = safeAnchor

if state.anchorConn then state.anchorConn:Disconnect() end
state.anchorConn = workspace.DescendantAdded:Connect(function(d)
    if state.anchorOn and d:IsA("BasePart") then
        task.defer(safeAnchor, d)
    end
end)

-- ═══════════════════════════════════════════
-- 5. HOOK SYSTEM
-- ═══════════════════════════════════════════
local function wrap(f) return newcclosure and newcclosure(f) or f end

local function anchorResults(res)
    if not state.anchorOn then return end
    local list = (type(res) == "table") and res or {res}
    for _, o in ipairs(list) do
        if typeof(o) == "Instance" then
            if o:IsA("BasePart") then state.safeAnchor(o) end
            for _, d in ipairs(o:GetDescendants()) do
                if d:IsA("BasePart") then state.safeAnchor(d) end
            end
        end
    end
end


-- ═══════════════════════════════════════════
-- DEBUG + RESOLVER untuk remote script source
-- ═══════════════════════════════════════════
state.debugLines = state.debugLines or {}

local function describe(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "string" then
        return '"' .. (#v > 60 and (v:sub(1, 60) .. "...(" .. #v .. ")") or v) .. '"'
    elseif t == "Instance" then
        local ok, n = pcall(function() return v.ClassName .. ":" .. v:GetFullName() end)
        return ok and n or "Instance"
    elseif t == "table" then
        if depth >= 2 then return "{...}" end
        local parts, c = {}, 0
        for k, val in pairs(v) do
            c = c + 1
            if c > 8 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. describe(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v) .. "(" .. t .. ")"
end

local function dbg(tag, args, res)
    local line = os.date("!%H:%M:%S") .. " " .. tag .. " args=" .. describe(args)
    if res ~= nil then line = line .. " -> " .. describe(res) end
    table.insert(state.debugLines, line)
    if #state.debugLines > 200 then table.remove(state.debugLines, 1) end
end

local function dbgw(msg)
    table.insert(state.debugLines, os.date("!%H:%M:%S") .. " " .. tostring(msg))
    if #state.debugLines > 200 then table.remove(state.debugLines, 1) end
end

local function resolveScript(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "Instance" then
        if state.scriptCache[v] then return v end
    elseif t == "string" then
        if #v == 0 or #v > 300 then return nil end
        local cand = v:gsub("[/\\]", "."):gsub("^game%.", "")
        local last = cand:match("[^%.]+$") or cand
        local nameHit, count = nil, 0
        local function endsWith(full, x) return #x > 0 and full:sub(-#x) == x end
        for inst in pairs(state.scriptCache) do
            local okF, full = pcall(function() return inst:GetFullName() end)
            if okF then
                local norm = full:gsub("_GOPAL_RBXM%.", "")
                if cand == full or cand == norm or endsWith(full, cand) or endsWith(norm, cand) then
                    return inst
                end
            end
            -- editor Studio Lite meminta dengan format ClassName..Name, mis. "ScriptDanceCatalogCompat"
            local cn = inst.ClassName .. inst.Name
            if cn == v or cn == cand then return inst end
            if inst.Name == cand or inst.Name == last then
                nameHit, count = inst, count + 1
            end
        end
        if count == 1 then return nameHit end
    elseif t == "table" and depth < 3 then
        for _, val in pairs(v) do
            local r = resolveScript(val, depth + 1)
            if r then return r end
        end
    end
    return nil
end

local SRC_KEYS = {source = true, content = true, code = true, body = true, text = true, script = true, data = true}

local function deepClone(t, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 4 then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deepClone(v, depth + 1) end
    return c
end

-- ganti semua field bertipe string dengan key mirip "source" di dalam tabel hasil
local function patchSource(t, src, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 4 then return false end
    local hit = false
    for k, v in pairs(t) do
        if type(v) == "string" and type(k) == "string" and SRC_KEYS[k:lower()] then
            t[k] = src
            hit = true
        elseif type(v) == "table" then
            if patchSource(v, src, depth + 1) then hit = true end
        end
    end
    return hit
end

-- Editor Studio Lite: source dicari langsung dari file .rbxm setiap kali diminta (tanpa cache source)
local function flattenArgs(v, out, depth)
    depth = depth or 0
    local t = typeof(v)
    if t == "string" or t == "Instance" then
        out[#out + 1] = v
    elseif t == "table" and depth < 3 then
        for _, x in pairs(v) do flattenArgs(x, out, depth + 1) end
    end
    return out
end

local function nodeScore(n, dotted, q)
    if typeof(q) == "Instance" then
        if n.Name == q.Name and n.Class == q.ClassName then return 2 end
        return 0
    end
    if #q == 0 or #q > 300 then return 0 end
    local cand = q:gsub("[/\\]", "."):gsub("^game%.", "")
    if n.Class .. n.Name == q or n.Class .. n.Name == cand then return 2 end
    if #cand > 0 and (cand == dotted or dotted:sub(-#cand) == cand) then return 2 end
    local last = cand:match("[^%.]+$") or cand
    if n.Name == q or n.Name == cand or n.Name == last then return 1 end
    return 0
end

local function walkForSource(nodes, path, queries, weak)
    for _, n in ipairs(nodes) do
        local dotted = (path == "") and n.Name or (path .. "." .. n.Name)
        if SCRIPT_CLASSES[n.Class] and n.Source then
            for _, q in ipairs(queries) do
                local sc = nodeScore(n, dotted, q)
                if sc == 2 then return n.Source end
                if sc == 1 then weak[#weak + 1] = n.Source end
            end
        end
        local r = walkForSource(n.Children, dotted, queries, weak)
        if r then return r end
    end
    return nil
end

-- Index script per file (disimpan di memori + file disk), supaya buka script tidak parse ulang
local HttpService = game:GetService("HttpService")
local INDEX_FILE = "gopal_index.json"

state.edits = state.edits or {}          -- hasil edit dari editor (key = file|path script)
state.idx = state.idx or {}              -- daftar entri script: {Path, Class, Name, dotted, Source}
state.indexedFiles = state.indexedFiles or {}   -- path -> ukuran file saat di-index

local function unwrapNodes(tree)
    local nodes = tree.roots
    if #nodes == 1 and nodes[1].Class == "DataModel" then nodes = nodes[1].Children end
    return nodes
end

local function loadDiskIndex()
    if state.diskLoaded then return end
    state.diskLoaded = true
    if not (readfile and isfile) then return end
    local ok, raw = pcall(function()
        if isfile(INDEX_FILE) then return readfile(INDEX_FILE) end
    end)
    if ok and type(raw) == "string" then
        local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
        if ok2 and type(data) == "table" and data.v == 1 and type(data.files) == "table" then
            state.diskFiles = data.files
        end
    end
end

local function saveDiskIndex()
    if not writefile then return end
    local files = {}
    for path, size in pairs(state.indexedFiles) do files[path] = {size = size, scripts = {}} end
    for _, e in ipairs(state.idx) do
        local ff = files[e.Path]
        if ff then ff.scripts[#ff.scripts + 1] = {c = e.Class, n = e.Name, d = e.dotted, s = e.Source} end
    end
    local ok, raw = pcall(HttpService.JSONEncode, HttpService, {v = 1, files = files})
    if ok and type(raw) == "string" then pcall(writefile, INDEX_FILE, raw) end
end

-- peta lookup supaya mencari script O(1), bukan menyisir ribuan entri
state.byCN, state.byName, state.byDotted = state.byCN or {}, state.byName or {}, state.byDotted or {}

local function mapAdd(e)
    local k = (e.Class or "") .. (e.Name or "")
    local l = state.byCN[k]
    if not l then l = {} state.byCN[k] = l end
    l[#l + 1] = e
    local l2 = state.byName[e.Name or ""]
    if not l2 then l2 = {} state.byName[e.Name or ""] = l2 end
    l2[#l2 + 1] = e
    if e.dotted and not state.byDotted[e.dotted] then state.byDotted[e.dotted] = e end
end

local function mapReset()
    state.byCN, state.byName, state.byDotted = {}, {}, {}
    for _, e in ipairs(state.idx) do mapAdd(e) end
end

local function commitEntries(f, entries)
    -- thread lain mungkin sudah menyelesaikan file ini selama kita parse
    if state.indexedFiles[f.path] == f.size then return end
    local hadOld = state.indexedFiles[f.path] ~= nil
    if hadOld then
        local kept = {}
        for _, e in ipairs(state.idx) do
            if e.Path ~= f.path then kept[#kept + 1] = e end
        end
        state.idx = kept
    end
    for _, e in ipairs(entries) do state.idx[#state.idx + 1] = e end
    state.indexedFiles[f.path] = f.size
    if hadOld then mapReset() else for _, e in ipairs(entries) do mapAdd(e) end end
end

local function entriesFromNodes(f, nodes)
    local entries = {}
    local function walk(ns, path)
        for _, n in ipairs(ns) do
            local dotted = (path == "") and n.Name or (path .. "." .. n.Name)
            if SCRIPT_CLASSES[n.Class] and n.Source then
                entries[#entries + 1] = {Path = f.path, Class = n.Class, Name = n.Name, dotted = dotted, Source = n.Source}
            end
            walk(n.Children, dotted)
        end
    end
    walk(nodes, "")
    return entries
end

-- dipakai loader: file yang baru di-INSERT sudah ter-parse, jadi langsung didaftarkan (tanpa parse ulang)
state.indexFromTree = function(f, nodes)
    commitEntries(f, entriesFromNodes(f, nodes))
end

local function indexFile(f)
    if state.indexedFiles[f.path] == f.size then return end
    local entries
    local disk = state.diskFiles and state.diskFiles[f.path]
    if disk and disk.size == f.size and type(disk.scripts) == "table" then
        entries = {}
        for _, e in ipairs(disk.scripts) do
            entries[#entries + 1] = {Path = f.path, Class = e.c, Name = e.n, dotted = e.d, Source = e.s}
        end
    else
        local okR, data = pcall(readfile, f.path)
        if not okR or type(data) ~= "string" then return end
        local okP, tree = pcall(parseAny, data)
        if not okP or not tree then return end
        entries = entriesFromNodes(f, unwrapNodes(tree))
    end
    commitEntries(f, entries)
end

-- dipanggil setelah SCAN: sisa file di-index di background (dipecah per frame)
state.startIndex = function(flist)
    local token = {}
    state.indexToken = token
    task.spawn(function()
        state.sliceThreads[coroutine.running()] = true
        task.wait(1.5)
        loadDiskIndex()
        local changed = false
        for _, f in ipairs(flist) do
            if state.indexToken ~= token then return end
            if state.indexedFiles[f.path] ~= f.size then
                indexFile(f)
                changed = true
            end
            task.wait()
        end
        if changed then saveDiskIndex() end
    end)
end

local function searchIdx(queries)
    local weak = {}
    for _, q in ipairs(queries) do
        if typeof(q) == "Instance" then
            local l = state.byCN[q.ClassName .. q.Name]
            if l then return l[1], weak end
        elseif #q > 0 and #q <= 300 then
            local cand = q:gsub("[/\\]", "."):gsub("^game%.", "")
            local l = state.byCN[q] or state.byCN[cand]
            if l then return l[1], weak end
            local e = state.byDotted[cand]
            if e then return e, weak end
            if cand:find(".", 1, true) then
                for _, x in ipairs(state.idx) do
                    if #x.dotted >= #cand and x.dotted:sub(-#cand) == cand then return x, weak end
                end
            end
            local last = cand:match("[^%.]+$") or cand
            local w = state.byName[q] or state.byName[cand] or state.byName[last]
            if w then for _, x in ipairs(w) do weak[#weak + 1] = x end end
        end
    end
    return nil, weak
end

-- return: source, key
local function findSourceInFiles(args)
    local queries = flattenArgs(args, {})
    if #queries == 0 then return nil end
    loadDiskIndex()

    local best, weak = searchIdx(queries)
    if not best then
        -- belum ke-index: parse file satu per satu, berhenti begitu ketemu (tidak menunggu semua file)
        local flist = state.fileList
        if (not flist or #flist == 0) and state.scanFn then flist = state.scanFn() end
        for _, f in ipairs(flist or {}) do
            if state.indexedFiles[f.path] ~= f.size then
                indexFile(f)
                best, weak = searchIdx(queries)
                if best then break end
            end
        end
    end
    if not best and #weak == 1 then best = weak[1] end
    if not best then return nil end

    local key = best.Path .. "|" .. best.dotted
    state.lastBest = best
    return state.edits[key] or best.Source, key
end

local function handleInvoke(nm, oldCall, self, ...)
    local args = {...}
    dbg("Invoke:" .. nm, args)
    local t0 = os.clock()
    local src, key = findSourceInFiles(args)
    dbgw(string.format("cari source: %s, %d ms, index=%d script",
        src and "ketemu" or "TIDAK ketemu", (os.clock() - t0) * 1000, #state.idx))

    if not src then
        state.lastBest = nil
        -- bukan script dari file kita: teruskan ke server, catat balasan aslinya, dan pelajari bentuknya
        local r = table.pack(pcall(oldCall, self, ...))
        if r[1] then
            dbg("Asli:" .. nm, args, r[2])
            if nm == "GetScriptSourceServerFunction" then
                if type(r[2]) == "table" and not state.respTemplate then state.respTemplate = deepClone(r[2]) end
            else
                if r[2] ~= nil then state.saveReply = r[2] end
            end
            return table.unpack(r, 2, r.n)
        end
        error(r[2], 0)
    end

    -- script hasil INSERT punya SL_CodeTextBox: pakai isinya (paling baru, termasuk hasil edit di Studio Lite)
    if state.lastBest then
        local e = state.lastBest
        for inst in pairs(state.scriptCache) do
            local okL, txt = pcall(function()
                if inst.Parent and inst.Name == e.Name and inst.ClassName == e.Class then
                    local tb = inst:FindFirstChild("SL_CodeTextBox")
                    if tb then return plainFromRich(tb.Text) end
                end
            end)
            if okL and type(txt) == "string" then
                src = txt
                break
            end
        end
    end

    if nm == "GetScriptSourceServerFunction" then
        if state.respTemplate then
            local c = deepClone(state.respTemplate)
            if not patchSource(c, src) then c.Source = src end
            return c
        end
        return src
    else
        -- Save dari editor: simpan hasil edit, buka lagi akan menampilkan versi yang diedit
        local newSrc
        for _, a in ipairs(args) do
            if type(a) == "string" and (not newSrc or #a > #newSrc) then newSrc = a end
        end
        if newSrc and key then state.edits[key] = newSrc end
        dbg("SaveSource", args, key)
        if state.saveReply ~= nil then return state.saveReply end
        return true
    end
end
state.invokeHandler = handleInvoke

-- catat semua remote lain milik editor (StudioLiteFolder) supaya kelihatan apa yang menentukan mode edit
state.spyRemote = function(self, method, ...)
    local ok, par = pcall(function() return self.Parent end)
    if ok and par and par.Name == "StudioLiteFolder" then
        local nm = self.Name
        if nm ~= "GetScriptSourceServerFunction" and nm ~= "SaveScriptSourceServerFunction" then
            dbg("Remote:" .. nm .. "." .. method, {...})
        end
    end
end

local function installHooks()
    if state.hooked then return end
    state.hooked = true

    -- __namecall + hook langsung InvokeServer: GetScriptSourceServerFunction / SaveScriptSourceServerFunction
    local function isSrcRemote(self)
        if typeof(self) ~= "Instance" then return nil end
        local nm = self.Name
        if nm == "GetScriptSourceServerFunction" or nm == "SaveScriptSourceServerFunction" then return nm end
        return nil
    end

    if hookmetamethod and getnamecallmethod then
        local okH, errH = pcall(function()
            local oldNC
            oldNC = hookmetamethod(game, "__namecall", wrap(function(self, ...)
                local method = getnamecallmethod()
                if state.hooksOn and (method == "InvokeServer" or method == "FireServer") and typeof(self) == "Instance" and state.spyRemote then
                    pcall(state.spyRemote, self, method, ...)
                    if setnamecallmethod then pcall(setnamecallmethod, method) end
                end
                if state.hooksOn and method == "InvokeServer" and state.invokeHandler then
                    local nm = isSrcRemote(self)
                    if nm then
                        return state.invokeHandler(nm, function(s, ...)
                            if setnamecallmethod then pcall(setnamecallmethod, method) end
                            return oldNC(s, ...)
                        end, self, ...)
                    end
                end
                return oldNC(self, ...)
            end))
        end)
        if not okH then dbgw("hook __namecall gagal: " .. tostring(errH)) end
    else
        dbgw("hookmetamethod/getnamecallmethod tidak tersedia")
    end

    if hookfunction then
        local okD, errD = pcall(function()
            local probe = Instance.new("RemoteFunction")
            local oldInv
            oldInv = hookfunction(probe.InvokeServer, wrap(function(self, ...)
                if state.hooksOn and state.spyRemote then pcall(state.spyRemote, self, "InvokeServer", ...) end
                if state.hooksOn and state.invokeHandler then
                    local nm = isSrcRemote(self)
                    if nm then return state.invokeHandler(nm, oldInv, self, ...) end
                end
                return oldInv(self, ...)
            end))
        end)
        if not okD then dbgw("hook InvokeServer gagal: " .. tostring(errD)) end
        pcall(function()
            local ev = Instance.new("RemoteEvent")
            local oldFire
            oldFire = hookfunction(ev.FireServer, wrap(function(self, ...)
                if state.hooksOn and state.spyRemote then pcall(state.spyRemote, self, "FireServer", ...) end
                return oldFire(self, ...)
            end))
        end)
    end

    -- require: jalankan ModuleScript dari source cache
    if hookfunction then
        pcall(function()
            local oldReq
            oldReq = hookfunction(require, wrap(function(m, ...)
                if state.hooksOn and typeof(m) == "Instance" and m:IsA("ModuleScript") and state.scriptCache[m] then
                    local cached = state.moduleResults[m]
                    if cached then return cached[1] end
                    local fn, err = loadstring(state.scriptCache[m], "=" .. m:GetFullName())
                    if fn then
                        pcall(function()
                            setfenv(fn, setmetatable({script = m}, {__index = getfenv(1)}))
                        end)
                        local ok, res = pcall(fn)
                        if ok then
                            state.moduleResults[m] = {res}
                            return res
                        end
                        dbgw("module error: " .. tostring(res))
                    else
                        dbgw("loadstring gagal: " .. tostring(err))
                    end
                end
                return oldReq(m, ...)
            end))
        end)

        -- game.GetObjects
        pcall(function()
            local oldGO
            oldGO = hookfunction(game.GetObjects, wrap(function(self, url, ...)
                local res = oldGO(self, url, ...)
                if state.hooksOn then
                    pcall(function()
                        local tree = state.registry[tostring(url)]
                        if tree and type(res) == "table" then injectSources(tree.roots, res) end
                        anchorResults(res)
                    end)
                end
                return res
            end))
        end)

        -- InsertService:LoadAsset
        pcall(function()
            local oldLA
            oldLA = hookfunction(InsertService.LoadAsset, wrap(function(self, id, ...)
                local res = oldLA(self, id, ...)
                if state.hooksOn then
                    pcall(function()
                        local tree = state.registry[tostring(id)] or state.registry["rbxassetid://" .. tostring(id)]
                        if tree and typeof(res) == "Instance" then injectSources(tree.roots, res:GetChildren()) end
                        anchorResults(res)
                    end)
                end
                return res
            end))
        end)
    end
end

installHooks()

-- ═══════════════════════════════════════════
-- 2. FILE SCANNER
-- ═══════════════════════════════════════════
local SCAN_ROOTS = {
    "", ".", "workspace", "Delta/workspace", "Delta",
    "/sdcard/Delta/workspace", "/sdcard/Delta",
    "/storage/emulated/0/Delta/workspace",
    "/sdcard/Download", "/sdcard/Downloads",
    "/storage/emulated/0/Download", "/storage/emulated/0/Downloads",
    "Download", "Downloads", "downloads",
}

local function hasExt(name)
    local l = name:lower()
    return l:match("%.rbxmx?$") ~= nil or l:match("%.rbxlx?$") ~= nil
end

local function fmtSize(n)
    if n < 1024 then return n .. " B" end
    if n < 1048576 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.2f MB", n / 1048576)
end

local function scanDir(path, depth, out, seen)
    if depth > 4 then return end
    local okL, list = pcall(listfiles, path)
    if not okL or type(list) ~= "table" then return end
    for _, f in ipairs(list) do
        slice()
        if not seen[f] then
            seen[f] = true
            local isF = false
            if isfolder then
                local okF, r = pcall(isfolder, f)
                isF = okF and r == true
            end
            if isF then
                scanDir(f, depth + 1, out, seen)
            elseif hasExt(f) then
                local okR, data = pcall(readfile, f)
                local size = (okR and type(data) == "string") and #data or 0
                local name = f:match("[^/\\]+$") or f
                local key = name .. ":" .. size
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = {path = f, name = name, size = size}
                end
            end
        end
    end
end

local function scanAll()
    if not listfiles or not readfile then return nil, "listfiles/readfile tidak tersedia" end
    local out, seen = {}, {}
    for _, root in ipairs(SCAN_ROOTS) do
        scanDir(root, 0, out, seen)
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    state.fileList = out
    return out
end
state.scanFn = scanAll

-- ═══════════════════════════════════════════
-- 3. LOADER
-- ═══════════════════════════════════════════
local SERVICE_NAMES = {
    Workspace = true, ReplicatedStorage = true, Lighting = true, StarterGui = true,
    StarterPack = true, StarterPlayer = true, ReplicatedFirst = true, SoundService = true,
    Teams = true, Chat = true, TextChatService = true, MaterialService = true,
}

local function getSvc(name)
    local ok, s = pcall(game.GetService, game, name)
    return ok and s or nil
end

local function tryGetObjects(url)
    local ok, res = pcall(function() return game:GetObjects(url) end)
    if ok and type(res) == "table" and #res > 0 then return res end
    return nil, ok and "kosong" or tostring(res)
end

local function loadFile(entry)
    state.codeBoxSearched = false
    state.editorLocalSearched = false
    state.boxStats = {tpl = 0, manual = 0, noLocal = 0}
    local okR, data = pcall(readfile, entry.path)
    if not okR or type(data) ~= "string" then error("gagal baca file") end

    local tree, perr = parseAny(data)
    if not tree then error("parser: " .. tostring(perr)) end

    local nodes = tree.roots
    if #nodes == 1 and nodes[1].Class == "DataModel" then nodes = nodes[1].Children end
    if state.indexFromTree then pcall(state.indexFromTree, entry, nodes) end

    local total, empty = 0, {}
    local function audit(ns, path)
        for _, n in ipairs(ns) do
            local p = path .. "/" .. n.Name
            if SCRIPT_CLASSES[n.Class] then
                total = total + 1
                local len = n.Source and #n.Source or 0
                dbgw(string.format("%s (%s) source=%d", p, n.Class, len))
                if len == 0 then empty[#empty + 1] = p end
            end
            audit(n.Children, p)
        end
    end
    audit(nodes, "")
    if tree.skipped > 0 then
        dbgw(tree.skipped .. " chunk gagal didecode (kemungkinan zstd), source bisa hilang")
    end
    for _, p in ipairs(empty) do dbgw("source kosong: " .. p) end

    local ext = entry.name:match("%.[%w]+$") or ".rbxm"
    local candidates = {
        {"getcustomasset", function() return getcustomasset(entry.path) end},
        {"rbxasset", function() return "rbxasset://" .. entry.path end},
        {"temp", function()
            local tmp = "gopal_tmp" .. ext
            writefile(tmp, data)
            return getcustomasset(tmp)
        end},
    }

    local objs, usedUrl, usedHow, lastErr
    for _, c in ipairs(candidates) do
        local okU, url = pcall(c[2])
        if okU and type(url) == "string" and url ~= "" then
            local res, e = tryGetObjects(url)
            if res then
                objs, usedUrl, usedHow = res, url, c[1]
                break
            end
            lastErr = e
        else
            lastErr = tostring(url)
        end
    end
    if not objs then error("GetObjects gagal: " .. tostring(lastErr)) end

    state.registry[usedUrl] = tree
    local injected = injectSources(nodes, objs)

    local stats = {made = 0, failed = 0, how = "-"}
    if RECREATE_SCRIPTS then
        recreateScripts(nodes, objs, stats)
    end

    for _, o in ipairs(objs) do
        local svc = SERVICE_NAMES[o.ClassName] and getSvc(o.ClassName)
        if svc then
            for _, ch in ipairs(o:GetChildren()) do
                pcall(function() ch.Parent = svc end)
            end
        else
            pcall(function() o.Parent = workspace end)
        end
        anchorResults(o)
    end

    if injected < total - #empty then
        dbgw("hanya " .. injected .. " dari " .. total .. " script yang cocok dengan instance hasil load")
    end
    local st = state.boxStats
    return string.format("OK via %s: %d script dibuat ulang | kotak kode: %d asli, %d buatan sendiri, %d tanpa editor",
        usedHow, stats.made, st.tpl, st.manual, st.noLocal)
end

-- ═══════════════════════════════════════════
-- 6. UI  (GOPAL IMPORTER V3 : pink + merah + gold, premium)
-- ═══════════════════════════════════════════
if state.gui then pcall(function() state.gui:Destroy() end) end
if state.uiConn then pcall(function() state.uiConn:Disconnect() end) end
if state.uiConns then
    for _, c in ipairs(state.uiConns) do pcall(function() c:Disconnect() end) end
end
state.uiConns = {}

local PINK  = Color3.fromRGB(255, 64, 160)
local RED   = Color3.fromRGB(255, 45, 75)
local HOT   = Color3.fromRGB(255, 130, 195)
local WINE  = Color3.fromRGB(38, 12, 30)
local NIGHT = Color3.fromRGB(14, 6, 16)
local GREY0 = Color3.fromRGB(78, 68, 86)
local GREY1 = Color3.fromRGB(48, 42, 56)
local WHITE = Color3.new(1, 1, 1)
local LGOLD = Color3.fromRGB(255, 205, 105)
local LGOLD2 = Color3.fromRGB(255, 232, 170)

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    o.Parent = parent
    return o
end
local function corner(o, r) return new("UICorner", {CornerRadius = UDim.new(0, r or 8)}, o) end
local function stroke(o, c, t, tr)
    return new("UIStroke", {Color = c, Thickness = t or 1, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, o)
end
local function grad(o, c0, c1, rot)
    return new("UIGradient", {Color = ColorSequence.new(c0, c1), Rotation = rot or 0}, o)
end

local function guiParent()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok = pcall(function()
        local t = Instance.new("Folder")
        t.Parent = CoreGui
        t:Destroy()
    end)
    if ok then return CoreGui end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local host = guiParent()
for _, n in ipairs({"GOPAL_UI"}) do
    local old = host:FindFirstChild(n)
    if old then pcall(function() old:Destroy() end) end
end

local gui = new("ScreenGui", {Name = "GOPAL_UI", ResetOnSpawn = false, DisplayOrder = 999, IgnoreGuiInset = true}, nil)

-- khusus LOADING SCREEN saja: landscape + full layar sampai ke tepi
local function forceLandscape(g)
    pcall(function() g.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor end)
    pcall(function() g.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None end)
    pcall(function() g.ScreenInsets = Enum.ScreenInsets.None end)
    pcall(function() g.IgnoreGuiInset = true end)
end
gui.Parent = host   -- UI utama normal (tidak dipaksa full layar / landscape)
state.gui = gui

-- ═══════════════════════════════════════════
-- LOADING SCREEN (teks animasi: huruf muncul satu-satu lalu hilang satu-satu)
-- ═══════════════════════════════════════════
local runLoading
do
    local TextService = game:GetService("TextService")

    local STEPS = {
        {0.35, "Memuat modul..."},
        {0.70, "Memasang hook..."},
        {1.00, "Selesai!"},
    }

    local function charWidth(ch, size, font)
        local ok, v = pcall(function()
            return TextService:GetTextSize(ch, size, font, Vector2.new(1000, 1000)).X
        end)
        return (ok and v or size * 0.62) + 2
    end

    -- bikin satu baris huruf (tiap huruf = 1 label), return daftar huruf
    local function makeRow(parent, text, size, font, y, h, colorFn)
        local row = new("Frame", {
            BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, y), Size = UDim2.new(1, 0, 0, h),
        }, parent)
        new("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
            VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
        }, row)
        local letters, n = {}, #text
        for i = 1, n do
            local ch = text:sub(i, i)
            local wrap = new("Frame", {
                BackgroundTransparency = 1, LayoutOrder = i,
                Size = UDim2.new(0, (ch == " ") and size * 0.4 or charWidth(ch, size, font), 1, 0),
            }, row)
            if ch ~= " " then
                local lbl = new("TextLabel", {
                    BackgroundTransparency = 1, Font = font, TextSize = size, Text = ch,
                    TextColor3 = colorFn(i, n), TextTransparency = 1,
                    Position = UDim2.new(0, 0, 0, 18), Size = UDim2.new(1, 0, 1, 0),
                }, wrap)
                local st = new("UIStroke", {Color = PINK, Thickness = 1.5, Transparency = 1}, lbl)
                letters[#letters + 1] = {lbl = lbl, st = st}
            end
        end
        return letters
    end

    -- semua huruf dijadwalkan sekaligus lewat DelayTime, jadi durasi tetap walau FPS rendah
    local function letterIn(l, delay)
        TweenService:Create(l.lbl, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay),
            {TextTransparency = 0, Position = UDim2.new(0, 0, 0, 0)}):Play()
        TweenService:Create(l.st, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay),
            {Transparency = 0.45}):Play()
    end
    local function letterOut(l, delay)
        TweenService:Create(l.lbl, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, delay),
            {TextTransparency = 1, Position = UDim2.new(0, 0, 0, -16)}):Play()
        TweenService:Create(l.st, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, delay),
            {Transparency = 1}):Play()
    end

    runLoading = function(onDone)
        task.spawn(function()
            local finished = false
            local function finish()
                if finished then return end
                finished = true
                pcall(onDone)
            end

            local sg, conn
            local ok, err = pcall(function()
                local old = host:FindFirstChild("GOPAL_LOAD")
                if old then old:Destroy() end
                sg = new("ScreenGui", {Name = "GOPAL_LOAD", ResetOnSpawn = false, DisplayOrder = 1000, IgnoreGuiInset = true}, nil)
                forceLandscape(sg)
                sg.Parent = host

                local root = new("CanvasGroup", {
                    BackgroundColor3 = WHITE, BorderSizePixel = 0, Active = true,
                    Size = UDim2.new(1, 0, 1, 0), GroupTransparency = 1,
                }, sg)
                grad(root, WINE, NIGHT, 90)

                -- partikel melayang naik
                local ps = {}
                for i = 1, 16 do
                    local sz = math.random(4, 11)
                    local f = new("Frame", {
                        BackgroundColor3 = (i % 2 == 0) and PINK or RED, BackgroundTransparency = 0.7,
                        BorderSizePixel = 0, Size = UDim2.new(0, sz, 0, sz),
                        Position = UDim2.new(math.random(), 0, math.random(), 0),
                    }, root)
                    corner(f, 99)
                    ps[i] = {f = f, x = math.random(), y = math.random(), v = 0.04 + math.random() * 0.08, ph = math.random() * 6}
                end

                -- teks animasi (2 baris)
                local logo = new("Frame", {
                    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
                    Position = UDim2.new(0.5, 0, 0.4, 0), Size = UDim2.new(0.9, 0, 0, 120),
                }, root)
                local row1 = makeRow(logo, "GOPAL", 52, Enum.Font.GothamBlack, 0, 60, function(i, n)
                    return PINK:Lerp(RED, (i - 1) / math.max(n - 1, 1))
                end)
                local row2 = makeRow(logo, "IMPORTER V3", 26, Enum.Font.GothamBold, 66, 34, function(i, n)
                    return (i > 9) and RED:Lerp(HOT, 0.2) or WHITE
                end)
                local all = {}
                for _, l in ipairs(row1) do all[#all + 1] = l end
                for _, l in ipairs(row2) do all[#all + 1] = l end

                -- bar progress
                local track = new("Frame", {
                    BackgroundColor3 = Color3.fromRGB(40, 20, 38), BorderSizePixel = 0,
                    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.68, 0),
                    Size = UDim2.new(0, 260, 0, 8),
                }, root)
                corner(track, 99)
                stroke(track, PINK, 1, 0.6)
                local fill = new("Frame", {BackgroundColor3 = WHITE, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0)}, track)
                corner(fill, 99)
                grad(fill, PINK, RED, 0)

                local status = new("TextLabel", {
                    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = HOT,
                    AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.68, 14),
                    Size = UDim2.new(0, 260, 0, 16), Text = "Memuat...",
                }, root)
                local pct = new("TextLabel", {
                    BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = WHITE,
                    AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.68, -12),
                    Size = UDim2.new(0, 260, 0, 16), Text = "0%",
                }, root)

                -- spinner
                local spin = new("Frame", {
                    BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
                    Position = UDim2.new(0.5, 0, 0.82, 0), Size = UDim2.new(0, 34, 0, 34),
                }, root)
                corner(spin, 99)
                local spinStroke = new("UIStroke", {Color = PINK, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, spin)
                local spinG = new("UIGradient", {
                    Transparency = NumberSequence.new({
                        NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 1), NumberSequenceKeypoint.new(1, 1),
                    }),
                }, spinStroke)

                -- pengaman: loading maksimal 5.5 detik, apa pun yang terjadi
                task.delay(5.5, function()
                    finish()
                    if conn then pcall(function() conn:Disconnect() end) end
                    if sg then pcall(function() sg:Destroy() end) end
                end)

                -- animasi per frame
                local t0 = os.clock()
                conn = RunService.RenderStepped:Connect(function(dt)
                    local t = os.clock() - t0
                    spinG.Rotation = (t * 360) % 360
                    for _, p in ipairs(ps) do
                        p.y = p.y - p.v * dt
                        if p.y < -0.05 then p.y = 1.05; p.x = math.random() end
                        p.f.Position = UDim2.new(p.x + math.sin(t + p.ph) * 0.01, 0, p.y, 0)
                    end
                    local tw = track.AbsoluteSize.X
                    if tw > 0 then pct.Text = math.floor(math.clamp(fill.AbsoluteSize.X / tw, 0, 1) * 100 + 0.5) .. "%" end
                end)
                state.uiConns[#state.uiConns + 1] = conn

                TweenService:Create(root, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {GroupTransparency = 0}):Play()

                local function waitUntil(sec)
                    while os.clock() - t0 < sec do task.wait() end
                end

                -- huruf muncul satu-satu (jadwal via DelayTime)
                for i, l in ipairs(all) do letterIn(l, (i - 1) * 0.07) end

                -- progress bar 1 tween + teks status terjadwal
                TweenService:Create(fill, TweenInfo.new(3.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
                    {Size = UDim2.new(1, 0, 1, 0)}):Play()
                for _, st in ipairs({{0.0, STEPS[1][2]}, {1.0, STEPS[2][2]}, {2.2, STEPS[3][2]}}) do
                    task.delay(st[1], function() status.Text = st[2] end)
                end

                -- huruf hilang satu-satu
                waitUntil(2.9)
                for i, l in ipairs(all) do letterOut(l, (i - 1) * 0.04) end

                waitUntil(3.75)
                local fo = TweenService:Create(root, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {GroupTransparency = 1})
                fo:Play()
                finish()   -- panel mulai muncul saat loading memudar
                fo.Completed:Wait()
            end)
            if conn then pcall(function() conn:Disconnect() end) end
            if sg then pcall(function() sg:Destroy() end) end
            finish()
        end)
    end
end

-- tombol pill/rounded dengan gradient + efek hover/tekan
local function mkBtn(parent, text, pos, size, textSize)
    local b = new("TextButton", {
        Text = "", BackgroundColor3 = WHITE, AutoButtonColor = false, Position = pos, Size = size,
    }, parent)
    corner(b, (size.Y.Offset <= 22) and 99 or 8)
    local g = grad(b, PINK, RED, 20)
    local gloss = new("Frame", {BackgroundColor3 = WHITE, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0)}, b)
    corner(gloss, (size.Y.Offset <= 22) and 99 or 8)
    new("UIGradient", {Rotation = 90, Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1)})}, gloss)
    stroke(b, Color3.fromRGB(255, 170, 215), 1, 0.55)
    local lbl = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = textSize or 11, TextColor3 = WHITE,
        Size = UDim2.new(1, 0, 1, 0), Text = text,
    }, b)
    local sc = new("UIScale", {Scale = 1}, b)
    local function tw(v)
        TweenService:Create(sc, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {Scale = v}):Play()
    end
    b.MouseEnter:Connect(function() tw(1.06) end)
    b.MouseLeave:Connect(function() tw(1) end)
    b.MouseButton1Down:Connect(function() tw(0.92) end)
    b.MouseButton1Up:Connect(function() tw(1.04) end)
    return b, g, lbl
end
local function setOn(g, on)
    g.Color = on and ColorSequence.new(PINK, RED) or ColorSequence.new(GREY0, GREY1)
end

-- tombol toggle samping
local toggle = new("TextButton", {
    Text = "", BackgroundColor3 = WHITE, AutoButtonColor = false,
    Position = UDim2.new(0, 6, 0.5, -25), Size = UDim2.new(0, 50, 0, 50),
}, gui)
corner(toggle, 99)
grad(toggle, PINK, RED, 45)
new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 11, TextColor3 = WHITE, TextWrapped = true,
    Size = UDim2.new(1, -6, 1, 0), Position = UDim2.new(0, 3, 0, 0), Text = NAME,
}, toggle)
local togStroke = stroke(toggle, LGOLD2, 2.5, 0.3)
local togScale = new("UIScale", {Scale = 1}, toggle)

-- panel utama
local cam = workspace.CurrentCamera
local vp = cam and cam.ViewportSize or Vector2.new(800, 450)
local geom = state.panelGeom
if geom and (geom.w < 500 or geom.h < 360) then geom = nil end
local pw = geom and geom.w or math.min(540, vp.X - 16)
local ph0 = geom and geom.h or math.min(396, vp.Y - 16)
local px = geom and geom.x or math.max(8, (vp.X - pw) / 2)
local py = geom and geom.y or math.max(8, (vp.Y - ph0) / 2)
local panel = new("Frame", {
    BackgroundColor3 = WHITE, AnchorPoint = Vector2.new(0, 0),
    Position = UDim2.fromOffset(px, py), Size = UDim2.fromOffset(pw, ph0),
}, gui)
corner(panel, 14)
grad(panel, WINE, NIGHT, 90)
local panelStroke = stroke(panel, WHITE, 3, 0)
local panelStrokeG = new("UIGradient", {
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, PINK), ColorSequenceKeypoint.new(0.3, LGOLD2),
        ColorSequenceKeypoint.new(0.55, RED), ColorSequenceKeypoint.new(0.8, LGOLD),
        ColorSequenceKeypoint.new(1, PINK),
    }),
}, panelStroke)
local panelScale = new("UIScale", {Scale = 0.85}, panel)

-- lapisan efek: orb melayang di belakang konten
local fx = new("Frame", {BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.new(1, 0, 1, 0)}, panel)
corner(fx, 14)
local orbs = {}
for i = 1, 5 do
    local sz = math.random(6, 16)
    local f = new("Frame", {
        BackgroundColor3 = (i % 2 == 0) and PINK or RED, BackgroundTransparency = 0.75,
        Size = UDim2.new(0, sz, 0, sz), BorderSizePixel = 0,
    }, fx)
    corner(f, 99)
    orbs[i] = {f = f, x = math.random(), y = math.random(0, 344), s = math.random(12, 30)}
end

local open = true
local restPos = panel.Position
local curTweens = {}
local function stopTweens()
    for _, t in ipairs(curTweens) do pcall(function() t:Cancel() end) end
    curTweens = {}
end
local function offsetPos(p, dy) return UDim2.new(p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset + dy) end

-- transisi masuk: slide dari bawah + zoom (Back) + stroke fade-in
local function playIn()
    stopTweens()
    panel.Visible = true
    panel.Position = offsetPos(restPos, 28)
    panelScale.Scale = 0.8
    panelStroke.Transparency = 1
    local ti = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    curTweens = {
        TweenService:Create(panelScale, ti, {Scale = 1}),
        TweenService:Create(panel, TweenInfo.new(0.38, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Position = restPos}),
        TweenService:Create(panelStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {Transparency = 0}),
    }
    for _, t in ipairs(curTweens) do t:Play() end
end

-- transisi keluar: kecil + turun sedikit lalu disembunyikan
local function playOut()
    stopTweens()
    restPos = panel.Position
    local ti = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    local twS = TweenService:Create(panelScale, ti, {Scale = 0.8})
    curTweens = {
        twS,
        TweenService:Create(panel, ti, {Position = offsetPos(restPos, 20)}),
        TweenService:Create(panelStroke, ti, {Transparency = 1}),
    }
    twS.Completed:Connect(function(state_)
        if not open and state_ == Enum.PlaybackState.Completed then
            panel.Visible = false
            panel.Position = restPos
        end
    end)
    for _, t in ipairs(curTweens) do t:Play() end
end

local function setOpen(v)
    if open == v then return end
    open = v
    if open then playIn() else playOut() end
end

toggle.MouseButton1Click:Connect(function() setOpen(not open) end)

-- jaga panel selalu muat di layar (awal, rotate, ganti ukuran)
local function fitPanel()
    local v = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 450)
    if v.X < 50 or v.Y < 50 then return end
    local w = math.min(panel.Size.X.Offset, v.X - 12)
    local h = math.min(panel.Size.Y.Offset, v.Y - 12)
    local x = math.clamp(panel.Position.X.Offset, 6, math.max(6, v.X - w - 6))
    local y = math.clamp(panel.Position.Y.Offset, 6, math.max(6, v.Y - h - 6))
    panel.Size = UDim2.fromOffset(w, h)
    panel.Position = UDim2.fromOffset(x, y)
    restPos = panel.Position
end
fitPanel()
do
    local cam = workspace.CurrentCamera
    if cam then
        state.uiConns[#state.uiConns + 1] = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            if open then fitPanel() end
        end)
    end
end

-- tampilkan loading screen dulu, baru panel masuk dengan transisi
panel.Visible = false
toggle.Visible = false
runLoading(function()
    toggle.Visible = true
    playIn()
end)

-- header + marquee + jam
local header = new("Frame", {BackgroundColor3 = WHITE, Size = UDim2.new(1, 0, 0, 74), ClipsDescendants = true}, panel)
corner(header, 14)
local headerG = new("UIGradient", {Color = ColorSequence.new({ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 20, 85)), ColorSequenceKeypoint.new(0.35, PINK), ColorSequenceKeypoint.new(0.7, RED), ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 18, 60))}), Rotation = 0}, header)

-- kilau (shine) yang menyapu header
local shine = new("Frame", {
    BackgroundColor3 = WHITE, BorderSizePixel = 0, Rotation = 18, ZIndex = 2,
    Position = UDim2.new(-0.3, 0, -0.6, 0), Size = UDim2.new(0, 46, 2.4, 0),
}, header)
new("UIGradient", {
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.82), NumberSequenceKeypoint.new(1, 1),
    }),
}, shine)

-- garis emas di bawah header
local goldLine = new("Frame", {
    BackgroundColor3 = WHITE, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 75), Size = UDim2.new(1, -28, 0, 2),
}, panel)
new("UIGradient", {
    Color = ColorSequence.new(LGOLD, LGOLD2),
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 0.1),
        NumberSequenceKeypoint.new(0.75, 0.1), NumberSequenceKeypoint.new(1, 1),
    }),
}, goldLine)

-- geser panel (tarik header) dan ubah ukuran (tarik pojok kanan bawah)
local function makeDrag(handle, onDrag)
    local dragging, startPos = false, nil
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startPos = input.Position
            onDrag("begin", 0, 0)
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    onDrag("end", 0, 0)
                end
            end)
        end
    end)
    state.uiConns[#state.uiConns + 1] = UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - startPos
            onDrag("move", d.X, d.Y)
        end
    end)
end

local function saveGeom()
    state.panelGeom = {
        x = panel.Position.X.Offset, y = panel.Position.Y.Offset,
        w = panel.Size.X.Offset, h = panel.Size.Y.Offset,
    }
end

local function viewport()
    local c = workspace.CurrentCamera
    return c and c.ViewportSize or Vector2.new(800, 450)
end

local startPanelPos, startPanelSize
makeDrag(header, function(kind, dx, dy)
    if kind == "begin" then
        startPanelPos = panel.Position
    elseif kind == "move" and startPanelPos then
        local v, sc = viewport(), panelScale.Scale
        local nx = math.clamp(startPanelPos.X.Offset + dx / sc, 60 - panel.Size.X.Offset, v.X - 60)
        local ny = math.clamp(startPanelPos.Y.Offset + dy / sc, 0, v.Y - 40)
        panel.Position = UDim2.fromOffset(nx, ny)
    elseif kind == "end" then
        saveGeom()
    end
end)

local grip = new("Frame", {
    BackgroundTransparency = 1, Active = true, ZIndex = 20,
    Position = UDim2.new(1, -30, 1, -30), Size = UDim2.new(0, 30, 0, 30),
}, panel)
for _, d in ipairs({{20, 20}, {12, 20}, {20, 12}, {4, 20}, {12, 12}, {20, 4}}) do
    local dotf = new("Frame", {
        BackgroundColor3 = HOT, BorderSizePixel = 0, ZIndex = 21,
        Position = UDim2.new(0, d[1] + 4, 0, d[2] + 4), Size = UDim2.new(0, 3, 0, 3),
    }, grip)
    corner(dotf, 99)
end
makeDrag(grip, function(kind, dx, dy)
    if kind == "begin" then
        startPanelSize = panel.Size
    elseif kind == "move" and startPanelSize then
        local v, sc = viewport(), panelScale.Scale
        local maxW = math.max(480, v.X - panel.Position.X.Offset - 4)
        local maxH = math.max(372, v.Y - panel.Position.Y.Offset - 4)
        local w = math.clamp(startPanelSize.X.Offset + dx / sc, 480, maxW)
        local h = math.clamp(startPanelSize.Y.Offset + dy / sc, 372, maxH)
        panel.Size = UDim2.fromOffset(w, h)
    elseif kind == "end" then
        saveGeom()
    end
end)

-- ═══ V3: variabel bersama (dideklarasikan sekali di sini) + wadah isi panel ═══
local files = {}
local setStatus
local mode = "files"
local render
local openEditor
local makeRow
local UI = {rowData = setmetatable({}, {__mode = "k"}), chk = {}, ROW_BG = Color3.fromRGB(38, 11, 31), ROW_SEL = Color3.fromRGB(70, 18, 52)}
local body = new("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, 0)}, panel)

-- helper gambar kecil (ikon digambar dari Frame, tidak butuh asset)
UI.box = function(p, x, y, w, h, col, rot)
    return new("Frame", {
        BackgroundColor3 = col, BorderSizePixel = 0, Rotation = rot or 0,
        Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, w, 0, h),
    }, p)
end
UI.ring = function(p, x, y, s, col, th)
    local r = new("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, s, 0, s)}, p)
    corner(r, 99)
    local st = stroke(r, col, th, 0)
    return r, st
end
UI.icon = function(kind, parent, col, pos)
    local f = new("Frame", {BackgroundTransparency = 1, Position = pos, Size = UDim2.new(0, 16, 0, 16)}, parent)
    local b = UI.box
    if kind == "home" then
        b(f, 3.5, 1.5, 9, 9, col, 45)
        b(f, 3, 8, 10, 7, col)
        b(f, 7, 10, 2, 5, NIGHT)
    elseif kind == "scan" then
        UI.ring(f, 1, 1, 10, col, 2)
        b(f, 9, 12, 7, 2, col, 45)
    elseif kind == "import" then
        b(f, 7, 0, 2, 8, col)
        b(f, 5, 5, 6, 6, col, 45)
        b(f, 1, 13, 14, 2, col)
        b(f, 1, 10, 2, 5, col)
        b(f, 13, 10, 2, 5, col)
    elseif kind == "settings" then
        UI.ring(f, 3, 3, 10, col, 3)
        b(f, 7, 0, 2, 3, col)
        b(f, 7, 13, 2, 3, col)
        b(f, 0, 7, 3, 2, col)
        b(f, 13, 7, 3, 2, col)
    elseif kind == "folder" then
        b(f, 1, 2, 7, 4, col)
        b(f, 1, 4, 14, 10, col)
    elseif kind == "doc" then
        local r = new("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, 3, 0, 1), Size = UDim2.new(0, 10, 0, 14)}, f)
        corner(r, 2)
        stroke(r, col, 1.6, 0)
        b(f, 5, 5, 6, 1.5, col)
        b(f, 5, 8, 6, 1.5, col)
        b(f, 5, 11, 4, 1.5, col)
    elseif kind == "note" then
        corner(b(f, 2, 10, 6, 5, col), 99)
        b(f, 7, 1, 2, 11, col)
        b(f, 7, 1, 7, 3, col)
    elseif kind == "bolt" then
        b(f, 7, 0, 3, 9, col, 20)
        b(f, 5, 7, 3, 9, col, 20)
    elseif kind == "speaker" then
        b(f, 2, 5, 4, 6, col)
        b(f, 5, 3, 4, 10, col, 0)
        b(f, 11, 6, 2, 4, col)
    end
    return f
end
UI.spin = {}
UI.sparks = {}
UI.glowOf = setmetatable({}, {__mode = "k"})
UI.spark = function(parent, x, y, size, col)
    local l = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = size, TextColor3 = col or WHITE,
        Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, size + 4, 0, size + 4), Text = "★", ZIndex = 4,
    }, parent)
    UI.sparks[#UI.sparks + 1] = {l = l, ph = math.random() * 6}
    return l
end
UI.card = function(parent, pos, size)
    -- glow lembut di belakang kartu
    local g = new("Frame", {
        BackgroundColor3 = PINK, BackgroundTransparency = 0.88, BorderSizePixel = 0,
        Position = UDim2.new(pos.X.Scale, pos.X.Offset - 3, pos.Y.Scale, pos.Y.Offset - 3),
        Size = UDim2.new(size.X.Scale, size.X.Offset + 6, size.Y.Scale, size.Y.Offset + 6),
    }, parent)
    corner(g, 13)
    local c = new("Frame", {BackgroundColor3 = WHITE, Position = pos, Size = size, ClipsDescendants = true}, parent)
    corner(c, 10)
    new("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(48, 14, 40), Color3.fromRGB(16, 6, 16)), Rotation = 90}, c)
    UI.spin[#UI.spin + 1] = grad(stroke(c, WHITE, 1.3, 0.1), PINK, LGOLD, 45)
    local hl = new("Frame", {BackgroundColor3 = WHITE, BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(1, -20, 0, 1)}, c)
    new("UIGradient", {Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.5), NumberSequenceKeypoint.new(1, 1),
    })}, hl)
    UI.glowOf[c] = g
    return c
end
-- cahaya lembut (lingkaran bertumpuk) di latar panel
UI.blob = function(parent, pos, size, col)
    for i = 1, 6 do
        local s = size * (1 - (i - 1) * 0.15)
        corner(new("Frame", {
            BackgroundColor3 = col, BackgroundTransparency = 0.94, BorderSizePixel = 0,
            AnchorPoint = Vector2.new(0.5, 0.5), Position = pos, Size = UDim2.new(0, s, 0, s),
        }, parent), 99)
    end
end
UI.blob(fx, UDim2.new(0.12, 0, 0.3, 0), 260, PINK)
UI.blob(fx, UDim2.new(0.92, 0, 0.95, 0), 260, RED)

-- header V3: logo G, judul, badge V3, tagline, jam WIB, tombol minimize + close
local marqueeClip, marquee, clock
do
    -- gambar karakter (decal) di sisi kanan header, memudar ke kiri
    local art = new("ImageLabel", {
        BackgroundTransparency = 1, Image = "rbxthumb://type=Asset&id=78671776541432&w=420&h=420",
        ScaleType = Enum.ScaleType.Crop, ImageTransparency = 0.05, ZIndex = 2,
        Position = UDim2.new(1, -330, 0, 0), Size = UDim2.new(0, 220, 1, 0),
    }, header)
    new("UIGradient", {Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 0.55), NumberSequenceKeypoint.new(1, 0),
    })}, art)
    -- garis miring dekoratif + bayangan bawah header
    for i, d in ipairs({{250, 14, 9}, {274, 14, 4}, {300, 14, 14}}) do
        new("Frame", {
            BackgroundColor3 = WHITE, BackgroundTransparency = 0.9, BorderSizePixel = 0, Rotation = 20, ZIndex = 2,
            Position = UDim2.new(0, d[1] + 120, 0, -10), Size = UDim2.new(0, d[3], 0, 110),
        }, header)
    end
    local vig = new("Frame", {
        BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 2,
        Position = UDim2.new(0, 0, 1, -26), Size = UDim2.new(1, 0, 0, 26),
    }, header)
    new("UIGradient", {Rotation = 90, Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.55),
    })}, vig)
    -- cahaya di sekitar logo
    for i, s in ipairs({68, 58}) do
        corner(new("Frame", {
            BackgroundColor3 = WHITE, BackgroundTransparency = 0.84 + i * 0.03, BorderSizePixel = 0, ZIndex = 2,
            Position = UDim2.new(0, 35 - s / 2, 0, 36 - s / 2), Size = UDim2.new(0, s, 0, s),
        }, header), 99)
    end
    UI.spark(header, 296, 8, 8, WHITE)
    UI.spark(header, 352, 50, 7, LGOLD2)
    UI.spark(header, 70, 60, 6, WHITE)

    local medal = new("Frame", {
        BackgroundColor3 = NIGHT, Position = UDim2.new(0, 12, 0, 13), Size = UDim2.new(0, 46, 0, 46), ZIndex = 3,
    }, header)
    corner(medal, 99)
    UI.spin[#UI.spin + 1] = grad(stroke(medal, WHITE, 3, 0), LGOLD2, PINK, 45)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 28, TextColor3 = WHITE,
        Size = UDim2.new(1, 0, 1, 0), Text = "G", ZIndex = 4,
    }, medal)

    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = Color3.fromRGB(110, 8, 55),
        TextTransparency = 0.3, ZIndex = 2, TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.new(0, 70, 0, 9), Size = UDim2.new(0, 200, 0, 24), Text = "RBXM IMPORTER",
    }, header)
    local titleRow = new("Frame", {
        BackgroundTransparency = 1, Position = UDim2.new(0, 68, 0, 7), Size = UDim2.new(0, 0, 0, 24),
        AutomaticSize = Enum.AutomaticSize.X, ZIndex = 3,
    }, header)
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
    }, titleRow)
    grad(new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 20, TextColor3 = WHITE, ZIndex = 3,
        AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.new(0, 0, 1, 0), LayoutOrder = 1, Text = "RBXM IMPORTER",
    }, titleRow), WHITE, LGOLD2, 0)
    local v3 = new("Frame", {BackgroundColor3 = WHITE, Size = UDim2.new(0, 30, 0, 16), LayoutOrder = 2, ZIndex = 3}, titleRow)
    corner(v3, 99)
    grad(v3, LGOLD2, LGOLD, 90)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 10, TextColor3 = Color3.fromRGB(100, 20, 55),
        Size = UDim2.new(1, 0, 1, 0), Text = "V3", ZIndex = 4,
    }, v3)

    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = WHITE, ZIndex = 3,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 68, 0, 32), Size = UDim2.new(0, 120, 0, 14),
        Text = "by GOPAL  ★",
    }, header)
    marqueeClip = new("Frame", {
        BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 3,
        Position = UDim2.new(0, 68, 0, 48), Size = UDim2.new(1, -68 - 152, 0, 14),
    }, header)
    marquee = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9, ZIndex = 3,
        TextColor3 = Color3.fromRGB(255, 240, 220), AutomaticSize = Enum.AutomaticSize.X,
        Size = UDim2.new(0, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Import RBXM / RBXL to Roblox  •  Fast  •  Easy  •  Free",
    }, marqueeClip)

    clock = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 9, TextColor3 = WHITE, ZIndex = 3,
        Position = UDim2.new(1, -182, 0, 11), Size = UDim2.new(0, 94, 0, 14),
        TextXAlignment = Enum.TextXAlignment.Right, Text = "--:--:-- WIB",
    }, header)

    -- tombol minimize (-) dan close (X)
    local function hbtn(txt, x, size)
        local b = new("TextButton", {
            Text = txt, Font = Enum.Font.GothamBlack, TextSize = size, TextColor3 = WHITE, AutoButtonColor = false,
            BackgroundColor3 = Color3.fromRGB(0, 0, 0), BackgroundTransparency = 0.65, ZIndex = 6,
            Position = UDim2.new(1, x, 0, 8), Size = UDim2.new(0, 22, 0, 22),
        }, header)
        corner(b, 99)
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.12), {BackgroundTransparency = 0.2}):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(0.12), {BackgroundTransparency = 0.65}):Play()
        end)
        return b
    end
    local minBtn = hbtn("-", -62, 16)
    local closeBtn = hbtn("X", -34, 13)
    closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)

    -- minimize: sisakan header saja, klik lagi untuk kembali
    local minimized, fullH = false, nil
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        if minimized then
            fullH = panel.Size.Y.Offset
            body.Visible = false
            grip.Visible = false
            panel.Size = UDim2.fromOffset(panel.Size.X.Offset, 82)
        else
            panel.Size = UDim2.fromOffset(panel.Size.X.Offset, fullH or 396)
            body.Visible = true
            grip.Visible = true
        end
    end)
end

-- sidebar: Home / Scan / Import / Settings (pintasan ke fitur yang sudah ada) + brand + profil Roblox
local dot, avatarG
do
    local side = UI.card(body, UDim2.new(0, 8, 0, 80), UDim2.new(0, 80, 1, -88))
    local NAV = {{"home", "Home"}, {"scan", "Scan"}, {"import", "Import"}, {"settings", "Settings"}}
    local ind = new("Frame", {
        BackgroundColor3 = WHITE, Position = UDim2.new(0, 5, 0, 8), Size = UDim2.new(1, -10, 0, 26),
    }, side)
    corner(ind, 8)
    grad(ind, PINK, RED, 0)
    stroke(ind, LGOLD2, 1.3, 0.35)
    UI.navTo = function(i)
        TweenService:Create(ind, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            {Position = UDim2.new(0, 5, 0, 8 + (i - 1) * 30)}):Play()
    end
    for i, d in ipairs(NAV) do
        local btn = new("TextButton", {
            Text = "", BackgroundTransparency = 1, AutoButtonColor = false, ZIndex = 3,
            Position = UDim2.new(0, 5, 0, 8 + (i - 1) * 30), Size = UDim2.new(1, -10, 0, 26),
        }, side)
        UI.icon(d[1], btn, WHITE, UDim2.new(0, 8, 0, 5))
        new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = WHITE,
            TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 30, 0, 0), Size = UDim2.new(1, -32, 1, 0),
            Text = d[2],
        }, btn)
        btn.MouseButton1Click:Connect(function()
            local name = d[1]
            if name == "settings" then
                UI.setPopup(not UI.popOpen)
            else
                UI.setPopup(false)
                UI.navTo(i)
                if name ~= "home" and UI.onNav and UI.onNav[name] then
                    UI.onNav[name]()
                    task.delay(0.6, function()
                        if not UI.popOpen then UI.navTo(1) end
                    end)
                end
            end
        end)
    end

    -- brand
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 17, TextColor3 = PINK, TextTransparency = 0.45,
        Position = UDim2.new(0, 1, 0, 136), Size = UDim2.new(1, 0, 0, 22), Text = "GOPAL",
    }, side)
    local brand = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 17, TextColor3 = WHITE,
        Position = UDim2.new(0, 0, 0, 134), Size = UDim2.new(1, 0, 0, 22), Text = "GOPAL",
    }, side)
    grad(brand, LGOLD2, PINK, 0)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 6, TextColor3 = HOT,
        Position = UDim2.new(0, 0, 0, 155), Size = UDim2.new(1, 0, 0, 8), Text = "IMPORT • PLAY • ENJOY",
    }, side)

    -- profil Roblox (tetap ada)
    local pc = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(40, 12, 34), Position = UDim2.new(0, 4, 1, -114), Size = UDim2.new(1, -8, 0, 82),
    }, side)
    corner(pc, 8)
    stroke(pc, LGOLD, 1, 0.7)
    local avatar = new("ImageLabel", {
        BackgroundColor3 = Color3.fromRGB(24, 10, 22), Position = UDim2.new(0.5, -16, 0, 5),
        Size = UDim2.new(0, 32, 0, 32), Image = "",
    }, pc)
    corner(avatar, 99)
    avatarG = grad(stroke(avatar, WHITE, 2, 0), PINK, RED, 0)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE,
        TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 2, 0, 40), Size = UDim2.new(1, -4, 0, 11),
        Text = LocalPlayer.DisplayName,
    }, pc)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 7, TextColor3 = HOT,
        TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 2, 0, 51), Size = UDim2.new(1, -4, 0, 9),
        Text = "@" .. LocalPlayer.Name,
    }, pc)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 7, TextColor3 = Color3.fromRGB(190, 150, 175),
        TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.new(0, 2, 0, 60), Size = UDim2.new(1, -4, 0, 9),
        Text = "ID " .. LocalPlayer.UserId,
    }, pc)
    local pill = new("Frame", {
        BackgroundColor3 = RED, BackgroundTransparency = 0.8, Position = UDim2.new(0.5, -22, 0, 70), Size = UDim2.new(0, 44, 0, 10),
    }, pc)
    corner(pill, 99)
    stroke(pill, PINK, 1, 0.3)
    dot = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(80, 255, 160), Position = UDim2.new(0, 5, 0.5, -2), Size = UDim2.new(0, 4, 0, 4),
    }, pill)
    corner(dot, 99)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 6, TextColor3 = WHITE,
        Position = UDim2.new(0, 11, 0, 0), Size = UDim2.new(1, -12, 1, 0), Text = "ACTIVE",
    }, pill)
    task.spawn(function()
        local ok, img = pcall(function()
            return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
        end)
        if ok and img then avatar.Image = img end
    end)

    -- versi
    local ver = new("Frame", {
        BackgroundTransparency = 1, Position = UDim2.new(0.5, -28, 1, -24), Size = UDim2.new(0, 56, 0, 17),
    }, side)
    corner(ver, 99)
    stroke(ver, PINK, 1, 0.3)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = HOT,
        Size = UDim2.new(1, 0, 1, 0), Text = "v3.0.0",
    }, ver)
end

-- kartu WORKSPACE FOLDER + kartu SCAN FILES
local search, btnScan
do
    local c = UI.card(body, UDim2.new(0, 94, 0, 80), UDim2.new(1, -256, 0, 46))
    local tile = new("Frame", {BackgroundColor3 = WHITE, Position = UDim2.new(0, 7, 0, 9), Size = UDim2.new(0, 28, 0, 28)}, c)
    corner(tile, 8)
    grad(tile, PINK, RED, 45)
    UI.icon("folder", tile, WHITE, UDim2.new(0, 6, 0, 6))
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 40, 0, 4), Size = UDim2.new(0, 88, 0, 13),
        Text = "WORKSPACE FOLDER",
    }, c)
    local fx_ = new("Frame", {BackgroundColor3 = WHITE, Position = UDim2.new(0, 132, 0, 6), Size = UDim2.new(0, 32, 0, 11)}, c)
    corner(fx_, 99)
    grad(fx_, PINK, RED, 20)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 6, TextColor3 = WHITE,
        Size = UDim2.new(1, 0, 1, 0), Text = "FIXED",
    }, fx_)
    local pathBox = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(34, 11, 30), Position = UDim2.new(0, 40, 0, 22), Size = UDim2.new(1, -40 - 82, 0, 17),
    }, c)
    corner(pathBox, 5)
    stroke(pathBox, PINK, 1, 0.75)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 8, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 6, 0, 0), Size = UDim2.new(1, -8, 1, 0), Text = "/storage/emulated/0/Delta/workspace/",
    }, pathBox)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = HOT,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(1, -76, 0, 4), Size = UDim2.new(0, 70, 0, 10),
        Text = "Info",
    }, c)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 7, TextColor3 = Color3.fromRGB(200, 165, 190),
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
        Position = UDim2.new(1, -76, 0, 15), Size = UDim2.new(0, 70, 0, 28), Text = "Jangan gunakan folder lain!",
    }, c)

    local sc = UI.card(body, UDim2.new(0, 94, 0, 130), UDim2.new(1, -256, 0, 46))
    local tile2 = new("Frame", {BackgroundColor3 = WHITE, Position = UDim2.new(0, 7, 0, 9), Size = UDim2.new(0, 28, 0, 28)}, sc)
    corner(tile2, 8)
    grad(tile2, PINK, RED, 45)
    UI.icon("scan", tile2, WHITE, UDim2.new(0, 6, 0, 6))
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 40, 0, 3), Size = UDim2.new(0, 100, 0, 14),
        Text = "SCAN FILES",
    }, sc)
    search = new("TextBox", {
        PlaceholderText = "Cari file RBXM/RBXL di folder workspace...", Text = "", ClearTextOnFocus = false, ClipsDescendants = true,
        Font = Enum.Font.Gotham, TextSize = 8, TextColor3 = WHITE,
        PlaceholderColor3 = Color3.fromRGB(170, 130, 155), BackgroundColor3 = Color3.fromRGB(34, 11, 30),
        TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.new(0, 40, 0, 20), Size = UDim2.new(1, -40 - 70, 0, 20),
    }, sc)
    corner(search, 6)
    new("UIPadding", {PaddingLeft = UDim.new(0, 6)}, search)
    local searchStroke = stroke(search, PINK, 1, 0.7)
    search.Focused:Connect(function()
        TweenService:Create(searchStroke, TweenInfo.new(0.2), {Transparency = 0}):Play()
    end)
    search.FocusLost:Connect(function()
        TweenService:Create(searchStroke, TweenInfo.new(0.2), {Transparency = 0.7}):Play()
    end)
    btnScan = mkBtn(sc, "SCAN", UDim2.new(1, -64, 0, 8), UDim2.new(0, 56, 0, 30), 10)
end

-- pengaturan (REFRESH / LOG / ANCHOR / HOOK) dibuka dari menu Settings di sidebar
local btnRefresh, btnAnchor, gAnchor, lAnchor, btnHook, gHook, lHook, btnLog
do
    local pop = UI.card(body, UDim2.new(0, 94, 0, 80), UDim2.new(1, -256, 1, -88))
    pop.Visible = false
    UI.glowOf[pop].Visible = false
    pop.ZIndex = 10
    UI.icon("settings", pop, HOT, UDim2.new(0, 10, 0, 8))
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 32, 0, 6), Size = UDim2.new(1, -40, 0, 20),
        Text = "SETTINGS",
    }, pop)
    btnRefresh = mkBtn(pop, "REFRESH", UDim2.new(0, 10, 0, 38), UDim2.new(0.5, -14, 0, 28), 9)
    btnLog = mkBtn(pop, "LOG", UDim2.new(0.5, 4, 0, 38), UDim2.new(0.5, -14, 0, 28), 9)
    btnAnchor, gAnchor, lAnchor = mkBtn(pop, "ANCHOR: ON", UDim2.new(0, 10, 0, 72), UDim2.new(0.5, -14, 0, 28), 9)
    btnHook, gHook, lHook = mkBtn(pop, "HOOK: ON", UDim2.new(0.5, 4, 0, 72), UDim2.new(0.5, -14, 0, 28), 9)
    UI.setPopup = function(v)
        UI.popOpen = v
        pop.Visible = v
        if UI.glowOf[pop] then UI.glowOf[pop].Visible = v end
        UI.navTo(v and 4 or 1)
    end
end

btnAnchor.MouseButton1Click:Connect(function()
    state.anchorOn = not state.anchorOn
    lAnchor.Text = "ANCHOR: " .. (state.anchorOn and "ON" or "OFF")
    setOn(gAnchor, state.anchorOn)
end)
btnHook.MouseButton1Click:Connect(function()
    state.hooksOn = not state.hooksOn
    lHook.Text = "HOOK: " .. (state.hooksOn and "ON" or "OFF")
    setOn(gHook, state.hooksOn)
end)
btnLog.MouseButton1Click:Connect(function()
    local txt = table.concat(state.debugLines, "\n")
    if txt == "" then txt = "(log kosong)" end
    pcall(function() if setclipboard then setclipboard(txt) end end)
    setStatus(setclipboard and "Log disalin ke clipboard" or "clipboard tidak tersedia", HOT)
end)
setOn(gAnchor, state.anchorOn)
setOn(gHook, state.hooksOn)

-- kartu DAFTAR FILE: judul, jumlah (klik = pilih semua), FILE|SCRIPT, daftar, IMPORT SELECTED + Hapus, status
local listCard = UI.card(body, UDim2.new(0, 94, 0, 180), UDim2.new(1, -256, 1, -188))
UI.icon("doc", listCard, HOT, UDim2.new(0, 8, 0, 5))
UI.listTitle = new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = WHITE,
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 28, 0, 4), Size = UDim2.new(1, -28 - 132, 0, 14), Text = "DAFTAR FILE (RBXM / RBXL)",
}, listCard)
UI.cntBtn = new("TextButton", {
    Text = "0 File", Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = WHITE, AutoButtonColor = false,
    BackgroundColor3 = Color3.fromRGB(60, 16, 48), Position = UDim2.new(1, -128, 0, 5), Size = UDim2.new(0, 44, 0, 16),
}, listCard)
corner(UI.cntBtn, 99)
stroke(UI.cntBtn, PINK, 1, 0.5)

local seg = new("Frame", {
    BackgroundColor3 = Color3.fromRGB(24, 8, 22), Position = UDim2.new(1, -80, 0, 5), Size = UDim2.new(0, 72, 0, 16),
}, listCard)
corner(seg, 99)
stroke(seg, PINK, 1, 0.2)
local segInd = new("Frame", {
    BackgroundColor3 = WHITE, Position = UDim2.new(0, 2, 0, 2), Size = UDim2.new(0.5, -3, 1, -4),
}, seg)
corner(segInd, 99)
grad(segInd, PINK, RED, 20)
local segF = new("TextButton", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 7, TextColor3 = WHITE,
    Size = UDim2.new(0.5, 0, 1, 0), Text = "FILE", AutoButtonColor = false, ZIndex = 2,
}, seg)
local segS = new("TextButton", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 7, TextColor3 = Color3.fromRGB(205, 160, 188),
    Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, 0, 1, 0), Text = "SCRIPT", AutoButtonColor = false, ZIndex = 2,
}, seg)

local function setMode(m)
    if mode == m then return end
    mode = m
    TweenService:Create(segInd, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        {Position = UDim2.new(m == "files" and 0 or 0.5, m == "files" and 2 or 1, 0, 2)}):Play()
    segF.TextColor3 = (m == "files") and WHITE or Color3.fromRGB(190, 150, 175)
    segS.TextColor3 = (m == "scripts") and WHITE or Color3.fromRGB(190, 150, 175)
    search.PlaceholderText = (m == "files") and "cari file..." or "cari script (nama)..."
    local shown = render()
    if m == "scripts" then
        setStatus(#state.idx .. " script ter-index, tampil " .. shown .. " (ketik untuk mencari)", HOT)
    else
        setStatus(#files .. " file", HOT)
    end
end
segF.MouseButton1Click:Connect(function() setMode("files") end)
segS.MouseButton1Click:Connect(function() setMode("scripts") end)

local list = new("ScrollingFrame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = PINK,
    Position = UDim2.new(0, 4, 0, 26), Size = UDim2.new(1, -8, 1, -84),
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, listCard)
new("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder}, list)
new("UIPadding", {PaddingTop = UDim.new(0, 1), PaddingLeft = UDim.new(0, 1), PaddingRight = UDim.new(0, 4), PaddingBottom = UDim.new(0, 1)}, list)
UI.listFull, UI.listShort = UDim2.new(1, -8, 1, -84), UDim2.new(1, -8, 1, -56)

do
    -- baris tombol bawah: IMPORT SELECTED (n) + Hapus (kosongkan pilihan)
    UI.bar = new("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, 0, 1, -56), Size = UDim2.new(1, 0, 0, 30)}, listCard)
    local bi, _, li = mkBtn(UI.bar, "IMPORT SELECTED (0)", UDim2.new(0, 6, 0, 3), UDim2.new(1, -80, 0, 24), 9)
    UI.lImp = li
    bi.MouseButton1Click:Connect(function() UI.importSel() end)
    local hb = new("TextButton", {
        Text = "Hapus", Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE, AutoButtonColor = false,
        BackgroundColor3 = Color3.fromRGB(34, 12, 30), Position = UDim2.new(1, -68, 0, 3), Size = UDim2.new(0, 62, 0, 24),
    }, UI.bar)
    corner(hb, 8)
    stroke(hb, PINK, 1, 0.5)
    hb.MouseButton1Click:Connect(function() UI.clear() end)

    -- status (satu-satunya tempat pesan dari logic ditampilkan)
    UI.statusDot = new("Frame", {
        BackgroundColor3 = HOT, Position = UDim2.new(0, 9, 1, -17), Size = UDim2.new(0, 6, 0, 6),
    }, listCard)
    corner(UI.statusDot, 99)
    UI.statusLabel = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 7, TextColor3 = HOT,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
        TextWrapped = true, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 20, 1, -26), Size = UDim2.new(1, -26, 0, 24), Text = "Siap! Scan dulu untuk menampilkan file.",
    }, listCard)
end

setStatus = function(text, color)
    UI.statusLabel.Text = tostring(text)
    UI.statusLabel.TextColor3 = color or HOT
    UI.statusDot.BackgroundColor3 = color or HOT
end

-- placeholder & judul kartu mengikuti mode (setMode asli tidak diubah)
search:GetPropertyChangedSignal("PlaceholderText"):Connect(function()
    local p = search.PlaceholderText
    if p == "cari file..." then
        search.PlaceholderText = "Cari file RBXM/RBXL di folder workspace..."
    elseif p == "cari script (nama)..." then
        search.PlaceholderText = "Cari script (nama)..."
    else
        UI.listTitle.Text = p:find("script") and "DAFTAR SCRIPT" or "DAFTAR FILE (RBXM / RBXL)"
    end
end)

-- baris daftar: file = kotak centang (klik untuk memilih), script = klik untuk membuka editor
do
    makeRow = function(i, title, subtitle, btnText, onClick)
        local isFile = (btnText == "INSERT")
        local key, badgeTxt, sub = nil, "LUA", subtitle
        if isFile then
            local ext = title:match("%.(%w+)$")
            badgeTxt = ext and ext:upper() or "RBXM"
            sub = badgeTxt .. "  •  " .. subtitle
            key = title
        end
        local row = new("Frame", {BackgroundColor3 = UI.ROW_BG, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = i}, list)
        corner(row, 7)
        new("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 170, 190)), Rotation = 0}, row)
        local rowStroke = stroke(row, LGOLD, 1, 1)
        local accent = new("Frame", {BackgroundColor3 = WHITE, BorderSizePixel = 0, Visible = false, Size = UDim2.new(0, 3, 1, 0)}, row)
        corner(accent, 99)
        grad(accent, PINK, RED, 90)
        local picked = false
        local x0, box, ck1, ck2 = 8, nil, nil, nil
        if isFile then
            box = new("Frame", {
                BackgroundColor3 = WHITE, BackgroundTransparency = 1,
                Position = UDim2.new(0, 8, 0.5, -7), Size = UDim2.new(0, 14, 0, 14),
            }, row)
            corner(box, 4)
            stroke(box, PINK, 1.5, 0)
            grad(box, PINK, RED, 45)
            ck1 = UI.box(box, 2.5, 7.5, 4, 2, WHITE, 45)
            ck2 = UI.box(box, 4.6, 6, 7.8, 2, WHITE, -50)
            ck1.Visible, ck2.Visible = false, false
            x0 = 28
        end
        local cube = new("Frame", {
            BackgroundColor3 = WHITE, Position = UDim2.new(0, x0, 0.5, -10), Size = UDim2.new(0, 20, 0, 20),
        }, row)
        corner(cube, 5)
        grad(cube, PINK, RED, 45)
        local dm = new("Frame", {
            BackgroundTransparency = 1, Rotation = 45, Position = UDim2.new(0, 6.5, 0, 6.5), Size = UDim2.new(0, 7, 0, 7),
        }, cube)
        stroke(dm, WHITE, 1.5, 0)
        local tx = x0 + 26
        new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE,
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, tx, 0, 3), Size = UDim2.new(1, -tx - 46, 0, 13), Text = title,
        }, row)
        new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 8, TextColor3 = Color3.fromRGB(190, 160, 180),
            TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
            Position = UDim2.new(0, tx, 0, 16), Size = UDim2.new(1, -tx - 46, 0, 11), Text = sub,
        }, row)
        local badge = new("Frame", {
            BackgroundColor3 = Color3.fromRGB(70, 18, 52), Position = UDim2.new(1, -44, 0.5, -7), Size = UDim2.new(0, 38, 0, 14),
        }, row)
        corner(badge, 99)
        new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 7, TextColor3 = HOT,
            Size = UDim2.new(1, 0, 1, 0), Text = badgeTxt,
        }, badge)

        local function paint(on)
            picked = on
            accent.Visible = on
            row.BackgroundColor3 = on and UI.ROW_SEL or UI.ROW_BG
            rowStroke.Transparency = on and 0.35 or 1
            if box then
                box.BackgroundTransparency = on and 0 or 1
                ck1.Visible, ck2.Visible = on, on
            end
        end
        UI.rowData[row] = {key = key, action = onClick, paint = paint}
        if key and UI.chk[key] then paint(true) end

        local click = new("TextButton", {
            Text = "", BackgroundTransparency = 1, AutoButtonColor = false, ZIndex = 3, Size = UDim2.new(1, 0, 1, 0),
        }, row)
        click.MouseEnter:Connect(function()
            if not picked then row.BackgroundColor3 = Color3.fromRGB(54, 16, 44) end
        end)
        click.MouseLeave:Connect(function()
            if not picked then row.BackgroundColor3 = UI.ROW_BG end
        end)
        click.MouseButton1Click:Connect(function()
            if isFile then
                UI.chk[key] = (not UI.chk[key]) or nil
                paint(UI.chk[key] == true)
            else
                onClick()
            end
        end)
    end

    -- baris yang sedang tampil dan dicentang (urut seperti di daftar)
    UI.selected = function()
        local out = {}
        for _, c in ipairs(list:GetChildren()) do
            local d = UI.rowData[c]
            if d and d.key and UI.chk[d.key] then out[#out + 1] = d end
        end
        return out
    end

    -- IMPORT SELECTED: jalankan aksi baris (fungsi INSERT asli) satu per satu, tunggu sampai selesai
    UI.importSel = function()
        if mode ~= "files" then
            setStatus("Pindah ke tab FILE dulu", HOT)
            return
        end
        if UI.busy then
            setStatus("Import masih berjalan...", HOT)
            return
        end
        local picks = UI.selected()
        if #picks == 0 then
            setStatus("Centang file dulu", HOT)
            return
        end
        UI.busy = true
        task.spawn(function()
            for _, d in ipairs(picks) do
                pcall(d.action)
                local t0 = os.clock()
                task.wait(0.15)
                while UI.statusLabel.Text:find("^Loading ") and os.clock() - t0 < 180 do task.wait(0.1) end
            end
            UI.busy = false
        end)
    end

    -- Hapus: kosongkan semua centang (tidak menghapus file apa pun)
    UI.clear = function()
        UI.chk = {}
        for _, c in ipairs(list:GetChildren()) do
            local d = UI.rowData[c]
            if d and d.paint then d.paint(false) end
        end
        setStatus("Pilihan dikosongkan", HOT)
    end

    -- klik jumlah file = pilih semua / batal pilih semua (yang sedang tampil)
    UI.cntBtn.MouseButton1Click:Connect(function()
        if mode ~= "files" then return end
        local rows, all = {}, true
        for _, c in ipairs(list:GetChildren()) do
            local d = UI.rowData[c]
            if d and d.key then
                rows[#rows + 1] = d
                if not UI.chk[d.key] then all = false end
            end
        end
        for _, d in ipairs(rows) do
            UI.chk[d.key] = (not all) or nil
            d.paint(not all)
        end
    end)
end

-- kolom kanan: GOPAL MUSIC, STATUS (hitungan file), kutipan GOPAL
do
    -- ► daftar lagu: ganti/tambah sesuai asset ID audio milikmu (format "rbxassetid://ID")
    local PLAYLIST = {
        {name = "Track 1", id = "rbxassetid://99522679374819"},
        {name = "Track 2", id = "rbxassetid://76482590100434"},
    }
    local GREEN = Color3.fromRGB(80, 255, 160)

    local mc = UI.card(body, UDim2.new(1, -158, 0, 80), UDim2.new(0, 150, 0, 128))
    UI.icon("note", mc, HOT, UDim2.new(0, 8, 0, 5))
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 28, 0, 5), Size = UDim2.new(0, 76, 0, 14),
        Text = "GOPAL MUSIC",
    }, mc)
    local pill = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(18, 58, 40), Position = UDim2.new(1, -44, 0, 6), Size = UDim2.new(0, 36, 0, 14),
    }, mc)
    corner(pill, 99)
    local pdot = new("Frame", {
        BackgroundColor3 = GREEN, Position = UDim2.new(0, 6, 0.5, -2.5), Size = UDim2.new(0, 5, 0, 5),
    }, pill)
    corner(pdot, 99)
    local plabel = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = GREEN,
        Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -14, 1, 0), Text = "Off",
    }, pill)

    local disc = new("Frame", {BackgroundColor3 = WHITE, Position = UDim2.new(0, 8, 0, 26), Size = UDim2.new(0, 30, 0, 30)}, mc)
    corner(disc, 99)
    local discG = grad(disc, PINK, RED, 0)
    stroke(disc, WHITE, 1, 0.6)
    for _, d in ipairs({{4, 22}, {8, 14}}) do
        local _, gs = UI.ring(disc, d[1], d[1], d[2], WHITE, 1)
        gs.Transparency = 0.8
    end
    corner(new("Frame", {
        BackgroundColor3 = NIGHT, Position = UDim2.new(0.5, -4, 0.5, -4), Size = UDim2.new(0, 8, 0, 8),
    }, disc), 99)
    local tname = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 44, 0, 28), Size = UDim2.new(1, -50, 0, 13),
        Text = PLAYLIST[1] and PLAYLIST[1].name or "Playlist kosong",
    }, mc)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 8, TextColor3 = Color3.fromRGB(190, 160, 180),
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 44, 0, 42), Size = UDim2.new(1, -50, 0, 11),
        Text = "GOPAL IMPORTER V3",
    }, mc)

    local function cbtn(txt, x, y, s, ts)
        local b = new("TextButton", {
            Text = txt, Font = Enum.Font.GothamBlack, TextSize = ts, TextColor3 = WHITE, AutoButtonColor = false,
            BackgroundColor3 = Color3.fromRGB(46, 14, 38), Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, s, 0, s),
        }, mc)
        corner(b, 99)
        return b
    end
    local bPrev = cbtn("|<", 34, 62, 24, 9)
    UI.playGlow = new("Frame", {
        BackgroundColor3 = PINK, BackgroundTransparency = 0.8, BorderSizePixel = 0,
        Position = UDim2.new(0, 56, 0, 53), Size = UDim2.new(0, 42, 0, 42),
    }, mc)
    corner(UI.playGlow, 99)
    local bPlay = cbtn(">", 62, 59, 30, 13)
    stroke(bPlay, WHITE, 1.5, 0.4)
    bPlay.BackgroundColor3 = WHITE
    grad(bPlay, PINK, RED, 20)
    local bNext = cbtn(">|", 96, 62, 24, 9)

    local track = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(50, 18, 42), Position = UDim2.new(0, 8, 0, 94), Size = UDim2.new(1, -16, 0, 4),
    }, mc)
    corner(track, 99)
    local fill = new("Frame", {BackgroundColor3 = WHITE, Size = UDim2.new(0, 0, 1, 0)}, track)
    corner(fill, 99)
    grad(fill, PINK, LGOLD2, 0)
    corner(new("Frame", {
        BackgroundColor3 = WHITE, BorderSizePixel = 0, Position = UDim2.new(1, -4, 0.5, -4), Size = UDim2.new(0, 8, 0, 8), ZIndex = 3,
    }, fill), 99)
    local tl = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 7, TextColor3 = Color3.fromRGB(190, 160, 180),
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 8, 0, 99), Size = UDim2.new(0, 40, 0, 9),
        Text = "00:00",
    }, mc)
    local tr = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 7, TextColor3 = Color3.fromRGB(190, 160, 180),
        TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -48, 0, 99), Size = UDim2.new(0, 40, 0, 9),
        Text = "00:00",
    }, mc)

    local spk = new("TextButton", {
        Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromRGB(46, 14, 38),
        Position = UDim2.new(0, 8, 0, 108), Size = UDim2.new(0, 18, 0, 18),
    }, mc)
    corner(spk, 99)
    UI.icon("speaker", spk, WHITE, UDim2.new(0, 1, 0, 1))
    local wave = new("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, 32, 0, 108), Size = UDim2.new(1, -40, 0, 18)}, mc)
    local bars = {}
    for i = 1, 22 do
        bars[i] = new("Frame", {
            BackgroundColor3 = PINK:Lerp(LGOLD2, (i - 1) / 21), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, (i - 1) * 5, 0.5, 0), Size = UDim2.new(0, 2, 0, 3),
        }, wave)
    end

    -- suara sungguhan (Sound di SoundService, ikut dibersihkan saat panel dihancurkan)
    local snd = Instance.new("Sound")
    snd.Name = "GOPAL_MUSIC"
    snd.Volume = 0.6
    snd.Looped = false
    snd.Parent = game:GetService("SoundService")
    gui.Destroying:Connect(function() pcall(function() snd:Destroy() end) end)

    local cur, muted, want, loadWait = 1, false, false, 0
    local function setTrack(n)
        if #PLAYLIST == 0 then return false end
        cur = ((n - 1) % #PLAYLIST) + 1
        snd.SoundId = PLAYLIST[cur].id
        tname.Text = PLAYLIST[cur].name
        loadWait = 0
        return true
    end
    local function play()
        if #PLAYLIST == 0 then
            setStatus("Playlist musik kosong (isi PLAYLIST di bagian GOPAL MUSIC)", HOT)
            return
        end
        if snd.SoundId == "" then setTrack(cur) end
        want = true
        pcall(function()
            if snd.IsPaused then snd:Resume() else snd:Play() end
        end)
    end
    bPlay.MouseButton1Click:Connect(function()
        if snd.IsPlaying then
            want = false
            pcall(function() snd:Pause() end)
        else
            play()
        end
    end)
    local function step(d)
        local was = snd.IsPlaying
        if setTrack(cur + d) and was then pcall(function() snd:Play() end) end
    end
    bPrev.MouseButton1Click:Connect(function() step(-1) end)
    bNext.MouseButton1Click:Connect(function() step(1) end)
    snd.Ended:Connect(function()
        if setTrack(cur + 1) then pcall(function() snd:Play() end) end
    end)
    spk.MouseButton1Click:Connect(function()
        muted = not muted
        snd.Volume = muted and 0 or 0.6
        spk.BackgroundTransparency = muted and 0.6 or 0
    end)

    local function fmt(s)
        s = math.max(0, math.floor(s))
        return string.format("%02d:%02d", math.floor(s / 60), s % 60)
    end
    local flat = false
    UI.musicTick = function(dt, t)
        local playing = snd.IsPlaying
        local lbl = playing and "On" or "Off"
        if plabel.Text ~= lbl then plabel.Text = lbl end
        local btxt = playing and "II" or ">"
        if bPlay.Text ~= btxt then bPlay.Text = btxt end
        local len, pos = snd.TimeLength, snd.TimePosition
        fill.Size = UDim2.new((len > 0) and math.clamp(pos / len, 0, 1) or 0, 0, 1, 0)
        local a, b = fmt(pos), fmt(len)
        if tl.Text ~= a then tl.Text = a end
        if tr.Text ~= b then tr.Text = b end
        if want and not snd.IsLoaded then
            loadWait = loadWait + dt
            if loadWait > 8 then
                want = false
                loadWait = 0
                setStatus("Musik gagal dimuat: ID audio tidak bisa diputar", COLORS.DANGER)
            end
        end
        if playing then
            flat = false
            discG.Rotation = (discG.Rotation + dt * 120) % 360
            local amp = math.clamp(snd.PlaybackLoudness / 250, 0.15, 1)
            for i, bar in ipairs(bars) do
                local h = 3 + amp * 14 * (0.45 + 0.55 * math.abs(math.sin(t * 6 + i * 0.7)))
                bar.Size = UDim2.new(0, 2, 0, h)
            end
        elseif not flat then
            flat = true
            for _, bar in ipairs(bars) do bar.Size = UDim2.new(0, 2, 0, 3) end
        end
    end

    -- STATUS: hitungan file
    local st = UI.card(body, UDim2.new(1, -158, 0, 212), UDim2.new(0, 150, 0, 82))
    UI.icon("bolt", st, LGOLD, UDim2.new(0, 8, 0, 5))
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 28, 0, 5), Size = UDim2.new(0, 80, 0, 14),
        Text = "STATUS",
    }, st)
    local ROWS = {{"File Terbaca", HOT}, {"RBXM", PINK}, {"RBXL", RED}, {"Siap Diimpor", GREEN}}
    UI.cntVals = {}
    for i, r in ipairs(ROWS) do
        local y = 22 + (i - 1) * 14
        corner(new("Frame", {BackgroundColor3 = r[2], Position = UDim2.new(0, 10, 0, y + 4), Size = UDim2.new(0, 7, 0, 7)}, st), 99)
        new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 8, TextColor3 = WHITE,
            TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 23, 0, y), Size = UDim2.new(0, 84, 0, 14),
            Text = r[1],
        }, st)
        UI.cntVals[i] = new("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = r[2],
            TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -44, 0, y), Size = UDim2.new(0, 36, 0, 14),
            Text = "0",
        }, st)
    end

    -- kutipan GOPAL
    local qc = UI.card(body, UDim2.new(1, -158, 0, 298), UDim2.new(0, 150, 1, -306))
    for i, d in ipairs({{70, 12}, {96, 6}, {116, 16}}) do
        new("Frame", {
            BackgroundColor3 = PINK, BackgroundTransparency = 0.82, BorderSizePixel = 0, Rotation = 25,
            Position = UDim2.new(0, d[1], 0, -20), Size = UDim2.new(0, d[2], 0, 140),
        }, qc)
    end
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = PINK, TextTransparency = 0.5,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 11, 0, 7), Size = UDim2.new(0, 70, 0, 22),
        Text = "GOPAL",
    }, qc)
    UI.spark(qc, 124, 30, 7, LGOLD2)
    UI.spark(qc, 20, 62, 6, WHITE)
    local gl = new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 18, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 10, 0, 5), Size = UDim2.new(0, 70, 0, 22),
        Text = "GOPAL",
    }, qc)
    grad(gl, LGOLD2, PINK, 0)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = LGOLD,
        Position = UDim2.new(0, 78, 0, 6), Size = UDim2.new(0, 14, 0, 14), Text = "★",
    }, qc)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 8, TextColor3 = WHITE,
        TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
        Position = UDim2.new(0, 10, 0, 29), Size = UDim2.new(1, -20, 0, 26), Text = '"File kecil, tapi bisa jadi dunia besar."',
    }, qc)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8, TextColor3 = HOT,
        TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(1, -70, 1, -16), Size = UDim2.new(0, 60, 0, 12),
        Text = "- Gopal",
    }, qc)
end

-- dipanggil dari animasi (Heartbeat): hitungan, tombol import, mode daftar, musik
do
    local lastFiles, lastN, nm, nl = nil, -1, 0, 0
    local lastMode = nil
    local function setTxt(l, s) if l.Text ~= s then l.Text = s end end
    UI.tick = function(dt, t)
        if files ~= lastFiles or #files ~= lastN then
            lastFiles, lastN, nm, nl = files, #files, 0, 0
            for _, f in ipairs(files) do
                local l = f.name:lower()
                if l:match("%.rbxl") then nl = nl + 1 elseif l:match("%.rbxm") then nm = nm + 1 end
            end
        end
        local n = #UI.selected()
        setTxt(UI.cntVals[1], tostring(#files))
        setTxt(UI.cntVals[2], tostring(nm))
        setTxt(UI.cntVals[3], tostring(nl))
        setTxt(UI.cntVals[4], tostring(n))
        setTxt(UI.lImp, "IMPORT SELECTED (" .. n .. ")")
        local shownRows = 0
        for _, c in ipairs(list:GetChildren()) do
            if UI.rowData[c] then shownRows = shownRows + 1 end
        end
        local isF = (mode == "files")
        setTxt(UI.cntBtn, (isF and #files or shownRows) .. (isF and " File" or " Script"))
        if mode ~= lastMode then
            lastMode = mode
            UI.bar.Visible = isF
            list.Size = isF and UI.listFull or UI.listShort
        end
        for i, g in ipairs(UI.spin) do g.Rotation = (t * 40 + i * 37) % 360 end
        for _, sp in ipairs(UI.sparks) do
            sp.l.TextTransparency = 0.15 + 0.85 * math.abs(math.sin(t * 1.8 + sp.ph))
        end
        UI.playGlow.BackgroundTransparency = 0.78 + 0.12 * math.sin(t * 3)
        UI.musicTick(dt, t)
    end
end

-- editor script bawaan GOPAL (editor game hanya bisa melihat)
local editor = new("Frame", {
    BackgroundColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 460, 0, 300), Visible = false,
}, gui)
corner(editor, 14)
grad(editor, WINE, NIGHT, 90)
grad(stroke(editor, WHITE, 2.5, 0), PINK, RED, 0)

local edTitle = new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = WHITE,
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 12, 0, 6), Size = UDim2.new(1, -24, 0, 22), Text = "",
}, editor)
local edScroll = new("ScrollingFrame", {
    BackgroundColor3 = Color3.fromRGB(12, 5, 14), BorderSizePixel = 0,
    ScrollBarThickness = 5, ScrollBarImageColor3 = PINK,
    Position = UDim2.new(0, 8, 0, 32), Size = UDim2.new(1, -16, 1, -78),
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.XY,
    ScrollingDirection = Enum.ScrollingDirection.XY,
}, editor)
corner(edScroll, 8)
local edBox = new("TextBox", {
    BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12, TextColor3 = Color3.fromRGB(255, 225, 240),
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    MultiLine = true, ClearTextOnFocus = false, TextWrapped = false,
    AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(1, 0, 0, 0), Text = "",
}, edScroll)
new("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 4)}, edBox)

local edStatus = new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = HOT,
    TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
    Position = UDim2.new(0, 300, 1, -40), Size = UDim2.new(1, -308, 0, 32), Text = "",
}, editor)
local btnSave  = mkBtn(editor, "SAVE",  UDim2.new(0, 8, 1, -38),   UDim2.new(0, 86, 0, 28), 11)
local btnApply = mkBtn(editor, "APPLY", UDim2.new(0, 102, 1, -38), UDim2.new(0, 86, 0, 28), 11)
local btnClose = mkBtn(editor, "TUTUP", UDim2.new(0, 196, 1, -38), UDim2.new(0, 86, 0, 28), 11)

local current
local function curKey() return current.Path .. "|" .. current.dotted end

openEditor = function(e)
    current = e
    edTitle.Text = e.Name .. "  (" .. e.Class .. ")"
    edBox.Text = state.edits[curKey()] or e.Source or ""
    edStatus.Text = ""
    editor.Visible = true
end

btnSave.MouseButton1Click:Connect(function()
    if not current then return end
    state.edits[curKey()] = edBox.Text
    edStatus.Text = "Tersimpan. Editor game akan menampilkan versi ini."
end)
btnApply.MouseButton1Click:Connect(function()
    if not current then return end
    local text = edBox.Text
    state.edits[curKey()] = text
    local n = 0
    for inst in pairs(state.scriptCache) do
        local okI = pcall(function()
            if inst.Parent and inst.Name == current.Name and inst.ClassName == current.Class then
                local tb = inst:FindFirstChild("SL_CodeTextBox")
                if tb then tb.Text = colorizeSource(text) end
                if writeSource(inst, text) or tb then
                    state.scriptCache[inst] = text
                    state.moduleResults[inst] = nil
                    n = n + 1
                end
            end
        end)
    end
    edStatus.Text = "Tersimpan + diterapkan ke " .. n .. " script di game."
end)
btnClose.MouseButton1Click:Connect(function() editor.Visible = false end)

render = function()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    local q = search.Text:lower()
    local shown = 0
    if mode == "files" then
        for i, f in ipairs(files) do
            if q == "" or f.name:lower():find(q, 1, true) then
                shown = shown + 1
                makeRow(i, f.name, fmtSize(f.size), "INSERT", function()
                    task.spawn(function()
                        setStatus("Loading " .. f.name .. "...", COLORS.WARNING)
                        state.sliceThreads[coroutine.running()] = true
                        local ok, res = pcall(loadFile, f)
                        if ok then
                            setStatus(res, COLORS.SUCCESS)
                        else
                            setStatus("Gagal: " .. tostring(res), COLORS.DANGER)
                            dbgw(tostring(res))
                        end
                    end)
                end)
            end
        end
    else
        local limit = (q == "") and 40 or 80
        for i, e in ipairs(state.idx) do
            if shown >= limit then break end
            if q == "" or e.Name:lower():find(q, 1, true) or e.dotted:lower():find(q, 1, true) then
                shown = shown + 1
                local fileName = e.Path:match("[^/\\]+$") or e.Path
                makeRow(i, e.Name, e.Class .. "  •  " .. fileName, "EDIT", function() openEditor(e) end)
            end
        end
    end
    return shown
end

local function doScan()
    setStatus("Scanning...", COLORS.WARNING)
    task.spawn(function()
        state.sliceThreads[coroutine.running()] = true
        local res, err = scanAll()
        if not res then
            setStatus(err, COLORS.DANGER)
            return
        end
        files = res
        if state.startIndex then state.startIndex(files) end
        local shown = render()
        setStatus(#files .. " file ditemukan, " .. shown .. " tampil", COLORS.SUCCESS)
    end)
end

btnScan.MouseButton1Click:Connect(doScan)
btnRefresh.MouseButton1Click:Connect(function()
    local shown = render()
    setStatus("Refresh: " .. shown .. " dari " .. #files .. " file", HOT)
end)
search:GetPropertyChangedSignal("Text"):Connect(function() render() end)

-- menu sidebar: Scan = SCAN, Import = IMPORT SELECTED
UI.onNav = {scan = doScan, import = function() UI.importSel() end}

-- animasi: marquee, jam, gradient berputar, pulse, orb
local mx, lastClock, t0 = 260, "", os.clock()
local acc = 0
state.uiConn = RunService.Heartbeat:Connect(function(step)
    acc = acc + step
    if acc < 1 / 20 then return end
    local dt = acc
    acc = 0
    local t = os.clock() - t0
    togScale.Scale = 1 + math.sin(t * 3) * 0.04
    togStroke.Transparency = 0.35 + math.sin(t * 3) * 0.25
    if not panel.Visible then return end

    local c = os.date("!%H:%M:%S", os.time() + 25200)
    if c ~= lastClock then
        lastClock = c
        clock.Text = c .. " WIB"
    end

    panelStrokeG.Rotation = (t * 70) % 360
    avatarG.Rotation = (t * 120) % 360
    headerG.Offset = Vector2.new(math.sin(t * 1.5) * 0.25, 0)
    dot.BackgroundTransparency = 0.5 + math.sin(t * 5) * 0.5
    UI.tick(dt, t)

    for _, o in ipairs(orbs) do
        o.y = o.y - o.s * dt
        if o.y < -20 then
            o.y = panel.Size.Y.Offset + 6
            o.x = math.random()
        end
        o.f.Position = UDim2.new(o.x, 0, 0, o.y)
    end
end)

-- ═══════════════════════════════════════════
-- EDIT LANGSUNG di viewer Studio (ViewScriptFrame): kotak teks bisa diketik dipasang di atas isi kode
-- ═══════════════════════════════════════════
local overlay = {}

local function applyToGame(e, text)
    local n = 0
    for inst in pairs(state.scriptCache) do
        pcall(function()
            if inst.Parent and inst.Name == e.Name and inst.ClassName == e.Class then
                local tb = inst:FindFirstChild("SL_CodeTextBox")
                if tb then tb.Text = colorizeSource(text) end
                if writeSource(inst, text) or tb then
                    state.scriptCache[inst] = text
                    state.moduleResults[inst] = nil
                    n = n + 1
                end
            end
        end)
    end
    return n
end

local function restoreOverlay()
    if overlay.box then pcall(function() overlay.box:Destroy() end) end
    if overlay.label then
        pcall(function() overlay.label.TextTransparency = overlay.oldTrans or 0 end)
    end
    overlay.box, overlay.label, overlay.key = nil, nil, nil
end

local function overlayTick()
    local e = state.lastBest
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local sg = pg and pg:FindFirstChild("StudioGui")
    local vf = sg and sg:FindFirstChild("ViewScriptFrame")
    if not (e and vf and vf.Visible) then
        if overlay.box then restoreOverlay() end
        return
    end

    local title = vf:FindFirstChild("TextLabel")
    if title and title:IsA("TextLabel") then
        if not title.Text:find(e.Name, 1, true) then
            if overlay.box then restoreOverlay() end
            return
        end
        if title.Text:find("read only", 1, true) then
            title.Text = e.Name .. "  (editable)"
        end
    end

    local key = e.Path .. "|" .. e.dotted
    if overlay.key == key and overlay.box and overlay.box.Parent then return end

    restoreOverlay()
    local bestLbl, bestLen
    for _, d in ipairs(vf:GetDescendants()) do
        if d:IsA("TextLabel") and d ~= title and not d:IsDescendantOf(gui) then
            local l = #d.Text
            if not bestLen or l > bestLen then bestLbl, bestLen = d, l end
        end
    end
    if not bestLbl or bestLen < 20 then return end

    local box = Instance.new("TextBox")
    box.Name = "GOPAL_EDIT"
    box.BackgroundTransparency = 1
    box.Font = bestLbl.Font
    box.TextSize = bestLbl.TextSize
    box.TextColor3 = Color3.fromRGB(240, 240, 240)
    box.TextXAlignment = bestLbl.TextXAlignment
    box.TextYAlignment = bestLbl.TextYAlignment
    box.TextWrapped = bestLbl.TextWrapped
    box.RichText = false
    box.MultiLine = true
    box.ClearTextOnFocus = false
    box.TextEditable = true
    box.AnchorPoint = bestLbl.AnchorPoint
    box.Position = bestLbl.Position
    box.Size = bestLbl.Size
    box.AutomaticSize = bestLbl.AutomaticSize
    box.ZIndex = bestLbl.ZIndex + 1
    box.Text = state.edits[key] or e.Source or ""
    box.Parent = bestLbl.Parent

    overlay.oldTrans = bestLbl.TextTransparency
    bestLbl.TextTransparency = 1
    overlay.box, overlay.label, overlay.key = box, bestLbl, key

    box:GetPropertyChangedSignal("Text"):Connect(function()
        state.edits[key] = box.Text
    end)
    box.FocusLost:Connect(function()
        state.edits[key] = box.Text
        local n = applyToGame(e, box.Text)
        setStatus("Tersimpan dari editor Studio, diterapkan ke " .. n .. " script", COLORS.SUCCESS)
    end)
end

-- dimatikan: pengamatan struktur menunjukkan viewer membuat satu label per baris (dari ViewScriptTextLabelTemplate),
-- jadi menimpa satu label dengan seluruh source akan salah tempat. Nyalakan hanya kalau nanti sudah disesuaikan.
local OVERLAY_ENABLED = false
task.spawn(function()
    while gui.Parent do
        task.wait(0.4)
        if OVERLAY_ENABLED then pcall(overlayTick) end
    end
end)

doScan()

print("GOPAL IMPORTER V3 ACTIVATED")

end, function(e) return debug.traceback(tostring(e)) end)

if not ok_main then GOPAL_ShowError(err_main) end
