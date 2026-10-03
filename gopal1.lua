--[[
    GOPAL IMPORTER+ V1
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
-- 6. UI  (GOPAL IMPORTER+ : gradient pink + merah)
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
gui.Parent = host
state.gui = gui

-- tombol dengan gradient + efek hover/tekan
local function mkBtn(parent, text, pos, size, textSize)
    local b = new("TextButton", {
        Text = "", BackgroundColor3 = WHITE, AutoButtonColor = false, Position = pos, Size = size,
    }, parent)
    corner(b, 8)
    local g = grad(b, PINK, RED, 20)
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
local togStroke = stroke(toggle, WHITE, 2, 0.3)
local togScale = new("UIScale", {Scale = 1}, toggle)

-- panel utama
local cam = workspace.CurrentCamera
local vp = cam and cam.ViewportSize or Vector2.new(800, 450)
local geom = state.panelGeom
local pw = geom and geom.w or math.min(380, vp.X - 16)
local ph0 = geom and geom.h or math.min(344, vp.Y - 16)
local px = geom and geom.x or math.max(8, (vp.X - pw) / 2)
local py = geom and geom.y or math.max(8, (vp.Y - ph0) / 2)
local panel = new("Frame", {
    BackgroundColor3 = WHITE, AnchorPoint = Vector2.new(0, 0),
    Position = UDim2.fromOffset(px, py), Size = UDim2.fromOffset(pw, ph0),
}, gui)
corner(panel, 14)
grad(panel, WINE, NIGHT, 90)
local panelStroke = stroke(panel, WHITE, 2.5, 0)
local panelStrokeG = grad(panelStroke, PINK, RED, 0)
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
toggle.MouseButton1Click:Connect(function()
    open = not open
    if open then
        panel.Visible = true
        panelScale.Scale = 0.85
        TweenService:Create(panelScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()
    else
        local tw = TweenService:Create(panelScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {Scale = 0.85})
        tw.Completed:Connect(function() if not open then panel.Visible = false end end)
        tw:Play()
    end
end)
TweenService:Create(panelScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1}):Play()

-- header + marquee + jam
local header = new("Frame", {BackgroundColor3 = WHITE, Size = UDim2.new(1, 0, 0, 32)}, panel)
corner(header, 14)
local headerG = grad(header, PINK, RED, 0)

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
        local maxW = math.max(330, v.X - panel.Position.X.Offset - 4)
        local maxH = math.max(270, v.Y - panel.Position.Y.Offset - 4)
        local w = math.clamp(startPanelSize.X.Offset + dx / sc, 330, maxW)
        local h = math.clamp(startPanelSize.Y.Offset + dy / sc, 270, maxH)
        panel.Size = UDim2.fromOffset(w, h)
    elseif kind == "end" then
        saveGeom()
    end
end)

new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, TextSize = 13, TextColor3 = WHITE,
    Position = UDim2.new(0, 10, 0, 0), Size = UDim2.new(0, 128, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Left, Text = "GOPAL IMPORTER+",
}, header)

local marqueeClip = new("Frame", {
    BackgroundTransparency = 1, ClipsDescendants = true,
    Position = UDim2.new(0, 142, 0, 0), Size = UDim2.new(1, -142 - 82, 1, 0),
}, header)
local marquee = new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 11,
    TextColor3 = Color3.fromRGB(255, 235, 245), AutomaticSize = Enum.AutomaticSize.X,
    Size = UDim2.new(0, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
    Text = "★ GOPAL IMPORTER+ V1 ★ Welcome, " .. LocalPlayer.DisplayName .. " ★ RBXM / RBXL Loader ★ ",
}, marqueeClip)

local clock = new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11, TextColor3 = WHITE,
    Position = UDim2.new(1, -82, 0, 0), Size = UDim2.new(0, 76, 1, 0),
    TextXAlignment = Enum.TextXAlignment.Right, Text = "--:--:-- WIB",
}, header)

-- kartu profil Roblox
local card = new("Frame", {
    BackgroundColor3 = WHITE, Position = UDim2.new(0, 8, 0, 38), Size = UDim2.new(1, -16, 0, 56),
}, panel)
corner(card, 12)
grad(card, Color3.fromRGB(56, 16, 44), Color3.fromRGB(34, 12, 30), 0)
stroke(card, PINK, 1, 0.55)

local avatar = new("ImageLabel", {
    BackgroundColor3 = Color3.fromRGB(24, 10, 22), Position = UDim2.new(0, 8, 0, 6),
    Size = UDim2.new(0, 44, 0, 44), Image = "",
}, card)
corner(avatar, 99)
local avatarG = grad(stroke(avatar, WHITE, 2.5, 0), PINK, RED, 0)

new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = WHITE,
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 60, 0, 6), Size = UDim2.new(1, -150, 0, 18), Text = LocalPlayer.DisplayName,
}, card)
new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = HOT,
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 60, 0, 24), Size = UDim2.new(1, -150, 0, 14), Text = "@" .. LocalPlayer.Name,
}, card)
new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = Color3.fromRGB(190, 150, 175),
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 60, 0, 38), Size = UDim2.new(1, -150, 0, 14),
    Text = "ID " .. LocalPlayer.UserId .. "  •  " .. LocalPlayer.AccountAge .. " hari",
}, card)

local pill = new("Frame", {
    BackgroundColor3 = RED, BackgroundTransparency = 0.8,
    Position = UDim2.new(1, -84, 0.5, -11), Size = UDim2.new(0, 76, 0, 22),
}, card)
corner(pill, 99)
stroke(pill, PINK, 1, 0.3)
local dot = new("Frame", {
    BackgroundColor3 = Color3.fromRGB(80, 255, 160), Position = UDim2.new(0, 9, 0.5, -4), Size = UDim2.new(0, 8, 0, 8),
}, pill)
corner(dot, 99)
new("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = WHITE,
    Position = UDim2.new(0, 22, 0, 0), Size = UDim2.new(1, -26, 1, 0), Text = "ACTIVE",
}, pill)

task.spawn(function()
    local ok, img = pcall(function()
        return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
    end)
    if ok and img then avatar.Image = img end
end)

-- tombol aksi
local setStatus
local bx = 8
local function nextBtn(text, w)
    local b, g, l = mkBtn(panel, text, UDim2.new(0, bx, 0, 100), UDim2.new(0, w, 0, 28))
    bx = bx + w + 4
    return b, g, l
end
local btnScan             = nextBtn("SCAN", 58)
local btnRefresh          = nextBtn("REFRESH", 72)
local btnAnchor, gAnchor, lAnchor = nextBtn("ANCHOR: ON", 86)
local btnHook, gHook, lHook = nextBtn("HOOK: ON", 74)
local btnLog              = nextBtn("LOG", 46)

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

-- search
local search = new("TextBox", {
    PlaceholderText = "cari file...", Text = "", ClearTextOnFocus = false,
    Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = WHITE,
    PlaceholderColor3 = Color3.fromRGB(170, 130, 155), BackgroundColor3 = Color3.fromRGB(34, 12, 30),
    TextXAlignment = Enum.TextXAlignment.Left,
    Position = UDim2.new(0, 8, 0, 132), Size = UDim2.new(1, -84, 0, 26),
}, panel)
corner(search, 8)
new("UIPadding", {PaddingLeft = UDim.new(0, 10)}, search)
local searchStroke = stroke(search, PINK, 1, 0.6)
search.Focused:Connect(function()
    TweenService:Create(searchStroke, TweenInfo.new(0.2), {Transparency = 0}):Play()
end)
search.FocusLost:Connect(function()
    TweenService:Create(searchStroke, TweenInfo.new(0.2), {Transparency = 0.6}):Play()
end)

-- mode daftar: FILE (file rbxm) atau SCRIPT (script di dalam file, untuk diedit)
local mode = "files"
local render
local openEditor
local _, _, lMode
local btnMode
btnMode, _, lMode = mkBtn(panel, "MODE: FILE", UDim2.new(1, -72, 0, 132), UDim2.new(0, 64, 0, 26), 10)
btnMode.MouseButton1Click:Connect(function()
    mode = (mode == "files") and "scripts" or "files"
    lMode.Text = (mode == "files") and "MODE: FILE" or "MODE: SCRIPT"
    search.PlaceholderText = (mode == "files") and "cari file..." or "cari script (nama)..."
    local shown = render()
    if mode == "scripts" then
        setStatus(#state.idx .. " script ter-index, tampil " .. shown .. " (ketik untuk mencari)", HOT)
    else
        setStatus(#files .. " file", HOT)
    end
end)

-- list
local list = new("ScrollingFrame", {
    BackgroundColor3 = Color3.fromRGB(20, 8, 20), BackgroundTransparency = 0.2, BorderSizePixel = 0,
    ScrollBarThickness = 4, ScrollBarImageColor3 = PINK,
    Position = UDim2.new(0, 8, 0, 162), Size = UDim2.new(1, -16, 1, -194),
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, panel)
corner(list, 10)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, list)
new("UIPadding", {PaddingTop = UDim.new(0, 5), PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5)}, list)

-- status bar
local statusLabel = new("TextLabel", {
    BackgroundColor3 = Color3.fromRGB(38, 12, 30), Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = HOT,
    TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
    Position = UDim2.new(0, 8, 1, -26), Size = UDim2.new(1, -46, 0, 20), Text = " Siap. Tekan SCAN.",
}, panel)
corner(statusLabel, 8)


setStatus = function(text, color)
    statusLabel.Text = " " .. tostring(text)
    statusLabel.TextColor3 = color or HOT
end

local files = {}

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

local function makeRow(i, title, subtitle, btnText, onClick)
    local row = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(44, 14, 34), Size = UDim2.new(1, 0, 0, 42), LayoutOrder = i,
    }, list)
    corner(row, 9)
    local bar = new("Frame", {BackgroundColor3 = WHITE, Size = UDim2.new(0, 3, 1, 0), BorderSizePixel = 0}, row)
    grad(bar, PINK, RED, 90)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = WHITE,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 12, 0, 4), Size = UDim2.new(1, -92, 0, 18), Text = title,
    }, row)
    new("TextLabel", {
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10, TextColor3 = HOT,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        Position = UDim2.new(0, 12, 0, 23), Size = UDim2.new(1, -92, 0, 14), Text = subtitle,
    }, row)
    local b = mkBtn(row, btnText, UDim2.new(1, -74, 0.5, -14), UDim2.new(0, 66, 0, 28), 11)
    b.MouseButton1Click:Connect(onClick)
end

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
    mx = mx - dt * 45
    if mx < -marquee.AbsoluteSize.X then mx = marqueeClip.AbsoluteSize.X end
    marquee.Position = UDim2.new(0, mx, 0, 0)

    local c = os.date("!%H:%M:%S", os.time() + 25200)
    if c ~= lastClock then
        lastClock = c
        clock.Text = c .. " WIB"
    end

    panelStrokeG.Rotation = (t * 70) % 360
    avatarG.Rotation = (t * 120) % 360
    headerG.Offset = Vector2.new(math.sin(t * 1.5) * 0.25, 0)
    dot.BackgroundTransparency = 0.5 + math.sin(t * 5) * 0.5

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

print("GOPAL IMPORTER V1 ACTIVATED")

end, function(e) return debug.traceback(tostring(e)) end)

if not ok_main then GOPAL_ShowError(err_main) end
