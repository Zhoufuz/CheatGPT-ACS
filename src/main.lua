-- 单文件私有状态：跨区域函数/配置放在局部表中，不向执行器环境写入同名全局。
-- 临时对象用 do ... end 缩短生命周期；块内仍计入外层存活的 local，不能靠嵌套块无限叠加。
-- 仅重复运行锁需要通过 _G / getgenv() / shared 在不同执行之间共享。
local app = {}
app.debugErrors = {}
function app.recordDebugError(tag, message)
    local entries = app.debugErrors
    entries[#entries + 1] = string.format("%.1fs [%s] %s", os.clock(), tostring(tag), tostring(message):sub(1, 1000))
    if #entries > 30 then table.remove(entries, 1) end
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Teams = game:GetService("Teams")
local StarterGui = game:GetService("StarterGui")
local CoreGui = game:GetService("CoreGui")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local TextService = game:GetService("TextService")
local LocalPlayer = Players.LocalPlayer

-- 多层运行锁：同时校验执行器全局环境、shared 状态和 CoreGui 隐形哨兵，避免只依赖一个可读写的布尔值。
app.CHEATGPT_RUNTIME_SIGNATURE = "CheatGPT.Runtime.Lock.v3"
app.CHEATGPT_RUNTIME_SENTINEL_NAME = "__CheatGPTRuntime_7F3A91D2"

function app.cheatGPTGetExecutorGlobal()
    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then return env end
    end
    return nil
end

function app.cheatGPTGetRuntimeStores()
    local stores = {_G}
    local executorGlobal = app.cheatGPTGetExecutorGlobal()
    if executorGlobal and executorGlobal ~= _G then
        stores[#stores + 1] = executorGlobal
    end
    if type(shared) == "table" then
        stores[#stores + 1] = shared
    end
    return stores
end

function app.cheatGPTGetRuntimeSentinel()
    local parents = {CoreGui}
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui and hui ~= CoreGui then parents[#parents + 1] = hui end
    end
    for _, parent in ipairs(parents) do
        local ok, child = pcall(parent.FindFirstChild, parent, app.CHEATGPT_RUNTIME_SENTINEL_NAME)
        if ok and child then
            local okSignature, signature = pcall(child.GetAttribute, child, "Signature")
            if okSignature and signature == app.CHEATGPT_RUNTIME_SIGNATURE then
                return child
            end
        end
    end
    return nil
end

function app.cheatGPTRuntimeStateIsLive(state)
    if type(state) ~= "table" or state.signature ~= app.CHEATGPT_RUNTIME_SIGNATURE then
        return false
    end
    local sealed = state.seal == (app.CHEATGPT_RUNTIME_SIGNATURE .. ":" .. tostring(state.version or ""))
    if not sealed or type(state.probe) ~= "function" then return false end
    local probeOk, probeValue = pcall(state.probe, app.CHEATGPT_RUNTIME_SIGNATURE)
    if not probeOk or probeValue ~= true then return false end
    local now = os.clock()
    local heartbeat = tonumber(state.heartbeatAt) or 0
    local sentinelAlive = state.sentinel and state.sentinel.Parent ~= nil
    local recentlyStarted = now - (tonumber(state.startedAt) or 0) < 15
    return state.active == true and (sentinelAlive or recentlyStarted or now - heartbeat < 8)
end

function app.cheatGPTReleaseRuntimeState(state)
    state = state or app.CHEATGPT_RUNTIME_STATE
    if type(state) ~= "table" then return end
    state.active = false
    if state.sentinel then pcall(state.sentinel.Destroy, state.sentinel) end
    for _, store in ipairs(app.cheatGPTGetRuntimeStores()) do
        if rawget(store, "CheatGPT_RuntimeLock") == state then
            pcall(rawset, store, "CheatGPT_RuntimeLock", nil)
        end
    end
    if app.CHEATGPT_RUNTIME_STATE == state then app.CHEATGPT_RUNTIME_STATE = nil end
end

function app.cheatGPTInstallRuntimeState()
    local existingSentinel = app.cheatGPTGetRuntimeSentinel()
    local stores = app.cheatGPTGetRuntimeStores()
    for _, store in ipairs(stores) do
        local existing = rawget(store, "CheatGPT_RuntimeLock")
        if app.cheatGPTRuntimeStateIsLive(existing) then
            return false, existing
        end
    end
    if existingSentinel then
        local okStarted, startedAt = pcall(existingSentinel.GetAttribute, existingSentinel, "StartedAt")
        if okStarted and tonumber(startedAt) and os.clock() - tonumber(startedAt) < 15 then
            return false
        end
        pcall(existingSentinel.Destroy, existingSentinel)
    end

    local state = {
        signature = app.CHEATGPT_RUNTIME_SIGNATURE,
        version = 3,
        startedAt = os.clock(),
        heartbeatAt = os.clock(),
        active = true,
        probe = function(value) return value == app.CHEATGPT_RUNTIME_SIGNATURE end,
    }
    state.seal = app.CHEATGPT_RUNTIME_SIGNATURE .. ":" .. tostring(state.version)

    local sentinelParent = nil
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then sentinelParent = hui end
    end
    sentinelParent = sentinelParent or CoreGui
    local okSentinel, sentinel = pcall(function()
        local folder = Instance.new("Folder")
        folder.Name = app.CHEATGPT_RUNTIME_SENTINEL_NAME
        folder:SetAttribute("Signature", app.CHEATGPT_RUNTIME_SIGNATURE)
        folder:SetAttribute("Version", state.version)
        folder:SetAttribute("StartedAt", tostring(state.startedAt))
        folder.Parent = sentinelParent
        return folder
    end)
    if okSentinel then state.sentinel = sentinel end

    for _, store in ipairs(stores) do
        pcall(rawset, store, "CheatGPT_RuntimeLock", state)
    end
    app.CHEATGPT_RUNTIME_STATE = state
    task.spawn(function()
        while state.active do
            state.heartbeatAt = os.clock()
            task.wait(2)
        end
    end)
    return true
end

-- 启动进度仅保留内部状态；不创建加载面板。失败通过现有通知入口报告。
local startup = {stage = "启动检查", retrySafe = true}
function app.startupReport(state, message, failed)
    state.lastMessage = message
    if not failed then return end
    if app.showNotification then
        pcall(app.showNotification, "CheatGPT.cc", message, 10, {error = true, copyText = message})
    else
        pcall(StarterGui.SetCore, StarterGui, "SendNotification", {
            Title = "CheatGPT.cc", Text = message, Duration = 10,
        })
    end
end

do
    local installed, existing = app.cheatGPTInstallRuntimeState()
    if not installed then
        if existing and type(existing.reveal) == "function" then
            local ok = pcall(existing.reveal)
            if ok then return end
        end
        app.startupReport(startup, "检测到已有运行实例。若没有窗口，请退出并重新进入服务器，清除旧版残留状态后再运行。", true)
        return
    end
end
startup.runtime = app.CHEATGPT_RUNTIME_STATE
startup.runtime.phase = "starting"
app.startupReport(startup, "正在准备配置与界面…", false)
startup.runtime.reveal = function()
    app.startupReport(startup, startup.failure or ("正在加载：" .. startup.stage), startup.failure ~= nil)
end
-- 只报告慢启动，不强行释放仍在执行的实例，避免重复安装功能。
task.delay(15, function()
    if startup.runtime.active and startup.runtime.phase == "starting" then
        app.startupReport(startup, "启动仍在等待：" .. startup.stage .. "。若长期不变，请把此阶段名称反馈。", true)
    end
end)

local startupOK, startupError = xpcall(function()
-- 错误统一走通知；同一来源 5 秒内只报一次，不写控制台。
local __xpcallw_last = {}
function app.xpcallw(f, tag, ...)
    return xpcall(f, function(err)
        if app.CONFIG_RESETTING then app.CONFIG_RESET_FAILED = true end
        local now = os.clock()
        local last = __xpcallw_last[tag]
        if not last or now - last >= 5 then
            __xpcallw_last[tag] = now
            app.recordDebugError(tag, err)
            -- 同步弹出自定义错误通知；"通知" 来源自身出错时不再弹，避免递归
            if app.showNotification and tag ~= "通知" then
                local line = tostring(err):match(":(%d+):") or "?"
                pcall(app.showNotification,
                    "Oops! Something went error on line " .. line,
                    "[CheatGPT.cc] " .. tostring(err),
                    10,
                    {
                        iconKey = "bug",
                        copyText = tostring(err),
                        error = true,
                    })
            end
        end
    end, ...)
end

-- 修改可能被锁定的表(env/mod 表/metatable)前调用:readonly 就先解锁再改
function app.ensureTableWritable(t)
    if type(t) ~= "table" then return end
    if not app.executorSupports("isreadonly", "setreadonly") then return end -- 执行器缺失:跳过解锁,写入成败由调用点 xpcallw 兜底
    app.xpcallw(function()
        if isreadonly(t) then
            setreadonly(t, false)
        end
    end, "setreadonly")
end

-- ================= 配置区域 =================
app.ORBIT_RADIUS_MIN = 10
app.ORBIT_RADIUS_MAX = 18
app.TRACE_LIFETIME = 3
app.TRACE_WIDTH = 0.28
app.TRACE_STYLE = "Basic"
app.FADE_TIME = 0.2
app.MAX_TRACE_DISTANCE = 300
app.BULLET_TRACE_MODE = "From Cam"
app.WALLBANG = false
app.TRACE_COOLDOWN = 0.1
app.TARGET_PRIORITY = "Distance"
app.RAGE_HIT_PART = "Head"
app.RAGE_HIT_PART_OPTIONS = {"Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg"}
app.RAGE_HIT_PART_FALLBACKS = {
    ["Head"] = {"Head"},
    ["Torso"] = {"Torso", "UpperTorso", "LowerTorso"},
    ["Left Arm"] = {"Left Arm", "LeftUpperArm", "LeftLowerArm", "LeftHand"},
    ["Right Arm"] = {"Right Arm", "RightUpperArm", "RightLowerArm", "RightHand"},
    ["Left Leg"] = {"Left Leg", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot"},
    ["Right Leg"] = {"Right Leg", "RightUpperLeg", "RightLowerLeg", "RightFoot"},
}
app.HITMARKER_MODE = "Centre"
app.HITMARKER_ENABLED = true
app.HIT_EFFECT_ENABLED = false
app.KILL_EFFECT_ENABLED = false
app.KILL_EFFECT_STYLE = "Valorant"
app.KILL_EFFECT_COLLECTION = "2021 Vandal"
app.KILL_EFFECT_COLLECTIONS = {"2021 Vandal", "Recon", "Rogue", "Singularity"}
app.KILL_SOUNDS_VOLUME = 2
app.HIT_EFFECT_COLOR = Color3.fromRGB(255, 255, 255)
app.HIT_EFFECT_TRANSPARENCY = 0.35
app.SHOW_IMPACT_ENABLED = false
app.SHOW_IMPACT_COLOR = Color3.fromRGB(255, 210, 90)
app.SHOW_IMPACT_TRANSPARENCY = 0.22
app.SHOW_IMPACT_MATERIAL = "Neon"
app.SHOW_IMPACT_SIZE = 0.35
app.SHOW_IMPACT_MATERIAL_OPTIONS = {"Neon", "ForceField", "Glass", "SmoothPlastic"}
app.SPREAD_FOV_ENABLED = false
app.SPREAD_FOV_COLOR = Color3.fromRGB(255, 255, 255)
app.SPREAD_FOV_TRANSPARENCY = 0.35
-- RageBot 多线程参数
app.RAGE_MULTI_TARGET = 3   -- 每帧最多同时攻击的目标数
app.RAGE_SCAN_LIMIT = 8     -- 扫描线程每帧最多精修的候选数
app.RAGE_THREADS_PER_TARGET = 1 -- 对单个目标同时并发发送攻击的线程数(无论如何不能小于 1)
app.RAGE_FIRE_BURST = 2         -- 每个帧事件(Stepped/PreAnimation/Heartbeat)触发时连续开火的轮数,与事件数相乘放大射速(无论如何不能小于 1)
app.RAGE_MAX_PENDING = 300      -- 同时在途的攻击请求上限,超过则暂停开火等回落,防并发子线程无限堆积(无论如何不能小于 1)
app.RAPID_FIRE_RATE = 10000     -- Rapid Fire 自定义射速(发/分钟),开启 Rapid Fire 后生效(通过 hook wait 实现,不改表)。
                            -- 实际射速受此值与引擎帧率下限的较小者限制:v1/v2 的 wait() 最快≈30/s,v3 的 task.wait() 最快≈60/s(每帧最多一发);
                            -- 10000 已远超下限,相当于顶格"每帧一发",想降速才需要调小此值

-- 精简后的音效列表
app.HITSOUNDS = {
    ["Bameware"] = "rbxassetid://3124331820",
    ["Skeet"] = "rbxassetid://5633695679",
    ["Neverlose"] = "rbxassetid://6534948092",
    ["Pick"] = "rbxassetid://1347140027",
    ["xp"] = "rbxassetid://17148249625",
    ["Minecraft"] = "rbxassetid://4018616850",
    ["Hit"] = "rbxassetid://125235091454234",
    ["TF2"] = "rbxassetid://137392628136734",
    -- Base64 音效的值是执行器不支持本地文件时的安全回退音效。
    ["Unknown"] = "rbxassetid://5633695679",
    ["Arcade"] = "rbxassetid://5633695679",
    ["Cartoon"] = "rbxassetid://5633695679",
    ["Glass"] = "rbxassetid://5633695679",
}

app.HITSOUND_ASSETS = {
    ["Unknown"] = {Path="cheatgpt/v1/hitsounds/Unknown-e705f0cdb3ee.mp3.lzma2", Size=6454, CRC32=3331644145, PackedSize=5866, PackedCRC32=2655341842},
    ["Arcade"] = {Path="cheatgpt/v1/hitsounds/Arcade-d4f294e3389f.mp3.lzma2", Size=6403, CRC32=642820381, PackedSize=5816, PackedCRC32=3998374800},
    ["Cartoon"] = {Path="cheatgpt/v1/hitsounds/Cartoon-f1d2e5395dbd.mp3.lzma2", Size=6408, CRC32=2317729920, PackedSize=6110, PackedCRC32=4017488471},
}

app.TAB_ICON_ASSETS = {
    ["Legit"] = {Path="cheatgpt/v1/icons/Legit-32c945c3f377.png.lzma2", Size=23169, CRC32=4241053929, PackedSize=20695, PackedCRC32=3963655523},
    ["Rage"] = {Path="cheatgpt/v1/icons/Rage-4ae9e513c04d.png.lzma2", Size=26036, CRC32=864785719, PackedSize=23418, PackedCRC32=4265677224},
    ["Visual"] = {Path="cheatgpt/v1/icons/Visual-350604583cb7.png.lzma2", Size=27224, CRC32=4193605592, PackedSize=24471, PackedCRC32=4201635866},
    ["LocalPlayer"] = {Path="cheatgpt/v1/icons/LocalPlayer-a63d5f5813f0.png.lzma2", Size=21489, CRC32=1481524962, PackedSize=18799, PackedCRC32=293540338},
    ["PlayersList"] = {Path="cheatgpt/v1/icons/PlayersList-af4aac3db9a9.png.lzma2", Size=10246, CRC32=1911626165, PackedSize=7864, PackedCRC32=3213572202},
    ["Setting"] = {Path="cheatgpt/v1/icons/Setting-162fb6bcd306.png.lzma2", Size=31352, CRC32=567032237, PackedSize=28880, PackedCRC32=3601423837},
    ["bug"] = {Path="cheatgpt/v1/icons/bug-dc974a1e8ca7.png.lzma2", Size=19728, CRC32=3027704835, PackedSize=17384, PackedCRC32=640412177},
    ["Glass"] = {Path="cheatgpt/v1/icons/Glass-c7bb197abe65.png.lzma2", Size=9613, CRC32=690334327, PackedSize=8995, PackedCRC32=3591146141},
}
app.HITSOUND_KEY = "Skeet"
app.HITSOUND_VOLUME = 0.8
app.LAST_HITSOUND_TIME = 0
app.HITSOUND_COOLDOWN = 0.05
app.HITSOUND_ENABLED = true

-- 内嵌 Base64 音效运行时解码为执行器本地 MP3；无法创建本地资产时由 HITSOUNDS 的回退 ID 播放。
app.GLASS_WAV_ASSET = {Path="cheatgpt/v1/hitsounds/Glass-fallback-920e831189be.wav.lzma2", Size=49656, CRC32=755762989, PackedSize=20822, PackedCRC32=3988452028}
app.HITSOUND_LOCAL_ASSETS = {}
app.TAB_ICON_LOCAL_ASSETS = {}
-- Raw LZMA2 for embedded resources, implemented from the LZMA SDK specification
-- and the LZMA2 chunk protocol. No executor-specific compression API is required.
-- https://github.com/jljusten/LZMA-SDK/blob/master/DOC/lzma-specification.txt
-- https://github.com/tukaani-project/xz/blob/master/src/liblzma/lzma/lzma2_decoder.c
function app.decodeLzma2(input, expected, idle)
    assert(type(expected) == "number" and expected >= 0 and expected <= 8388608 and expected % 1 == 0, "Invalid LZMA2 output size")
    local output = buffer.create(expected)
    local cursor, written, dictStart = 1, 0, 0
    local needDictionary, needProperties, needState = true, true, true
    local lc, lp, pb, state, rep0, rep1, rep2, rep3
    local probabilities, range, code, limit
    local floor, read8, write8 = math.floor, buffer.readu8, buffer.writeu8
    local canYield = type(task) == "table" and type(task.wait) == "function" and coroutine.isyieldable()
    local budget = idle and 0.001 or 0.004
    local nextCheck, deadline = 4096, os.clock() + budget
    local function byte()
        assert(cursor <= #input, "Truncated LZMA2 stream")
        local value = input:byte(cursor)
        cursor += 1
        return value
    end
    local function u16() return byte() * 256 + byte() end
    local function normalize()
        if range < 16777216 then
            assert(cursor < limit, "Truncated LZMA range stream")
            range *= 256
            code = (code * 256 + byte()) % 4294967296
        end
    end
    local function bit(index)
        local probability = probabilities[index] or 1024
        local bound = floor(range / 2048) * probability
        local value
        if code < bound then
            range = bound
            probabilities[index] = probability + floor((2048 - probability) / 32)
            value = 0
        else
            range -= bound
            code -= bound
            probabilities[index] = probability - floor(probability / 32)
            value = 1
        end
        normalize()
        return value
    end
    local function tree(base, bits, reverse)
        local symbol, result, power = 1, 0, 1
        for _ = 1, bits do
            local value = bit(base + symbol)
            symbol = symbol * 2 + value
            result += value * power
            power *= 2
        end
        return reverse and result or symbol - power
    end
    local function direct(bits)
        local result = 0
        for _ = 1, bits do
            range = floor(range / 2)
            local value = 0
            if code >= range then code -= range; value = 1 end
            normalize()
            result = result * 2 + value
        end
        return result
    end
    -- Disjoint model regions, with zero-based state/position indexing.
    -- isMatch:0, isRep:192, repG0:204, repG1:216, repG2:228,
    -- rep0Long:240, lengths:432/946, slots:1460, distances:1716,
    -- align:1844, literals:1860.
    local function length(base, position)
        if bit(base) == 0 then return tree(base + 2 + position * 8, 3, false) + 2 end
        if bit(base + 1) == 0 then return tree(base + 130 + position * 8, 3, false) + 10 end
        return tree(base + 258, 8, false) + 18
    end
    local function reset()
        probabilities = {}
        state, rep0, rep1, rep2, rep3 = 0, 0, 0, 0, 0
        needState = false
    end
    while true do
        if canYield and os.clock() >= deadline then
            task.wait()
            if idle then idle() end
            deadline = os.clock() + budget
        end
        local control = byte()
        if control == 0 then
            assert(written == expected and cursor == #input + 1, "LZMA2 size/trailing data mismatch")
            return buffer.tostring(output)
        end
        if control == 1 or control >= 224 then
            dictStart = written
            needDictionary, needProperties, needState = false, true, true
        else
            assert(not needDictionary, "Missing LZMA2 dictionary reset")
        end
        if control < 128 then
            assert(control == 1 or control == 2, "Invalid LZMA2 control")
            local size = u16() + 1
            assert(written + size <= expected and cursor + size - 1 <= #input, "Invalid LZMA2 raw chunk")
            buffer.writestring(output, written, input:sub(cursor, cursor + size - 1))
            written += size
            cursor += size
            needState = true
        else
            local size = (control % 32) * 65536 + u16() + 1
            local packed = u16() + 1
            assert(written + size <= expected, "LZMA2 output overflow")
            if control >= 192 then
                local properties = byte()
                assert(properties < 225, "Invalid LZMA properties")
                lc = properties % 9
                local rest = floor(properties / 9)
                lp, pb = rest % 5, floor(rest / 5)
                assert(lc + lp <= 4, "Unsupported LZMA2 literal context")
                needProperties = false
            end
            assert(not needProperties, "Missing LZMA2 properties")
            if control >= 160 then reset() end
            assert(not needState, "Missing LZMA2 state reset")
            limit = cursor + packed
            assert(packed >= 5 and limit - 1 <= #input and byte() == 0, "Invalid LZMA range header")
            range, code = 4294967295, 0
            for _ = 1, 4 do code = code * 256 + byte() end
            assert(code < range, "Invalid LZMA initial code")
            local finish = written + size
            while written < finish do
                if canYield and written >= nextCheck then
                    nextCheck = written + 4096
                    if os.clock() >= deadline then
                        task.wait()
                        if idle then idle() end
                        deadline = os.clock() + budget
                    end
                end
                local position = (written - dictStart) % (2 ^ pb)
                if bit(state * 16 + position) == 0 then
                    local previous = written > dictStart and read8(output, written - 1) or 0
                    local context = ((written - dictStart) % (2 ^ lp)) * (2 ^ lc) + floor(previous / (2 ^ (8 - lc)))
                    local base, symbol = 1860 + context * 768, 1
                    if state >= 7 then
                        assert(rep0 < written - dictStart, "Invalid LZMA literal distance")
                        local match = read8(output, written - rep0 - 1)
                        repeat
                            local matchBit = floor(match / 128) % 2
                            match *= 2
                            local value = bit(base + (1 + matchBit) * 256 + symbol)
                            symbol = symbol * 2 + value
                            if value ~= matchBit then break end
                        until symbol >= 256
                    end
                    while symbol < 256 do symbol = symbol * 2 + bit(base + symbol) end
                    write8(output, written, symbol - 256)
                    written += 1
                    state = state < 4 and 0 or (state < 10 and state - 3 or state - 6)
                else
                    local count
                    if bit(192 + state) == 1 then
                        if bit(204 + state) == 0 then
                            if bit(240 + state * 16 + position) == 0 then
                                count = 1
                                state = state < 7 and 9 or 11
                            end
                        else
                            local distance
                            if bit(216 + state) == 0 then
                                distance = rep1
                            else
                                if bit(228 + state) == 0 then distance = rep2 else distance = rep3; rep3 = rep2 end
                                rep2 = rep1
                            end
                            rep1, rep0 = rep0, distance
                        end
                        if not count then count = length(946, position); state = state < 7 and 8 or 11 end
                    else
                        count = length(432, position)
                        state = state < 7 and 7 or 10
                        rep3, rep2, rep1 = rep2, rep1, rep0
                        local slot = tree(1460 + math.min(count - 2, 3) * 64, 6, false)
                        rep0 = slot
                        if slot >= 4 then
                            local bits = floor(slot / 2) - 1
                            rep0 = (2 + slot % 2) * (2 ^ bits)
                            if slot < 14 then
                                rep0 += tree(1716 + rep0 - slot - 1, bits, true)
                            else
                                rep0 += direct(bits - 4) * 16 + tree(1844, 4, true)
                            end
                        end
                    end
                    local distance = rep0 + 1
                    assert(distance <= written - dictStart and distance <= 1048576 and written + count <= finish, "Invalid LZMA match")
                    while count > 0 do
                        local n = math.min(count, distance)
                        buffer.copy(output, written, output, written - distance, n)
                        written += n
                        count -= n
                    end
                end
            end
            assert(cursor == limit and code == 0, "Invalid LZMA chunk ending")
        end
    end
end

function app.resourceCrc32(bytes, idle)
    local lookup = app.RESOURCE_CRC32_TABLE
    if not lookup then
        lookup = {}
        for i = 0, 255 do
            local value = i
            for _ = 1, 8 do
                value = value % 2 == 1 and bit32.bxor(bit32.rshift(value, 1), 0xEDB88320) or bit32.rshift(value, 1)
            end
            lookup[i] = value
        end
        app.RESOURCE_CRC32_TABLE = lookup
    end
    local value = 0xFFFFFFFF
    local canYield = type(task) == "table" and type(task.wait) == "function" and coroutine.isyieldable()
    local budget = idle and 0.001 or 0.004
    local deadline = os.clock() + budget
    for i = 1, #bytes do
        value = bit32.bxor(bit32.rshift(value, 8), lookup[bit32.bxor(value, bytes:byte(i)) % 256])
        if canYield and i % 4096 == 0 and os.clock() >= deadline then
            task.wait()
            if idle then idle() end
            deadline = os.clock() + budget
        end
    end
    return bit32.bnot(value)
end

function app.decodeBase64Bytes(encoded)
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local values = {}
    for i = 1, #alphabet do values[alphabet:byte(i)] = i - 1 end
    local clean = encoded:gsub("%s", "")
    assert(#clean % 4 == 0, "Invalid Base64 length")
    local pieces, batch = {}, {}
    for i = 1, #clean, 4 do
        local a, b, c, d = clean:byte(i, i + 3)
        local x, y = values[a], values[b]
        local z, w = values[c], values[d]
        assert(x and y and (z or c == 61) and (w or d == 61), "Invalid Base64 data")
        local n = x * 262144 + y * 4096 + (z or 0) * 64 + (w or 0)
        local decoded = string.char(math.floor(n / 65536), math.floor(n / 256) % 256, n % 256)
        batch[#batch + 1] = decoded:sub(1, c == 61 and 1 or d == 61 and 2 or 3)
        if #batch == 1024 then pieces[#pieces + 1] = table.concat(batch); table.clear(batch) end
    end
    pieces[#pieces + 1] = table.concat(batch)
    return table.concat(pieces)
end

-- Public static data only: every mirror serves the same immutable Git revision.
app.ASSET_REVISION = "d54d1f2188510f15514f7fe08f1ce49693f41237"
app.RESOURCE_DOWNLOADS = {}
app.RESOURCE_DOWNLOAD_ACTIVE = 0
app.RESOURCE_QUEUE = {}
app.RESOURCE_WORKERS = 0
app.RESOURCE_HOSTS = {
    {Prefix = "https://cdn.jsdelivr.net/gh/Zhoufuz/assets@", Active = 0, RetryAt = 0},
    {Prefix = "https://fastly.jsdelivr.net/gh/Zhoufuz/assets@", Active = 0, RetryAt = 0},
    {Prefix = "https://raw.githubusercontent.com/Zhoufuz/assets/", Active = 0, RetryAt = 0},
}
function app.fetchResourceBytes(descriptor, verifyInWorker)
    assert(#app.ASSET_REVISION == 40 and app.ASSET_REVISION:match("^[0-9a-f]+$"), "Assets revision is not pinned")
    local timeout = math.clamp(math.ceil(descriptor.PackedSize / 65536), 15, 90)
    local lastError = "All resource hosts are temporarily unavailable"
    for round = 1, 2 do
        local order = {}
        local preferred = app.RESOURCE_PREFERRED_HOST
        if preferred then order[#order + 1] = preferred end
        for _, host in ipairs(app.RESOURCE_HOSTS) do
            if host ~= preferred then order[#order + 1] = host end
        end
        for _, host in ipairs(order) do
            -- A hung native call retains its slot. Other hosts can still make progress;
            -- repeated retries never create an unbounded number of native requests.
            if host.Active < 2 and (round == 2 or os.clock() >= host.RetryAt) then
                local url = host.Prefix .. app.ASSET_REVISION .. "/" .. descriptor.Path
                local attempt = {Done = false}
                host.Active += 1
                app.RESOURCE_DOWNLOAD_ACTIVE += 1
                task.spawn(function()
                    local ok, value = pcall(function()
                        local requestFn = type(request) == "function" and request or (type(http_request) == "function" and http_request)
                        if not requestFn and type(syn) == "table" and type(syn.request) == "function" then requestFn = syn.request end
                        if not requestFn and type(http) == "table" and type(http.request) == "function" then requestFn = http.request end
                        local body
                        if requestFn then
                            local response = requestFn({Url = url, Method = "GET", Timeout = timeout})
                            local status = type(response) == "table" and tonumber(response.StatusCode or response.Status)
                            assert(status == 200, "HTTP " .. tostring(status or "invalid response"))
                            body = response.Body
                        else
                            body = game:HttpGet(url)
                        end
                        assert(type(body) == "string" and #body == descriptor.PackedSize, "Resource download size mismatch")
                        -- Compaction verifies in its worker so a paused checksum
                        -- cannot consume the HTTP timeout while a banner plays.
                        if not verifyInWorker then assert(app.resourceCrc32(body) == descriptor.PackedCRC32, "Packed resource CRC mismatch") end
                        return body
                    end)
                    host.Active -= 1
                    app.RESOURCE_DOWNLOAD_ACTIVE -= 1
                    if not attempt.Expired then
                        attempt.OK, attempt.Value, attempt.Done = ok, value, true
                    end
                end)
                local deadline = os.clock() + timeout
                while not attempt.Done and os.clock() < deadline do task.wait() end
                if attempt.Done and attempt.OK then
                    host.RetryAt = 0
                    app.RESOURCE_PREFERRED_HOST = host
                    return attempt.Value
                end
                attempt.Expired = true
                host.RetryAt = os.clock() + 30
                lastError = host.Prefix .. ": " .. tostring(attempt.Done and attempt.Value or "HTTP request timed out")
            end
        end
        if round == 1 then task.wait(2) end
    end
    return nil, lastError
end

function app.waitForCacheIdle()
    while app.killEffect and app.killEffect.IsPlaying and app.killEffect.IsPlaying() do task.wait(0.25) end
end

function app.pumpResourceQueue()
    while app.RESOURCE_WORKERS < 2 and #app.RESOURCE_QUEUE > 0 do
        local best = 1
        for index = 2, #app.RESOURCE_QUEUE do
            if app.RESOURCE_QUEUE[index].Priority > app.RESOURCE_QUEUE[best].Priority then best = index end
        end
        -- Compaction uses at most one worker; foreground resources retain a lane.
        if app.RESOURCE_QUEUE[best].Upgrade and app.CACHE_COMPACTION_ACTIVE then break end
        local record = table.remove(app.RESOURCE_QUEUE, best)
        if record.Upgrade then app.CACHE_COMPACTION_ACTIVE = true end
        app.RESOURCE_WORKERS += 1
        record.Running = true
        task.spawn(function()
            local ok, result = pcall(function()
                local idle = record.Upgrade and app.waitForCacheIdle or nil
                if idle then idle() end
                local bytes, err = app.fetchResourceBytes(record.Descriptor, record.Upgrade)
                assert(bytes, err)
                if idle then
                    idle()
                    assert(app.resourceCrc32(bytes, idle) == record.Descriptor.PackedCRC32, "Packed resource CRC mismatch")
                end
                bytes = app.decodeLzma2(bytes, record.Descriptor.Size, idle)
                assert(app.resourceCrc32(bytes, idle) == record.Descriptor.CRC32, "Decoded resource CRC mismatch")
                assert(type(writefile) == "function", "Resources require writefile")
                app.ensureCheatGPTAcsStorage()
                -- Background compaction must not sacrifice a working old cache on
                -- a failed write. Keep its recovery copy in memory, never on disk.
                if record.Upgrade then
                    app.waitForCacheIdle()
                    local oldOk, oldBytes = pcall(readfile, record.CachePath)
                    local saved, saveError = pcall(function()
                        writefile(record.CachePath, bytes)
                        local persisted = readfile(record.CachePath)
                        assert(persisted == bytes, "Compacted cache write verification failed")
                    end)
                    if not saved then
                        if oldOk and type(oldBytes) == "string" then
                            local restored, restoreError = pcall(writefile, record.CachePath, oldBytes)
                            if not restored then warn("[CheatGPT cache] Restore failed: " .. tostring(restoreError)) end
                        end
                        error(saveError)
                    end
                else
                    writefile(record.CachePath, bytes)
                    assert(type(readfile) == "function" and readfile(record.CachePath) == bytes,
                        "Resource cache write verification failed")
                end
                return bytes
            end)
            record.Done = true
            app.RESOURCE_WORKERS -= 1
            if record.Upgrade then app.CACHE_COMPACTION_ACTIVE = false end
            if ok then
                record.Bytes = result
            else
                record.Error, record.RetryAt = tostring(result), os.clock() + 15
                warn("[CheatGPT resources] " .. record.Descriptor.Path .. ": " .. record.Error)
            end
            task.delay(ok and 2 or 16, function()
                if app.RESOURCE_DOWNLOADS[record.Key] == record then app.RESOURCE_DOWNLOADS[record.Key] = nil end
            end)
            app.pumpResourceQueue()
        end)
    end
end

function app.queueCacheCompaction(descriptor, cachePath)
    app.CACHE_COMPACTION_JOBS = app.CACHE_COMPACTION_JOBS or {}
    local key = descriptor.Path
    if app.CACHE_COMPACTION_JOBS[key] then return end
    app.CACHE_COMPACTION_JOBS[key] = true
    -- Existing decoded assets remain immediately usable. Upgrade below all
    -- foreground preload jobs, without changing their registered asset URI.
    task.delay(15, function()
        if app.RESOURCE_DOWNLOADS[key] then return end
        local record = {Key = key, Descriptor = descriptor, CachePath = cachePath,
            Done = false, Priority = -100, Upgrade = true}
        app.RESOURCE_DOWNLOADS[key] = record
        app.RESOURCE_QUEUE[#app.RESOURCE_QUEUE + 1] = record
        app.pumpResourceQueue()
    end)
end

function app.readResourceBytes(descriptor, cachePath, priority)
    assert(type(descriptor) == "table" and type(descriptor.Path) == "string", "Invalid resource descriptor")
    assert(descriptor.Path:match("^cheatgpt/v1/[%w%-%._/]+$") and not descriptor.Path:find("..", 1, true), "Invalid resource path")
    assert(descriptor.Size > 0 and descriptor.Size <= 8388608 and descriptor.PackedSize > 0 and descriptor.PackedSize <= 8388608, "Invalid resource size")
    if type(readfile) == "function" then
        local ok, bytes = pcall(readfile, cachePath)
        if ok and type(bytes) == "string" and #bytes == descriptor.Size and app.resourceCrc32(bytes) == descriptor.CRC32 then return bytes end
        if ok and type(bytes) == "string" and descriptor.PreviousSize == #bytes
            and app.resourceCrc32(bytes) == descriptor.PreviousCRC32 then
            app.queueCacheCompaction(descriptor, cachePath)
            return bytes
        end
    end
    local key = descriptor.Path
    local record = app.RESOURCE_DOWNLOADS[key]
    if record and record.Done and record.Error and os.clock() >= record.RetryAt then record = nil end
    if not record then
        record = {Key = key, Descriptor = descriptor, CachePath = cachePath, Done = false, Priority = priority or 0}
        app.RESOURCE_DOWNLOADS[key] = record
        app.RESOURCE_QUEUE[#app.RESOURCE_QUEUE + 1] = record
        app.pumpResourceQueue()
    else
        record.Priority = math.max(record.Priority, priority or 0)
    end
    if not record.Done and not coroutine.isyieldable() then return nil, "Resource is loading" end
    -- Queue time does not consume the per-attempt HTTP timeout. A detached caller
    -- leaves the shared job intact, so another caller cannot duplicate its download.
    local deadline = os.clock() + 600
    while not record.Done and os.clock() < deadline do task.wait() end
    if not record.Done then return nil, "Resource is still loading; retry shortly" end
    if record.Bytes and cachePath ~= record.CachePath then
        local ok, err = pcall(writefile, cachePath, record.Bytes)
        if not ok then return nil, tostring(err) end
    end
    return record.Bytes, record.Error
end

-- Only obsolete, byte-identified HQ2 animation pages are reclaimable. The
-- current atlas must have registered successfully before its stage is queued.
do
    local legacy = {
        [1] = {{1,38991,3525758684},{2,150418,3528862537},{3,139402,2166192401},{4,170714,187837435},{5,117830,2260227590},{6,103375,1848061812},{7,104596,3317695210},{8,95764,1013174834},{9,96537,2040739896},{10,95749,1485704954},{11,95749,1485704954},{12,95749,1485704954},{13,95879,1184574788},{14,111730,1951770619},{15,61247,1719011942},{16,28688,986685640},{17,3129,857523957}},
        [2] = {{1,13290,706864316},{2,101128,3720861786},{3,174381,77441793},{4,180668,1936357487},{5,217906,3493711759},{6,160418,3022632892},{7,173193,1850276460},{8,151783,2337456979},{9,120247,3237158122},{10,115725,1366080312},{11,105038,1853450064},{12,106000,4015287050},{13,100441,2698633536},{14,100650,2253353520},{15,87102,2748636489},{16,61447,3398086816},{17,8739,2886793149},{18,3129,857523957}},
        [3] = {{1,3129,857523957},{2,38767,3742520518},{3,163292,739987554},{4,201355,2708505682},{5,221202,4256517473},{6,166816,1590715643},{7,182468,1652137034},{8,168964,2456603866},{9,142589,2834086698},{10,126389,1834712535},{11,118834,5189494},{12,147891,1759831116},{13,104037,2427729090},{14,102907,2791227899},{15,102504,1669557717},{16,86849,2536750794},{17,37780,187831388},{18,3129,857523957}},
        [4] = {{1,3129,857523957},{2,24800,1427096423},{3,136294,869423173},{4,171622,3416216868},{5,191801,2382811992},{6,263318,3747078199},{7,247490,843832708},{8,236035,1851794296},{9,198966,3934564045},{10,147908,4257060731},{11,132721,3010418128},{12,117133,437814420},{13,111643,205105007},{14,108101,1868716352},{15,106110,3947503955},{16,82350,2698575159},{17,61472,2094311231},{18,3129,857523957}},
        [5] = {{1,15218,1746527420},{2,79818,4263889859},{3,136329,747806339},{4,131463,917555072},{5,189934,1546573794},{6,271222,3211741203},{7,388216,4059274771},{8,403812,763299395},{9,404774,3363054975},{10,351465,1029404623},{11,257909,2138776922},{12,197155,3577444692},{13,118219,3385207080},{14,108954,626685286},{15,108912,2567518231},{16,153022,295418953},{17,105421,3770257448},{18,105428,598275069},{19,105428,598275069},{20,131382,3009305499},{21,146165,942366366},{22,164313,2371361836},{23,131278,2021243630},{24,145794,793770809},{25,143321,3658524982},{26,141285,1888511844},{27,138814,3869776524},{28,135951,2823829073},{29,118750,3689881455},{30,113900,3992900659},{31,153470,10748036},{32,121730,1185771739},{33,109285,3463654399},{34,105477,457685386},{35,105548,1875015000},{36,105478,1985567120},{37,105486,1182099085},{38,105479,4294813065},{39,106050,3721577709},{40,105494,1742410570},{41,105494,1742410570},{42,105500,1842331241},{43,105500,1842331241},{44,141931,1979697225},{45,108172,2550953290},{46,117400,2002368386},{47,100283,2656141338},{48,49502,378520714},{49,41324,270969180},{50,53934,1353165335},{51,72427,3390331080},{52,67141,3807518042},{53,30170,696807183},{54,3129,857523957},{55,3129,857523957},{56,3129,857523957},{57,3129,857523957}},
        [6] = {{1,3129,857523957},{2,22934,3970376669},{3,101750,553334129},{4,150511,2991311003},{5,113208,3251823302},{6,200780,3915497653},{7,278142,398847160},{8,387350,1885849732},{9,410170,185524960},{10,385838,1479204410},{11,358090,3086435611},{12,246486,2219014041},{13,168449,2958001034},{14,120873,3150335657},{15,110890,3179647812},{16,155297,2171888063},{17,106569,1365623511},{18,106569,1365623511},{19,106558,2970126009},{20,106558,2970126009},{21,129866,4038711094},{22,152336,2408279237},{23,153624,680670193},{24,152429,2720403721},{25,152398,1647939311},{26,152290,128692890},{27,148768,469916582},{28,128357,958319730},{29,149266,2512894456},{30,129649,1436979286},{31,157524,2984239071},{32,112323,2981041454},{33,144484,4057850834},{34,108602,2462822300},{35,106815,1917803736},{36,107137,1721590975},{37,107497,2052497326},{38,106932,3420585771},{39,106811,3751973157},{40,107102,2406975859},{41,106789,2396900236},{42,106795,4100540456},{43,106800,3963891782},{44,106800,3963891782},{45,106800,3963891782},{46,106800,3963891782},{47,137971,980359021},{48,82941,856901113},{49,49524,3438897600},{50,43579,2745606735},{51,60279,2571479222},{52,80167,977329723},{53,72471,3419339215},{54,20516,3491224313},{55,3129,857523957}},
    }
    local queued, pending, running = {}, {}, false
    function app.cleanLegacyKillPages(name)
        if type(name) ~= "string" or type(readfile) ~= "function" or type(delfile) ~= "function" then return end
        local stage = tonumber(name:match("^KillBannerAtlas1%-([1-6])$"))
        if not stage or queued[stage] then return end
        queued[stage] = true
        pending[#pending + 1] = stage
        if running then return end
        running = true
        task.delay(20, function()
            while #pending > 0 do
                local current = table.remove(pending, 1)
                for _, entry in ipairs(legacy[current]) do
                    app.waitForCacheIdle()
                    local path = "CheatGPT/ACS/Cache/KillBannerHQ2-" .. current .. "-" .. entry[1] .. ".png"
                    local ok, bytes = pcall(readfile, path)
                    if ok and type(bytes) == "string" and #bytes == entry[2]
                        and app.resourceCrc32(bytes, app.waitForCacheIdle) == entry[3] then
                        local removed, err = pcall(delfile, path)
                        if removed then
                            app.CACHE_RECLAIMED_BYTES = (app.CACHE_RECLAIMED_BYTES or 0) + #bytes
                        else
                            warn("[CheatGPT cache] Legacy page cleanup failed: " .. tostring(err))
                        end
                    end
                    task.wait(0.1)
                end
            end
            running = false
        end)
    end
end

function app.resolveResourceFile(cache, folder, name, descriptor, extension, priority)
    if cache[name] then return cache[name] end
    if type(descriptor) ~= "table" then return nil, "Invalid resource descriptor" end
    if type(writefile) ~= "function" then return nil, "Resources require writefile" end
    local assetLoader = type(getcustomasset) == "function" and getcustomasset or (type(getsynasset) == "function" and getsynasset)
    if not assetLoader then return nil, "Resources require getcustomasset/getsynasset" end
    local path = folder .. "/" .. tostring(name):gsub("[^%w_-]", "_") .. "." .. extension
    local ok, bytes, readError = pcall(app.readResourceBytes, descriptor, path, priority)
    if not ok or not bytes then return nil, tostring(readError or bytes or "Resource unavailable") end
    local loaded, assetId = pcall(assetLoader, path)
    if loaded and type(assetId) == "string" and #assetId > 0 then
        cache[name] = assetId
        if app.cleanLegacyKillPages then app.cleanLegacyKillPages(name) end
        return assetId
    end
    return nil, "Local resource registration failed: " .. tostring(assetId)
end

function app.resolveResourceHitsound(name)
    return app.resolveResourceFile(app.HITSOUND_LOCAL_ASSETS, "CheatGPT/ACS/Cache", name == "Glass" and "Glass-clean-v3" or name, app.HITSOUND_ASSETS[name], "mp3")
end

function app.resolveResourceTabIcon(name)
    return app.resolveResourceFile(app.TAB_ICON_LOCAL_ASSETS, "CheatGPT/ACS/Cache", name, app.TAB_ICON_ASSETS[name], "png", 100)
end

-- A URI is not proof that an ImageLabel has decoded its texture. Keep a bounded
-- retry loop alive until IsLoaded, without waiting for PreloadAsync to return.
app.imageBindings = {}
function app.bindAsyncImage(image, resolver, key, fallback, needsResolve)
    local previous = app.imageBindings[image]
    if previous and previous.Cancel then previous.Cancel() end
    local record = {Key = key, Attempts = 0, State = "Waiting", NextAt = 0}
    app.imageBindings[image] = record
    local stopped = false
    local function ready()
        return image.Image ~= "" and image.IsLoaded
    end
    local function attempt()
        if stopped or record.Busy then return end
        record.Busy, record.State = true, "Resolving"
        record.Attempts += 1
        task.spawn(function()
            local ok, uri, detail = pcall(resolver, record.Attempts)
            record.Busy = false
            if stopped then return end
            if ok and type(uri) == "string" and uri ~= "" then
                if image.Image == uri and not ready() then
                    -- Same-tick clear/reassign can be coalesced by the renderer.
                    image.Image = ""
                    task.wait()
                    if stopped then return end
                    -- A thumbnail query may have published its generated URI
                    -- during this yield. Never overwrite it with an old fallback.
                    if image.Image ~= "" then
                        record.NextAt = os.clock() + math.min(30, record.Attempts * 3)
                        return
                    end
                end
                image.Image = uri
                record.State, record.Error = "Decoding", nil
                if record.Attempts > 1 and not ready() and not record.Preloading then
                    record.Preloading = true
                    task.defer(function()
                        if stopped then record.Preloading = false; return end
                        local loaded, err = pcall(function()
                            game:GetService("ContentProvider"):PreloadAsync({image})
                        end)
                        record.Preloading = false
                        if not loaded and not stopped then record.Error = tostring(err) end
                    end)
                end
            else
                record.State, record.Error = "Retrying", tostring(detail or uri or "No image URI")
            end
            record.NextAt = os.clock() + math.min(30, record.Attempts * 3)
        end)
    end
    local destroyed
    function record.Cancel()
        stopped = true
        if app.imageBindings[image] == record then app.imageBindings[image] = nil end
        if destroyed then destroyed:Disconnect() end
    end
    destroyed = image.Destroying:Connect(record.Cancel)
    task.defer(function()
        while not stopped do
            if ready() then
                record.State = needsResolve and needsResolve() and "Waiting for thumbnail" or "Ready"
                if fallback then fallback.Visible = false end
            else
                if fallback then fallback.Visible = true end
            end
            -- A loaded rbxthumb can still be Roblox's placeholder. Generation
            -- confirmation is independent from texture decode readiness.
            if record.Attempts == 0 or ((not ready() or (needsResolve and needsResolve()))
                and os.clock() >= record.NextAt) then attempt() end
            task.wait(1)
        end
        destroyed:Disconnect()
    end)
    return record
end

function app.bindTabIcon(image, name)
    local fallback = Instance.new("TextLabel")
    fallback.Name = "IconFallback"
    fallback.Size = UDim2.fromScale(1, 1)
    fallback.BackgroundTransparency = 1
    fallback.Text = name == "bug" and "!" or name:sub(1, 1)
    fallback.TextColor3 = image.ImageColor3
    fallback.Font = Enum.Font.Code
    fallback.TextScaled = true
    fallback.ZIndex = image.ZIndex
    fallback.Parent = image
    return app.bindAsyncImage(image, function(attempt)
        if attempt > 1 then app.TAB_ICON_LOCAL_ASSETS[name] = nil end
        return app.resolveResourceTabIcon(name)
    end, "Icon: " .. name, fallback)
end

function app.getHitsoundId(name)
    if name == "Glass" then return (app.GLASS_SOUND_STATE and app.GLASS_SOUND_STATE.asset) or app.resolveResourceHitsound(name) end
    return app.resolveResourceHitsound(name) or app.HITSOUNDS[name] or app.HITSOUNDS["Skeet"]
end

-- 敌人/朋友列表（初始为空，将通过玩家列表动态管理）
app.ENEMY_NAMES = {}
app.FRIEND_NAMES = {}
-- =============================================
local enemySet = {}
local friendSet = {}


local env = nil
local char = nil
local modTable = nil
local accessId = nil
local environmentLoaded = false
local firstSuccessShown = false

app.TRIGGER_ENABLED = false
app.TRIGGER_DELAY_MS = 100
app.TRIGGER_TEAM_CHECK = true
app.TRIGGER_ONLY_ENEMY = false
app.TRIGGER_ONLY_SCOPE = false
app.TRIGGER_MAX_DISTANCE = 1500
app.AIM_ENABLED = false
app.AIM_MODE = "Lock"
app.AIM_PART = "Head"
app.AIM_PARTS = {"Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg"}
app.AIM_SPEED = 10
app.AIM_ONLY_ENEMY = false
app.AIM_TEAM_CHECK = true
app.AIM_WALL_CHECK = true
app.AIM_DRAW_FOV = false
app.AIM_FOV_SIZE = 100
app.AIM_FOV_COLOR = Color3.new(1, 1, 1)
app.AIM_FOV_TRANSPARENCY = 0
app.AIM_ONLY_SCOPE = false
app.AIM_MAX_DISTANCE = 1500
app.triggerFeedbackUntil = 0
app.triggerFeedbackTarget = nil
local rageEnabled = false
local targetWalkSpeed = 0
local speedEnabled = false
local tpwalkConn = nil

-- Team check 开关
local teamCheckEnabled = true

-- No Recoil / No Spread
local noRecoilEnabled = false
local noSpreadEnabled = false
app.NO_SUPPRESSION = false
app.NO_MALFUNCTION = false
app.STEADY_AIM = false
local muzzleBoostEnabled = false
local rapidFireEnabled = false
local infiniteAmmoEnabled = false
local instantAimEnabled = false
local instantEquipEnabled = false
local notifyEnabled = true

-- 新增变量
local onlyEnemyEnabled = false
local hitLogEnabled = true
local hitLogSize = 16
app.HITLOG_DURATION = 2.2
local guiToggleKey = Enum.KeyCode.RightShift
local mainGuiVisible = true
local relayoutHitLogs = function() end
local closeOpenedDropdown = function() end

-- 第三人称摄像机控制
local thirdPersonCamEnabled = false
local originalCamMinZoom = LocalPlayer.CameraMinZoomDistance
local originalCamMaxZoom = LocalPlayer.CameraMaxZoomDistance
local isApplyingCam = false

-- Arms Chams 变量
local armsChamsEnabled = false
local armsChamsThread = nil

-- Character Chams 变量
local characterChamsEnabled = false
local characterChamsThread = nil
local originalProperties = {}

-- Chams / Trace 颜色(颜色选择器实时改写;私有状态表字段不增加 local 名额)
app.armsChamsColor = Color3.new(1, 1, 1)
app.characterChamsColor = Color3.new(1, 1, 1)
app.toolChamsColor = Color3.new(1, 1, 1)
app.TRACE_SELF_COLOR = Color3.fromRGB(224, 224, 224)
app.TRACE_OTHERS_COLOR = Color3.fromRGB(64, 64, 64)
app.TRACE_SELF_TRANSPARENCY = 0
app.TRACE_OTHERS_TRANSPARENCY = 0
app.armsOriginalProps = {} -- Arms Chams 原颜色/材质备份(现在连颜色一起改,关闭时要还原)

-- 离开通知开关
local enemyLeaveNotifyEnabled = false
local friendLeaveNotifyEnabled = false
local enemyJoinNotifyEnabled = false
local friendJoinNotifyEnabled = false

-- Fly 变量
local flying = false
local flyEnabled = false
local flyBg, flyBv
local flyLoopConn
local flySpeed = 1

-- Spin 变量
local spinning = false
local spinEnabled = false
local spinBody = nil
local spinSpeed = 20

-- ================= 持久化配置/名单 =================
-- 所有运行时文件统一放在 CheatGPT/ACS；Cache 用于内嵌音效和图标等临时资产。
app.CHEATGPT_ROOT_DIR = "CheatGPT"
app.CHEATGPT_ACS_DIR = "CheatGPT/ACS"
app.CHEATGPT_CACHE_DIR = "CheatGPT/ACS/Cache"
app.CHEATGPT_CONFIG_PATH = "CheatGPT/ACS/Config.json"
app.CHEATGPT_WHITELIST_PATH = "CheatGPT/ACS/whitelist.json"
app.CHEATGPT_ENEMYLIST_PATH = "CheatGPT/ACS/enemylist.json"
app.CONFIG_VALUES = {}
app.CONFIG_EXTRA = {}
app.CONFIG_SAVE_TOKEN = 0
app.CONFIG_LOADING = true
app.CONFIG_FILE_DELETED = false

function app.ensureCheatGPTAcsStorage()
    if type(makefolder) ~= "function" then
        return false
    end
    local folders = {app.CHEATGPT_ROOT_DIR, app.CHEATGPT_ACS_DIR, app.CHEATGPT_CACHE_DIR}
    for _, folder in ipairs(folders) do
        local exists = false
        if type(isfolder) == "function" then
            local ok, result = pcall(isfolder, folder)
            exists = ok and result == true
        end
        if not exists then
            pcall(makefolder, folder)
        end
    end
    return true
end

function app.readCheatGPTJson(path)
    if type(readfile) ~= "function" then return nil end
    if type(isfile) == "function" then
        local okFile, exists = pcall(isfile, path)
        if okFile and not exists then return nil end
    end
    local ok, text = pcall(readfile, path)
    if not ok or type(text) ~= "string" or #text == 0 then return nil end
    local service = game:GetService("HttpService")
    local okDecode, value = pcall(function() return service:JSONDecode(text) end)
    return okDecode and type(value) == "table" and value or nil
end

function app.writeCheatGPTJson(path, value)
    if type(writefile) ~= "function" then return false end
    app.ensureCheatGPTAcsStorage()
    local service = game:GetService("HttpService")
    local okEncode, text = pcall(function() return service:JSONEncode(value) end)
    if not okEncode or type(text) ~= "string" then return false end
    local okWrite = pcall(writefile, path, text)
    return okWrite
end

-- Lifetime totals are deliberately outside Config.json and life/feedback resets.
function app.createLifetimeStats()
    local path = "CheatGPT/ACS/misc.json"
    local stats = {Kills = 0, Score = 0}
    local revision, saved, busy, scheduled, warned = 0, 0, false, false, false
    local function valid(value)
        return type(value) == "number" and value >= 0 and value < 9007199254740992 and value % 1 == 0
    end
    local data = app.readCheatGPTJson(path)
    if data and data.version == 1 and valid(data.kills) and valid(data.score) then
        stats.Kills, stats.Score = data.kills, data.score
    end
    function stats.Flush()
        if busy or saved == revision then return saved == revision end
        busy = true
        local writing = revision
        local snapshot = {version = 1, kills = stats.Kills, score = stats.Score}
        local okMain = app.writeCheatGPTJson(path, snapshot)
        busy = false
        if okMain then saved, warned = writing, false; return true end
        if not warned then
            warned = true
            warn("[CheatGPT] Could not persist lifetime totals to misc.json; retrying.")
            if app.showNotification then
                pcall(app.showNotification, "Statistics", "Could not save misc.json. Totals are kept in memory; retrying.", 6)
            end
        end
        return false
    end
    local function schedule(delaySeconds)
        if scheduled then return end
        scheduled = true
        task.delay(delaySeconds, function()
            scheduled = false
            local ok = stats.Flush()
            if saved ~= revision then schedule(ok and 0.25 or 5) end
        end)
    end
    function stats.Add(kills, score)
        if not valid(kills) or not valid(score) or (kills == 0 and score == 0) then return end
        stats.Kills = math.min(9007199254740991, stats.Kills + kills)
        stats.Score = math.min(9007199254740991, stats.Score + score)
        revision += 1
        schedule(0.25) -- bounded batching, not an indefinitely reset debounce
    end
    return stats
end

-- ClientId 是本地随机标记，不参与联网、授权或配置重置。
-- 32 位 A-Z/0-9 -> basE91 -> RSA-OAEP(SHA-256, MGF1-SHA-256, 空 label) -> Base64 JSON。
function app.ensureClientId()
    local path = "CheatGPT/ACS/ClientId.json"
    assert(type(isfile) == "function" and type(writefile) == "function", "ClientId requires isfile/writefile")
    if isfile(path) then return true end -- 即使已有内容无效，也不覆盖用户文件。
    assert(type(crypt) == "table" and type(crypt.generatebytes) == "function", "ClientId requires crypt.generatebytes")
    assert(app.ensureCheatGPTAcsStorage(), "ClientId could not create storage folders")

    local function randomBytes(count)
        local encoded = crypt.generatebytes(count) -- Potassium/UNC 返回 Base64，非原始字节。
        assert(type(encoded) == "string", "Invalid random byte response")
        local bytes = app.decodeBase64Bytes(encoded)
        assert(type(bytes) == "string" and #bytes == count, "Invalid random byte count")
        return bytes
    end
    -- 独立 SHA-256（FIPS 180-4）：只使用 Luau bit32，不调用执行器 crypt.hash。
    local sha256Constants = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }
    local function sha256(bytes)
        local band, bxor, bnot, rshift, rotate = bit32.band, bit32.bxor, bit32.bnot, bit32.rshift, bit32.rrotate
        local function wordBytes(word)
            return string.char(rshift(word, 24), band(rshift(word, 16), 255), band(rshift(word, 8), 255), band(word, 255))
        end
        local length = #bytes
        local padded = bytes .. "\128" .. string.rep("\0", (55 - length) % 64)
            .. wordBytes(math.floor(length / 536870912)) .. wordBytes((length * 8) % 4294967296)
        local state = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
        local words = table.create(64, 0)
        for offset = 1, #padded, 64 do
            for i = 1, 16 do
                local index = offset + (i - 1) * 4
                local a, b, c, d = padded:byte(index, index + 3)
                words[i] = ((a * 256 + b) * 256 + c) * 256 + d
            end
            for i = 17, 64 do
                local a, b = words[i - 15], words[i - 2]
                local sigma0 = bxor(rotate(a, 7), rotate(a, 18), rshift(a, 3))
                local sigma1 = bxor(rotate(b, 17), rotate(b, 19), rshift(b, 10))
                words[i] = (words[i - 16] + sigma0 + words[i - 7] + sigma1) % 4294967296
            end
            local a, b, c, d, e, f, g, h = table.unpack(state)
            for i = 1, 64 do
                local sum1 = bxor(rotate(e, 6), rotate(e, 11), rotate(e, 25))
                local choose = bxor(band(e, f), band(bnot(e), g))
                local temp1 = (h + sum1 + choose + sha256Constants[i] + words[i]) % 4294967296
                local sum0 = bxor(rotate(a, 2), rotate(a, 13), rotate(a, 22))
                local majority = bxor(band(a, b), band(a, c), band(b, c))
                h, g, f, e, d, c, b, a = g, f, e, (d + temp1) % 4294967296, c, b, a,
                    (temp1 + sum0 + majority) % 4294967296
            end
            local working = {a, b, c, d, e, f, g, h}
            for i = 1, 8 do state[i] = (state[i] + working[i]) % 4294967296 end
        end
        local result = table.create(8)
        for i = 1, 8 do result[i] = wordBytes(state[i]) end
        return table.concat(result)
    end
    local function base91(bytes)
        local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()*+,./:;<=>?@[]^_`{|}~"'
        local out, buffer, bits = {}, 0, 0
        for i = 1, #bytes do
            buffer += bytes:byte(i) * 2 ^ bits
            bits += 8
            if bits > 13 then
                local value = buffer % 8192
                local count = value > 88 and 13 or 14
                if count == 14 then value = buffer % 16384 end
                buffer = math.floor(buffer / 2 ^ count)
                bits -= count
                local a, b = value % 91 + 1, math.floor(value / 91) + 1
                out[#out + 1] = alphabet:sub(a, a) .. alphabet:sub(b, b)
            end
        end
        if bits > 0 then
            local a = buffer % 91 + 1
            out[#out + 1] = alphabet:sub(a, a)
            if bits > 7 or buffer > 90 then
                local b = math.floor(buffer / 91) + 1
                out[#out + 1] = alphabet:sub(b, b)
            end
        end
        return table.concat(out)
    end
    local function base64(bytes)
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local out = {}
        for i = 1, #bytes, 3 do
            local a, b, c = bytes:byte(i, i + 2)
            local value = a * 65536 + (b or 0) * 256 + (c or 0)
            for shift = 18, 0, -6 do
                local index = math.floor(value / 2 ^ shift) % 64 + 1
                out[#out + 1] = (shift == 6 and not b or shift == 0 and not c) and "=" or alphabet:sub(index, index)
            end
        end
        return table.concat(out)
    end
    local function xorBytes(a, b)
        local out = {}
        for i = 1, #a do out[i] = string.char(bit32.bxor(a:byte(i), b:byte(i))) end
        return table.concat(out)
    end
    local function mgf1(seed, length)
        local out = {}
        for counter = 0, math.ceil(length / 32) - 1 do
            out[#out + 1] = sha256(seed .. string.char(
                math.floor(counter / 16777216) % 256, math.floor(counter / 65536) % 256,
                math.floor(counter / 256) % 256, counter % 256))
        end
        return table.concat(out):sub(1, length)
    end

    local id, alphabet = {}, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    for _ = 1, 16 do
        local bytes = randomBytes(64)
        for i = 1, #bytes do
            local value = bytes:byte(i)
            if value < 252 then -- 拒绝 252..255，避免取模使部分字符偏多。
                local index = value % 36 + 1
                id[#id + 1] = alphabet:sub(index, index)
                if #id == 32 then break end
            end
        end
        if #id == 32 then break end
    end
    assert(#id == 32, "ClientId random source produced no usable bytes")
    local message, seed = base91(table.concat(id)), randomBytes(32)
    local keyBytes = 512 -- 4096-bit RSA 公钥，e = 65537。
    local limbCount = keyBytes / 2
    assert(#message <= keyBytes - 66, "ClientId is too long for RSA-OAEP-4096")
    local db = sha256("") .. string.rep("\0", keyBytes - #message - 66) .. "\1" .. message
    local maskedDB = xorBytes(db, mgf1(seed, keyBytes - 33))
    local encoded = "\0" .. xorBytes(seed, mgf1(maskedDB, 32)) .. maskedDB

    -- 下面是用户提供的 RSA 公钥的 modulus，以及 R^2 mod n；e = 65537，R = 2^4096。
    -- 16-bit limbs 的 Montgomery 乘法，所有中间整数都低于 double 的精确整数上限。
    local modulusHex = "916d828652d37747230bb15ba48f1d4ce3a9351e46ca04255e4d1eb886f344b0a2999cc8d3d6db314a210fc7b5b2f0fb729fb3cdfa315317895c493a91342ce8767753b7d8f850dd0644a05eb817a6c44e297c889f55ad577f9c485e22aeb4bbd11c09b57b48a466fca78d95936a3032f996638eb3080c46a757dcc937f95749abb6e25008429974fbc2642c984abcdc1cc81dc9fb8e79b5e44176789b72a42ddb45a744ca61e1e97c61e17d28ded8d22335ce4250b792fa557f29da01ad3b97712f53015bf59cd471f73b24933ff10dec4d7e991ec841ed60cb118bba01b52129822a88cfb28fae25b3d0cfd7bbe790e4a411075c0c0d9271adeb25fdd000718a8ce749f4f63e9d1f1a743361479b2bfc1177111e1b94761eb3c2fc5a1bdefe06b4aaa98d2e2ccf6e1a9a31c3a3160e99509f61c6cfcb5de0de413cd8d64e00500b071b7b9207553b1fd3e35ae1c439c9204d9126c574c17d39fc11c4869d269aa62d8bfe07a66478ff679ec3bc2c206a0712f37edac0f214757b2dd3088b0c1f80b4f3aecd54b05b2f46307fe53c77048f4957493a2107a44f478020053cbb3cbb9c920f86c0fc79732520f219127f3c981b0818b5f3cea1e400db80114bd0b3f36e0b041cb7d99c0c9b3c3547f4d4d3e79cfff40ccf86db7b4aa3d7c427911c95c42c8a5aab7150063830ae7c026ea8e682dc85b7342ee306430736431c9b"
    local rSquaredHex = "739289cdb9e0ee48297eb784cd3ad7543ed4e836d045027ff94fcad8bf98f410c64ce0230003f6cb88569022f1b16a9a16060db22fcb5970c54b0fed09e22dd419077d1299435b515ff7948a948c2e76f714e3109156953f1852f33ff89da4b94dbd515b78e6b38c6aa8e1653d62dbf2e5315563804fbc98fdbc9f7134182a71955d47dc051894785239a942305e4642769eff64d9b70895188c36d60051af5ee217fac3072f515691d9eb302c27a32a77a369c3bcd2742ec62f72c48e2dd9bdcdfbe73e2ec1e598b97cdb364df53cfbde9d735c531c473e8310f237559f959d928a7798616f7a73086da701c0ab9b0dcd695ff85c286a35214d035d092e5529f086f8872d416f48bd67e0e1ee37947eb782d757eaf0fa423a8993cfca22288988869a79231e27264dbb60803dd5a21091bea0d7b736a604970b1a8b83948ea056f400054d7d56aa7da78e0fdc838a02d4b922e0424cf967f7c40ce78b26f96e8c032d4b2dd90a6ca9c25f616ad48fb7fe159e6f0c1971907661a8f999b7dc65da669d9981987fe94cf0d240caf7eed400e1b83c1e7c4a7fcbdbb4be56dd99fd9e58a3b2a515b178276816d4225572c33ed44b90b37b6579f8ed1c9103af4d533d7e396035a987223671fecd4bdbdc3e60b24dc216175fc0b6407f0f7b110f3d58306b63b046075193778a7e9eb4768e9e2002aa429154eb14750faf6c08eff7"
    local function fromBytes(bytes)
        local limbs = table.create(limbCount, 0)
        for i = 1, limbCount do
            local index = #bytes - (i - 1) * 2
            limbs[i] = (bytes:byte(index - 1) or 0) * 256 + (bytes:byte(index) or 0)
        end
        return limbs
    end
    local function fromHex(hex)
        return fromBytes((hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)))
    end
    local modulus, rSquared = fromHex(modulusHex), fromHex(rSquaredHex)
    local inverse = 1
    for _ = 1, 4 do inverse = (inverse * (2 - modulus[1] * inverse)) % 65536 end
    local negativeInverse = (65536 - inverse) % 65536
    local sliceStarted = os.clock()
    local function yieldSlice()
        if os.clock() - sliceStarted >= 0.002 then
            task.wait()
            sliceStarted = os.clock()
        end
    end
    local function multiply(a, b)
        local product = table.create(limbCount * 2 + 2, 0)
        for i = 1, limbCount do
            local carry = 0
            for j = 1, limbCount do
                local index = i + j - 1
                local value = product[index] + a[i] * b[j] + carry
                product[index], carry = value % 65536, math.floor(value / 65536)
            end
            product[i + limbCount] = carry
            if i % 32 == 0 then yieldSlice() end
        end
        for i = 1, limbCount do
            local factor, carry = (product[i] * negativeInverse) % 65536, 0
            for j = 1, limbCount do
                local index = i + j - 1
                local value = product[index] + factor * modulus[j] + carry
                product[index], carry = value % 65536, math.floor(value / 65536)
            end
            local index = i + limbCount
            while carry > 0 do
                local value = product[index] + carry
                product[index], carry = value % 65536, math.floor(value / 65536)
                index += 1
            end
            if i % 32 == 0 then yieldSlice() end
        end
        local result = table.create(limbCount, 0)
        for i = 1, limbCount do result[i] = product[i + limbCount] end
        local greater = product[limbCount * 2 + 1] > 0
        if not greater then
            greater = true
            for i = limbCount, 1, -1 do
                if result[i] ~= modulus[i] then greater = result[i] > modulus[i]; break end
            end
        end
        if greater then
            local borrow = 0
            for i = 1, limbCount do
                local value = result[i] - modulus[i] - borrow
                result[i], borrow = value % 65536, value < 0 and 1 or 0
            end
        end
        task.wait() -- 只在缺文件时计算；每轮让出帧，不阻塞 GUI 初始化。
        sliceStarted = os.clock()
        return result
    end
    local base = multiply(fromBytes(encoded), rSquared)
    local result = base
    for _ = 1, 16 do result = multiply(result, result) end
    result = multiply(result, base)
    local one = table.create(limbCount, 0); one[1] = 1
    result = multiply(result, one)
    local ciphertext = {}
    for i = limbCount, 1, -1 do
        ciphertext[#ciphertext + 1] = string.char(math.floor(result[i] / 256), result[i] % 256)
    end
    if isfile(path) then return true end -- 计算期间可能已有其他实例创建文件。
    assert(app.writeCheatGPTJson(path, {ClientId = base64(table.concat(ciphertext))}), "Could not write ClientId.json")
    return true
end

function app.cheatGPTConfigValue(name, fallback)
    local value = app.CONFIG_VALUES and app.CONFIG_VALUES[name]
    return value == nil and fallback or value
end

function app.configBoolean(name, current)
    local value = app.CONFIG_VALUES[name]
    if type(value) == "boolean" then return value end
    return current
end

function app.configNumber(name, current)
    local value = tonumber(app.CONFIG_VALUES[name])
    return value or current
end

function app.configString(name, current)
    local value = app.CONFIG_VALUES[name]
    return type(value) == "string" and value or current
end

function app.configColor(name, current)
    local value = app.CONFIG_VALUES[name]
    if type(value) == "table" then
        local r, g, b = tonumber(value.r), tonumber(value.g), tonumber(value.b)
        if r and g and b then
            return Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
        end
    end
    return current
end

function app.colorToConfig(value)
    if typeof(value) ~= "Color3" then return nil end
    return {r = value.R, g = value.G, b = value.B}
end

function app.sortedNameList(set)
    local names = {}
    for name, enabled in pairs(set) do
        if enabled and type(name) == "string" and name ~= "" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function app.normalizeNameList(value)
    local set = {}
    if type(value) == "table" then
        for _, name in ipairs(value) do
            if type(name) == "string" then
                local normalized = name:lower():gsub("^%s+", ""):gsub("%s+$", "")
                if normalized ~= "" then set[normalized] = true end
            end
        end
    end
    return set
end

function app.saveCheatGPTLists()
    local conflicts = {}
    for name in pairs(friendSet) do
        if enemySet[name] then
            conflicts[name] = true
            friendSet[name] = nil
            enemySet[name] = nil
        end
    end
    app.writeCheatGPTJson(app.CHEATGPT_WHITELIST_PATH, app.sortedNameList(friendSet))
    app.writeCheatGPTJson(app.CHEATGPT_ENEMYLIST_PATH, app.sortedNameList(enemySet))
    return next(conflicts) ~= nil
end

function app.collectCheatGPTConfig()
    local values = {
        ORBIT_RADIUS_MIN = app.ORBIT_RADIUS_MIN, ORBIT_RADIUS_MAX = app.ORBIT_RADIUS_MAX,
        TRACE_LIFETIME = app.TRACE_LIFETIME, TRACE_WIDTH = app.TRACE_WIDTH, FADE_TIME = app.FADE_TIME,
        TRACE_STYLE = app.TRACE_STYLE,
        MAX_TRACE_DISTANCE = app.MAX_TRACE_DISTANCE, BULLET_TRACE_MODE = app.BULLET_TRACE_MODE,
        WALLBANG = app.WALLBANG, TRACE_COOLDOWN = app.TRACE_COOLDOWN, TARGET_PRIORITY = app.TARGET_PRIORITY,
        RAGE_HIT_PART = app.RAGE_HIT_PART,
        HITMARKER_MODE = app.HITMARKER_MODE, HITMARKER_ENABLED = app.HITMARKER_ENABLED,
        KILL_EFFECT_ENABLED = app.KILL_EFFECT_ENABLED, KILL_EFFECT_STYLE = app.KILL_EFFECT_STYLE, KILL_SOUNDS_VOLUME = app.KILL_SOUNDS_VOLUME,
        KILL_EFFECT_COLLECTION = app.KILL_EFFECT_COLLECTION,
        NO_SUPPRESSION = app.NO_SUPPRESSION, NO_MALFUNCTION = app.NO_MALFUNCTION, STEADY_AIM = app.STEADY_AIM,
        HIT_EFFECT_ENABLED = app.HIT_EFFECT_ENABLED, HIT_EFFECT_COLOR = app.colorToConfig(app.HIT_EFFECT_COLOR),
        HIT_EFFECT_TRANSPARENCY = app.HIT_EFFECT_TRANSPARENCY,
        SHOW_IMPACT_ENABLED = app.SHOW_IMPACT_ENABLED, SHOW_IMPACT_COLOR = app.colorToConfig(app.SHOW_IMPACT_COLOR),
        SHOW_IMPACT_TRANSPARENCY = app.SHOW_IMPACT_TRANSPARENCY,
        SHOW_IMPACT_MATERIAL = app.SHOW_IMPACT_MATERIAL, SHOW_IMPACT_SIZE = app.SHOW_IMPACT_SIZE,
        SPREAD_FOV_ENABLED = app.SPREAD_FOV_ENABLED, SPREAD_FOV_COLOR = app.colorToConfig(app.SPREAD_FOV_COLOR),
        SPREAD_FOV_TRANSPARENCY = app.SPREAD_FOV_TRANSPARENCY,
        RAGE_MULTI_TARGET = app.RAGE_MULTI_TARGET, RAGE_SCAN_LIMIT = app.RAGE_SCAN_LIMIT,
        RAGE_THREADS_PER_TARGET = app.RAGE_THREADS_PER_TARGET, RAGE_FIRE_BURST = app.RAGE_FIRE_BURST,
        RAGE_MAX_PENDING = app.RAGE_MAX_PENDING, RAPID_FIRE_RATE = app.RAPID_FIRE_RATE,
        HITSOUND_KEY = app.HITSOUND_KEY, HITSOUND_VOLUME = app.HITSOUND_VOLUME, HITSOUND_ENABLED = app.HITSOUND_ENABLED,
        TRIGGER_ENABLED = app.TRIGGER_ENABLED, TRIGGER_DELAY_MS = app.TRIGGER_DELAY_MS,
        TRIGGER_TEAM_CHECK = app.TRIGGER_TEAM_CHECK, TRIGGER_ONLY_ENEMY = app.TRIGGER_ONLY_ENEMY,
        TRIGGER_ONLY_SCOPE = app.TRIGGER_ONLY_SCOPE,
        TRIGGER_MAX_DISTANCE = app.TRIGGER_MAX_DISTANCE, AIM_MAX_DISTANCE = app.AIM_MAX_DISTANCE,
        AIM_ENABLED = app.AIM_ENABLED, AIM_MODE = app.AIM_MODE, AIM_PART = app.AIM_PART,
        AIM_SPEED = app.AIM_SPEED, AIM_ONLY_ENEMY = app.AIM_ONLY_ENEMY,
        AIM_TEAM_CHECK = app.AIM_TEAM_CHECK, AIM_WALL_CHECK = app.AIM_WALL_CHECK,
        AIM_DRAW_FOV = app.AIM_DRAW_FOV, AIM_FOV_SIZE = app.AIM_FOV_SIZE,
        AIM_FOV_COLOR = app.colorToConfig(app.AIM_FOV_COLOR), AIM_FOV_TRANSPARENCY = app.AIM_FOV_TRANSPARENCY,
        AIM_ONLY_SCOPE = app.AIM_ONLY_SCOPE,
        rageEnabled = rageEnabled, targetWalkSpeed = targetWalkSpeed, speedEnabled = speedEnabled,
        teamCheckEnabled = teamCheckEnabled, noRecoilEnabled = noRecoilEnabled, noSpreadEnabled = noSpreadEnabled,
        muzzleBoostEnabled = muzzleBoostEnabled, rapidFireEnabled = rapidFireEnabled,
        infiniteAmmoEnabled = infiniteAmmoEnabled, instantAimEnabled = instantAimEnabled,
        instantEquipEnabled = instantEquipEnabled, notifyEnabled = notifyEnabled,
        onlyEnemyEnabled = onlyEnemyEnabled, hitLogEnabled = hitLogEnabled, hitLogSize = hitLogSize, HITLOG_DURATION = app.HITLOG_DURATION,
        guiToggleKey = guiToggleKey and guiToggleKey.Name or "RightShift",
        thirdPersonCamEnabled = thirdPersonCamEnabled, armsChamsEnabled = armsChamsEnabled,
        characterChamsEnabled = characterChamsEnabled, enemyLeaveNotifyEnabled = enemyLeaveNotifyEnabled,
        friendLeaveNotifyEnabled = friendLeaveNotifyEnabled, enemyJoinNotifyEnabled = enemyJoinNotifyEnabled,
        friendJoinNotifyEnabled = friendJoinNotifyEnabled, flySpeed = flySpeed, spinSpeed = spinSpeed,
        flyEnabled = flyEnabled, spinEnabled = spinEnabled,
        armsChamsColor = app.colorToConfig(app.armsChamsColor), characterChamsColor = app.colorToConfig(app.characterChamsColor),
        toolChamsColor = app.colorToConfig(app.toolChamsColor),
        TRACE_SELF_COLOR = app.colorToConfig(app.TRACE_SELF_COLOR), TRACE_OTHERS_COLOR = app.colorToConfig(app.TRACE_OTHERS_COLOR),
        TRACE_SELF_TRANSPARENCY = app.TRACE_SELF_TRANSPARENCY, TRACE_OTHERS_TRANSPARENCY = app.TRACE_OTHERS_TRANSPARENCY,
    }
    for key, value in pairs(app.CONFIG_EXTRA) do values[key] = value end
    return {version = 1, values = values}
end

-- 配置保存与删除共用忙状态，避免执行器文件 API 让出线程时交叉写回。
do
    local fileBusy = false

    function app.saveCheatGPTConfig()
        if fileBusy then return false, "busy" end
        fileBusy = true
        local ok = app.xpcallw(function()
            if not app.CONFIG_FILE_DELETED then
                app.writeCheatGPTJson(app.CHEATGPT_CONFIG_PATH, app.collectCheatGPTConfig())
            end
            app.saveCheatGPTLists()
        end, "Save configuration")
        fileBusy = false
        return ok
    end

    function app.clearCheatGPTConfig()
        if fileBusy then return false, "Configuration is being saved. Please try again shortly." end
        if type(isfile) ~= "function" or type(delfile) ~= "function" then
            return false, "Your executor must support isfile and delfile to clear configuration."
        end
        fileBusy = true
        local ok, err = pcall(function()
            if isfile(app.CHEATGPT_CONFIG_PATH) then
                delfile(app.CHEATGPT_CONFIG_PATH)
            end
            assert(not isfile(app.CHEATGPT_CONFIG_PATH), "The configuration file still exists after deletion")
        end)
        if ok then
            -- 旧的延迟保存只继续保存名单；下一次明确修改设置才允许重建配置。
            app.CONFIG_FILE_DELETED = true
        end
        fileBusy = false
        if not ok then
            return false, "Failed to clear configuration: " .. tostring(err)
        end
        local resetOK = app.resetControlsToDefaults()
        if not resetOK then
            return false, "Saved configuration deleted, but some controls failed to reset. Check the error details."
        end
        return true, "Configuration cleared. All controls have been reset to defaults."
    end
end

function app.scheduleCheatGPTSave()
    if app.CONFIG_LOADING or app.CONFIG_RESETTING then return end
    app.CONFIG_FILE_DELETED = false
    app.CONFIG_SAVE_TOKEN = app.CONFIG_SAVE_TOKEN + 1
    local token = app.CONFIG_SAVE_TOKEN
    local function saveWhenReady()
        if token ~= app.CONFIG_SAVE_TOKEN then return end
        local _, reason = app.saveCheatGPTConfig()
        if reason == "busy" then task.delay(4, saveWhenReady) end
    end
    task.delay(4, saveWhenReady)
end

function app.markCheatGPTConfigDirty()
    app.scheduleCheatGPTSave()
end

function app.applyLoadedCheatGPTConfig()
    app.ORBIT_RADIUS_MIN = app.configNumber("ORBIT_RADIUS_MIN", app.ORBIT_RADIUS_MIN)
    app.ORBIT_RADIUS_MAX = app.configNumber("ORBIT_RADIUS_MAX", app.ORBIT_RADIUS_MAX)
    app.TRACE_LIFETIME = app.configNumber("TRACE_LIFETIME", app.TRACE_LIFETIME)
    app.TRACE_WIDTH = app.configNumber("TRACE_WIDTH", app.TRACE_WIDTH)
    app.TRACE_STYLE = app.configString("TRACE_STYLE", app.TRACE_STYLE)
    if app.TRACE_STYLE ~= "Styled" then app.TRACE_STYLE = "Basic" end
    app.FADE_TIME = app.configNumber("FADE_TIME", app.FADE_TIME)
    app.MAX_TRACE_DISTANCE = app.configNumber("MAX_TRACE_DISTANCE", app.MAX_TRACE_DISTANCE)
    app.BULLET_TRACE_MODE = app.configString("BULLET_TRACE_MODE", app.BULLET_TRACE_MODE)
    app.WALLBANG = app.configBoolean("WALLBANG", app.WALLBANG)
    app.TRACE_COOLDOWN = app.configNumber("TRACE_COOLDOWN", app.TRACE_COOLDOWN)
    app.TARGET_PRIORITY = app.configString("TARGET_PRIORITY", app.TARGET_PRIORITY)
    app.RAGE_HIT_PART = app.configString("RAGE_HIT_PART", app.RAGE_HIT_PART)
    local validHitPart = false
    for _, partName in ipairs(app.RAGE_HIT_PART_OPTIONS) do
        if app.RAGE_HIT_PART == partName then
            validHitPart = true
            break
        end
    end
    if not validHitPart then app.RAGE_HIT_PART = "Head" end
    app.HITMARKER_MODE = app.configString("HITMARKER_MODE", app.HITMARKER_MODE)
    app.HITMARKER_ENABLED = app.configBoolean("HITMARKER_ENABLED", app.HITMARKER_ENABLED)
    app.KILL_SOUNDS_VOLUME = math.clamp(app.configNumber("KILL_SOUNDS_VOLUME", 2), 0, 5)
    app.KILL_EFFECT_ENABLED = app.configBoolean("KILL_EFFECT_ENABLED", app.KILL_EFFECT_ENABLED)
    app.KILL_EFFECT_STYLE = app.configString("KILL_EFFECT_STYLE", app.KILL_EFFECT_STYLE)
    if app.KILL_EFFECT_STYLE ~= "Battlefield 1" then app.KILL_EFFECT_STYLE = "Valorant" end
    app.KILL_EFFECT_COLLECTION = app.configString("KILL_EFFECT_COLLECTION", app.KILL_EFFECT_COLLECTION)
    if not table.find(app.KILL_EFFECT_COLLECTIONS, app.KILL_EFFECT_COLLECTION) then app.KILL_EFFECT_COLLECTION = "2021 Vandal" end
    app.HIT_EFFECT_ENABLED = app.configBoolean("HIT_EFFECT_ENABLED", app.HIT_EFFECT_ENABLED)
    app.HIT_EFFECT_COLOR = app.configColor("HIT_EFFECT_COLOR", app.HIT_EFFECT_COLOR)
    app.HIT_EFFECT_TRANSPARENCY = math.clamp(app.configNumber("HIT_EFFECT_TRANSPARENCY", app.HIT_EFFECT_TRANSPARENCY), 0, 1)
    app.SHOW_IMPACT_ENABLED = app.configBoolean("SHOW_IMPACT_ENABLED", app.SHOW_IMPACT_ENABLED)
    app.SHOW_IMPACT_COLOR = app.configColor("SHOW_IMPACT_COLOR", app.SHOW_IMPACT_COLOR)
    app.SHOW_IMPACT_TRANSPARENCY = math.clamp(app.configNumber("SHOW_IMPACT_TRANSPARENCY", app.SHOW_IMPACT_TRANSPARENCY), 0, 1)
    app.SHOW_IMPACT_MATERIAL = app.configString("SHOW_IMPACT_MATERIAL", app.SHOW_IMPACT_MATERIAL)
    local validImpactMaterial = false
    for _, materialName in ipairs(app.SHOW_IMPACT_MATERIAL_OPTIONS) do
        if app.SHOW_IMPACT_MATERIAL == materialName then validImpactMaterial = true break end
    end
    if not validImpactMaterial then app.SHOW_IMPACT_MATERIAL = "Neon" end
    app.SHOW_IMPACT_SIZE = math.clamp(app.configNumber("SHOW_IMPACT_SIZE", app.SHOW_IMPACT_SIZE), 0.1, 5)
    app.SPREAD_FOV_ENABLED = app.configBoolean("SPREAD_FOV_ENABLED", app.SPREAD_FOV_ENABLED)
    app.SPREAD_FOV_COLOR = app.configColor("SPREAD_FOV_COLOR", app.SPREAD_FOV_COLOR)
    app.SPREAD_FOV_TRANSPARENCY = math.clamp(app.configNumber("SPREAD_FOV_TRANSPARENCY", app.SPREAD_FOV_TRANSPARENCY), 0, 1)
    app.RAGE_MULTI_TARGET = app.configNumber("RAGE_MULTI_TARGET", app.RAGE_MULTI_TARGET)
    app.RAGE_SCAN_LIMIT = app.configNumber("RAGE_SCAN_LIMIT", app.RAGE_SCAN_LIMIT)
    app.RAGE_THREADS_PER_TARGET = app.configNumber("RAGE_THREADS_PER_TARGET", app.RAGE_THREADS_PER_TARGET)
    app.RAGE_FIRE_BURST = app.configNumber("RAGE_FIRE_BURST", app.RAGE_FIRE_BURST)
    app.RAGE_MAX_PENDING = app.configNumber("RAGE_MAX_PENDING", app.RAGE_MAX_PENDING)
    app.RAPID_FIRE_RATE = app.configNumber("RAPID_FIRE_RATE", app.RAPID_FIRE_RATE)
    app.HITSOUND_KEY = app.configString("HITSOUND_KEY", app.HITSOUND_KEY)
    app.HITSOUND_VOLUME = app.configNumber("HITSOUND_VOLUME", app.HITSOUND_VOLUME)
    app.HITSOUND_ENABLED = app.configBoolean("HITSOUND_ENABLED", app.HITSOUND_ENABLED)
    app.TRIGGER_ENABLED = app.configBoolean("TRIGGER_ENABLED", false)
    app.TRIGGER_DELAY_MS = math.clamp(app.configNumber("TRIGGER_DELAY_MS", 100), 0, 1000)
    app.TRIGGER_TEAM_CHECK = app.configBoolean("TRIGGER_TEAM_CHECK", true)
    app.TRIGGER_ONLY_ENEMY = app.configBoolean("TRIGGER_ONLY_ENEMY", false)
    app.TRIGGER_ONLY_SCOPE = app.configBoolean("TRIGGER_ONLY_SCOPE", false)
    app.TRIGGER_MAX_DISTANCE = math.clamp(app.configNumber("TRIGGER_MAX_DISTANCE", 1500), 0, 10000)
    app.AIM_MAX_DISTANCE = math.clamp(app.configNumber("AIM_MAX_DISTANCE", 1500), 0, 10000)
    app.AIM_ENABLED = app.configBoolean("AIM_ENABLED", false)
    app.AIM_MODE = app.configString("AIM_MODE", "Lock") == "Adaptive" and "Adaptive" or "Lock"
    app.AIM_PART = app.configString("AIM_PART", "Head")
    if app.AIM_PART == "Body" then app.AIM_PART = "Torso" end
    if not table.find(app.AIM_PARTS, app.AIM_PART) then app.AIM_PART = "Head" end
    app.AIM_SPEED = math.clamp(app.configNumber("AIM_SPEED", 10), 1, 30)
    app.AIM_ONLY_ENEMY = app.configBoolean("AIM_ONLY_ENEMY", false)
    app.AIM_TEAM_CHECK = app.configBoolean("AIM_TEAM_CHECK", true)
    app.AIM_WALL_CHECK = app.configBoolean("AIM_WALL_CHECK", true)
    app.AIM_DRAW_FOV = app.configBoolean("AIM_DRAW_FOV", false)
    app.AIM_FOV_SIZE = math.clamp(app.configNumber("AIM_FOV_SIZE", 100), 0, 200)
    app.AIM_FOV_COLOR = app.configColor("AIM_FOV_COLOR", Color3.new(1, 1, 1))
    app.AIM_FOV_TRANSPARENCY = math.clamp(app.configNumber("AIM_FOV_TRANSPARENCY", 0), 0, 1)
    app.AIM_ONLY_SCOPE = app.configBoolean("AIM_ONLY_SCOPE", false)
    rageEnabled = app.configBoolean("rageEnabled", rageEnabled)
    targetWalkSpeed = app.configNumber("targetWalkSpeed", targetWalkSpeed)
    speedEnabled = app.configBoolean("speedEnabled", speedEnabled)
    teamCheckEnabled = app.configBoolean("teamCheckEnabled", teamCheckEnabled)
    noRecoilEnabled = app.configBoolean("noRecoilEnabled", noRecoilEnabled)
    noSpreadEnabled = app.configBoolean("noSpreadEnabled", noSpreadEnabled)
    app.NO_SUPPRESSION = app.configBoolean("NO_SUPPRESSION", false)
    app.NO_MALFUNCTION = app.configBoolean("NO_MALFUNCTION", false)
    app.STEADY_AIM = app.configBoolean("STEADY_AIM", false)
    muzzleBoostEnabled = app.configBoolean("muzzleBoostEnabled", muzzleBoostEnabled)
    rapidFireEnabled = app.configBoolean("rapidFireEnabled", rapidFireEnabled)
    infiniteAmmoEnabled = app.configBoolean("infiniteAmmoEnabled", infiniteAmmoEnabled)
    instantAimEnabled = app.configBoolean("instantAimEnabled", instantAimEnabled)
    instantEquipEnabled = app.configBoolean("instantEquipEnabled", instantEquipEnabled)
    notifyEnabled = app.configBoolean("notifyEnabled", notifyEnabled)
    onlyEnemyEnabled = app.configBoolean("onlyEnemyEnabled", onlyEnemyEnabled)
    hitLogEnabled = app.configBoolean("hitLogEnabled", hitLogEnabled)
    hitLogSize = math.clamp(math.floor(app.configNumber("hitLogSize", hitLogSize) + 0.5), 8, 24)
    app.HITLOG_DURATION = math.clamp(app.configNumber("HITLOG_DURATION", 2.2), 0.5, 10)
    thirdPersonCamEnabled = app.configBoolean("thirdPersonCamEnabled", thirdPersonCamEnabled)
    armsChamsEnabled = app.configBoolean("armsChamsEnabled", armsChamsEnabled)
    characterChamsEnabled = app.configBoolean("characterChamsEnabled", characterChamsEnabled)
    enemyLeaveNotifyEnabled = app.configBoolean("enemyLeaveNotifyEnabled", enemyLeaveNotifyEnabled)
    friendLeaveNotifyEnabled = app.configBoolean("friendLeaveNotifyEnabled", friendLeaveNotifyEnabled)
    enemyJoinNotifyEnabled = app.configBoolean("enemyJoinNotifyEnabled", enemyJoinNotifyEnabled)
    friendJoinNotifyEnabled = app.configBoolean("friendJoinNotifyEnabled", friendJoinNotifyEnabled)
    flySpeed = app.configNumber("flySpeed", flySpeed)
    spinSpeed = app.configNumber("spinSpeed", spinSpeed)
    flyEnabled = app.configBoolean("flyEnabled", flyEnabled)
    spinEnabled = app.configBoolean("spinEnabled", spinEnabled)
    app.armsChamsColor = app.configColor("armsChamsColor", app.armsChamsColor)
    app.characterChamsColor = app.configColor("characterChamsColor", app.characterChamsColor)
    app.toolChamsColor = app.configColor("toolChamsColor", app.toolChamsColor)
    app.TRACE_SELF_COLOR = app.configColor("TRACE_SELF_COLOR", app.TRACE_SELF_COLOR)
    app.TRACE_OTHERS_COLOR = app.configColor("TRACE_OTHERS_COLOR", app.TRACE_OTHERS_COLOR)
    app.TRACE_SELF_TRANSPARENCY = math.clamp(app.configNumber("TRACE_SELF_TRANSPARENCY", 0), 0, 1)
    app.TRACE_OTHERS_TRANSPARENCY = math.clamp(app.configNumber("TRACE_OTHERS_TRANSPARENCY", 0), 0, 1)
    local keyName = app.configString("guiToggleKey", guiToggleKey.Name)
    if Enum.KeyCode[keyName] then guiToggleKey = Enum.KeyCode[keyName] end
end

function app.loadCheatGPTState()
    app.ensureCheatGPTAcsStorage()
    local config = app.readCheatGPTJson(app.CHEATGPT_CONFIG_PATH)
    if config and type(config.values) == "table" then
        app.CONFIG_VALUES = config.values
        app.applyLoadedCheatGPTConfig()
    end
    local whitelist = app.readCheatGPTJson(app.CHEATGPT_WHITELIST_PATH)
    local enemylist = app.readCheatGPTJson(app.CHEATGPT_ENEMYLIST_PATH)
    friendSet = app.normalizeNameList(whitelist)
    enemySet = app.normalizeNameList(enemylist)
    for name in pairs(friendSet) do
        if enemySet[name] then
            friendSet[name] = nil
            enemySet[name] = nil
        end
    end
end

app.DEFAULT_CONFIG = app.collectCheatGPTConfig().values
app.DEFAULT_CONFIG.toolChamsEnabled = false
app.DEFAULT_CONFIG.bulletTraceEnabled = false
app.DEFAULT_CONFIG.noclipEnabled = false
app.DEFAULT_CONFIG.traceShowSelection = {Self = true, Others = true}
app.DEFAULT_CONFIG.watermarkEnabled = true
app.DEFAULT_CONFIG.watermarkCustomText = ""
app.DEFAULT_CONFIG.watermarkSelection = {FPS = true, PING = true, PLAYERS = false, USERNAME = false, TIME = false, CUSTOM = false}
app.DEFAULT_CONFIG.watermarkOrder = {"FPS", "PING"}
app.loadCheatGPTState()
app.lifetimeStats = app.createLifetimeStats()
app.CONFIG_LOADING = false
app.scheduleCheatGPTSave()

local tracesFolder
local secureParent
local guiFolder

-- ================= 工具函数（提前定义，供 Fly/Spin 使用） =================
local function getRoot(character)
    return character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
end

-- Fly 停止函数
local function stopFly()
    if not flying then return end
    flying = false

    if flyLoopConn then flyLoopConn:Disconnect(); flyLoopConn = nil end
    if flyBg then app.xpcallw(function() flyBg:Destroy() end, "stopFly"); flyBg = nil end
    if flyBv then app.xpcallw(function() flyBv:Destroy() end, "stopFly"); flyBv = nil end

    local char = LocalPlayer.Character
    if char then
        local humanoid = char:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.PlatformStand = false
        end
    end
    app.xpcallw(function() Workspace.CurrentCamera.CameraType = Enum.CameraType.Custom end, "stopFly")
end

-- Fly 启动函数
local function startFly()
    if flying then stopFly(); wait(0.1) end

    local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        repeat task.wait() until char:FindFirstChildOfClass("Humanoid")
        humanoid = char:FindFirstChildOfClass("Humanoid")
    end

    local root = getRoot(char)
    if not root then
        return
    end

    -- 启用 PlatformStand，避免 Humanoid 干扰
    humanoid.PlatformStand = true

    local camera = Workspace.CurrentCamera

    flyBg = Instance.new("BodyGyro")
    flyBg.P = 9e4
    flyBg.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
    flyBg.CFrame = root.CFrame
    flyBg.Parent = root

    flyBv = Instance.new("BodyVelocity")
    flyBv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    flyBv.Velocity = Vector3.new(0, 0, 0)
    flyBv.Parent = root

    flying = true

    -- 监听 Humanoid.MoveDirection（手机摇杆和键盘都会驱动它），不再监听 WSAD
    flyLoopConn = RunService.Heartbeat:Connect(function()
        if not (char and humanoid and char.Parent and humanoid.Parent) then
            stopFly()
            return
        end

        -- 保持 PlatformStand 状态（防止被游戏重置）
        if not humanoid.PlatformStand then
            humanoid.PlatformStand = true
        end

        local moveDir = humanoid.MoveDirection
        if moveDir.Magnitude > 0.01 then
            -- 绝对速度：flySpeed 即每秒 studs 数
            flyBv.Velocity = moveDir.Unit * flySpeed
        else
            flyBv.Velocity = Vector3.new(0, 0, 0)
        end
        flyBg.CFrame = camera.CFrame
    end)
end

-- Spin 停止函数
local function stopSpin()
    if not spinning then return end
    local char = LocalPlayer.Character
    if char then
        local root = getRoot(char)
        if root then
            for _, v in pairs(root:GetChildren()) do
                if v.Name == "Spinning" then
                    v:Destroy()
                    break
                end
            end
        end
    end
    spinBody = nil
    spinning = false
end

-- Spin 启动函数
local function startSpin()
    if spinning then return end
    local char = LocalPlayer.Character
    if not char then return end
    local root = getRoot(char)
    if not root then return end

    -- 删除已有的旋转实例
    for _, v in pairs(root:GetChildren()) do
        if v.Name == "Spinning" then
            v:Destroy()
        end
    end

    spinBody = Instance.new("BodyAngularVelocity")
    spinBody.Name = "Spinning"
    spinBody.Parent = root
    spinBody.MaxTorque = Vector3.new(0, math.huge, 0)
    spinBody.AngularVelocity = Vector3.new(0, spinSpeed, 0)

    spinning = true
end

-- 生成完全随机的 Unicode 名称
function app.randomName()
    local len = math.random(15, 30)
    local chars = {}
    for i = 1, len do
        local cp
        repeat
            cp = math.random(0x20, 0x10FFFF)
        until cp < 0xD800 or cp > 0xDFFF
        chars[i] = utf8.char(cp)
    end
    return table.concat(chars)
end

-- 创建受保护的文件夹
function app.createProtectedFolder(parent, name)
    local folder = Instance.new("Folder")
    folder.Name = name or app.randomName()
    folder.Parent = parent
    if syn and syn.protect_gui then
        syn.protect_gui(folder)
    end
    return folder
end

tracesFolder = app.createProtectedFolder(Workspace)
startup.traceFolder = tracesFolder
secureParent = app.createProtectedFolder(CoreGui)
startup.secureParent = secureParent
guiFolder = app.createProtectedFolder(secureParent)

-- ================= 执行器兼容性检测（SynapseX 自定义函数存在性,清单依 SynapseXDocs） =================
-- EXEC_SUPPORT[函数名]=bool;EXEC_UNSUPPORTED={缺失函数名}——保存在私有状态表,UI 禁用态/启动通知/调用点守卫共用
app.EXEC_SUPPORT = {}
app.EXEC_UNSUPPORTED = {}
do
    local synT = type(syn) == "table" and syn or {}
    local dbgT = type(debug) == "table" and debug or {}
    local detected = {
        getsenv = getsenv,                          -- ACS env 收集(RageBot/NoRecoil/瞬发/弹药等全部 ACS 功能)
        hookfunction = hookfunction,                -- Rapid Fire wait 节流 hook
        newcclosure = newcclosure,                  -- hook 包装(RapidFire/__namecall)
        getcallingscript = getcallingscript,        -- hook 调用方过滤
        getrawmetatable = getrawmetatable,          -- 手动命中反馈 __namecall hook
        getnamecallmethod = getnamecallmethod,      -- 同上
        isreadonly = isreadonly,                    -- 改表前解锁(ensureTableWritable)
        setreadonly = setreadonly,                  -- 同上
        setclipboard = setclipboard,                -- Copy 按钮(颜色选择器/Toast)
        getclipboard = getclipboard or synT.get_clipboard, -- Paste 按钮(颜色选择器)
        ["syn.protect_gui"] = synT.protect_gui,     -- GUI 保护(有回退:不保护也能跑)
        ["syn.secure_call"] = synT.secure_call,     -- 伪造环境执行(有回退:直接调/入队)
        ["debug.getupvalues"] = dbgT.getupvalues,   -- 上值读取(mod 表/弹药/瞄准识别)
        ["debug.getupvalue"] = dbgT.getupvalue,     -- 上值单读(Instant Aim 重钉)
        ["debug.setupvalue"] = dbgT.setupvalue,     -- 上值改写(弹药/瞄准/装备)
    }
    for name, fn in pairs(detected) do
        app.EXEC_SUPPORT[name] = type(fn) == "function"
        if not app.EXEC_SUPPORT[name] then
            table.insert(app.EXEC_UNSUPPORTED, name)
        end
    end
    table.sort(app.EXEC_UNSUPPORTED)
    app.EXEC_SUPPORT["debug.info"] = type(dbgT.info) == "function"
    app.EXEC_SUPPORT["getconnections"] = type(getconnections) == "function"
    app.EXEC_SUPPORT["getconnections/getgc"] = type(getconnections) == "function" or type(getgc) == "function"
    app.EXEC_SUPPORT["getfenv"] = type(getfenv) == "function"
    app.EXEC_SUPPORT["debug.getconstants"] = type(dbgT.getconstants) == "function"
end

-- 依赖判定:列出的函数全部存在才返回 true(私有状态表函数,不增加 local 名额)
function app.executorSupports(...)
    for _, name in ipairs({...}) do
        if not app.EXEC_SUPPORT[name] then
            return false
        end
    end
    return true
end

-- 缺失函数统一提示:点击禁用开关/Copy/Paste 等无回退调用点时弹出;启动汇总也走这里
function app.notifyUnsupportedFunc(names)
    local list = type(names) == "table" and names or { names }
    local quoted = {}
    for _, n in ipairs(list) do
        table.insert(quoted, "'" .. n .. "'")
    end
    local msg = "Your executor doesn't support " .. table.concat(quoted, ", ") .. (#list > 1 and " functions" or " function")
    if app.showNotification then
        pcall(app.showNotification, "CheatGPT.cc", msg, 8)
    end
end

-- 功能开关门禁:缺函数则禁用该开关(强制关+标灰+点击弹提示),原样返回 control 便于包裹创建语句
function app.gateExecutorToggle(control, ...)
    if not control then
        return control
    end
    local missing = {}
    for _, name in ipairs({...}) do
        if not app.EXEC_SUPPORT[name] then
            table.insert(missing, name)
        end
    end
    if #missing > 0 and control.SetExecutorDisabled then
        control.SetExecutorDisabled(missing)
    end
    return control
end

-- ================= Hook closure 保真层 =================
-- 所有可替换函数都经过这里创建 replacement：
-- 1) handler 使用零声明参数的 vararg 形式，避免 nparams 被写死；
-- 2) newcclosure 负责把 replacement 放进 C closure，iscclosure=true/islclosure=false；
-- 3) Potassium 存在 debug.setinfo 时，把 source/short_src/name 对齐到 C closure 约定；
-- 4) hookfunction 仍以原函数对象为 target，func/isfunctionhooked 由执行器维护，原函数用于恢复。
app.HOOK_CLOSURE_RECORDS = {}

function app.getHookFunctionInfo(func)
    if type(debug) ~= "table" or type(func) ~= "function" then
        return nil
    end
    if type(debug.getinfo) == "function" then
        local ok, info = pcall(debug.getinfo, func)
        if ok and type(info) == "table" then
            return info
        end
    end
    return nil
end

function app.applyHookCClosureInfo(original, replacement)
    if type(replacement) ~= "function" or type(debug) ~= "table" then
        return replacement
    end
    if type(debug.setinfo) ~= "function" then
        return replacement
    end

    local originalInfo = app.getHookFunctionInfo(original)
    local info = {
        source = "=[C]",
        short_src = "[C]",
        currentline = -1,
    }
    if originalInfo and originalInfo.name then
        info.name = originalInfo.name
    end
    -- Potassium 的 setinfo 只允许修改公开的元信息字段；what/nups/func
    -- 由 replacement 的 C closure 身份和原 target 对象自然提供，不能伪造写入。
    pcall(debug.setinfo, replacement, info)
    return replacement
end

function app.makeHookCClosure(original, handler)
    if type(handler) ~= "function" or type(newcclosure) ~= "function" then
        return nil
    end
    local replacement = handler
    local ok, value = pcall(newcclosure, handler)
    if not ok or type(value) ~= "function" then
        return nil
    end
    replacement = value
    app.applyHookCClosureInfo(original, replacement)
    -- 执行器提供检测函数时，C/L closure 身份不满足约束就拒绝安装，
    -- 防止把普通 Lua closure 误当成已保真的 hook。
    if type(iscclosure) == "function" and not iscclosure(replacement) then
        return nil
    end
    if type(islclosure) == "function" and islclosure(replacement) then
        return nil
    end
    return replacement
end

function app.installHookFunction(original, handler, tag)
    if type(original) ~= "function" or type(handler) ~= "function" or type(hookfunction) ~= "function" then
        return nil, nil
    end
    local replacement = app.makeHookCClosure(original, handler)
    if not replacement then
        return nil, nil
    end
    local ok, old = pcall(hookfunction, original, replacement)
    if not ok or type(old) ~= "function" then
        return nil, nil
    end
    local record = {
        target = original,
        original = old,
        replacement = replacement,
        tag = tag,
    }
    app.HOOK_CLOSURE_RECORDS[original] = record
    return old, record
end

function app.restoreHookFunction(record)
    if type(record) ~= "table" or type(record.target) ~= "function" then
        return false
    end
    if type(restorefunction) == "function" then
        local ok, result = pcall(restorefunction, record.target)
        if ok and result ~= false then
            app.HOOK_CLOSURE_RECORDS[record.target] = nil
            return true
        end
    end
    if type(record.original) == "function" and type(hookfunction) == "function" then
        local ok = pcall(hookfunction, record.target, record.original)
        if ok then
            app.HOOK_CLOSURE_RECORDS[record.target] = nil
            return true
        end
    end
    return false
end

-- 供调试/验收使用：返回 Potassium closure 状态和 debug 元信息。
-- 不修改 debug API，因此不会影响游戏或反作弊自己的检查。
function app.inspectHookClosure(func)
    local result = {func = func}
    if type(func) ~= "function" then
        return result
    end
    local function readClosureFlag(reader)
        if type(reader) ~= "function" then return nil end
        local ok, value = pcall(reader, func)
        return ok and value or nil
    end
    result.iscclosure = readClosureFlag(iscclosure)
    result.islclosure = readClosureFlag(islclosure)
    result.isexecutorclosure = readClosureFlag(isexecutorclosure)
    result.isnewcclosure = readClosureFlag(isnewcclosure)
    result.isfunctionhooked = readClosureFlag(isfunctionhooked)
    local info = app.getHookFunctionInfo(func)
    if info then
        result.source = info.source
        result.short_src = info.short_src
        result.what = info.what
        result.linedefined = info.linedefined
        result.name = info.name
        result.namewhat = info.namewhat
        result.nups = info.nups
        result.func = info.func or func
    end
    if type(dumpbytecode) == "function" then
        result.dumpbytecode = pcall(dumpbytecode, func)
    end
    return result
end

-- 在 hook handler 内调用可取得当前调用栈；Potassium 返回的每一项包含
-- source/line/what/name/func。这里仅做安全转发，不篡改调用栈内容。
function app.getHookCallStack(offset)
    if type(debug) ~= "table" or type(debug.getcallstack) ~= "function" then
        return nil
    end
    local ok, stack = pcall(debug.getcallstack, offset or 0)
    return ok and stack or nil
end

-- 所有 ACS 环境入口共用候选列表，兼容 LocalScript 本体及任意容器内的嵌套脚本。
function app.collectACSScripts()
    local candidates = {}
    local character = LocalPlayer and LocalPlayer.Character
    local client = character and character:FindFirstChild("ACS_Client")
    if not client then return candidates end
    if client:IsA("LocalScript") then candidates[#candidates + 1] = client end
    for _, child in ipairs(client:GetDescendants()) do
        if child:IsA("LocalScript") then candidates[#candidates + 1] = child end
    end
    return candidates
end

local function precheckACS()
    for _, scriptObj in ipairs(app.collectACSScripts()) do
        local ok, envTemp = app.xpcallw(getsenv, "precheckACS", scriptObj)
        if ok and type(envTemp) == "table" and type(envTemp.setMods) == "function" then
            return true
        end
    end
    return false
end

-- 角色/框架可能晚于注入到达；有限等待，不再无限等 CharacterAdded 或立即静默退出。
startup.stage = "等待 ACS_Client / setMods"
app.startupReport(startup, "正在等待角色与 ACS 框架加载（最多 12 秒）…", false)
if app.EXEC_SUPPORT["getsenv"] then
    local deadline = os.clock() + 12
    local ready = precheckACS()
    while not ready and os.clock() < deadline do
        task.wait(0.25)
        ready = precheckACS()
    end
    if not ready then
        error("12 秒内未找到可读取的 ACS 环境。请等待角色和武器加载后重试；当前游戏也可能不是兼容的 ACS。", 0)
    end
else
    error("执行器缺少 getsenv，无法读取 ACS 环境。", 0)
end
startup.retrySafe = false
startup.stage = "创建主界面"
app.startupReport(startup, "正在创建主界面…", false)

-- ================= UI 主题与辅助函数 =================
app.THEME = {
    bg = Color3.fromRGB(17, 17, 19),
    panel = Color3.fromRGB(22, 22, 25),
    section = Color3.fromRGB(27, 27, 31),
    section2 = Color3.fromRGB(32, 32, 37),
    line = Color3.fromRGB(44, 44, 50),
    text = Color3.fromRGB(236, 236, 239),
    sub = Color3.fromRGB(150, 150, 158),
    accent = Color3.fromRGB(245, 245, 245),
    accentSoft = Color3.fromRGB(205, 205, 210),
    green = Color3.fromRGB(120, 255, 140),
    red = Color3.fromRGB(205, 82, 82),
}

function app.addCorner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = obj
    return c
end

function app.addStroke(obj, color, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color or app.THEME.line
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = obj
    return s
end

function app.tween(obj, t, props)
    return TweenService:Create(obj, TweenInfo.new(t or 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
end

-- Full SoftRound CJK font, verified LZMA2 resource from the pinned assets revision.
-- The cache filename includes the source fingerprint so previous fonts cannot be reused.
app.UI_FONT_OBJECTS = setmetatable({}, {__mode = "k"})
function app.applyFont(object, fallback)
    app.UI_FONT_OBJECTS[object] = true
    if app.UI_FONT then
        object.FontFace = app.UI_FONT
    else
        object.Font = fallback or Enum.Font.GothamMedium
    end
end

function app.readResourceUiFontBytes()
    return app.readResourceBytes({Path="cheatgpt/v1/fonts/SoftRoundCJK-9ae2e3002585.ttf.lzma2", Size=6168744, CRC32=3926058858, PackedSize=3054961, PackedCRC32=216930294}, "CheatGPT/ACS/Cache/SoftRoundCJK-9ae2e3002585.ttf")
end

function app.loadUiFont(root)
    task.spawn(function()
        task.wait() -- Build the UI first; decompression never blocks its initialization.
        app.xpcallw(function()
            local assetLoader = type(getcustomasset) == "function" and getcustomasset or getsynasset
            assert(type(assetLoader) == "function" and type(writefile) == "function", "SoftRound CJK requires writefile/getcustomasset")
            app.ensureCheatGPTAcsStorage()
            local path = "CheatGPT/ACS/Cache/SoftRoundCJK-9ae2e3002585.ttf"
            local bytes, resourceError = app.readResourceUiFontBytes()
            assert(bytes, resourceError or "Font resource unavailable")
            assert(bytes and #bytes == 6168744 and bytes:sub(1, 4) == "\0\1\0\0", "Invalid SoftRound CJK font")
            bytes = nil
            if not root.Parent then return end
            local fontAsset = assetLoader(path)
            local familyPath = "CheatGPT/ACS/Cache/SoftRoundCJK-9ae2e3002585.json"
            -- Re-register the TTF each run: custom asset URIs may be session-specific.
            writefile(familyPath, game:GetService("HttpService"):JSONEncode({
                name = "SoftRound CJK",
                faces = {{name = "Regular", weight = 400, style = "normal", assetId = fontAsset}}
            }))
            local face = Font.new(assetLoader(familyPath), Enum.FontWeight.Regular, Enum.FontStyle.Normal)
            TextService:GetFamilyInfoAsync(face.Family)
            if not root.Parent then return end
            app.UI_FONT = face
            for object in pairs(app.UI_FONT_OBJECTS) do
                if object.Parent then object.FontFace = face end
            end
            relayoutHitLogs(false)
        end, "SoftRound CJK font")
        app.readResourceUiFontBytes = nil
    end)
end

-- ================= GUI 构建 =================
local gui = Instance.new("ScreenGui")
gui.Name = app.randomName()
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset = true
gui.Parent = guiFolder
startup.gui = gui
app.loadUiFont(gui)
gui.AncestryChanged:Connect(function(_, parent)
    if not parent and startup.runtime.phase == "ready" then
        app.cheatGPTReleaseRuntimeState(startup.runtime)
    end
end)
if syn and syn.protect_gui then
    syn.protect_gui(gui)
end

-- ================= 统一浮动下拉层（所有 Dropdown 共用，样式同 PlayersList 角色下拉） =================
-- 面板挂在全屏层、绝对定位到按钮下方(不再把页面内容顶下去);打开=淡入+上滑,关闭=淡出+回滑
local dropdownLayer = Instance.new("Frame")
dropdownLayer.Name = app.randomName()
dropdownLayer.Size = UDim2.fromScale(1, 1)
dropdownLayer.BackgroundTransparency = 1
dropdownLayer.BorderSizePixel = 0
dropdownLayer.ClipsDescendants = false
dropdownLayer.Active = false
dropdownLayer.ZIndex = 200
dropdownLayer.Parent = gui

-- BEGIN RESPONSIVE UI
function app.computeUIScale(viewport, touch)
    local short = math.min(viewport.X, viewport.Y)
    local wanted = touch and math.clamp(short / 720, 1, 2.25) or math.clamp(short / 900 * 1.45, 1, 2.5)
    return math.max(0.25, math.min(wanted, (viewport.X - 24) / 350, (viewport.Y - 32) / 360))
end
function app.killBannerWidth(viewport)
    return math.max(1, math.min(viewport.X * 0.78, viewport.Y * 0.46, 900))
end
function app.getUIViewport()
    local size = gui.AbsoluteSize
    if size.X > 0 and size.Y > 0 then return size end
    local camera = Workspace.CurrentCamera
    return camera and camera.ViewportSize or Vector2.new(800, 600)
end
app.UI_SCALE = app.computeUIScale(app.getUIViewport(), UserInputService.TouchEnabled)
app.RESPONSIVE_ROOTS = setmetatable({}, {__mode = "k"})
function app.refreshResponsiveUI()
    if not gui.Parent then return end
    local viewport = app.getUIViewport()
    local previous = app.UI_LAST_VIEWPORT
    local changed = not previous or previous.X ~= viewport.X or previous.Y ~= viewport.Y
    app.UI_LAST_VIEWPORT = viewport
    app.UI_SCALE = app.computeUIScale(viewport, UserInputService.TouchEnabled)
    for object, record in pairs(app.RESPONSIVE_ROOTS) do
        if object.Parent then
            local scale = app.UI_SCALE
            local oldScale = math.max(record.Scale.Scale, 0.001)
            local baseWidth = object.Size.X.Offset
            local baseHeight = object.Size.Y.Offset
            if object.AutomaticSize ~= Enum.AutomaticSize.None then
                baseWidth, baseHeight = object.AbsoluteSize.X / oldScale, object.AbsoluteSize.Y / oldScale
                scale = math.min(scale, (viewport.X - 24) / math.max(1, baseWidth))
            end
            record.Scale.Scale = scale
            if record.Layout then record.Layout(viewport, scale) end
            if record.Clamp and (changed or not record.Placed) then
                local p = object.Position
                local x = p.X.Scale * viewport.X + p.X.Offset
                local y = p.Y.Scale * viewport.Y + p.Y.Offset
                local width, height = baseWidth * scale, baseHeight * scale
                x = math.clamp(x, 12, math.max(12, viewport.X - width - 12))
                y = math.clamp(y, 12, math.max(12, viewport.Y - height - 12))
                object.Position = UDim2.fromOffset(x, y)
                record.Placed = true
            end
        end
    end
    if changed then
        closeOpenedDropdown()
        task.defer(function() if gui.Parent then relayoutHitLogs(false) end end)
    end
end
function app.registerResponsiveRoot(object, clampPosition, layout)
    local scale = Instance.new("UIScale")
    scale.Name = "ResponsiveScale"
    scale.Scale = app.UI_SCALE
    scale.Parent = object
    app.RESPONSIVE_ROOTS[object] = {Scale = scale, Clamp = clampPosition, Layout = layout}
    app.refreshResponsiveUI()
    return scale
end
do
    local connections, viewportConnection = {}, nil
    local function cameraChanged()
        if viewportConnection then viewportConnection:Disconnect(); viewportConnection = nil end
        local camera = Workspace.CurrentCamera
        if camera then viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(app.refreshResponsiveUI) end
        app.refreshResponsiveUI()
    end
    connections[1] = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(app.refreshResponsiveUI)
    connections[2] = Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(cameraChanged)
    connections[3] = gui.Destroying:Connect(function()
        if viewportConnection then viewportConnection:Disconnect() end
        for _, connection in ipairs(connections) do connection:Disconnect() end
        table.clear(app.RESPONSIVE_ROOTS)
    end)
    cameraChanged()
end
app.registerResponsiveRoot(dropdownLayer, false, function(viewport, scale)
    dropdownLayer.Size = UDim2.fromOffset(viewport.X / scale, viewport.Y / scale)
end)
-- END RESPONSIVE UI

local openedDropdown = nil
local dropdownPressGuard = 0 -- 按下落在面板/锚按钮上的时间戳:外部点击关闭据此豁免

app.DROPDOWN_OPTION_HEIGHT = 30     -- 选项高度(触摸友好,22 太容易按空)
app.DROPDOWN_MAX_LIST_HEIGHT = 240  -- 约 8 个选项,超出后列表可滑动

-- 内容仍使用原生滚轮/触摸滚动,条体由独立的输入层控制。
function app.configureVerticalScroll(scroll)
    scroll.Active = true
    scroll.Selectable = true
    scroll.ScrollingEnabled = true
    scroll.ScrollingDirection = Enum.ScrollingDirection.Y
    scroll.ClipsDescendants = true
    scroll.ScrollBarThickness = 0
    scroll.ScrollBarImageTransparency = 1
    scroll.TopImage, scroll.MidImage, scroll.BottomImage = "", "", ""
    scroll.VerticalScrollBarInset = Enum.ScrollBarInset.None
end

app.VERTICAL_SCROLLBARS = setmetatable({}, {__mode = "k"})
function app.attachVerticalScrollbar(scroll)
    local existing = app.VERTICAL_SCROLLBARS[scroll]
    if existing and existing.Parent then return existing end
    app.configureVerticalScroll(scroll)
    -- 放在滚动容器旁边,避免随 CanvasPosition 移动或被列表布局/触摸手势接管。
    local track = Instance.new("TextButton")
    track.Name = app.randomName()
    track.AnchorPoint = Vector2.new(1, 0)
    track.BackgroundTransparency = 1
    track.BorderSizePixel = 0
    track.Text = ""
    track.AutoButtonColor = false
    track.Active = true
    track.Selectable = false
    track.ZIndex = scroll.ZIndex + 3
    track.Parent = scroll.Parent
    app.VERTICAL_SCROLLBARS[scroll] = track

    local thumb = Instance.new("Frame")
    thumb.Name = app.randomName()
    thumb.AnchorPoint = Vector2.new(0.5, 0)
    thumb.BackgroundColor3 = app.THEME.sub
    thumb.BorderSizePixel = 0
    thumb.ZIndex = track.ZIndex + 1
    thumb.Parent = track
    app.addCorner(thumb, 2)

    local pad = scroll:FindFirstChildOfClass("UIPadding") or Instance.new("UIPadding")
    pad.PaddingRight = UDim.new(pad.PaddingRight.Scale, pad.PaddingRight.Offset + 16)
    pad.Parent = scroll

    local connections = {}
    local dragInput, dragConnection
    local grabFraction = 0.5
    local hovered = false
    local function connect(signal, callback)
        connections[#connections + 1] = signal:Connect(callback)
    end
    local function stopDrag()
        dragInput = nil
        if dragConnection then dragConnection:Disconnect(); dragConnection = nil end
        if app.stopScrollbarDrag == stopDrag then app.stopScrollbarDrag = nil end
        thumb.BackgroundColor3 = hovered and app.THEME.accentSoft or app.THEME.sub
    end
    local function isVisible()
        if not mainGuiVisible or not scroll.Parent or not scroll.ScrollingEnabled then return false end
        local node = scroll
        while node and node ~= gui do
            if node:IsA("GuiObject") and not node.Visible then return false end
            node = node.Parent
        end
        return node == gui and gui.Enabled
    end
    local function metrics()
        local window = math.max(0, scroll.AbsoluteWindowSize.Y)
        local canvas = math.max(window, scroll.AbsoluteCanvasSize.Y)
        local height = track.AbsoluteSize.Y
        local fraction = height > 0 and math.min(1, math.max(window / math.max(1, canvas), 24 * app.UI_SCALE / height)) or 1
        return math.max(0, canvas - window), height, fraction
    end
    local function refresh()
        track.Size = UDim2.new(0, 16, scroll.Size.Y.Scale, scroll.Size.Y.Offset)
        track.Position = UDim2.new(scroll.Position.X.Scale + scroll.Size.X.Scale,
            scroll.Position.X.Offset + scroll.Size.X.Offset, scroll.Position.Y.Scale, scroll.Position.Y.Offset)
        local range, height, fraction = metrics()
        track.Visible = isVisible() and range > 0 and height > 0
        if not track.Visible then stopDrag() end
        thumb.Size = UDim2.new(0, 3, fraction, 0)
        thumb.Position = UDim2.new(0.5, 0, range > 0 and math.clamp(scroll.CanvasPosition.Y / range, 0, 1) * (1 - fraction) or 0, 0)
    end
    local function moveTo(y)
        if not isVisible() then stopDrag(); return end
        local range, height, fraction = metrics()
        local travel = height * (1 - fraction)
        if range <= 0 or travel <= 0 then stopDrag(); return end
        local offset = y - track.AbsolutePosition.Y - grabFraction * height * fraction
        scroll.CanvasPosition = Vector2.new(scroll.CanvasPosition.X, math.clamp(offset / travel, 0, 1) * range)
    end

    connect(track.InputBegan, function(input)
        if not app.isPressInput(input) or dragInput then return end
        refresh()
        if not track.Visible then return end
        if app.stopScrollbarDrag then app.stopScrollbarDrag() end
        dropdownPressGuard = os.clock() -- 点击浮层滚动条不能触发“外部点击关闭”。
        scroll:ResetScrollVelocity()
        local range, height, fraction = metrics()
        local thumbHeight = height * fraction
        local top = track.AbsolutePosition.Y + math.clamp(scroll.CanvasPosition.Y / range, 0, 1) * (height - thumbHeight)
        local withinThumb = input.Position.Y >= top and input.Position.Y <= top + thumbHeight
        grabFraction = withinThumb and (input.Position.Y - top) / math.max(1, thumbHeight) or 0.5
        dragInput = input
        app.stopScrollbarDrag = stopDrag
        thumb.BackgroundColor3 = app.THEME.accent
        dragConnection = input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then stopDrag() end
        end)
        if not withinThumb then moveTo(input.Position.Y) end
    end)
    connect(UserInputService.InputChanged, function(input)
        if dragInput and app.isSameDragInput(dragInput, input) then moveTo(input.Position.Y) end
    end)
    connect(UserInputService.InputEnded, function(input)
        if dragInput and app.isDragEndInput(dragInput, input) then stopDrag() end
    end)
    connect(UserInputService.WindowFocusReleased, stopDrag)
    connect(track.MouseEnter, function()
        hovered = true
        if not dragInput then thumb.BackgroundColor3 = app.THEME.accentSoft end
    end)
    connect(track.MouseLeave, function()
        hovered = false
        if not dragInput then thumb.BackgroundColor3 = app.THEME.sub end
    end)
    for _, property in ipairs({"CanvasPosition", "AbsoluteCanvasSize", "AbsoluteWindowSize", "Size", "Position", "Visible", "ScrollingEnabled"}) do
        connect(scroll:GetPropertyChangedSignal(property), refresh)
    end
    connect(track:GetPropertyChangedSignal("AbsoluteSize"), refresh)
    local ancestor = scroll.Parent
    while ancestor and ancestor ~= gui do
        if ancestor:IsA("GuiObject") then connect(ancestor:GetPropertyChangedSignal("Visible"), refresh) end
        ancestor = ancestor.Parent
    end
    connect(gui:GetPropertyChangedSignal("Enabled"), refresh)
    connect(scroll.Destroying, function()
        stopDrag()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        track:Destroy()
        app.VERTICAL_SCROLLBARS[scroll] = nil
    end)
    refresh()
    return track
end

-- 统一样式的浮动面板(CanvasGroup:GroupTransparency 整体淡入淡出,子元素同步;选项区可滑动)
function app.createDropdownPanel(width)
    local panel = Instance.new("CanvasGroup")
    panel.Name = app.randomName()
    panel.Size = UDim2.fromOffset(width, 0)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.BackgroundColor3 = app.THEME.panel
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.GroupTransparency = 1
    panel.ZIndex = 200
    panel.Parent = dropdownLayer
    app.addCorner(panel, 7)
    app.addStroke(panel, app.THEME.line, 1, 0.35)

    panel.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 4)
    pad.PaddingBottom = UDim.new(0, 4)
    pad.PaddingLeft = UDim.new(0, 4)
    pad.PaddingRight = UDim.new(0, 4)
    pad.Parent = panel

    -- 选项列表可滑动:超出 DROPDOWN_MAX_LIST_HEIGHT 出滚动条,防止面板超出屏幕
    local scroll = Instance.new("ScrollingFrame")
    scroll.Name = app.randomName()
    scroll.Size = UDim2.new(1, 0, 0, 0)
    scroll.BackgroundTransparency = 1
    scroll.BorderSizePixel = 0
    app.configureVerticalScroll(scroll)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.ZIndex = 201
    scroll.Parent = panel

    scroll.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder -- 必须显式指定:默认按 Name 排序,随机名会导致选项顺序每次打开都乱
    layout.Parent = scroll

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        scroll.Size = UDim2.new(1, 0, 0, math.min(layout.AbsoluteContentSize.Y / app.UI_SCALE, app.DROPDOWN_MAX_LIST_HEIGHT)) -- AbsoluteContentSize 含 UIScale,除回未缩放单位
    end)

    app.attachVerticalScrollbar(scroll)
    return panel
end

-- 统一样式的选项按钮(高 30、字号 12;按下立即变色给触摸即时反馈,不用等抬手)
function app.createDropdownOption(panel, order)
    local option = Instance.new("TextButton")
    option.Name = app.randomName()
    option.LayoutOrder = order
    option.Size = UDim2.new(1, 0, 0, app.DROPDOWN_OPTION_HEIGHT)
    option.BackgroundColor3 = app.THEME.section
    option.BorderSizePixel = 0
    option.TextColor3 = app.THEME.text
    app.applyFont(option, Enum.Font.GothamMedium)
    option.TextSize = 12
    option.AutoButtonColor = false
    option.ZIndex = 202
    option.Parent = panel:FindFirstChildOfClass("ScrollingFrame")
    app.addCorner(option, 6)

    -- 关键:选项会吞掉输入,面板的 InputBegan 不触发——必须在这里打豁免时间戳,
    -- 否则按下选项的瞬间会被"外部点击关闭"误判,手机端慢点按时面板提前消失,Click 永远不触发
    option.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
            option.BackgroundColor3 = app.THEME.section2 -- 按下即时反馈
        end
    end)
    option.InputEnded:Connect(function()
        option.BackgroundColor3 = app.THEME.section
    end)

    option.MouseEnter:Connect(function()
        app.tween(option, 0.1, {BackgroundColor3 = app.THEME.section2}):Play()
    end)
    option.MouseLeave:Connect(function()
        app.tween(option, 0.1, {BackgroundColor3 = app.THEME.section}):Play()
    end)

    return option
end

-- 面板总高(列表高 + 上下 padding),用于超出屏幕判定;返回屏幕视觉高度(AbsoluteContentSize 含 UIScale,先除回未缩放单位再乘出视觉值)
function app.getDropdownListHeight(panel)
    local scroll = panel:FindFirstChildOfClass("ScrollingFrame")
    local layout = scroll and scroll:FindFirstChildOfClass("UIListLayout")
    local content = layout and (layout.AbsoluteContentSize.Y / app.UI_SCALE) or 0
    return (math.min(content, app.DROPDOWN_MAX_LIST_HEIGHT) + 8) * app.UI_SCALE
end

-- 打开浮动下拉:淡入+滑入;X 钳制在屏幕内,下方放不下就翻到锚按钮上方(alignRight 右对齐,PlayersList 角色下拉用)
function app.openDropdownAnimated(panel, anchor, alignRight)
    if openedDropdown and openedDropdown ~= panel then
        closeOpenedDropdown(true)
    end
    openedDropdown = panel

    local btnPos = anchor.AbsolutePosition
    local btnSize = anchor.AbsoluteSize
    -- dropdownLayer 带 UIScale:钳制用屏幕视觉尺寸(宽=未缩放宽×UI_SCALE;高=getDropdownListHeight 已返回视觉高)
    local width = panel.Size.X.Offset * app.UI_SCALE
    local height = app.getDropdownListHeight(panel)
    local vp = Workspace.CurrentCamera.ViewportSize

    local x = alignRight and (btnPos.X + btnSize.X - width) or btnPos.X
    x = math.clamp(x, 4, math.max(4, vp.X - width - 4))

    local y = btnPos.Y + btnSize.Y + 4
    local upward = false
    if y + height > vp.Y - 4 then
        if btnPos.Y - height - 4 >= 4 then
            y = btnPos.Y - height - 4
            upward = true
        else
            y = math.max(4, vp.Y - height - 4)
        end
    end
    panel:SetAttribute("DropUpward", upward)

    -- Position 除回层内未缩放坐标(层渲染时再乘 UI_SCALE 落回屏幕位置)
    panel.Position = UDim2.fromOffset(x / app.UI_SCALE, (upward and (y + 6) or (y - 6)) / app.UI_SCALE)
    panel.GroupTransparency = 1
    panel.Visible = true
    app.tween(panel, 0.12, {GroupTransparency = 0, Position = UDim2.fromOffset(x / app.UI_SCALE, y / app.UI_SCALE)}):Play()
end

-- 关闭下拉(instant=true 立即隐藏:切标签/滚动/为开新下拉而关旧下拉时);滑出方向与打开方向相反
closeOpenedDropdown = function(instant)
    local d = openedDropdown
    if not d then return end
    openedDropdown = nil
    if instant or not d.Parent then
        d.Visible = false
        return
    end
    local offset = d:GetAttribute("DropUpward") and 6 or -6
    local out = app.tween(d, 0.1, {GroupTransparency = 1, Position = d.Position + UDim2.fromOffset(0, offset)})
    out:Play()
    out.Completed:Connect(function()
        if openedDropdown ~= d then
            d.Visible = false
        end
    end)
end

-- 颜色选择器面板的打开动画(逻辑同 openDropdownAnimated,但面板是固定尺寸、右对齐锚点色块)
function app.openColorPickerPanel(panel, anchor)
    if openedDropdown and openedDropdown ~= panel then
        closeOpenedDropdown(true)
    end
    openedDropdown = panel

    local btnPos = anchor.AbsolutePosition
    local btnSize = anchor.AbsoluteSize
    -- 同 openDropdownAnimated:钳制用屏幕视觉尺寸(未缩放尺寸×UI_SCALE)
    local width = panel.Size.X.Offset * app.UI_SCALE
    local height = panel.Size.Y.Offset * app.UI_SCALE
    local vp = Workspace.CurrentCamera.ViewportSize

    local x = math.clamp(btnPos.X + btnSize.X - width, 4, math.max(4, vp.X - width - 4))

    local y = btnPos.Y + btnSize.Y + 4
    local upward = false
    if y + height > vp.Y - 4 then
        if btnPos.Y - height - 4 >= 4 then
            y = btnPos.Y - height - 4
            upward = true
        else
            y = math.max(4, vp.Y - height - 4)
        end
    end
    panel:SetAttribute("DropUpward", upward)

    -- Position 除回层内未缩放坐标
    panel.Position = UDim2.fromOffset(x / app.UI_SCALE, (upward and (y + 6) or (y - 6)) / app.UI_SCALE)
    panel.GroupTransparency = 1
    panel.Visible = true
    app.tween(panel, 0.12, {GroupTransparency = 0, Position = UDim2.fromOffset(x / app.UI_SCALE, y / app.UI_SCALE)}):Play()
end

-- 点击下拉以外的位置关闭:defer 一帧再判,等本帧内选项/面板/锚按钮的 InputBegan 先打上豁免时间戳
-- (不打 defer 会有竞态:UserInputService 先触发时豁免还没写上,按下选项被误判为外部点击)
UserInputService.InputBegan:Connect(function(input)
    if not openedDropdown or not app.isPressInput(input) then return end
    task.defer(function()
        if os.clock() - dropdownPressGuard < 0.1 then return end
        closeOpenedDropdown()
    end)
end)

-- CanvasGroup 支持 GroupTransparency,整个窗口可以一键淡入淡出
local mainFrame = Instance.new("CanvasGroup")
mainFrame.Name = app.randomName()
mainFrame.Size = UDim2.new(0, 350, 0, 360)
-- UIScale 只放大渲染、不改 Position 坐标系:初始右贴边按视觉宽度(350×UI_SCALE)留 15px 边距
mainFrame.Position = UDim2.new(1, -(math.floor(350 * app.UI_SCALE) + 15), 0, 14)
mainFrame.BackgroundColor3 = app.THEME.bg
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.GroupTransparency = 1 -- 初始透明,启动时淡入
mainFrame.Parent = gui
app.registerResponsiveRoot(mainFrame, false) -- 用户拖动的位置不由自动缩放回写。
app.addCorner(mainFrame, 10)
app.addStroke(mainFrame, app.THEME.line, 1, 0.25)

local topBar = Instance.new("Frame")
topBar.Name = app.randomName()
topBar.Size = UDim2.new(1, 0, 0, 44)
topBar.BackgroundTransparency = 1
topBar.Parent = mainFrame

-- 标题栏带Logo
local titleBar = Instance.new("TextButton")
titleBar.Name = app.randomName()
titleBar.Size = UDim2.new(1, -18, 0, 24)
titleBar.Position = UDim2.new(0, 9, 0, 8)
titleBar.BackgroundTransparency = 1
titleBar.Text = ""
titleBar.AutoButtonColor = false
titleBar.Active = true
titleBar.Parent = topBar

do
    local titleLayout = Instance.new("UIListLayout")
    titleLayout.FillDirection = Enum.FillDirection.Horizontal
    titleLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    titleLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    titleLayout.Padding = UDim.new(0, 6)
    titleLayout.Parent = titleBar

    local titleLogo = Instance.new("ImageLabel")
    titleLogo.Name = app.randomName()
    titleLogo.Size = UDim2.fromOffset(16, 16)
    titleLogo.BackgroundTransparency = 1
    titleLogo.BorderSizePixel = 0
    titleLogo.Image = "rbxassetid://93763775045380"
    titleLogo.ScaleType = Enum.ScaleType.Crop
    titleLogo.Parent = titleBar
    app.addCorner(titleLogo, 4)

    local titleText = Instance.new("TextLabel")
    titleText.Name = app.randomName()
    titleText.AutomaticSize = Enum.AutomaticSize.XY
    titleText.Size = UDim2.fromOffset(0, 0)
    titleText.BackgroundTransparency = 1
    titleText.Text = "CheatGPT.cc"
    titleText.TextColor3 = app.THEME.text
    app.applyFont(titleText, Enum.Font.GothamBold)
    titleText.TextSize = 14
    titleText.TextXAlignment = Enum.TextXAlignment.Left
    titleText.Parent = titleBar

end

-- ========== 标题栏附加:左=版本号(标题正下方);右=Welcome+头像+角色标签(do-end 块不占顶层 local) ==========
do
    -- 版本号,左对齐标题文字(9 左边距 + 16 logo + 6 间距 = 31)
    local versionLabel = Instance.new("TextButton")
    versionLabel.Name = app.randomName()
    versionLabel.Size = UDim2.new(0, 112, 0, 24)
    versionLabel.Position = UDim2.new(0, 31, 0, 24)
    versionLabel.BackgroundTransparency = 1
    versionLabel.Text = "Release-v1.2.2"
    versionLabel.TextColor3 = app.THEME.sub
    app.applyFont(versionLabel, Enum.Font.GothamMedium)
    versionLabel.TextSize = 10
    versionLabel.TextXAlignment = Enum.TextXAlignment.Left
    versionLabel.Parent = topBar
    versionLabel.AutoButtonColor = false
    versionLabel.Activated:Connect(function()
        if app.onVersionTap then app.onVersionTap() end
    end)

    -- 右上:Welcome + 圆形头像,下面角色标签(默认 User,仅 GraysonNinja7248 / RealGuioff 显示 Dev)
    local welcomeBox = Instance.new("Frame")
    welcomeBox.Name = app.randomName()
    welcomeBox.Size = UDim2.new(0, 190, 0, 36)
    welcomeBox.Position = UDim2.new(1, -199, 0, 4)
    welcomeBox.BackgroundTransparency = 1
    welcomeBox.Parent = topBar

    local welcomeLabel = Instance.new("TextLabel")
    welcomeLabel.Name = app.randomName()
    welcomeLabel.Size = UDim2.new(1, -30, 0, 15)
    welcomeLabel.BackgroundTransparency = 1
    welcomeLabel.Text = "Welcome, " .. LocalPlayer.DisplayName
    welcomeLabel.TextColor3 = app.THEME.text
    app.applyFont(welcomeLabel, Enum.Font.GothamMedium)
    welcomeLabel.TextSize = 12
    welcomeLabel.TextXAlignment = Enum.TextXAlignment.Right
    welcomeLabel.TextTruncate = Enum.TextTruncate.AtEnd
    welcomeLabel.Parent = welcomeBox

    local welcomeAvatar = Instance.new("ImageLabel")
    welcomeAvatar.Name = app.randomName()
    welcomeAvatar.Size = UDim2.new(0, 24, 0, 24)
    welcomeAvatar.Position = UDim2.new(1, -24, 0, 0)
    welcomeAvatar.BackgroundColor3 = app.THEME.section
    welcomeAvatar.BorderSizePixel = 0
    welcomeAvatar.Parent = welcomeBox
    app.addCorner(welcomeAvatar, 999)
    app.addStroke(welcomeAvatar, app.THEME.line, 1, 0.45)

    app.bindAsyncImage(welcomeAvatar, function()
        return "rbxthumb://type=AvatarHeadShot&id=" .. LocalPlayer.UserId .. "&w=150&h=150"
    end, "Welcome avatar")
    app.welcomeAvatar = welcomeAvatar

    local isDev = LocalPlayer.Name == "GraysonNinja7248" or LocalPlayer.Name == "RealGuioff"
    local tagLabel = Instance.new("TextLabel")
    tagLabel.Name = app.randomName()
    tagLabel.Size = UDim2.new(1, -30, 0, 12)
    tagLabel.Position = UDim2.new(0, 0, 0, 20)
    tagLabel.BackgroundTransparency = 1
    tagLabel.Text = isDev and "Dev" or "User"
    tagLabel.TextColor3 = isDev and app.THEME.accent or app.THEME.sub
    app.applyFont(tagLabel, Enum.Font.GothamBold)
    tagLabel.TextSize = 10
    tagLabel.TextXAlignment = Enum.TextXAlignment.Right
    tagLabel.Parent = welcomeBox
end

local topLine = Instance.new("Frame")
topLine.Name = app.randomName()
topLine.Size = UDim2.new(1, -18, 0, 1)
topLine.Position = UDim2.new(0, 9, 1, -1)
topLine.BackgroundColor3 = app.THEME.line
topLine.BorderSizePixel = 0
topLine.Parent = topBar

-- 标签栏
local tabButtons = Instance.new("ScrollingFrame")
tabButtons.Name = app.randomName()
tabButtons.Size = UDim2.new(1, -58, 0, 28)
tabButtons.Position = UDim2.new(0, 29, 0, 50)
tabButtons.BackgroundTransparency = 1
tabButtons.BorderSizePixel = 0
tabButtons.ScrollBarThickness = 0
tabButtons.ScrollBarImageTransparency = 1
tabButtons.TopImage, tabButtons.MidImage, tabButtons.BottomImage = "", "", ""
tabButtons.ScrollingDirection = Enum.ScrollingDirection.X
tabButtons.CanvasSize = UDim2.fromOffset(0, 0)
tabButtons.Active = true
tabButtons.ClipsDescendants = true
tabButtons.Parent = mainFrame

local tabStrip = Instance.new("Frame")
tabStrip.Size = UDim2.new(0, 0, 1, 0)
tabStrip.AutomaticSize = Enum.AutomaticSize.X
tabStrip.BackgroundTransparency = 1
tabStrip.Parent = tabButtons
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabLayout.Padding = UDim.new(0, 14)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabStrip

-- 共享的标签下划线指示器:切换标签时从旧位置滑动到新位置
-- 与 tabStrip 并列挂在滚动容器中，不参与 UIListLayout。
local tabIndicator = Instance.new("Frame")
tabIndicator.Name = app.randomName()
tabIndicator.Size = UDim2.new(0, 0, 0, 2)
tabIndicator.Position = UDim2.new(0, 0, 1, -2)
tabIndicator.BackgroundColor3 = app.THEME.accent
tabIndicator.BorderSizePixel = 0
tabIndicator.ZIndex = 5
tabIndicator.Parent = tabButtons

local contentFrame = Instance.new("Frame")
contentFrame.Name = app.randomName()
contentFrame.Size = UDim2.new(1, -18, 1, -88)
contentFrame.Position = UDim2.new(0, 9, 0, 82)
contentFrame.BackgroundTransparency = 1
contentFrame.ClipsDescendants = true
contentFrame.Parent = mainFrame

-- 页面创建函数（修复滚动）
local function createPage()
    local page = Instance.new("ScrollingFrame")
    page.Name = app.randomName()
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    app.configureVerticalScroll(page)
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.Visible = false
    page.Parent = contentFrame

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 2)
    pad.PaddingBottom = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 0)
    pad.PaddingRight = UDim.new(0, 2)
    pad.Parent = page

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 10)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = page

    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        page.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y / app.UI_SCALE + 12) -- AbsoluteContentSize 含 UIScale,除回未缩放单位
    end)

    -- 滚动页面时关闭打开的下拉(浮层绝对定位,不随内容滚动,不关闭会错位悬在原处)
    page:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        closeOpenedDropdown(true)
    end)

    app.attachVerticalScrollbar(page)
    return page
end

local tabOrder = {"Legit", "Rage", "Visual", "LocalPlayer", "PlayersList", "Setting", "Debug"}
local tabFrames = {
    Legit = createPage(),
    Rage = createPage(),
    Visual = createPage(),
    LocalPlayer = createPage(),
    PlayersList = createPage(),
    Setting = createPage(),
    Debug = createPage()
}

local tabButtonsMap = {}
app.activeTabName = nil
app.tabPageEpoch = 0
app.tabPageTweens = {}

function app.scrollTabStrip(target)
    if app.tabStripTween then app.tabStripTween:Cancel() end
    local maxX = math.max(0, tabButtons.CanvasSize.X.Offset - tabButtons.AbsoluteSize.X / app.UI_SCALE)
    app.tabStripTarget = math.clamp(target, 0, maxX)
    app.tabStripTween = TweenService:Create(tabButtons, TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        CanvasPosition = Vector2.new(app.tabStripTarget, 0),
    })
    app.tabStripTween:Play()
end

function app.setActiveTab(tabName)
    if not tabFrames[tabName] then return end
    if tabName == "Debug" and not app.DEBUG_UNLOCKED then return end
    closeOpenedDropdown(true) -- 切换标签前关闭浮层下拉(它不随页面隐藏)

    local previousName = app.activeTabName
    local previousPage = previousName and tabFrames[previousName]
    local targetPage = tabFrames[tabName]
    app.tabPageEpoch += 1
    local pageEpoch = app.tabPageEpoch
    for _, tween in ipairs(app.tabPageTweens) do
        pcall(function() tween:Cancel() end)
    end
    table.clear(app.tabPageTweens)

    -- 页面切换采用水平推压：当前页被推出，目标页从相反方向压入。
    -- 目标页只走 86% 的视差距离，当前页走完整宽度，形成前后层次。
    if not previousName then
        for name, page in pairs(tabFrames) do
            page.Visible = name == tabName
            page.Position = UDim2.new(0, 0, 0, 0)
        end
    elseif previousName ~= tabName then
        local previousIndex = table.find(tabOrder, previousName) or 1
        local targetIndex = table.find(tabOrder, tabName) or 1
        local direction = targetIndex >= previousIndex and 1 or -1
        for name, page in pairs(tabFrames) do
            if name ~= previousName and name ~= tabName then
                page.Visible = false
                page.Position = UDim2.new(0, 0, 0, 0)
            end
        end
        previousPage.Visible = true
        previousPage.Position = UDim2.new(0, 0, 0, 0)
        targetPage.Visible = true
        targetPage.Position = UDim2.new(direction * 0.86, 0, 0, 0)

        local outTween = TweenService:Create(previousPage,
            TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
            {Position = UDim2.new(-direction, 0, 0, 0)})
        local inTween = TweenService:Create(targetPage,
            TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
            {Position = UDim2.new(0, 0, 0, 0)})
        table.insert(app.tabPageTweens, outTween)
        table.insert(app.tabPageTweens, inTween)
        outTween.Completed:Connect(function()
            if pageEpoch == app.tabPageEpoch then
                previousPage.Visible = false
                previousPage.Position = UDim2.new(0, 0, 0, 0)
            end
        end)
        outTween:Play()
        inTween:Play()
    else
        targetPage.Visible = true
        targetPage.Position = UDim2.new(0, 0, 0, 0)
    end
    app.activeTabName = tabName

    for name, data in pairs(tabButtonsMap) do
        local selected = name == tabName
        app.tween(data.Label, 0.12, {TextColor3 = selected and app.THEME.text or app.THEME.sub}):Play()
        if data.Icon then
            app.tween(data.Icon, 0.12, {ImageColor3 = selected and app.THEME.text or app.THEME.sub}):Play()
        end
    end

    -- 新选择取消旧补间和等待布局的任务，Back.Out 在抵达目标前轻微过冲。
    app.tabIndicatorEpoch = (app.tabIndicatorEpoch or 0) + 1
    local epoch = app.tabIndicatorEpoch
    if app.tabIndicatorTween then app.tabIndicatorTween:Cancel() end
    local target = tabButtonsMap[tabName]
    if target then
        task.spawn(function()
            app.xpcallw(function()
                -- 等布局计算出按钮实际位置/宽度(初始化时可能还没排好)
                local offsetX, width
                for _ = 1, 10 do
                    -- AbsolutePosition/AbsoluteSize 是含 UIScale 的屏幕像素,除回窗内未缩放坐标
                    offsetX = (target.Button.AbsolutePosition.X - tabStrip.AbsolutePosition.X) / app.UI_SCALE
                    width = target.Button.AbsoluteSize.X / app.UI_SCALE
                    if width > 0 then break end
                    RunService.RenderStepped:Wait()
                    if epoch ~= app.tabIndicatorEpoch then return end
                end
                if epoch ~= app.tabIndicatorEpoch then return end
                if width and width > 0 then
                    local visibleWidth = tabButtons.AbsoluteSize.X / app.UI_SCALE
                    local scrollX = tabButtons.CanvasPosition.X
                    if offsetX < scrollX then
                        scrollX = offsetX
                    elseif offsetX + width > scrollX + visibleWidth then
                        scrollX = offsetX + width - visibleWidth
                    end
                    app.scrollTabStrip(math.max(0, scrollX))
                    app.tabIndicatorTween = TweenService:Create(tabIndicator, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
                        Position = UDim2.new(0, offsetX, 1, -2),
                        Size = UDim2.new(0, width, 0, 2),
                    })
                    app.tabIndicatorTween:Play()
                end
            end, "标签下划线")
        end)
    end
end

for index, tabName in ipairs(tabOrder) do
    local btn = Instance.new("TextButton")
    btn.Name = app.randomName()
    btn.LayoutOrder = index
    btn.Visible = tabName ~= "Debug"
    btn.Size = UDim2.new(0, 0, 1, 0)
    btn.AutomaticSize = Enum.AutomaticSize.X
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.Parent = tabStrip

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 2)
    pad.PaddingRight = UDim.new(0, 2)
    pad.Parent = btn

    local tabContent = Instance.new("Frame")
    tabContent.Name = app.randomName()
    tabContent.Size = UDim2.new(0, 0, 1, 0)
    tabContent.AutomaticSize = Enum.AutomaticSize.X
    tabContent.BackgroundTransparency = 1
    tabContent.Parent = btn

    local tabContentLayout = Instance.new("UIListLayout")
    tabContentLayout.FillDirection = Enum.FillDirection.Horizontal
    tabContentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    tabContentLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    tabContentLayout.Padding = UDim.new(0, 5)
    tabContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabContentLayout.Parent = tabContent

    local icon = Instance.new("ImageLabel")
    icon.Name = app.randomName()
    icon.Size = UDim2.new(0, 15, 0, 15)
    icon.BackgroundTransparency = 1
    icon.Image = ""
    icon.ImageColor3 = app.THEME.sub
    icon.ScaleType = Enum.ScaleType.Fit
    icon.LayoutOrder = 1
    icon.Parent = tabContent
    app.bindTabIcon(icon, tabName == "Debug" and "bug" or tabName)

    local label = Instance.new("TextLabel")
    label.Name = "TabLabel"
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(0, 0, 1, -4)
    label.Position = UDim2.new(0, 0, 0, 0)
    label.AutomaticSize = Enum.AutomaticSize.X
    label.Text = tabName
    label.TextColor3 = app.THEME.sub
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.LayoutOrder = 2
    label.Parent = tabContent

    btn.MouseEnter:Connect(function()
        if not tabFrames[tabName].Visible then
            app.tween(label, 0.12, {TextColor3 = app.THEME.accentSoft}):Play()
            app.tween(icon, 0.12, {ImageColor3 = app.THEME.accentSoft}):Play()
        end
    end)

    btn.MouseLeave:Connect(function()
        if not tabFrames[tabName].Visible then
            app.tween(label, 0.12, {TextColor3 = app.THEME.sub}):Play()
            app.tween(icon, 0.12, {ImageColor3 = app.THEME.sub}):Play()
        end
    end)

    btn.MouseButton1Click:Connect(function()
        app.setActiveTab(tabName)
    end)

    tabButtonsMap[tabName] = {
        Button = btn,
        Label = label,
        Icon = icon,
    }
end

-- 明确的左右按钮让触屏/鼠标都能访问末尾 Setting，不依赖隐藏的横向滚动手势。
do
    local function refreshCanvas()
        local width = tabLayout.AbsoluteContentSize.X / app.UI_SCALE
        tabButtons.CanvasSize = UDim2.fromOffset(width, 0)
        local maxX = math.max(0, width - tabButtons.AbsoluteSize.X / app.UI_SCALE)
        tabButtons.CanvasPosition = Vector2.new(math.clamp(tabButtons.CanvasPosition.X, 0, maxX), 0)
    end
    tabLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refreshCanvas)
    tabButtons:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshCanvas)
    for _, direction in ipairs({-1, 1}) do
        local arrow = Instance.new("TextButton")
        arrow.Size = UDim2.fromOffset(20, 28)
        arrow.Position = direction < 0 and UDim2.new(0, 9, 0, 50) or UDim2.new(1, -29, 0, 50)
        arrow.Text = direction < 0 and "‹" or "›"
        arrow.TextSize = 22
        app.applyFont(arrow, Enum.Font.GothamMedium)
        arrow.TextColor3 = app.THEME.text
        arrow.BackgroundTransparency = 1
        arrow.Parent = mainFrame
        arrow.Activated:Connect(function()
            closeOpenedDropdown(true)
            local maxX = math.max(0, tabButtons.CanvasSize.X.Offset - tabButtons.AbsoluteSize.X / app.UI_SCALE)
            local step = tabButtons.AbsoluteSize.X / app.UI_SCALE * 0.75
            local current = app.tabStripTween and app.tabStripTween.PlaybackState == Enum.PlaybackState.Playing
                and app.tabStripTarget or tabButtons.CanvasPosition.X
            app.scrollTabStrip(math.clamp(current + direction * step, 0, maxX))
        end)
    end
    refreshCanvas()
end

app.setActiveTab("Rage")

function app.onVersionTap()
    if app.DEBUG_UNLOCKED then app.setActiveTab("Debug"); return end
    app.debugTaps = (app.debugTaps or 0) + 1
    if app.debugTaps < 7 then return end
    app.DEBUG_UNLOCKED = true
    tabButtonsMap.Debug.Button.Visible = true
    task.defer(function() app.setActiveTab("Debug") end)
end

-- 窗口拖动（修复版）
local frameDragging = false
local frameDragInput = nil
local frameDragStartPos = nil
local frameStartPosition = nil

local sliders = {}
local activeSlider = nil

function app.isPressInput(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

-- 判断 input 是否属于当前拖动的那根手指/鼠标（触摸拖动全程是同一个 InputObject；鼠标按下是 MouseButton1、移动是 MouseMovement，需特判）
function app.isSameDragInput(dragInput, input)
    if dragInput == input then
        return true
    end
    return dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement
end

function app.isDragEndInput(dragInput, input)
    if dragInput == input then
        return true
    end
    return dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseButton1
end

titleBar.InputBegan:Connect(function(input)
    if not app.isPressInput(input) then
        return
    end

    if activeSlider then
        return
    end

    frameDragging = true
    frameDragInput = input -- 记录发起拖动的输入源，防止第二根手指把 GUI 拉瞬移
    frameDragStartPos = input.Position
    frameStartPosition = mainFrame.Position
end)

UserInputService.InputChanged:Connect(function(input)
    if frameDragging and frameDragInput and app.isSameDragInput(frameDragInput, input) then
        local delta = input.Position - frameDragStartPos
        mainFrame.Position = UDim2.new(
            frameStartPosition.X.Scale,
            frameStartPosition.X.Offset + delta.X,
            frameStartPosition.Y.Scale,
            frameStartPosition.Y.Offset + delta.Y
        )
        return
    end

    if activeSlider and activeSlider.dragInput and app.isSameDragInput(activeSlider.dragInput, input) then
        local trackPos = activeSlider.track.AbsolutePosition
        local trackSize = activeSlider.track.AbsoluteSize
        local ratio = math.clamp((input.Position.X - trackPos.X) / trackSize.X, 0, 1)
        local value = activeSlider.min + ratio * (activeSlider.max - activeSlider.min)
        activeSlider.setValue(value)
        return
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if frameDragInput and app.isDragEndInput(frameDragInput, input) then
        frameDragging = false
        frameDragInput = nil
        frameDragStartPos = nil
        frameStartPosition = nil
    end

    if activeSlider and activeSlider.dragInput and app.isDragEndInput(activeSlider.dragInput, input) then
        activeSlider.dragging = false
        activeSlider.dragInput = nil
        activeSlider = nil
    end
end)

-- ================= UI 控件函数 =================
function app.createSection(parent, titleText)
    local section = Instance.new("Frame")
    section.Name = app.randomName()
    section.Size = UDim2.new(1, 0, 0, 30)
    section.BackgroundTransparency = 1
    section.AutomaticSize = Enum.AutomaticSize.Y
    section.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = section

    local title = Instance.new("TextLabel")
    title.Name = app.randomName()
    title.Size = UDim2.new(1, 0, 0, 16)
    title.BackgroundTransparency = 1
    title.Text = titleText
    title.TextColor3 = app.THEME.sub
    app.applyFont(title, Enum.Font.GothamMedium)
    title.TextSize = 11
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = section

    local body = Instance.new("Frame")
    body.Name = app.randomName()
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundColor3 = app.THEME.panel
    body.BorderSizePixel = 0
    body.Parent = section
    app.addCorner(body, 8)
    app.addStroke(body, app.THEME.line, 1, 0.45)

    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10)
    pad.PaddingRight = UDim.new(0, 10)
    pad.PaddingTop = UDim.new(0, 10)
    pad.PaddingBottom = UDim.new(0, 10)
    pad.Parent = body

    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.Padding = UDim.new(0, 8)
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Parent = body

    return body
end

-- ================= 功能按键绑定（开关旁的小方块，RageBot/Fly/Noclip/SpinBot） =================
-- id -> { key = Enum.KeyCode|nil, button = TextButton, api = 开关api }
app.keybindBindings = {}
app.keybindListening = nil -- 当前正在听键的绑定 id(全局唯一,开始新的听键会自动还原上一个方块的显示)

-- 切换听键状态:退出时按当前绑定还原方块文字;再次点击同一方块=取消绑定(空),见工厂内 Click
function app.setKeybindListening(id)
    if app.keybindListening and app.keybindBindings[app.keybindListening] then
        local old = app.keybindBindings[app.keybindListening]
        old.button.Text = old.key and ("[" .. old.key.Name .. "]") or "[  ]"
    end
    app.keybindListening = id
    if id then
        local rec = app.keybindBindings[id]
        rec.button.Text = rec.hovered and "[.X.]" or "[...]"
    end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    -- 听键模式:任意键盘键=绑定(鼠标左右键不可绑,忽略继续听;ESC 不可绑,作为退出听键保留原绑定)
    if app.keybindListening then
        if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
            local rec = app.keybindBindings[app.keybindListening]
            if rec then
                -- 一个键只允许绑一个功能:清掉占用同一键的旧绑定
                for id, r in pairs(app.keybindBindings) do
                    if id ~= app.keybindListening and r.key == input.KeyCode then
                        r.key = nil
                        r.button.Text = "[  ]"
                    end
                end
                rec.key = input.KeyCode
            end
        end
        app.setKeybindListening(nil)
        return
    end
    -- 触发模式:打字中(TextBox 聚焦)不触发
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end
    if UserInputService:GetFocusedTextBox() then
        return
    end
    for _, rec in pairs(app.keybindBindings) do
        if rec.key and input.KeyCode == rec.key then
            rec.api.Set(not rec.api.Get())
        end
    end
end)

-- 控件重置注册表：默认值来自读取 Config.json 之前的快照。
app.CONFIG_CONTROLS = {}
function app.copyConfigValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = app.copyConfigValue(item) end
    return copy
end

do
    local keys = {
        toggle = {
            ["Trigger"] = "TRIGGER_ENABLED",
            ["Aim Assist"] = "AIM_ENABLED", ["Wall Check"] = "AIM_WALL_CHECK", ["Draw Fov"] = "AIM_DRAW_FOV",
            ["RageBot"] = "rageEnabled", ["Only Enemy"] = "onlyEnemyEnabled", ["Team Check"] = "teamCheckEnabled",
            ["WallBang"] = "WALLBANG", ["HitLog"] = "hitLogEnabled", ["Hitsounds"] = "HITSOUND_ENABLED",
            ["Kill effect"] = "KILL_EFFECT_ENABLED",
            ["No Suppression"] = "NO_SUPPRESSION", ["No Malfunction"] = "NO_MALFUNCTION", ["Steady Aim"] = "STEADY_AIM",
            ["Hit Marker"] = "HITMARKER_ENABLED", ["Hit effect"] = "HIT_EFFECT_ENABLED", ["Show Impact"] = "SHOW_IMPACT_ENABLED",
            ["Spread FOV"] = "SPREAD_FOV_ENABLED",
            ["Arms Chams"] = "armsChamsEnabled", ["Character Chams"] = "characterChamsEnabled",
            ["Tool Chams"] = "toolChamsEnabled", ["Bullet Trace"] = "bulletTraceEnabled", ["Fly"] = "flyEnabled",
            ["Speed"] = "speedEnabled", ["Noclip"] = "noclipEnabled", ["No Recoil"] = "noRecoilEnabled", ["No Spread"] = "noSpreadEnabled",
            ["Enemy join notify"] = "enemyJoinNotifyEnabled", ["Friend join notify"] = "friendJoinNotifyEnabled",
            ["Accelerate Muzzle Velocity"] = "muzzleBoostEnabled", ["Rapid Fire"] = "rapidFireEnabled", ["Infinite Ammo"] = "infiniteAmmoEnabled",
            ["Instant Aim"] = "instantAimEnabled", ["Instant Equip"] = "instantEquipEnabled", ["3rd Cam"] = "thirdPersonCamEnabled",
            ["SpinBot"] = "spinEnabled", ["Watermark"] = "watermarkEnabled", ["Enemy leave notify"] = "enemyLeaveNotifyEnabled",
            ["Friend leave notify"] = "friendLeaveNotifyEnabled", ["Notifications"] = "notifyEnabled",
        },
        slider = {
            ["Reaction Time (ms)"] = "TRIGGER_DELAY_MS",
            ["Aim speed"] = "AIM_SPEED", ["Fov size"] = "AIM_FOV_SIZE", ["Impact Size"] = "SHOW_IMPACT_SIZE",
            ["Multi Target"] = "RAGE_MULTI_TARGET", ["Thread"] = "RAGE_THREADS_PER_TARGET", ["HitLog Size"] = "hitLogSize", ["Duration Time (s)"] = "HITLOG_DURATION",
            ["Kill Sounds Volume"] = "KILL_SOUNDS_VOLUME", ["Volume"] = "HITSOUND_VOLUME", ["Trace Lifetime"] = "TRACE_LIFETIME", ["Trace Width"] = "TRACE_WIDTH",
            ["Fly Speed"] = "flySpeed", ["Speed Value"] = "targetWalkSpeed", ["Spin Speed"] = "spinSpeed",
        },
        color = { ["Hit effect Color"] = "HIT_EFFECT_COLOR", ["Impact Color"] = "SHOW_IMPACT_COLOR", ["Spread FOV Color"] = "SPREAD_FOV_COLOR" },
        dropdown = {["Collection Style"] = "KILL_EFFECT_COLLECTION", ["Kill effect style"] = "KILL_EFFECT_STYLE", ["Mode"] = "AIM_MODE", ["AimPart"] = "AIM_PART", ["Target Priority"] = "TARGET_PRIORITY", ["Hit Part"] = "RAGE_HIT_PART", ["Hitsound"] = "HITSOUND_KEY", ["Hit Marker"] = "HITMARKER_MODE", ["Trace Style"] = "TRACE_STYLE", ["Impact Material"] = "SHOW_IMPACT_MATERIAL"},
        input = {Custom = "watermarkCustomText"},
        keybind = {["GUI Key"] = "guiToggleKey"},
    }
    function app.registerConfigControl(kind, text, api, key)
        key = key or (keys[kind] and keys[kind][text])
        assert(key and app.DEFAULT_CONFIG[key] ~= nil, "Missing control default: " .. kind .. "/" .. text)
        app.CONFIG_CONTROLS[#app.CONFIG_CONTROLS + 1] = {Kind = kind, Key = key, Api = api}
        return api
    end
end

function app.resetControlsToDefaults()
    if app.CONFIG_RESETTING then return false end
    app.CONFIG_RESETTING = true
    app.CONFIG_RESET_FAILED = false
    local failed = false
    local ok = app.xpcallw(function()
        closeOpenedDropdown(true)
        app.CONFIG_VALUES = app.copyConfigValue(app.DEFAULT_CONFIG)
        table.clear(app.CONFIG_EXTRA)
        app.applyLoadedCheatGPTConfig()
        for _, rec in pairs(app.keybindBindings) do
            rec.key = nil
            rec.button.Text = "[  ]"
        end
        app.setKeybindListening(nil)
        -- 先关闭默认关闭的功能并调用其清理回调，再还原数值/颜色，最后恢复默认开启的控件。
        for pass = 1, 3 do
            for _, rec in ipairs(app.CONFIG_CONTROLS) do
                local value = app.copyConfigValue(app.DEFAULT_CONFIG[rec.Key])
                local order = rec.Kind == "toggle" and (value and 3 or 1) or 2
                if order == pass then
                    local applied = app.xpcallw(function()
                        if rec.Kind == "color" then value = Color3.new(value.r, value.g, value.b) end
                        if rec.Kind == "keybind" then value = Enum.KeyCode[value] end
                        (rec.Api.Reset or rec.Api.Set)(value)
                    end, "Reset " .. rec.Key)
                    if not applied then failed = true end
                end
            end
        end
    end, "Reset configuration")
    app.CONFIG_RESETTING = false
    return ok and not failed and not app.CONFIG_RESET_FAILED
end

-- 新的 createModernToggle（修复状态同步）
-- swatches: 可选,{ {初始色, 回调}, ... } —— 在开关左侧挂颜色选择色块(attachColorSwatch)
-- configKey: 可选,用于同名控件分别保存不同配置字段(例如两个 Team Check/Only Enemy)
local function createModernToggle(parent, text, defaultValue, callback, keybindId, swatches, configKey)
    local state = defaultValue and true or false
    local internalUpdating = false
    local executorDisabled = false   -- 执行器缺函数禁用态:不允许开启
    local executorMissing = nil      -- 缺失函数名列表(点击时提示)

    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 26)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(1, -52, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = app.randomName()
    toggleBtn.Size = UDim2.new(0, 38, 0, 20)
    toggleBtn.Position = UDim2.new(1, -38, 0.5, -10)
    toggleBtn.BackgroundColor3 = app.THEME.section2
    toggleBtn.Text = ""
    toggleBtn.AutoButtonColor = false
    toggleBtn.Parent = holder
    app.addCorner(toggleBtn, 999)

    local knob = Instance.new("Frame")
    knob.Name = app.randomName()
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, 3, 0.5, -7)
    knob.BackgroundColor3 = app.THEME.text
    knob.BorderSizePixel = 0
    knob.Parent = toggleBtn
    app.addCorner(knob, 999)

    local function refresh(animated)
        local bg = state and app.THEME.accent or app.THEME.section2
        local pos = state and UDim2.new(1, -17, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        local knobColor = state and app.THEME.bg or app.THEME.text

        if animated then
            app.tween(toggleBtn, 0.12, {BackgroundColor3 = bg}):Play()
            app.tween(knob, 0.12, {Position = pos, BackgroundColor3 = knobColor}):Play()
        else
            toggleBtn.BackgroundColor3 = bg
            knob.Position = pos
            knob.BackgroundColor3 = knobColor
        end
    end

    local api = {}

    function api.Set(v, silent)
        local newState = v and true or false
        if newState and executorDisabled then
            -- 禁用态:强制保持关并提示缺失函数(开关点击/按键绑定/程序调用统一在此拦截)
            state = false
            refresh(true)
            if not silent and executorMissing then
                app.notifyUnsupportedFunc(executorMissing)
            end
            return
        end
        state = newState
        refresh(true)

        if not silent and callback and not internalUpdating then
            internalUpdating = true
            local ok, err = pcall(callback, state)
            internalUpdating = false
            if not ok then error(err, 0) end
            app.markCheatGPTConfigDirty()
        end
    end

    function api.Get()
        return state
    end

    -- 执行器缺函数禁用态:强制关 + 整行标灰,不允许开启
    function api.SetExecutorDisabled(missing)
        executorDisabled = true
        executorMissing = missing
        state = false
        refresh(false)
        label.TextTransparency = 0.55
        toggleBtn.BackgroundTransparency = 0.45
        knob.BackgroundTransparency = 0.45
    end

    -- 右侧附件布局:toggle(38px) 在最右;颜色色块(24px/个,可多个)与按键绑定方块(32px)依次排在其左
    local rightEdge = -38

    -- 可选:开关旁的颜色选择色块({初始色, 回调} 列表,Bullet Trace 的 glow/core 就是两个)
    if swatches then
        for _, sw in ipairs(swatches) do
            rightEdge = rightEdge - 28
            app.attachColorSwatch(holder, UDim2.new(1, rightEdge, 0.5, -10), sw[1], sw[2], sw[3])
        end
    end

    -- 可选:开关旁的按键绑定小方块(默认"[  ]"空;点击听键,再点一次取消绑定)
    if keybindId then
        rightEdge = rightEdge - 36

        local kbBtn = Instance.new("TextButton")
        kbBtn.Name = app.randomName()
        kbBtn.Size = UDim2.new(0, 32, 0, 20)
        kbBtn.Position = UDim2.new(1, rightEdge, 0.5, -10)
        kbBtn.BackgroundColor3 = app.THEME.section2
        kbBtn.TextColor3 = app.THEME.sub
        app.applyFont(kbBtn, Enum.Font.GothamBold)
        kbBtn.Text = "[  ]"
        kbBtn.TextScaled = true
        kbBtn.AutoButtonColor = false
        kbBtn.Parent = holder
        app.addCorner(kbBtn, 5)
        app.addStroke(kbBtn, app.THEME.line, 1, 0.45)

        local kbTextLimit = Instance.new("UITextSizeConstraint")
        kbTextLimit.MinTextSize = 6
        kbTextLimit.MaxTextSize = 11
        kbTextLimit.Parent = kbBtn

        app.keybindBindings[keybindId] = { key = nil, button = kbBtn, api = api, hovered = false }

        -- 听键中悬停提示:鼠标靠近显示 [.X.](再点一次=取消绑定),离远恢复 [...]
        kbBtn.MouseEnter:Connect(function()
            local rec = app.keybindBindings[keybindId]
            rec.hovered = true
            if app.keybindListening == keybindId then
                kbBtn.Text = "[.X.]"
            end
        end)
        kbBtn.MouseLeave:Connect(function()
            local rec = app.keybindBindings[keybindId]
            rec.hovered = false
            if app.keybindListening == keybindId then
                kbBtn.Text = "[...]"
            end
        end)

        kbBtn.MouseButton1Click:Connect(function()
            if app.keybindListening == keybindId then
                -- 听键中再次点击 = 取消绑定(空)
                app.keybindBindings[keybindId].key = nil
                app.setKeybindListening(nil)
            else
                app.setKeybindListening(keybindId)
            end
        end)
    end

    -- 附件(色块/绑定方块)占位后,标题宽度一次性收缩
    label.Size = UDim2.new(1, rightEdge - 14, 1, 0)

    toggleBtn.MouseButton1Click:Connect(function()
        api.Set(not state)
    end)

    refresh(false)

    return app.registerConfigControl("toggle", text, api, configKey)
end

-- 新的 createSlider（修复串值）
local function createSlider(parent, text, min, max, initial, decimals, callback, strictBounds, configKey)
    local current = initial
    local precision = decimals or 0

    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 38)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local topRow = Instance.new("Frame")
    topRow.Name = app.randomName()
    topRow.Size = UDim2.new(1, 0, 0, 14)
    topRow.BackgroundTransparency = 1
    topRow.Parent = holder

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(0.7, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = topRow

    -- 数值用 TextBox:点击可直接输入修改,允许超出滑条设计范围
    local valueBox = Instance.new("TextBox")
    valueBox.Name = app.randomName()
    valueBox.Size = UDim2.new(0.3, 0, 1, 0)
    valueBox.Position = UDim2.new(0.7, 0, 0, 0)
    valueBox.BackgroundTransparency = 1
    valueBox.TextColor3 = app.THEME.sub
    app.applyFont(valueBox, Enum.Font.GothamMedium)
    valueBox.TextSize = 11
    valueBox.TextXAlignment = Enum.TextXAlignment.Right
    valueBox.ClearTextOnFocus = false
    valueBox.Text = ""
    valueBox.Parent = topRow

    local track = Instance.new("TextButton")
    track.Name = app.randomName()
    track.Size = UDim2.new(1, 0, 0, 4)
    track.Position = UDim2.new(0, 0, 0, 24)
    track.BackgroundColor3 = app.THEME.section2
    track.BorderSizePixel = 0
    track.Text = ""
    track.AutoButtonColor = false
    track.Active = true
    track.Parent = holder
    app.addCorner(track, 999)

    local fill = Instance.new("Frame")
    fill.Name = app.randomName()
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = app.THEME.accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    app.addCorner(fill, 999)

    local knob = Instance.new("TextButton")
    knob.Name = app.randomName()
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.Position = UDim2.new(0, -7, 0.5, -7)
    knob.BackgroundColor3 = app.THEME.text
    knob.BorderSizePixel = 0
    knob.Text = ""
    knob.AutoButtonColor = false
    knob.Active = true
    knob.Parent = track
    app.addCorner(knob, 999)

    local function formatValue(v)
        if precision <= 0 then
            return tostring(math.floor(v + 0.5))
        end
        return string.format("%." .. precision .. "f", v)
    end

    local function setValue(v)
        local previous = current
        if strictBounds then
            if v ~= v then v = min end
            v = math.clamp(v, min, max)
        end
        -- 全局硬上限:输入超过 900000001 一律压到 900000000(防 9e9 之类天文数字打爆下游逻辑)
        if v > 900000001 then
            v = 900000000
        end
        -- 数值本身只按精度取整,不夹在 min/max 内(textbox 输入允许超出设计范围)
        if precision <= 0 then
            current = math.floor(v + 0.5)
        else
            local p = 10 ^ precision
            current = math.floor(v * p + 0.5) / p
        end
        -- 滑条显示比例仍夹在 0-1(超出范围时显示满格/空,但数值照常生效)
        local ratio = math.clamp((current - min) / (max - min), 0, 1)
        fill.Size = UDim2.new(ratio, 0, 1, 0)
        knob.Position = UDim2.new(ratio, -7, 0.5, -7)
        valueBox.Text = formatValue(current)
        -- 回调用 xpcall 包裹:用户输入的异常值通过通知报告，不会中止整个脚本
        app.xpcallw(callback, "Slider:" .. tostring(text), current)
        if current ~= previous then app.markCheatGPTConfigDirty() end
    end

    local sliderData = {
        dragging = false,
        track = track,
        fill = fill,
        knob = knob,
        min = min,
        max = max,
        setValue = setValue
    }
    table.insert(sliders, sliderData)

    local function beginDrag(input)
        if not app.isPressInput(input) then
            return
        end

        frameDragging = false
        frameDragStartPos = nil
        frameStartPosition = nil

        if activeSlider and activeSlider ~= sliderData then
            activeSlider.dragging = false
        end

        activeSlider = sliderData
        sliderData.dragging = true
        sliderData.dragInput = input -- 记录发起拖动的输入源

        local trackPos = track.AbsolutePosition
        local trackSize = track.AbsoluteSize
        local ratio = math.clamp((input.Position.X - trackPos.X) / trackSize.X, 0, 1)
        local value = min + ratio * (max - min)
        setValue(value)
    end

    track.InputBegan:Connect(beginDrag)
    knob.InputBegan:Connect(beginDrag)

    -- 手动输入:有效数字直接生效(可超出 min/max),无效输入还原
    valueBox.FocusLost:Connect(function()
        app.xpcallw(function()
            local num = tonumber(valueBox.Text)
            if num then
                setValue(num)
            else
                valueBox.Text = formatValue(current)
            end
        end, "Slider输入")
    end)

    setValue(initial)

    return app.registerConfigControl("slider", text, {
        Holder = holder,
        Set = setValue,
        Reset = function(value)
            sliderData.dragging = false
            sliderData.dragInput = nil
            if activeSlider == sliderData then activeSlider = nil end
            setValue(value)
        end,
        Get = function()
            return current
        end
    }, configKey)
end

function app.createDropdown(parent, text, items, initial, callback)
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 28)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(0.35, 0, 0, 16)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    local button = Instance.new("TextButton")
    button.Name = app.randomName()
    button.Size = UDim2.new(0.65, 0, 0, 28)
    button.Position = UDim2.new(0.35, 0, 0, 0)
    button.BackgroundColor3 = app.THEME.section
    button.Text = initial or ""
    button.TextColor3 = app.THEME.text
    app.applyFont(button, Enum.Font.GothamMedium)
    button.TextSize = 12
    button.AutoButtonColor = false
    button.Parent = holder
    app.addCorner(button, 7)
    app.addStroke(button, app.THEME.line, 1, 0.45)

    -- 浮动面板:统一样式(同 PlayersList 角色下拉),绝对定位在按钮下方,打开/关闭带动画
    local drop = app.createDropdownPanel(92)
    button.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    for index, item in ipairs(items) do
        local option = app.createDropdownOption(drop, index)
        option.Text = tostring(item)

        option.Activated:Connect(function()
            button.Text = tostring(item)
            closeOpenedDropdown()
            callback(item)
            app.markCheatGPTConfigDirty()
        end)
    end

    button.Activated:Connect(function()
        if openedDropdown == drop then
            closeOpenedDropdown()
        else
            drop.Size = UDim2.fromOffset(button.AbsoluteSize.X / app.UI_SCALE, 0) -- AbsoluteSize 含缩放,除回未缩放宽
            app.openDropdownAnimated(drop, button)
        end
    end)

    callback(initial)

    return app.registerConfigControl("dropdown", text, {
        Holder = holder,
        Get = function()
            return button.Text
        end,
        Set = function(v)
            button.Text = tostring(v)
            callback(v)
            app.markCheatGPTConfigDirty()
        end
    })
end

function app.createInput(parent, text, placeholder, initial, callback)
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 28)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(0.35, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    local box = Instance.new("TextBox")
    box.Name = app.randomName()
    box.Size = UDim2.new(0.65, 0, 0, 28)
    box.Position = UDim2.new(0.35, 0, 0, 0)
    box.BackgroundColor3 = app.THEME.section
    box.Text = initial or ""
    box.PlaceholderText = placeholder or ""
    box.TextColor3 = app.THEME.text
    box.PlaceholderColor3 = app.THEME.sub
    app.applyFont(box, Enum.Font.GothamMedium)
    box.TextSize = 12
    box.ClearTextOnFocus = false
    box.Parent = holder
    app.addCorner(box, 7)
    app.addStroke(box, app.THEME.line, 1, 0.45)

    local appliedText = box.Text
    local function applyUserText()
        if box.Text == appliedText then return end
        appliedText = box.Text
        callback(appliedText)
        app.markCheatGPTConfigDirty()
    end
    box.FocusLost:Connect(applyUserText)
    box:GetPropertyChangedSignal("Text"):Connect(applyUserText)

    callback(box.Text)

    return app.registerConfigControl("input", text, {
        Holder = holder,
        Box = box,
        Get = function()
            return box.Text
        end,
        Set = function(v)
            appliedText = tostring(v or "")
            box.Text = appliedText
            callback(box.Text)
            app.markCheatGPTConfigDirty()
        end
    })
end

function app.createMultiDropdown(parent, text, items, selectedMap, callback, resetKey)
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 28)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(0.35, 0, 0, 16)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    local button = Instance.new("TextButton")
    button.Name = app.randomName()
    button.Size = UDim2.new(0.65, 0, 0, 28)
    button.Position = UDim2.new(0.35, 0, 0, 0)
    button.BackgroundColor3 = app.THEME.section
    button.TextColor3 = app.THEME.text
    app.applyFont(button, Enum.Font.GothamMedium)
    button.TextSize = 12
    button.AutoButtonColor = false
    button.Parent = holder
    app.addCorner(button, 7)
    app.addStroke(button, app.THEME.line, 1, 0.45)

    -- 浮动面板:统一样式(同 PlayersList 角色下拉),绝对定位在按钮下方,打开/关闭带动画
    local drop = app.createDropdownPanel(92)
    button.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    local function refreshButtonText()
        local chosen = {}
        for _, item in ipairs(items) do
            if selectedMap[item] then
                table.insert(chosen, item)
            end
        end

        if #chosen == 0 then
            button.Text = "None"
        elseif #chosen == 1 then
            button.Text = chosen[1]
        else
            button.Text = tostring(#chosen) .. " Selected"
        end
    end

    local function fireCallback()
        callback(selectedMap)
        app.markCheatGPTConfigDirty()
        refreshButtonText()
    end

    for index, item in ipairs(items) do
        local option = app.createDropdownOption(drop, index)

        local function refreshOption() -- 必须 local:全局函数会被下一次循环覆盖,点击时只会刷新最后一个选项,导致"√"不显示
            local checked = selectedMap[item] == true
            option.Text = (checked and "✓ " or "") .. item
            option.TextColor3 = checked and app.THEME.accent or app.THEME.text
        end

        refreshOption()

        option.Activated:Connect(function()
            selectedMap[item] = not selectedMap[item]
            refreshOption()
            fireCallback()
        end)
    end

    button.Activated:Connect(function()
        if openedDropdown == drop then
            closeOpenedDropdown()
        else
            drop.Size = UDim2.fromOffset(button.AbsoluteSize.X / app.UI_SCALE, 0) -- AbsoluteSize 含缩放,除回未缩放宽
            app.openDropdownAnimated(drop, button)
        end
    end)

    fireCallback()

    return app.registerConfigControl("multi", text, {
        Holder = holder,
        Get = function()
            return selectedMap
        end,
        Set = function(newMap)
            for k in pairs(selectedMap) do
                selectedMap[k] = nil
            end
            for k, v in pairs(newMap or {}) do
                selectedMap[k] = v
            end
            for _, child in ipairs(drop:FindFirstChildOfClass("ScrollingFrame"):GetChildren()) do
                if child:IsA("TextButton") then
                    local raw = child.Text:gsub("^✓%s*", "")
                    local checked = selectedMap[raw] == true
                    child.Text = (checked and "✓ " or "") .. raw
                    child.TextColor3 = checked and app.THEME.accent or app.THEME.text
                end
            end
            fireCallback()
        end
    }, resetKey)
end

function app.createButton(parent, text, callback)
    local btn = Instance.new("TextButton")
    btn.Name = app.randomName()
    btn.Size = UDim2.new(1, 0, 0, 28)
    btn.BackgroundColor3 = app.THEME.panel
    btn.Text = text
    btn.TextColor3 = app.THEME.text
    app.applyFont(btn, Enum.Font.GothamMedium)
    btn.TextSize = 12
    btn.AutoButtonColor = false
    btn.Parent = parent
    app.addCorner(btn, 7)
    app.addStroke(btn, app.THEME.line, 1, 0.45)

    btn.MouseEnter:Connect(function()
        app.tween(btn, 0.1, {BackgroundColor3 = app.THEME.section2}):Play()
    end)

    btn.MouseLeave:Connect(function()
        app.tween(btn, 0.1, {BackgroundColor3 = app.THEME.panel}):Play()
    end)

    btn.MouseButton1Click:Connect(callback)

    return btn
end

function app.createKeybindPicker(parent, text, initialKey, callback)
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 28)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(0.35, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    local button = Instance.new("TextButton")
    button.Name = app.randomName()
    button.Size = UDim2.new(0.65, 0, 0, 28)
    button.Position = UDim2.new(0.35, 0, 0, 0)
    button.BackgroundColor3 = app.THEME.section
    button.TextColor3 = app.THEME.text
    app.applyFont(button, Enum.Font.GothamMedium)
    button.TextSize = 12
    button.AutoButtonColor = false
    button.Parent = holder
    app.addCorner(button, 7)
    app.addStroke(button, app.THEME.line, 1, 0.45)

    local waiting = false
    local currentKey = initialKey

    local function refresh()
        button.Text = waiting and "Press key..." or currentKey.Name
    end

    button.MouseButton1Click:Connect(function()
        waiting = true
        refresh()
    end)

    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed or not waiting then
            return
        end
        if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.Unknown then
            currentKey = input.KeyCode
            waiting = false
            refresh()
            callback(currentKey)
            app.markCheatGPTConfigDirty()
        end
    end)

    refresh()
    callback(currentKey)

    return app.registerConfigControl("keybind", text, {
        Holder = holder,
        Get = function()
            return currentKey
        end,
        Set = function(v)
            currentKey = v
            waiting = false
            refresh()
            callback(currentKey)
            app.markCheatGPTConfigDirty()
        end
    })
end

-- ================= 颜色选择器色块(挂在开关行内;面板:SV 方块 + 竖直色相条 + RGB 输入 + Copy/Paste) =================
-- holder=所在行容器, position=色块在行内的位置;面板复用浮动下拉层的单例/外部关闭机制
function app.attachColorSwatch(holder, position, initialColor, callback, resetKey, initialTransparency, transparencyCallback, transparencyResetKey)
    -- 色块:点击打开/关闭选择器面板
    local swatch = Instance.new("TextButton")
    swatch.Name = app.randomName()
    swatch.Size = UDim2.new(0, 24, 0, 20)
    swatch.Position = position
    swatch.BackgroundColor3 = initialColor
    swatch.Text = ""
    swatch.AutoButtonColor = false
    swatch.Parent = holder
    app.addCorner(swatch, 5)
    app.addStroke(swatch, app.THEME.line, 1, 0.45)

    swatch.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    local hue, sat, val = Color3.toHSV(initialColor)
    local transparency = math.clamp(tonumber(initialTransparency) or 0, 0, 1)
    local lastPickerTransparency = transparency

    -- 浮动面板(紧凑固定尺寸,挂 dropdownLayer;openedDropdown 单例 + 外部点击/滚动/切页关闭全部复用)
    local panel = Instance.new("CanvasGroup")
    panel.Name = app.randomName()
    panel.Size = UDim2.fromOffset(194, 250)
    panel.BackgroundColor3 = app.THEME.panel
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.GroupTransparency = 1
    panel.ZIndex = 200
    panel.Parent = dropdownLayer
    app.addCorner(panel, 7)
    app.addStroke(panel, app.THEME.line, 1, 0.35)

    panel.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    -- SV 方块:底色=纯色相,左白渐变(饱和度 0→1 左→右) + 下黑渐变(明度 1→0 上→下)
    local svBase = Instance.new("Frame")
    svBase.Name = app.randomName()
    svBase.Size = UDim2.fromOffset(150, 150)
    svBase.Position = UDim2.fromOffset(10, 10)
    svBase.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
    svBase.BorderSizePixel = 0
    svBase.ZIndex = 201
    svBase.Parent = panel
    app.addCorner(svBase, 6)

    local svWhite = Instance.new("Frame")
    svWhite.Name = app.randomName()
    svWhite.Size = UDim2.fromScale(1, 1)
    svWhite.BackgroundColor3 = Color3.new(1, 1, 1)
    svWhite.BorderSizePixel = 0
    svWhite.ZIndex = 202
    svWhite.Parent = svBase
    app.addCorner(svWhite, 6)
    local svWhiteGrad = Instance.new("UIGradient")
    svWhiteGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    svWhiteGrad.Parent = svWhite

    local svBlack = Instance.new("Frame")
    svBlack.Name = app.randomName()
    svBlack.Size = UDim2.fromScale(1, 1)
    svBlack.BackgroundColor3 = Color3.new(0, 0, 0)
    svBlack.BorderSizePixel = 0
    svBlack.ZIndex = 203
    svBlack.Parent = svBase
    app.addCorner(svBlack, 6)
    local svBlackGrad = Instance.new("UIGradient")
    svBlackGrad.Rotation = 90
    svBlackGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0),
    })
    svBlackGrad.Parent = svBlack

    -- SV 输入层(隐形按钮盖在最上,鼠标/触摸输入都可靠捕获)
    local svCover = Instance.new("TextButton")
    svCover.Name = app.randomName()
    svCover.Size = UDim2.fromScale(1, 1)
    svCover.BackgroundTransparency = 1
    svCover.Text = ""
    svCover.ZIndex = 204
    svCover.Parent = svBase

    -- SV 游标圆环(描边圆,锚点中心,按 sat/val 定位)
    local svCursor = Instance.new("Frame")
    svCursor.Name = app.randomName()
    svCursor.Size = UDim2.fromOffset(12, 12)
    svCursor.AnchorPoint = Vector2.new(0.5, 0.5)
    svCursor.BackgroundTransparency = 1
    svCursor.ZIndex = 205
    svCursor.Parent = svBase
    app.addCorner(svCursor, 999)
    app.addStroke(svCursor, Color3.new(1, 1, 1), 2, 0)

    -- 竖直色相条(彩虹渐变,marker 横线指示当前色相)
    local hueBar = Instance.new("Frame")
    hueBar.Name = app.randomName()
    hueBar.Size = UDim2.fromOffset(16, 150)
    hueBar.Position = UDim2.fromOffset(168, 10)
    hueBar.BackgroundColor3 = Color3.new(1, 1, 1)
    hueBar.BorderSizePixel = 0
    hueBar.ZIndex = 201
    hueBar.Parent = panel
    app.addCorner(hueBar, 6)
    local hueGrad = Instance.new("UIGradient")
    hueGrad.Rotation = 90
    hueGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromHSV(0, 1, 1)),
        ColorSequenceKeypoint.new(0.17, Color3.fromHSV(1 / 6, 1, 1)),
        ColorSequenceKeypoint.new(0.33, Color3.fromHSV(2 / 6, 1, 1)),
        ColorSequenceKeypoint.new(0.5, Color3.fromHSV(3 / 6, 1, 1)),
        ColorSequenceKeypoint.new(0.67, Color3.fromHSV(4 / 6, 1, 1)),
        ColorSequenceKeypoint.new(0.83, Color3.fromHSV(5 / 6, 1, 1)),
        ColorSequenceKeypoint.new(1, Color3.fromHSV(1, 1, 1)),
    })
    hueGrad.Parent = hueBar

    local hueCover = Instance.new("TextButton")
    hueCover.Name = app.randomName()
    hueCover.Size = UDim2.fromScale(1, 1)
    hueCover.BackgroundTransparency = 1
    hueCover.Text = ""
    hueCover.ZIndex = 204
    hueCover.Parent = hueBar

    local hueMarker = Instance.new("Frame")
    hueMarker.Name = app.randomName()
    hueMarker.Size = UDim2.new(1, 4, 0, 4)
    hueMarker.AnchorPoint = Vector2.new(0.5, 0.5)
    hueMarker.BackgroundColor3 = Color3.new(1, 1, 1)
    hueMarker.BorderSizePixel = 0
    hueMarker.ZIndex = 205
    hueMarker.Parent = hueBar
    app.addCorner(hueMarker, 2)
    app.addStroke(hueMarker, Color3.new(0, 0, 0), 1, 0.4)

    -- RGB 行:Copy / Paste 按钮 + 输入框("R, G, B" 格式,也认 #RRGGBB;无效输入还原)
    local copyBtn = Instance.new("TextButton")
    copyBtn.Name = app.randomName()
    copyBtn.Size = UDim2.fromOffset(40, 30)
    copyBtn.Position = UDim2.fromOffset(10, 168)
    copyBtn.BackgroundColor3 = app.THEME.section
    copyBtn.TextColor3 = app.THEME.sub
    app.applyFont(copyBtn, Enum.Font.GothamBold)
    copyBtn.Text = "Copy"
    copyBtn.TextScaled = true
    copyBtn.AutoButtonColor = false
    copyBtn.ZIndex = 201
    copyBtn.Parent = panel
    app.addCorner(copyBtn, 7)
    app.addStroke(copyBtn, app.THEME.line, 1, 0.45)
    local copyTextLimit = Instance.new("UITextSizeConstraint")
    copyTextLimit.MinTextSize = 6
    copyTextLimit.MaxTextSize = 10
    copyTextLimit.Parent = copyBtn

    local pasteBtn = Instance.new("TextButton")
    pasteBtn.Name = app.randomName()
    pasteBtn.Size = UDim2.fromOffset(40, 30)
    pasteBtn.Position = UDim2.fromOffset(56, 168)
    pasteBtn.BackgroundColor3 = app.THEME.section
    pasteBtn.TextColor3 = app.THEME.sub
    app.applyFont(pasteBtn, Enum.Font.GothamBold)
    pasteBtn.Text = "Paste"
    pasteBtn.TextScaled = true
    pasteBtn.AutoButtonColor = false
    pasteBtn.ZIndex = 201
    pasteBtn.Parent = panel
    app.addCorner(pasteBtn, 7)
    app.addStroke(pasteBtn, app.THEME.line, 1, 0.45)
    local pasteTextLimit = Instance.new("UITextSizeConstraint")
    pasteTextLimit.MinTextSize = 6
    pasteTextLimit.MaxTextSize = 10
    pasteTextLimit.Parent = pasteBtn

    local rgbBox = Instance.new("TextBox")
    rgbBox.Name = app.randomName()
    rgbBox.Size = UDim2.fromOffset(82, 30)
    rgbBox.Position = UDim2.fromOffset(102, 168)
    rgbBox.BackgroundColor3 = app.THEME.section
    rgbBox.TextColor3 = app.THEME.text
    app.applyFont(rgbBox, Enum.Font.GothamMedium)
    rgbBox.TextScaled = true
    rgbBox.ClearTextOnFocus = false
    rgbBox.ZIndex = 201
    rgbBox.Parent = panel
    app.addCorner(rgbBox, 7)
    app.addStroke(rgbBox, app.THEME.line, 1, 0.45)
    local rgbTextLimit = Instance.new("UITextSizeConstraint")
    rgbTextLimit.MinTextSize = 6
    rgbTextLimit.MaxTextSize = 12
    rgbTextLimit.Parent = rgbBox

    -- 透明度条:0% 为不透明,100% 为完全透明。它与颜色本身分离,因此颜色预览和
    -- Hit effect/Impact/Spread 等使用者都能保留同一个 Color3,只改变可见强度。
    local alphaLabel = Instance.new("TextLabel")
    alphaLabel.Name = app.randomName()
    alphaLabel.Size = UDim2.fromOffset(100, 14)
    alphaLabel.Position = UDim2.fromOffset(10, 204)
    alphaLabel.BackgroundTransparency = 1
    alphaLabel.TextColor3 = app.THEME.sub
    app.applyFont(alphaLabel, Enum.Font.GothamMedium)
    alphaLabel.TextSize = 10
    alphaLabel.TextXAlignment = Enum.TextXAlignment.Left
    alphaLabel.ZIndex = 201
    alphaLabel.Parent = panel

    local alphaValue = Instance.new("TextLabel")
    alphaValue.Name = app.randomName()
    alphaValue.Size = UDim2.fromOffset(70, 14)
    alphaValue.Position = UDim2.fromOffset(114, 204)
    alphaValue.BackgroundTransparency = 1
    alphaValue.TextColor3 = app.THEME.sub
    app.applyFont(alphaValue, Enum.Font.GothamMedium)
    alphaValue.TextSize = 10
    alphaValue.TextXAlignment = Enum.TextXAlignment.Right
    alphaValue.ZIndex = 201
    alphaValue.Parent = panel

    local alphaBar = Instance.new("Frame")
    alphaBar.Name = app.randomName()
    alphaBar.Size = UDim2.fromOffset(174, 8)
    alphaBar.Position = UDim2.fromOffset(10, 222)
    alphaBar.BackgroundColor3 = app.THEME.section2
    alphaBar.BorderSizePixel = 0
    alphaBar.ZIndex = 201
    alphaBar.Parent = panel
    app.addCorner(alphaBar, 999)
    app.addStroke(alphaBar, app.THEME.line, 1, 0.45)

    local alphaFill = Instance.new("Frame")
    alphaFill.Name = app.randomName()
    alphaFill.Size = UDim2.new(0, 0, 1, 0)
    alphaFill.BackgroundColor3 = app.THEME.accentSoft
    alphaFill.BorderSizePixel = 0
    alphaFill.ZIndex = 202
    alphaFill.Parent = alphaBar
    app.addCorner(alphaFill, 999)

    local alphaCover = Instance.new("TextButton")
    alphaCover.Name = app.randomName()
    alphaCover.Size = UDim2.new(1, 0, 1, 12)
    alphaCover.Position = UDim2.fromOffset(0, -6)
    alphaCover.BackgroundTransparency = 1
    alphaCover.Text = ""
    alphaCover.ZIndex = 204
    alphaCover.Parent = alphaBar

    local alphaMarker = Instance.new("Frame")
    alphaMarker.Name = app.randomName()
    alphaMarker.Size = UDim2.fromOffset(3, 14)
    alphaMarker.AnchorPoint = Vector2.new(0.5, 0.5)
    alphaMarker.BackgroundColor3 = app.THEME.text
    alphaMarker.BorderSizePixel = 0
    alphaMarker.ZIndex = 205
    alphaMarker.Parent = alphaBar
    app.addCorner(alphaMarker, 999)
    app.addStroke(alphaMarker, Color3.new(0, 0, 0), 1, 0.4)

    local function refreshPicker()
        local previous = swatch.BackgroundColor3
        local previousTransparency = lastPickerTransparency
        svBase.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
        svCursor.Position = UDim2.fromScale(sat, 1 - val)
        hueMarker.Position = UDim2.fromScale(0.5, hue)
        local col = Color3.fromHSV(hue, sat, val)
        swatch.BackgroundColor3 = col
        swatch.BackgroundTransparency = transparency
        rgbBox.Text = string.format("%d, %d, %d",
            math.floor(col.R * 255 + 0.5),
            math.floor(col.G * 255 + 0.5),
            math.floor(col.B * 255 + 0.5))
        callback(col)
        alphaLabel.Text = "Transparency"
        alphaValue.Text = string.format("%d%%", math.floor(transparency * 100 + 0.5))
        alphaFill.Size = UDim2.new(1 - transparency, 0, 1, 0)
        alphaMarker.Position = UDim2.new(1 - transparency, 0, 0.5, 0)
        if transparencyCallback then transparencyCallback(transparency) end
        lastPickerTransparency = transparency
        if previous.R ~= col.R or previous.G ~= col.G or previous.B ~= col.B or previousTransparency ~= transparency then
            app.markCheatGPTConfigDirty()
        end
    end

    -- 文本(RGB 或 #HEX)解析进颜色;无效则仅还原显示
    local function applyTextColor(str)
        local r, g, b
        local hex = str:gsub("#", ""):match("^(%x%x%x%x%x%x)$")
        if hex then
            r = tonumber(hex:sub(1, 2), 16)
            g = tonumber(hex:sub(3, 4), 16)
            b = tonumber(hex:sub(5, 6), 16)
        else
            local rs, gs, bs = str:match("(%d+)%D+(%d+)%D+(%d+)")
            r = tonumber(rs)
            g = tonumber(gs)
            b = tonumber(bs)
        end
        if r and g and b then
            hue, sat, val = Color3.toHSV(Color3.fromRGB(
                math.clamp(r, 0, 255),
                math.clamp(g, 0, 255),
                math.clamp(b, 0, 255)))
        end
        refreshPicker()
    end

    -- SV / 色相条拖动(鼠标+触摸,用 isSameDragInput 判同一输入,与窗口拖动同一套辅助)
    local cpDragInput = nil
    local cpDragTarget = nil

    local function applySVInput(pos)
        local origin = svBase.AbsolutePosition
        local size = svBase.AbsoluteSize
        sat = math.clamp((pos.X - origin.X) / size.X, 0, 1)
        val = 1 - math.clamp((pos.Y - origin.Y) / size.Y, 0, 1)
        refreshPicker()
    end

    local function applyHueInput(pos)
        local origin = hueBar.AbsolutePosition
        local size = hueBar.AbsoluteSize
        hue = math.clamp((pos.Y - origin.Y) / size.Y, 0, 1)
        refreshPicker()
    end

    local function applyAlphaInput(pos)
        local origin = alphaBar.AbsolutePosition
        local size = alphaBar.AbsoluteSize
        transparency = 1 - math.clamp((pos.X - origin.X) / size.X, 0, 1)
        refreshPicker()
    end

    svCover.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
            cpDragInput = input
            cpDragTarget = "sv"
            applySVInput(input.Position)
        end
    end)

    hueCover.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
            cpDragInput = input
            cpDragTarget = "hue"
            applyHueInput(input.Position)
        end
    end)

    alphaCover.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
            cpDragInput = input
            cpDragTarget = "alpha"
            applyAlphaInput(input.Position)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if cpDragTarget and cpDragInput and app.isSameDragInput(cpDragInput, input) then
            if cpDragTarget == "sv" then
                applySVInput(input.Position)
            elseif cpDragTarget == "hue" then
                applyHueInput(input.Position)
            else
                applyAlphaInput(input.Position)
            end
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if cpDragInput and app.isDragEndInput(cpDragInput, input) then
            cpDragInput = nil
            cpDragTarget = nil
        end
    end)

    rgbBox.FocusLost:Connect(function()
        applyTextColor(rgbBox.Text)
    end)

    copyBtn.Activated:Connect(function()
        if not app.EXEC_SUPPORT["setclipboard"] then
            app.notifyUnsupportedFunc("setclipboard")
            return
        end
        app.xpcallw(function()
            setclipboard(rgbBox.Text)
        end, "颜色复制")
    end)

    pasteBtn.Activated:Connect(function()
        if not app.EXEC_SUPPORT["getclipboard"] then
            app.notifyUnsupportedFunc("getclipboard")
            return
        end
        app.xpcallw(function()
            local reader = getclipboard or (type(syn) == "table" and syn.get_clipboard)
            if reader then
                applyTextColor(tostring(reader()))
            end
        end, "颜色粘贴")
    end)

    -- 缺函数标灰(仍可点击,点击弹缺失提示)
    if not app.EXEC_SUPPORT["setclipboard"] then
        copyBtn.TextTransparency = 0.55
        copyBtn.BackgroundTransparency = 0.45
    end
    if not app.EXEC_SUPPORT["getclipboard"] then
        pasteBtn.TextTransparency = 0.55
        pasteBtn.BackgroundTransparency = 0.45
    end

    swatch.Activated:Connect(function()
        if openedDropdown == panel then
            closeOpenedDropdown()
        else
            app.openColorPickerPanel(panel, swatch)
        end
    end)

    refreshPicker() -- 初始化色块/RGB 显示(回调一次初始色,与现有控件初始化风格一致)
    local colorApi = app.registerConfigControl("color", resetKey, {
        Set = function(value)
            cpDragInput, cpDragTarget = nil, nil
            hue, sat, val = Color3.toHSV(value)
            refreshPicker()
        end,
        Get = function() return swatch.BackgroundColor3 end,
    }, resetKey)
    local alphaApi
    if transparencyResetKey then
        alphaApi = app.registerConfigControl("slider", transparencyResetKey, {
            Set = function(value)
                transparency = math.clamp(tonumber(value) or 0, 0, 1)
                refreshPicker()
            end,
            Get = function() return transparency end,
        }, transparencyResetKey)
    end
    return {Color = colorApi, Transparency = alphaApi}
end

function app.createColorPickerRow(parent, text, initialColor, callback, resetKey, initialTransparency, transparencyCallback, transparencyResetKey)
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, 0, 0, 26)
    holder.BackgroundTransparency = 1
    holder.Parent = parent

    local label = Instance.new("TextLabel")
    label.Name = app.randomName()
    label.Size = UDim2.new(1, -38, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = app.THEME.text
    app.applyFont(label, Enum.Font.GothamMedium)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = holder

    app.attachColorSwatch(holder, UDim2.new(1, -24, 0.5, -10), initialColor, callback, resetKey,
        initialTransparency, transparencyCallback, transparencyResetKey)
    return holder
end

-- ================= 创建各个标签页内容 =================
local rageFrame = tabFrames.Rage
local visualFrame = tabFrames.Visual
local localFrame = tabFrames.LocalPlayer
local playersFrame = tabFrames.PlayersList
local settingFrame = tabFrames.Setting

-- ========== Legit 标签页 ==========
do
    local aimBody = app.createSection(tabFrames.Legit, "Aim Assist")
    local function resetAim()
        if app.resetAimAssist then app.resetAimAssist() end
        if app.resetTrigger then app.resetTrigger() end
    end
    createModernToggle(aimBody, "Aim Assist", app.AIM_ENABLED, function(v)
        app.AIM_ENABLED = v; resetAim()
    end, "AimAssist")
    app.createDropdown(aimBody, "Mode", {"Lock", "Adaptive"}, app.AIM_MODE, function(v)
        app.AIM_MODE = v; resetAim()
    end)
    app.createDropdown(aimBody, "AimPart", app.AIM_PARTS, app.AIM_PART, function(v)
        app.AIM_PART = v; resetAim()
    end)
    createSlider(aimBody, "Aim speed", 1, 30, app.AIM_SPEED, 0, function(v)
        app.AIM_SPEED = math.clamp(v, 1, 30)
    end, true)
    createSlider(aimBody, "Max Distance", 0, 10000, app.AIM_MAX_DISTANCE, 0, function(v)
        app.AIM_MAX_DISTANCE = math.clamp(v, 0, 10000); resetAim()
    end, true, "AIM_MAX_DISTANCE")
    createModernToggle(aimBody, "Only Enemy", app.AIM_ONLY_ENEMY, function(v)
        app.AIM_ONLY_ENEMY = v; resetAim()
    end, nil, nil, "AIM_ONLY_ENEMY")
    createModernToggle(aimBody, "Team Check", app.AIM_TEAM_CHECK, function(v)
        app.AIM_TEAM_CHECK = v; resetAim()
    end, nil, nil, "AIM_TEAM_CHECK")
    createModernToggle(aimBody, "Wall Check", app.AIM_WALL_CHECK, function(v)
        app.AIM_WALL_CHECK = v; resetAim()
    end)
    createModernToggle(aimBody, "Draw Fov", app.AIM_DRAW_FOV, function(v) app.AIM_DRAW_FOV = v end)
    createSlider(aimBody, "Fov size", 0, 200, app.AIM_FOV_SIZE, 0, function(v)
        app.AIM_FOV_SIZE = math.clamp(v, 0, 200); resetAim()
    end, true)
    app.createColorPickerRow(aimBody, "Fov Color", app.AIM_FOV_COLOR, function(c)
        app.AIM_FOV_COLOR = c
    end, "AIM_FOV_COLOR", app.AIM_FOV_TRANSPARENCY, function(v)
        app.AIM_FOV_TRANSPARENCY = v
    end, "AIM_FOV_TRANSPARENCY")
    createModernToggle(aimBody, "Only Scope", app.AIM_ONLY_SCOPE, function(v)
        app.AIM_ONLY_SCOPE = v; resetAim()
    end, nil, nil, "AIM_ONLY_SCOPE")
    local legitBody = app.createSection(tabFrames.Legit, "Combat")
    app.gateExecutorToggle(createModernToggle(legitBody, "Trigger", app.TRIGGER_ENABLED, function(v)
        app.TRIGGER_ENABLED = v
        if app.resetTrigger then app.resetTrigger() end
    end), "getsenv")
    createModernToggle(legitBody, "Team Check", app.TRIGGER_TEAM_CHECK, function(v)
        app.TRIGGER_TEAM_CHECK = v
        if app.resetTrigger then app.resetTrigger() end
    end, nil, nil, "TRIGGER_TEAM_CHECK")
    createModernToggle(legitBody, "Only Enemy", app.TRIGGER_ONLY_ENEMY, function(v)
        app.TRIGGER_ONLY_ENEMY = v
        if app.resetTrigger then app.resetTrigger() end
    end, nil, nil, "TRIGGER_ONLY_ENEMY")
    createModernToggle(legitBody, "Only Scope", app.TRIGGER_ONLY_SCOPE, function(v)
        app.TRIGGER_ONLY_SCOPE = v
        if app.resetTrigger then app.resetTrigger() end
    end, nil, nil, "TRIGGER_ONLY_SCOPE")
    createSlider(legitBody, "Max Distance", 0, 10000, app.TRIGGER_MAX_DISTANCE, 0, function(v)
        app.TRIGGER_MAX_DISTANCE = math.clamp(v, 0, 10000)
        if app.resetTrigger then app.resetTrigger() end
    end, true, "TRIGGER_MAX_DISTANCE")
    createSlider(legitBody, "Reaction Time (ms)", 0, 1000, app.TRIGGER_DELAY_MS, 0, function(v)
        app.TRIGGER_DELAY_MS = math.clamp(v, 0, 1000)
        if app.resetTrigger then app.resetTrigger() end
    end, true)
end

-- Rage 标签页
local rageBody = app.createSection(rageFrame, "Combat")

local rageToggleControl = app.gateExecutorToggle(createModernToggle(rageBody, "RageBot", rageEnabled, function(v)
    rageEnabled = v
end, "RageBot"), "getsenv", "debug.getupvalues")

local onlyEnemyToggleControl = createModernToggle(rageBody, "Only Enemy", onlyEnemyEnabled, function(v)
    onlyEnemyEnabled = v
end)

local teamCheckToggleControl = createModernToggle(rageBody, "Team Check", teamCheckEnabled, function(v)
    teamCheckEnabled = v
end)

-- WallBang 关:不攻击墙后的敌人; 开:攻击墙后的敌人
local wallbangToggleControl = createModernToggle(rageBody, "WallBang", app.WALLBANG, function(v)
    app.WALLBANG = v
end)

-- 每帧同时攻击的目标数（多线程并发开火）
createSlider(rageBody, "Multi Target", 1, 8, app.RAGE_MULTI_TARGET, 0, function(v)
    app.RAGE_MULTI_TARGET = v
end)

-- 对单个目标同时并发发送攻击的线程数(无论如何不能小于 1,这里 clamp 一次,使用处再兜底)
createSlider(rageBody, "Thread", 1, 9, app.RAGE_THREADS_PER_TARGET, 0, function(v)
    app.RAGE_THREADS_PER_TARGET = math.max(1, math.floor(v + 0.5))
end)

local targetPriorityDropdownControl = app.createDropdown(rageBody, "Target Priority", {"Distance", "Centre"}, app.TARGET_PRIORITY, function(v)
    app.TARGET_PRIORITY = v
end)

local hitPartDropdownControl = app.createDropdown(rageBody, "Hit Part", app.RAGE_HIT_PART_OPTIONS, app.RAGE_HIT_PART, function(v)
    app.RAGE_HIT_PART = v
end)

local hitLogToggleControl = createModernToggle(rageBody, "HitLog", hitLogEnabled, function(v)
    hitLogEnabled = v
    relayoutHitLogs(true)
end)

local hitLogSizeSliderControl = createSlider(rageBody, "HitLog Size", 8, 24, hitLogSize, 0, function(v)
    hitLogSize = math.clamp(math.floor(v + 0.5), 8, 24)
    relayoutHitLogs(true)
end, true)

createSlider(rageBody, "Duration Time (s)", 0.5, 10, app.HITLOG_DURATION, 1, function(v)
    app.HITLOG_DURATION = math.clamp(v, 0.5, 10)
    relayoutHitLogs(false)
end, true)

local soundNames = {}
for name in pairs(app.HITSOUNDS) do
    table.insert(soundNames, name)
end
table.sort(soundNames)

-- Glass follows the same direct Sound:Play path as other embedded hitsounds.
-- Its stripped CBR MP3 is tried first; PCM WAV is a local decoder fallback.
do
    local state = {pending = nil, active = {}, preferred = 1, retryAt = 0, stopped = false}
    app.GLASS_SOUND_STATE = state
    function app.playGlassSound(preview)
        if state.stopped then return end
        if state.pending then
            state.pending.preview = state.pending.preview or preview == true
            return
        end
        if not preview and os.clock() < state.retryAt then return end
        local sound = Instance.new("Sound")
        sound.Name = app.randomName()
        sound.Volume = app.HITSOUND_VOLUME
        sound.Parent = secureParent
        local record = {sound = sound, preview = preview == true}
        state.pending = record
        local finished, loaded, token = false, false, 0
        local loadedConnection, endedConnection, destroyingConnection
        local currentFormat = state.preferred
        local function finish(destroying)
            if finished then return end
            finished = true
            token += 1
            if state.pending == record then state.pending = nil end
            state.active[sound] = nil
            if loadedConnection then loadedConnection:Disconnect() end
            if endedConnection then endedConnection:Disconnect() end
            if destroyingConnection then destroyingConnection:Disconnect() end
            if not destroying then sound:Destroy() end
        end
        state.active[sound] = finish
        local function markLoaded()
            if finished then return end
            loaded = true
            state.asset = sound.SoundId
            state.preferred = currentFormat
            state.retryAt = 0
            if state.pending == record then state.pending = nil end
        end
        loadedConnection = sound.Loaded:Connect(function(id)
            if id == nil or id == sound.SoundId then markLoaded() end
        end)
        endedConnection = sound.Ended:Connect(function() markLoaded(); finish() end)
        destroyingConnection = sound.Destroying:Connect(function() finish(true) end)
        local order = state.preferred == 2 and {2, 1} or {1, 2}
        local function attempt(step)
            if finished then return end
            if not app.HITSOUND_ENABLED or app.HITSOUND_KEY ~= "Glass" or state.stopped then finish(); return end
            if not order[step] then
                state.asset = nil
                state.preferred = 1
                state.retryAt = os.clock() + 5
                if record.preview and app.showNotification then
                    app.showNotification("CheatGPT.cc", "Glass failed to load (MP3 and PCM WAV). Select Glass to retry.", 6, {error = true})
                end
                finish()
                return
            end
            currentFormat = order[step]
            local id
            if currentFormat == 1 then
                id = app.resolveResourceHitsound("Glass")
            else
                id = app.resolveResourceFile(app.HITSOUND_LOCAL_ASSETS, "CheatGPT/ACS/Cache", "Glass-pcm-v3", app.GLASS_WAV_ASSET, "wav")
            end
            if not id then attempt(step + 1); return end
            loaded = false
            token += 1
            local thisToken = token
            sound:Stop()
            sound.SoundId = id
            sound:Play()
            if sound.IsLoaded or sound.TimeLength > 0 then markLoaded() end
            task.delay(2, function()
                if finished or thisToken ~= token or loaded then return end
                if sound.IsLoaded or sound.TimeLength > 0 then markLoaded() else attempt(step + 1) end
            end)
        end
        attempt(1)
        -- Ended normally releases this 0.6 s sound; this also bounds stalled engine objects.
        task.delay(10, finish)
    end
    gui.Destroying:Connect(function()
        state.stopped = true
        for _, finish in pairs(state.active) do finish() end
    end)
end

-- Preloading is optional; a preload failure never prevents a subsequent Play call.
for name in pairs(app.HITSOUNDS) do
    task.spawn(function()
        local sound = Instance.new("Sound")
        local id = app.getHitsoundId(name)
        if id then
            sound.SoundId = id
            game:GetService("Debris"):AddItem(sound, 10)
            pcall(function() game:GetService("ContentProvider"):PreloadAsync({sound}) end)
        end
        sound:Destroy()
    end)
end

local hitsoundInitDone = false
local hitsoundDropdownControl = app.createDropdown(rageBody, "Hitsound", soundNames, app.HITSOUND_KEY, function(v)
    app.HITSOUND_KEY = v
    -- 选中立刻试听(初始化时 createDropdown 的首次回调不播)
    if hitsoundInitDone and not app.CONFIG_RESETTING then
        app.previewHitsound()
    end
end)
hitsoundInitDone = true

-- Hitsounds 总开关(关闭后命中和试听都不播放)
createModernToggle(rageBody, "Hitsounds", app.HITSOUND_ENABLED, function(v)
    app.HITSOUND_ENABLED = v
end)

local hitsoundVolumeSliderControl = createSlider(rageBody, "Volume", 0, 5, app.HITSOUND_VOLUME, 1, function(v)
    app.HITSOUND_VOLUME = v
end)


-- BEGIN KILL EFFECT: native creator observation + transparent local media
-- Local observation only: no CombatLog requests and no server damage changes.
function app.createKillEffectTracker(onKill, onReset, onDamage, wantsDamage, onOtherDeath, onRecovery)
    local tracker = {Count = 0, Life = 0, Stopped = false}
    local players, connections = {}, {}
    local localHumanoid, localCharacter
    local function disconnect(list)
        for _, connection in ipairs(list) do connection:Disconnect() end
        table.clear(list)
    end
    local function resetLife()
        tracker.Life += 1
        tracker.Count = 0
        onReset()
    end
    local function disposeHumanoid(record)
        if not record then return end
        record.Disposed = true
        disconnect(record.Connections)
        for _, tag in pairs(record.Tags) do disconnect(tag.Connections) end
        table.clear(record.Tags)
    end
    local function bindHumanoid(playerRecord, humanoid)
        if playerRecord.Humanoid and playerRecord.Humanoid.Object == humanoid then return end
        disposeHumanoid(playerRecord.Humanoid)
        local record = {Object = humanoid, Connections = {}, Tags = {}, Done = humanoid.Health <= 0, LastHealth = math.max(0, humanoid.Health), PendingDamage = 0}
        playerRecord.Humanoid = record
        local isSelf = playerRecord.Player == LocalPlayer
        if isSelf then
            if localHumanoid and localHumanoid ~= humanoid then resetLife() end
            localHumanoid = humanoid
        end
        local function connect(signal, callback) record.Connections[#record.Connections + 1] = signal:Connect(callback) end
        local function live()
            return not tracker.Stopped and not record.Disposed and not record.Done
        end
        local function flushDamage()
            local damage = record.PendingDamage
            record.PendingDamage = 0
            if not onDamage or damage <= 0 or not localHumanoid or localHumanoid.Health <= 0 then return end
            local owner, conflict
            for _, tag in pairs(record.Tags) do
                if tag.Owner and os.clock() - tag.Seen <= 1.25 and
                    (not tag.Removed or (record.DeathTime and tag.Removed >= record.DeathTime - 0.12)) then
                    if owner and owner ~= tag.Owner then conflict = true end
                    owner = tag.Owner
                end
            end
            if not conflict then onDamage(humanoid, damage, owner, record.DamageAt, playerRecord.Player) end
        end
        local function resolve()
            if not live() or not record.DeathTime then return end
            local now = os.clock()
            local candidate, conflict = nil, false
            for _, tag in pairs(record.Tags) do
                local fresh = now - tag.Seen <= 1.25
                local aroundDeath = not tag.Removed or tag.Removed >= record.DeathTime - 0.12
                local owner = tag.Owner
                if fresh and aroundDeath and owner and owner:IsA("Player") and owner.Parent == Players then
                    if candidate and candidate ~= owner then conflict = true end
                    candidate = owner
                end
            end
            if not candidate and now < record.DeathTime + 0.25 then return end
            record.Done = true
            -- Lifetime kills include confirmed posthumous kills; banner/life
            -- stages below still require the same living local character.
            if not conflict and candidate == LocalPlayer and app.lifetimeStats then
                app.lifetimeStats.Add(1, 0)
            end
            if not conflict and record.Life == tracker.Life
                and localHumanoid and localHumanoid.Parent and localHumanoid.Health > 0
                and LocalPlayer.Character == localCharacter then
                if candidate == LocalPlayer then
                    flushDamage()
                    tracker.Count += 1
                    onKill(tracker.Count, playerRecord.Player, humanoid)
                elseif candidate and candidate ~= playerRecord.Player and onOtherDeath then
                    -- Window boundaries use the actual death, not tag resolution time.
                    onOtherDeath(playerRecord.Player, humanoid, candidate, record.DeathTime)
                end
            end
            disposeHumanoid(record)
        end
        local function changedTag(tag)
            if not live() or tag.Removed then return end
            local object = tag.Object
            if object.Parent == humanoid and object.Name == "creator" then
                if tag.Owner ~= object.Value then tag.Seen = os.clock() end
                tag.Owner = object.Value
            else
                tag.Owner = nil
            end
            if record.DeathTime then task.defer(resolve) end
        end
        local function addTag(object)
            if isSelf or not live() or not object:IsA("ObjectValue") or record.Tags[object] then return end
            -- ObjectValue can be parented before Name/Value are assigned.
            local tag = {Object = object, Seen = os.clock(), Connections = {}}
            record.Tags[object] = tag
            tag.Connections[1] = object:GetPropertyChangedSignal("Name"):Connect(function() changedTag(tag) end)
            tag.Connections[2] = object:GetPropertyChangedSignal("Value"):Connect(function() changedTag(tag) end)
            changedTag(tag)
            task.defer(function() changedTag(tag) end)
        end
        local function died()
            if not live() or record.DeathTime then return end
            if isSelf then
                record.Done = true
                resetLife()
                return
            end
            record.DeathTime, record.Life = os.clock(), tracker.Life
            -- One deferred turn observes same-tick tags; allow a short bounded
            -- grace period for the official grenade's damage-before-tag order.
            task.defer(resolve)
            task.delay(0.26, resolve)
        end
        connect(humanoid.Died, died)
        connect(humanoid.HealthChanged, function(health)
            if not live() then return end
            local remaining = math.max(0, health)
            if not isSelf and onRecovery and remaining > record.LastHealth then
                record.PendingDamage = 0
                onRecovery(humanoid)
            end
            if not isSelf and onDamage and (not wantsDamage or wantsDamage()) and remaining < record.LastHealth then
                record.PendingDamage += record.LastHealth - remaining
                record.DamageAt = os.clock()
                task.defer(function()
                    if live() and not record.DeathTime then flushDamage() end
                end)
            end
            record.LastHealth = remaining
            if health <= 0 then died() end
        end)
        if not isSelf and not record.Done then
            if onRecovery then
                connect(humanoid:GetPropertyChangedSignal("MaxHealth"), function() onRecovery(humanoid) end)
            end
            connect(humanoid.ChildAdded, addTag)
            connect(humanoid.ChildRemoved, function(object)
                local tag = record.Tags[object]
                if not tag then return end
                tag.Removed = os.clock()
                disconnect(tag.Connections)
                task.delay(0.15, function()
                    if record.Tags[object] == tag then record.Tags[object] = nil end
                end)
            end)
            for _, object in ipairs(humanoid:GetChildren()) do addTag(object) end
        end
    end
    local function clearCharacter(record)
        disconnect(record.CharacterConnections)
        disposeHumanoid(record.Humanoid)
        record.Humanoid = nil
        record.Character = nil
    end
    local function bindCharacter(record, character)
        if tracker.Stopped or record.Character == character then return end
        clearCharacter(record)
        record.Character = character
        if record.Player == LocalPlayer then
            localCharacter, localHumanoid = character, nil
            resetLife()
        end
        local function childAdded(child)
            if record.Character == character and child:IsA("Humanoid") then bindHumanoid(record, child) end
        end
        record.CharacterConnections[1] = character.ChildAdded:Connect(childAdded)
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if humanoid then childAdded(humanoid) end
    end
    local function addPlayer(player)
        if tracker.Stopped or players[player] then return end
        local record = {Player = player, Connections = {}, CharacterConnections = {}}
        players[player] = record
        record.Connections[1] = player.CharacterAdded:Connect(function(character) bindCharacter(record, character) end)
        record.Connections[2] = player.CharacterRemoving:Connect(function(character)
            if record.Character ~= character then return end
            clearCharacter(record)
            if player == LocalPlayer then
                localCharacter, localHumanoid = nil, nil
                resetLife()
            end
        end)
        if player.Character then bindCharacter(record, player.Character) end
    end
    local function removePlayer(player)
        local record = players[player]
        if not record then return end
        clearCharacter(record)
        disconnect(record.Connections)
        players[player] = nil
    end
    function tracker.Stop()
        if tracker.Stopped then return end
        tracker.Stopped = true
        disconnect(connections)
        for player in pairs(players) do removePlayer(player) end
        localHumanoid, localCharacter = nil, nil
    end
    addPlayer(LocalPlayer)
    for _, player in ipairs(Players:GetPlayers()) do addPlayer(player) end
    connections[1] = Players.PlayerAdded:Connect(addPlayer)
    connections[2] = Players.PlayerRemoving:Connect(removePlayer)
    return tracker
end

-- Battlefield feedback uses a fixed set of native labels and one static texture.
-- Points are a local BF1-style presentation, never the game's authoritative score.
function app.createBattlefieldKillEffect()
    local controller = {Stopped = false}
    local duration, scoreFadeTime, cardExitTime, countTime = 5, 0.45, 0.2, 0.35
    local cardQueue, queueFirst, queueLast = {}, 1, 0
    local currentCard, flipAt, flipSwapped, enteredByFlip = nil, nil, false, false
    local chainHold, flipTime = 1, 0.2
    local cache, connections, rows, contexts = {}, {}, {}, setmetatable({}, {__mode = "k"})
    local contributions = setmetatable({}, {__mode = "k"})
    local observationEpoch = os.clock()
    local sound, busy, retryAt, warnedAt = nil, false, 0, -math.huge
    local total, shown, from, countAt, lastEvent, headerAt = 0, 0, 0, 0, -math.huge, -math.huge
    local media = {
        Skull = {Path="cheatgpt/v1/kill-effect/battlefield1/skull-4b83e0416301.png.lzma2", Size=631058, CRC32=2659230661, PackedSize=447320, PackedCRC32=3660287002},
        Sound = {Path="cheatgpt/v1/kill-effect/battlefield1/killsound-fce8c8b55a46.mp3.lzma2", Size=28210, CRC32=3558872585, PackedSize=25317, PackedCRC32=1469087250},
    }
    local root = Instance.new("Frame")
    root.Name = "BattlefieldKillBanner"
    root.BackgroundTransparency = 1
    root.BorderSizePixel = 0
    root.AnchorPoint = Vector2.new(0.5, 0)
    root.Position = UDim2.fromScale(0.5, 0.65)
    root.Size = UDim2.fromOffset(360, 148)
    root.Active = false
    root.Visible = false
    root.ZIndex = 62
    root.Parent = gui
    local scale = Instance.new("UIScale")
    scale.Parent = root
    local function resize()
        local size = gui.AbsoluteSize
        if size.X <= 0 or size.Y <= 0 then
            local camera = Workspace.CurrentCamera
            size = camera and camera.ViewportSize or Vector2.new(800, 600)
        end
        local touch = game:GetService("UserInputService").TouchEnabled
        -- Include the feathered card margin; keep mobile compact without falling off
        -- the bottom in landscape or crossing the sides in portrait.
        scale.Scale = math.max(0.1, math.min(size.Y / 720 * (touch and 1.65 or 1.1),
            size.X * 0.92 / 384, size.Y * 0.33 / 148, touch and 2.9 or 2.5)) * (touch and 0.8 or 1)
    end
    connections[#connections + 1] = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
    resize()
    local card = Instance.new("Frame")
    card.Name = "KillCard"
    card.BackgroundTransparency = 1
    card.BorderSizePixel = 0
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.new(0.5, 0, 0, 32)
    card.Size = UDim2.fromOffset(360, 64)
    card.Visible = false
    card.Active = false
    card.ZIndex = 62
    card.Parent = root
    -- Soft frosted-card approximation: fixed translucent layers feather its
    -- edges, with no full-screen BlurEffect or per-kill texture/part allocation.
    -- ScreenGui cannot sample/blur just the world behind this rectangle.
    for i = 6, 1, -1 do
        local surface = Instance.new("Frame")
        surface.Name = "Frost" .. i
        surface.AnchorPoint = Vector2.new(0.5, 0.5)
        surface.Position = UDim2.fromScale(0.5, 0.5)
        surface.Size = UDim2.fromScale(1 + i * 0.009, 1 + i * 0.065)
        surface.BackgroundColor3 = Color3.fromRGB(196, 204, 210)
        surface.BackgroundTransparency = 0.975
        surface.BorderSizePixel = 0
        surface.ZIndex = 62
        surface.Parent = card
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0.1, 0)
        corner.Parent = surface
    end
    local surface = Instance.new("Frame")
    surface.Name = "FrostCore"
    surface.Size = UDim2.fromScale(1, 1)
    surface.BackgroundColor3 = Color3.fromRGB(210, 218, 224)
    surface.BackgroundTransparency = 0.86
    surface.BorderSizePixel = 0
    surface.ZIndex = 62
    surface.Parent = card
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0.075, 0)
    corner.Parent = surface
    local gradient = Instance.new("UIGradient")
    gradient.Rotation = 90
    gradient.Color = ColorSequence.new(Color3.fromRGB(245, 248, 250), Color3.fromRGB(184, 195, 204))
    gradient.Parent = surface
    -- Static, low-contrast mosaic cells suggest frosted/pixelated glass. This
    -- remains a transparent UI texture, not a live sample of the 3D scene.
    -- Allocate once; neither kills nor animation generate or randomize cells.
    for row = 0, 2 do
        for column = 0, 9 do
            local shade = (column * 17 + row * 31 + column * row * 7) % 7
            local tile = Instance.new("Frame")
            tile.Name = "Mosaic" .. (row * 10 + column + 1)
            tile.Position = UDim2.fromScale(0.015 + column * 0.097, 0.065 + row * 0.29)
            tile.Size = UDim2.fromScale(0.099, 0.305)
            tile.BackgroundColor3 = Color3.fromRGB(166 + shade * 13, 176 + shade * 11, 184 + shade * 10)
            tile.BackgroundTransparency = 0.88 + (shade % 3) * 0.025
            tile.BorderSizePixel = 0
            tile.ZIndex = 62
            tile.Parent = surface
            local softCorner = Instance.new("UICorner")
            softCorner.CornerRadius = UDim.new(0.12, 0)
            softCorner.Parent = tile
        end
    end
    local function label(name, x, y, width, height, fontSize, alignment)
        local object = Instance.new("TextLabel")
        object.Name = name
        object.BackgroundTransparency = 1
        object.BorderSizePixel = 0
        object.Position = UDim2.fromOffset(x, y)
        object.Size = UDim2.fromOffset(width, height)
        object.Font = Enum.Font.GothamMedium
        object.TextSize = fontSize
        object.TextColor3 = Color3.fromRGB(242, 242, 238)
        object.TextStrokeColor3 = Color3.fromRGB(15, 15, 15)
        object.TextStrokeTransparency = 0.65
        object.TextXAlignment = alignment
        object.TextTruncate = Enum.TextTruncate.AtEnd
        object.TextWrapped = false
        object.RichText = false
        object.Text = ""
        object.Active = false
        object.ZIndex = 63
        object.Parent = root
        return object
    end
    local skull = Instance.new("ImageLabel")
    skull.Name = "Skull"
    skull.BackgroundTransparency = 1
    skull.Size = UDim2.fromScale(30 / 360, 30 / 64)
    skull.Position = UDim2.fromScale(16 / 360, 17 / 64)
    skull.ScaleType = Enum.ScaleType.Stretch
    skull.ImageTransparency = 0
    skull.ZIndex = 63
    skull.Parent = card
    local function cardLabel(name, x, y, width, height, fontSize, alignment)
        local object = label(name, x, y, width, height, fontSize, alignment)
        object.Position = UDim2.fromScale(x / 360, y / 64)
        object.Size = UDim2.fromScale(width / 360, height / 64)
        object.Parent = card
        return object
    end
    local victim = cardLabel("Victim", 56, 7, 218, 28, 20, Enum.TextXAlignment.Left)
    victim.TextColor3 = Color3.fromRGB(177, 59, 54)
    local killPoints = cardLabel("KillPoints", 280, 7, 58, 28, 20, Enum.TextXAlignment.Right)
    local weapon = cardLabel("Weapon", 56, 35, 282, 21, 14, Enum.TextXAlignment.Left)
    local counter = label("Score", 276, 70, 84, 32, 28, Enum.TextXAlignment.Left)
    local rowLabels = {}
    for i = 1, 4 do
        rowLabels[i] = label("Reward" .. i, 0, 73 + (i - 1) * 18, 262, 18, 13, Enum.TextXAlignment.Right)
    end
    local function enabled()
        return not controller.Stopped and app.KILL_EFFECT_ENABLED and app.KILL_EFFECT_STYLE == "Battlefield 1"
    end
    controller.WantsDamage = enabled
    local skullBinding
    local function warm()
        if not enabled() or busy or os.clock() < retryAt or (sound and skullBinding) then return end
        busy = true
        -- A slow download never delays the text or queues a stale kill sound.
        task.defer(function()
            if not enabled() then busy = false; return end
            local failed = false
            local function load(key, name, extension)
                local ok, id = pcall(app.resolveResourceFile, cache, "CheatGPT/ACS/Cache", name, media[key], extension, 30)
                if not ok or not id then failed = true; return nil end
                return id
            end
            if not skullBinding then
                local id = load("Skull", "BF1-skull-4b83e0416301", "png")
                if id and not controller.Stopped then
                    skull.Image = id
                    skullBinding = app.bindAsyncImage(skull, function(attempt)
                        if attempt == 1 then return id end
                        cache["BF1-skull-4b83e0416301"] = nil
                        return app.resolveResourceFile(cache, "CheatGPT/ACS/Cache", "BF1-skull-4b83e0416301", media.Skull, "png", 30)
                    end, "Battlefield skull")
                    task.defer(function()
                        if not controller.Stopped then pcall(function() game:GetService("ContentProvider"):PreloadAsync({skull}) end) end
                    end)
                end
            end
            if not sound and not controller.Stopped then
                local id = load("Sound", "BF1-sound-fce8c8b55a46", "mp3")
                if id and not controller.Stopped then
                    sound = Instance.new("Sound")
                    sound.Name = "BattlefieldKillSound"
                    sound.SoundId = id
                    sound.Looped = false
                    sound.Volume = math.clamp(app.KILL_SOUNDS_VOLUME, 0, 5)
                    sound.Parent = game:GetService("SoundService")
                    task.defer(function()
                        if not controller.Stopped then pcall(function() game:GetService("ContentProvider"):PreloadAsync({sound}) end) end
                    end)
                end
            end
            busy, retryAt = false, os.clock() + (failed and 5 or 0)
            if failed and enabled() and os.clock() - warnedAt >= 15 then
                warnedAt = os.clock()
                if app.showNotification then app.showNotification("Kill effect", "Battlefield media unavailable; text feedback remains active.", 5) end
            end
        end)
    end
    local function alpha(object, value)
        object.TextTransparency = value
        object.TextStrokeTransparency = 0.65 + value * 0.35
    end
    local function fade(age)
        return math.clamp((age - (duration - scoreFadeTime)) / scoreFadeTime, 0, 1)
    end
    local function cardsActive(now)
        return flipAt ~= nil or queueFirst <= queueLast
            or (currentCard ~= nil and now - headerAt < duration)
    end
    local function resetExpiredScore(now)
        if now - lastEvent >= duration and not cardsActive(now) then
            total, shown = 0, 0
            table.clear(rows)
        end
    end
    local function presentCard(record, now, flipped)
        currentCard, headerAt, enteredByFlip = record, now, flipped
        victim.Text, weapon.Text, killPoints.Text = record.Name, record.Weapon, "20"
    end
    local function nextCard()
        local record = cardQueue[queueFirst]
        cardQueue[queueFirst] = nil
        queueFirst += 1
        if queueFirst > queueLast then
            table.clear(cardQueue)
            queueFirst, queueLast = 1, 0
        end
        return record
    end
    local function draw()
        if not enabled() or not root.Visible then return end
        local now = os.clock()
        -- Never replace a readable face early. Once it has had one second,
        -- pending kills turn it over; a late kill can interrupt the final exit.
        if not flipAt and currentCard and queueFirst <= queueLast and now - headerAt >= chainHold then
            flipAt, flipSwapped = now, false
        end
        local horizontal, vertical = 1, 1
        if flipAt then
            local phase = math.clamp((now - flipAt) / flipTime, 0, 1)
            horizontal = math.abs(math.cos(math.pi * phase))
            if phase >= 0.5 and not flipSwapped then
                presentCard(nextCard(), now, true)
                flipSwapped = true
            end
            if phase >= 1 then
                -- Give every revealed face its full hold, even after a stalled frame.
                flipAt, headerAt, horizontal = nil, now, 1
            end
        else
            local age = now - headerAt
            local entering = math.clamp(age / 0.1, 0, 1)
            local pop = enteredByFlip and 1 or (0.72 + 0.28 * (1 - (1 - entering) ^ 3))
            local exiting = math.clamp((age - (duration - cardExitTime)) / cardExitTime, 0, 1)
            horizontal, vertical = pop, pop * (1 - exiting * exiting)
        end
        local activeCards = cardsActive(now)
        card.Visible = activeCards == true
        if not activeCards and now - lastEvent >= duration then
            root.Visible = false
            return
        end
        if card.Visible then
            -- A GUI flip is projected about its vertical axis: narrow to an edge,
            -- swap the face at the midpoint, then widen. Final exit changes only Y.
            card.Size = UDim2.fromOffset(360 * horizontal, 64 * vertical)
            local textScale = math.min(horizontal, vertical)
            victim.TextSize = math.max(1, 20 * textScale)
            killPoints.TextSize = math.max(1, 20 * textScale)
            weapon.TextSize = math.max(1, 14 * textScale)
        end
        local progress = math.clamp((now - countAt) / countTime, 0, 1)
        shown = math.floor(from + (total - from) * (1 - (1 - progress) ^ 3) + 0.5)
        local text = "+" .. shown
        if counter.Text ~= text then counter.Text = text end
        -- Card presentation never adds score or replays audio. Keep the total
        -- visible through the queue and fade with the final fully revealed card.
        alpha(counter, (flipAt or queueFirst <= queueLast) and 0 or fade(now - math.max(lastEvent, headerAt)))
        for i, object in ipairs(rowLabels) do
            local row = rows[i]
            object.Text = row and (row.Title .. "  " .. row.Points) or ""
            alpha(object, row and fade(now - row.At) or 1)
        end
    end
    local function add(points, title, key)
        local now = os.clock()
        resetExpiredScore(now)
        from, countAt, lastEvent = shown, now, now
        total += points
        if app.lifetimeStats then app.lifetimeStats.Add(0, points) end
        if title then
            local previous
            if key then
                for i, row in ipairs(rows) do
                    if row.Key == key and now - row.At < duration - scoreFadeTime then previous = table.remove(rows, i); break end
                end
            end
            table.insert(rows, 1, {Title = title, Points = points + (previous and previous.Points or 0), At = now, Key = key})
            if #rows > 4 then table.remove(rows) end
        end
        root.Visible = true
        draw()
    end
    local function isAssistEnemy(player)
        return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
            and player ~= LocalPlayer and not (player.Team and LocalPlayer.Team and player.Team == LocalPlayer.Team)
            and not (friendSet and friendSet[player.Name:lower()])
    end
    local function contribution(humanoid)
        local record = contributions[humanoid]
        if not record then record = {Damage = 0}; contributions[humanoid] = record end
        return record
    end
    function controller.ObserveRecovery(humanoid)
        local record = contributions[humanoid]
        if record then record.Damage, record.DamageAt, record.MaxHealth = 0, nil, nil end
    end
    function controller.ObserveSuppression(player, sentAt)
        if not enabled() or not isAssistEnemy(player) or not player.Character then return end
        local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
        local at, now = tonumber(sentAt), os.clock()
        if not humanoid or not at or at < observationEpoch or at > now or now - at > 0.5 then return end
        local record = contribution(humanoid)
        if humanoid.Health <= 0 and (not record.PendingDeath or at > record.PendingDeath.At) then return end
        if record.Done or (record.HitAt and math.abs(at - record.HitAt) <= 0.25) then return end
        -- ACS emits Suppression before its hit raycast. A direct-hit observation
        -- cancels this candidate so a hit is not counted as a near miss.
        -- Explosion suppression (kind ~= 1) is filtered at the capture point.
        record.SuppressedAt = math.max(record.SuppressedAt or -math.huge, at)
    end
    function controller.ObserveOtherDeath(player, humanoid, killer, deathAt)
        if not enabled() or not isAssistEnemy(player) or player.Character ~= humanoid.Parent
            or not killer or killer == LocalPlayer or killer == player then return end
        local record = contribution(humanoid)
        if record.Done or record.PendingDeath then return end
        local at = tonumber(deathAt) or os.clock()
        record.PendingDeath = {At = at}
        -- Let the existing Heartbeat queue deliver same-frame near misses/hits.
        -- Eligibility still uses the captured death time, not this grace period.
        task.delay(0.05, function()
            if contributions[humanoid] ~= record or record.Done then return end
            record.Done = true
            if not enabled() or not isAssistEnemy(player) or player.Character ~= humanoid.Parent then return end
            local ratio = record.MaxHealth and record.MaxHealth > 0 and record.Damage / record.MaxHealth or 0
            if record.DamageAt and at >= record.DamageAt and at - record.DamageAt <= 7
                and ratio >= 0.75 and ratio <= 0.99 then
                add(20, "ASSIST")
            elseif record.SuppressedAt and at >= record.SuppressedAt and at - record.SuppressedAt <= 5 then
                add(15, "SUPPRESSION ASSIST")
            end
        end)
    end
    -- Correlate existing local hit feedback with replicated health and creator.
    -- Missing/ambiguous context omits damage/headshot credit instead of inventing it.
    function controller.ObserveHit(humanoid, tool, zone, sentAt)
        if not enabled() or typeof(humanoid) ~= "Instance" or not humanoid.Parent then return end
        local now = os.clock()
        local hitAt = tonumber(sentAt) or now
        if hitAt < observationEpoch or hitAt > now then return end
        local record = contribution(humanoid)
        record.HitAt = hitAt
        if record.SuppressedAt and math.abs(hitAt - record.SuppressedAt) <= 0.25 then record.SuppressedAt = nil end
        local context = contexts[humanoid]
        if not context or now - context.At > 0.9 then context = {}; contexts[humanoid] = context end
        if context.At and now - context.At < 0.1 and context.Zone ~= zone then
            context.AmbiguousUntil = now + 0.1
        end
        context.At, context.Zone = hitAt, zone
        context.Weapon = typeof(tool) == "Instance" and tool:IsA("Tool") and tool.Name or nil
    end
    function controller.ObserveDamage(humanoid, damage, owner, damageAt, player)
        if not enabled() or owner ~= LocalPlayer or damage <= 0 then return end
        local context = contexts[humanoid]
        if not context or os.clock() - context.At > 0.9 then return end
        local points = math.max(1, math.floor(damage + 0.5))
        context.DamageAt = os.clock()
        if isAssistEnemy(player) then
            local maximum = tonumber(humanoid.MaxHealth)
            local record = contribution(humanoid)
            if maximum and maximum > 0 and not record.Done then
                if record.MaxHealth ~= maximum then record.Damage = 0 end
                record.MaxHealth = maximum
                record.Damage += damage
                record.DamageAt = tonumber(damageAt) or os.clock()
                if record.SuppressedAt and math.abs(record.DamageAt - record.SuppressedAt) <= 0.25 then
                    record.SuppressedAt = nil
                end
            end
        end
        context.FatalHeadshot = humanoid.Health <= 0 and context.Zone == 1
            and (not context.AmbiguousUntil or os.clock() > context.AmbiguousUntil)
        add(points, "ENEMY HIT", humanoid)
    end
    function controller.IsPlaying() return root.Visible end
    function controller.Play(_, player, humanoid)
        if not enabled() then return end
        warm()
        local context = humanoid and contexts[humanoid]
        local now = os.clock()
        resetExpiredScore(now)
        -- Copy strings now; queued cards retain the correct victim and weapon
        -- after a weapon switch, player departure or later hit context update.
        local record = {Name = player and player.Name or "ENEMY KILLED",
            Weapon = context and now - context.At <= 0.9 and context.Weapon or ""}
        if not cardsActive(now) then
            presentCard(record, now, false)
        else
            queueLast += 1
            cardQueue[queueLast] = record
        end
        -- Each confirmed kill adds to the same count-up, including the first
        -- and only kill. No multi-kill threshold; animate from the visible value.
        add(20)
        if context and context.FatalHeadshot and now - context.DamageAt <= 0.3 then add(25, "HEADSHOT BONUS") end
        if humanoid then
            contexts[humanoid] = nil
            local record = contributions[humanoid]
            if record then record.Done = true end
        end
        if sound then
            sound:Stop()
            sound.TimePosition = 0
            sound:Play()
        end
        draw()
    end
    function controller.Clear()
        root.Visible = false
        card.Visible = false
        total, shown, from, lastEvent, headerAt = 0, 0, 0, -math.huge, -math.huge
        table.clear(rows); table.clear(contexts); table.clear(contributions); table.clear(cardQueue)
        observationEpoch = os.clock()
        queueFirst, queueLast = 1, 0
        currentCard, flipAt, flipSwapped, enteredByFlip = nil, nil, false, false
        if sound then sound:Stop() end
    end
    function controller.SetVolume(value)
        if sound then sound.Volume = math.clamp(value, 0, 5) end
    end
    function controller.OptionsChanged()
        controller.Clear()
        if enabled() then warm() end
    end
    function controller.Destroy()
        if controller.Stopped then return end
        controller.Clear(); controller.Stopped = true
        for _, connection in ipairs(connections) do connection:Disconnect() end
        if sound then sound:Destroy() end
        root:Destroy()
        table.clear(cache)
    end
    connections[#connections + 1] = RunService.RenderStepped:Connect(draw)
    return controller
end


-- One immutable atlas per stage; playback never rebinds textures or streams pages.
function app.createKillEffectPlayer(media, collections)
    local controller = {Stopped = false, Sequence = 0}
    collections = collections or {["2021 Vandal"] = media}
    local collection = collections[app.KILL_EFFECT_COLLECTION] and app.KILL_EFFECT_COLLECTION or "2021 Vandal"
    local banks, names, slots, connections, jobs = {}, {}, {}, {}, {}
    for name, clips in pairs(collections) do
        banks[name] = {Media = clips, Records = {}, Cache = {}}
        names[#names + 1] = name
    end
    table.sort(names)
    local battlefield = app.createBattlefieldKillEffect()
    controller.ObserveHit = battlefield.ObserveHit
    controller.ObserveSuppression = battlefield.ObserveSuppression
    local active, front, targetStage, warnedAt = nil, nil, 1, nil
    local preparing, available, dirty = false, true, true
    local workers, nextPrepareAt, nextCatalogAt = 0, 0, 0
    local wanted = {}
    local configuredStyle, configuredEnabled
    local prepare, pump
    local provider = game:GetService("ContentProvider")
    local soundParent = game:GetService("SoundService")
    local banner = Instance.new("Frame")
    banner.Name = "KillBanner"
    banner.BackgroundTransparency = 1
    banner.BorderSizePixel = 0
    banner.AnchorPoint = Vector2.new(0.5, 0.5)
    banner.Position = UDim2.fromScale(0.5, 0.72)
    banner.ZIndex = 60
    banner.Active = false
    banner.Parent = gui

    local function enabled()
        return not controller.Stopped and available and app.KILL_EFFECT_ENABLED and app.KILL_EFFECT_STYLE == "Valorant"
    end
    local function report(message)
        if controller.Stopped or (warnedAt and os.clock() - warnedAt < 15) then return end
        warnedAt = os.clock()
        warn("[Kill effect] " .. message)
        if app.showNotification then app.showNotification("Kill effect", message, 5) end
    end
    local function resize()
        local size = gui.AbsoluteSize
        if size.X <= 0 or size.Y <= 0 then
            local camera = Workspace.CurrentCamera
            size = camera and camera.ViewportSize or Vector2.new(800, 600)
        end
        local width = app.killBannerWidth(size)
        banner.Size = UDim2.fromOffset(width, width * 0.75)
    end
    connections[#connections + 1] = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize)
    resize()

    local function stageKey(name, stage) return name .. ":" .. stage end
    local function resourceName(name, stage, soundOnly)
        -- Reuse every existing on-disk filename and registered URI.
        if name == "2021 Vandal" then
            return soundOnly and ("KillBannerHQ2-" .. stage .. "-sound") or ("KillBannerAtlas1-" .. stage)
        end
        return "KillBanner-" .. name .. "-" .. stage .. (soundOnly and "-sound" or "-atlas")
    end
    local function jobPriority(job)
        local score = job.Cached and 200 or 0
        if active and job.Collection == active.Collection and job.Stage == active.Stage then score += 100 end
        if wanted[stageKey(job.Collection, job.Stage)] then score += 40 end
        if job.Collection == collection then score += 20 end
        return score
    end
    pump = function()
        if not enabled() then return end
        -- Limit registration/CRC work as well as HTTP work. Cache hits are queued
        -- ahead of missing files, so a cold background collection cannot win first.
        while workers < 2 and #jobs > 0 do
            local best = 1
            for i = 2, #jobs do if jobPriority(jobs[i]) > jobPriority(jobs[best]) then best = i end end
            local job = table.remove(jobs, best)
            workers += 1
            task.defer(function()
                local record, bank = job.Record, banks[job.Collection]
                local ok, err = pcall(function()
                    if controller.Stopped then return end
                    local loadError
                    record.Id, loadError = app.resolveResourceFile(bank.Cache, "CheatGPT/ACS/Cache", job.Name,
                        job.Descriptor, job.SoundOnly and "mp3" or "png", jobPriority(job))
                    if controller.Stopped then return end
                    if not record.Id then error(loadError or "Kill banner resource unavailable") end
                    if job.SoundOnly then
                        local sound = Instance.new("Sound")
                        sound.Name = "KillBannerSound" .. (job.Collection == "2021 Vandal" and "" or job.Collection) .. job.Stage
                        sound.Volume = math.clamp(app.KILL_SOUNDS_VOLUME, 0, 5)
                        sound.SoundId = record.Id
                        sound.Looped = false
                        sound.Parent = soundParent
                        record.Sound = sound
                        -- Advisory only: some executors never finish PreloadAsync.
                        -- Never gate playback or re-register cached files on it.
                        task.defer(function()
                            if not controller.Stopped and sound.Parent then pcall(function() provider:PreloadAsync({sound}) end) end
                        end)
                    end
                end)
                workers -= 1
                record.Busy, record.Ready, record.RetryAt = false, ok and record.Id ~= nil, os.clock() + 5
                record.Error = not ok and tostring(err) or nil
                if controller.Stopped then return end
                if not ok and job.Collection == collection and wanted[stageKey(job.Collection, job.Stage)] then
                    report("Kill banner resource unavailable; cached files will be retried.")
                end
                dirty = true
                prepare()
                pump()
            end)
        end
    end
    local function request(name, stage, soundOnly)
        local bank = banks[name]
        local key = stage .. (soundOnly and "-sound" or "-atlas")
        local record = bank.Records[key]
        if record and (record.Ready or record.Busy or os.clock() < record.RetryAt) then return record end
        record = {Busy = true, RetryAt = math.huge}
        bank.Records[key] = record
        local resource = resourceName(name, stage, soundOnly)
        local path = "CheatGPT/ACS/Cache/" .. resource .. (soundOnly and ".mp3" or ".png")
        local cached = false
        if type(isfile) == "function" then
            local ok, exists = pcall(isfile, path)
            cached = ok and exists == true
        end
        jobs[#jobs + 1] = {Record = record, Collection = name, Stage = stage, Name = resource,
            SoundOnly = soundOnly, Cached = cached, Descriptor = soundOnly and bank.Media[stage].Sound or bank.Media[stage].Atlas}
        return record
    end
    local function place(slot, rect)
        if rect[3] == 0 then slot.Image.ImageTransparency = 1; return end
        local clip = slot.Clip
        slot.Host.Position = UDim2.fromScale(rect[5] / 512, rect[6] / 384)
        slot.Host.Size = UDim2.fromScale(rect[3] / 512, rect[4] / 384)
        slot.Image.Position = UDim2.fromScale(-rect[1] / rect[3], -rect[2] / rect[4])
        slot.Image.Size = UDim2.fromScale(clip.AtlasWidth / rect[3], clip.AtlasHeight / rect[4])
    end
    local function findSlot(name, stage)
        local key = stageKey(name, stage)
        for _, slot in ipairs(slots) do if slot.Key == key then return slot end end
    end
    local function bind(name, stage)
        local slot = findSlot(name, stage)
        if slot then return slot end
        local record = request(name, stage, false)
        if not record.Ready then return nil end
        if #slots < math.max(2, #names + 1) then
            local host = Instance.new("Frame")
            host.Name = "KillBannerViewport" .. (#slots + 1)
            host.BackgroundTransparency = 1
            host.BorderSizePixel = 0
            host.ClipsDescendants = true
            host.Active = false
            host.Size = UDim2.fromOffset(0, 0)
            host.ZIndex = 60
            host.Parent = banner
            local image = Instance.new("ImageLabel")
            image.Name = "KillBannerAtlas" .. (#slots + 1)
            image.BackgroundTransparency = 1
            image.BorderSizePixel = 0
            image.ScaleType = Enum.ScaleType.Stretch
            image.Active = false
            image.ZIndex = 60
            image.ImageTransparency = 0.999
            image.Parent = host
            slot = {Image = image, Host = host}
            slots[#slots + 1] = slot
        else
            for _, candidate in ipairs(slots) do
                if candidate ~= front and not wanted[candidate.Key] then slot = candidate; break end
            end
        end
        if not slot then return nil end
        if slot.Binding then slot.Binding.Cancel() end
        slot.Key, slot.Collection, slot.Stage, slot.Decoded = stageKey(name, stage), name, stage, false
        slot.Clip = banks[name].Media[stage]
        slot.Image.ImageTransparency = 0.999
        slot.Image.ZIndex, slot.Host.ZIndex = 60, 60
        for _, rect in ipairs(slot.Clip.Rects) do if rect[3] > 0 then place(slot, rect); break end end
        -- Size and crop before binding, including hidden preparation views.
        slot.Image.Image = record.Id
        slot.Binding = app.bindAsyncImage(slot.Image, function(attempt)
            if attempt == 1 then return record.Id end
            if front == slot and active and active.StartAt then return nil, "Retry after playback" end
            local resource = resourceName(name, stage, false)
            local bank = banks[name]
            bank.Cache[resource] = nil
            local id, err = app.resolveResourceFile(bank.Cache, "CheatGPT/ACS/Cache", resource,
                bank.Media[stage].Atlas, "png", 30)
            if front == slot and active and active.StartAt then return nil, "Retry after playback" end
            if id then record.Id = id end
            return id, err
        end, "Kill atlas: " .. slot.Key)
        return slot
    end
    prepare = function(force)
        if force then dirty = true end
        if preparing or not enabled() or (not dirty and os.clock() < nextPrepareAt) then return end
        preparing = true
        task.defer(function()
            preparing = false
            if not enabled() then return end
            dirty, nextPrepareAt = false, os.clock() + 0.1
            local desired = {}
            table.clear(wanted)
            local function want(name, stage)
                local clips = banks[name].Media
                if #clips == 0 then return end
                stage = math.clamp(stage, 1, #clips)
                local key = stageKey(name, stage)
                if wanted[key] then return end
                wanted[key] = true
                desired[#desired + 1] = {name, stage}
            end
            if active then want(active.Collection, active.Stage) end
            local upcoming = active and active.Stage + 1 or targetStage
            want(collection, upcoming)
            for _, name in ipairs(names) do want(name, upcoming) end
            -- Before the first/next idle kill, also keep the selected lookahead.
            if not active then want(collection, upcoming + 1) end
            for _, item in ipairs(desired) do
                bind(item[1], item[2])
                request(item[1], item[2], true)
            end
            if os.clock() >= nextCatalogAt then
                nextCatalogAt = os.clock() + 2
                -- Register all six stages per collection once. Valid disk caches
                -- never download; retained bank URIs avoid repeating file CRC work.
                for _, name in ipairs(names) do
                    for stage = 1, #banks[name].Media do
                        request(name, stage, true)
                        request(name, stage, false)
                    end
                end
            end
            pump()
        end)
    end
    local function stop()
        controller.Sequence += 1
        active, front = nil, nil
        for _, slot in ipairs(slots) do
            slot.Image.ImageTransparency = 0.999
            slot.Image.ZIndex, slot.Host.ZIndex = 60, 60
        end
        for _, bank in pairs(banks) do
            for _, record in pairs(bank.Records) do if record.Sound then record.Sound:Stop() end end
        end
    end
    function controller.Clear()
        battlefield.Clear()
        stop()
        targetStage = 1
        prepare(true)
    end
    function controller.SetVolume(value)
        app.KILL_SOUNDS_VOLUME = math.clamp(tonumber(value) or 2, 0, 5)
        for _, bank in pairs(banks) do
            for _, record in pairs(bank.Records) do if record.Sound then record.Sound.Volume = app.KILL_SOUNDS_VOLUME end end
        end
        battlefield.SetVolume(app.KILL_SOUNDS_VOLUME)
    end
    local function draw()
        if not enabled() then return end
        for _, slot in ipairs(slots) do if not slot.Decoded and slot.Image.IsLoaded then slot.Decoded = true end end
        if not active then prepare(); return end
        local playing, now = active, os.clock()
        local bank = banks[playing.Collection]
        local slot = findSlot(playing.Collection, playing.Stage)
        local soundRecord = bank.Records[playing.Stage .. "-sound"]
        local sound = soundRecord and soundRecord.Sound
        if not playing.StartAt then
            if not slot or not (slot.Decoded or slot.Image.IsLoaded) or not sound then prepare(); return end
            slot.Decoded, playing.StartAt, front = true, now, slot
            slot.Image.ZIndex, slot.Host.ZIndex = 62, 62
            sound:Play()
            sound.TimePosition = 0
        end
        local elapsed = now - playing.StartAt
        local clip = bank.Media[playing.Stage]
        if elapsed >= clip.Seconds then
            stop(); targetStage = math.min(playing.Stage + 1, #banks[collection].Media); prepare(true); return
        end
        if not playing.SoundSynced and (sound.IsLoaded or sound.TimeLength > 0) then
            sound.TimePosition = elapsed; playing.SoundSynced = true
        end
        local frame = math.min(clip.Frames, math.floor(elapsed * 30) + 1)
        if playing.Frame ~= frame then
            local rect = clip.Rects[frame]
            place(front, rect)
            front.Image.ImageTransparency = rect[3] > 0 and 0 or 1
            playing.Frame = frame
        end
        prepare()
    end
    function controller.IsPlaying() return active ~= nil or (battlefield.IsPlaying and battlefield.IsPlaying()) == true end
    function controller.Play(count, player, humanoid)
        if app.KILL_EFFECT_STYLE == "Battlefield 1" then battlefield.Play(count, player, humanoid); return end
        if not enabled() or #banks[collection].Media == 0 then return end
        stop()
        targetStage = math.clamp(math.floor(count), 1, #banks[collection].Media)
        active = {Collection = collection, Stage = targetStage}
        -- Warm view + sound means this draw presents in the kill callback itself.
        draw()
        prepare(true)
    end
    function controller.OptionsChanged()
        local modeChanged = configuredStyle ~= app.KILL_EFFECT_STYLE or configuredEnabled ~= app.KILL_EFFECT_ENABLED
        configuredStyle, configuredEnabled = app.KILL_EFFECT_STYLE, app.KILL_EFFECT_ENABLED
        collection = collections[app.KILL_EFFECT_COLLECTION] and app.KILL_EFFECT_COLLECTION or "2021 Vandal"
        if modeChanged or app.KILL_EFFECT_STYLE ~= "Valorant" then battlefield.OptionsChanged(); stop() end
        available = type(writefile) == "function" and (type(getcustomasset) == "function" or type(getsynasset) == "function")
        banner.Visible = enabled() and #banks[collection].Media > 0
        if controller.Stopped or not app.KILL_EFFECT_ENABLED or app.KILL_EFFECT_STYLE ~= "Valorant" then return end
        if not available then report("Kill effect requires writefile and getcustomasset/getsynasset."); return end
        if not active then targetStage = (controller.Tracker and controller.Tracker.Count or 0) + 1 end
        -- A collection selection never stops/replays the current banner, clears
        -- bank caches or re-registers files. The next Play captures the new choice.
        prepare(true)
    end
    function controller.Destroy()
        if controller.Stopped then return end
        stop(); controller.Stopped = true
        battlefield.Destroy()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        if controller.Tracker then controller.Tracker.Stop() end
        for _, bank in pairs(banks) do
            for _, record in pairs(bank.Records) do if record.Sound then record.Sound:Destroy() end end
            table.clear(bank.Cache)
            table.clear(bank.Records)
        end
        table.clear(jobs)
        banner:Destroy()
        table.clear(slots)
    end
    connections[#connections + 1] = RunService.RenderStepped:Connect(function()
        if not app.xpcallw(draw, "Kill effect playback") then controller.Clear() end
    end)
    connections[#connections + 1] = gui.Destroying:Connect(controller.Destroy)
    controller.Tracker = app.createKillEffectTracker(controller.Play, controller.Clear, battlefield.ObserveDamage, battlefield.WantsDamage,
        battlefield.ObserveOtherDeath, battlefield.ObserveRecovery)
    controller.OptionsChanged()
    return controller
end



do
local media = {
{Frames=67, Seconds=2.233333, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_1k-b1f6ee4c4cee.mp3.lzma2", Size=55316, CRC32=1927749926, PackedSize=54198, PackedCRC32=2239130224}, AtlasWidth=1024, AtlasHeight=2048, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_1k-atlas-4a00082469af.png.lzma2", Size=980563, CRC32=1556304608, PackedSize=980609, PackedCRC32=3766302786, PreviousSize=1070890, PreviousCRC32=2693328533}, Rects={
{0,0,0,0,0,0},
{494,1518,74,85,218,124},
{762,1319,83,91,214,119},
{2,1604,84,129,213,113},
{382,1327,182,187,163,98},
{2,1116,183,213,163,88},
{382,1111,186,212,162,88},
{572,1319,186,212,162,88},
{572,229,186,214,162,88},
{762,229,186,214,162,88},
{192,239,186,214,162,88},
{2,244,186,214,162,88},
{382,239,186,214,162,88},
{572,447,186,214,162,88},
{762,447,186,214,162,88},
{572,2,186,223,162,79},
{762,2,186,223,162,79},
{192,2,186,233,162,69},
{382,2,186,233,162,69},
{2,2,186,238,162,64},
{192,457,186,214,162,88},
{2,462,186,214,162,88},
{382,457,186,214,162,88},
{572,665,186,214,162,88},
{762,665,186,214,162,88},
{192,675,186,214,162,88},
{2,680,186,214,162,88},
{382,675,186,214,162,88},
{572,883,186,214,162,88},
{572,883,186,214,162,88},
{762,883,186,214,162,88},
{762,883,186,214,162,88},
{192,893,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{2,898,186,214,162,88},
{382,893,186,214,162,88},
{572,1101,186,214,162,88},
{762,1101,186,214,162,88},
{192,1111,186,214,162,88},
{192,1111,186,214,162,88},
{192,1111,186,214,162,88},
{250,1467,118,130,196,120},
{372,1518,118,130,196,120},
{250,1601,118,130,196,120},
{125,1602,118,130,196,120},
{2,1470,119,130,195,120},
{2,1333,120,133,195,119},
{189,1329,122,134,194,119},
{126,1467,120,131,194,120},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=70, Seconds=2.333333, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_2k-0f6935eb7fd2.mp3.lzma2", Size=56623, CRC32=2172469546, PackedSize=55829, PackedCRC32=3940327811}, AtlasWidth=2048, AtlasHeight=2048, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_2k-atlas-811ca5142d72.png.lzma2", Size=1718060, CRC32=3068275973, PackedSize=1718142, PackedCRC32=174572544, PreviousSize=1766632, PreviousCRC32=1590440942}, Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{1141,777,74,79,218,124},
{1609,436,83,93,213,118},
{1161,455,146,114,183,127},
{1134,870,182,190,163,90},
{1133,1087,184,213,163,89},
{608,1763,186,215,162,87},
{374,870,186,213,162,89},
{563,1087,186,213,162,89},
{381,653,186,213,162,89},
{401,436,186,213,162,89},
{372,1087,187,213,161,89},
{1791,2,227,213,142,89},
{349,1304,227,213,142,89},
{348,1546,268,213,121,89},
{2,1782,299,223,105,79},
{305,1782,299,223,105,79},
{1720,219,324,232,93,70},
{2,1546,342,232,85,70},
{2,1304,343,238,84,64},
{2,1087,366,213,72,89},
{2,870,368,213,70,89},
{2,653,375,213,68,89},
{2,436,395,213,57,89},
{442,219,430,213,40,89},
{876,219,430,213,40,89},
{2,2,451,213,30,89},
{457,2,442,213,33,89},
{903,2,442,213,33,89},
{1310,219,406,213,52,89},
{2,219,436,213,37,89},
{1349,2,438,213,35,89},
{564,870,186,213,162,89},
{571,653,186,213,162,89},
{591,436,186,213,162,89},
{580,1304,186,213,162,89},
{753,1087,186,213,162,89},
{754,870,186,213,162,89},
{761,653,186,213,162,89},
{781,436,186,213,162,89},
{620,1521,186,213,162,89},
{770,1304,186,213,162,89},
{943,1087,186,213,162,89},
{943,1087,186,213,162,89},
{943,1087,186,213,162,89},
{944,870,186,213,162,89},
{951,653,186,213,162,89},
{951,653,186,213,162,89},
{951,653,186,213,162,89},
{951,653,186,213,162,89},
{971,436,186,213,162,89},
{798,1738,186,213,162,89},
{798,1738,186,213,162,89},
{798,1738,186,213,162,89},
{810,1521,186,213,162,89},
{960,1304,186,213,162,89},
{1311,436,145,118,183,132},
{1291,700,145,118,183,132},
{1460,436,145,118,183,132},
{1320,946,144,118,183,132},
{1141,653,146,120,182,132},
{1291,573,145,123,182,130},
{1320,822,144,120,183,131},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=70, Seconds=2.333333, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_3k-d699901c6d60.mp3.lzma2", Size=56623, CRC32=1949521407, PackedSize=55893, PackedCRC32=1478929584}, AtlasWidth=2048, AtlasHeight=2048, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_3k-atlas-1d43059a6e64.png.lzma2", Size=1982656, CRC32=3891484253, PackedSize=1982750, PackedCRC32=3885388355, PreviousSize=2028388, PreviousCRC32=3786980790}, Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{874,1967,74,79,218,124},
{1201,1778,83,94,213,115},
{1219,1236,135,129,188,114},
{1034,1316,181,184,165,98},
{874,1752,185,211,163,89},
{1338,659,185,215,163,87},
{958,659,186,215,162,87},
{1356,440,186,213,162,89},
{844,1535,186,213,162,89},
{382,659,188,215,161,87},
{1790,2,226,215,142,87},
{374,878,226,215,142,87},
{372,1097,266,215,121,87},
{350,1316,300,223,105,79},
{350,1543,300,223,105,79},
{347,1800,333,233,85,69},
{2,1800,341,233,84,69},
{2,1316,344,238,82,64},
{2,1558,344,238,82,64},
{2,1097,366,215,72,87},
{2,878,368,215,70,87},
{2,659,376,215,66,87},
{2,440,394,215,58,87},
{442,221,430,215,40,87},
{876,221,430,215,40,87},
{2,2,452,215,29,87},
{905,2,441,215,34,87},
{458,2,443,215,34,87},
{1310,221,402,215,55,87},
{1350,2,436,215,37,87},
{2,221,436,215,37,87},
{1716,221,320,215,30,87},
{400,440,188,215,162,87},
{574,659,188,215,162,87},
{604,878,188,215,162,87},
{642,1097,188,215,162,87},
{592,440,188,215,162,87},
{766,659,188,215,162,87},
{796,878,188,215,162,87},
{784,440,188,215,162,87},
{976,440,186,215,162,87},
{654,1316,186,215,162,87},
{834,1097,186,215,162,87},
{988,878,186,215,162,87},
{1148,659,186,215,162,87},
{1166,440,186,215,162,87},
{654,1535,186,215,162,87},
{684,1754,186,215,162,87},
{844,1316,186,215,162,87},
{844,1316,186,215,162,87},
{844,1316,186,215,162,87},
{844,1316,186,215,162,87},
{1024,1097,186,215,162,87},
{1178,878,186,215,162,87},
{1178,878,186,215,162,87},
{1219,1369,134,130,188,120},
{1063,1778,134,132,188,118},
{1063,1914,134,132,188,118},
{1175,1504,135,132,187,118},
{1034,1504,137,135,186,117},
{1214,1097,140,135,185,118},
{1063,1643,137,131,187,120},
{2040,2,2,3,212,241},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=71, Seconds=2.366667, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_4k-bda3e364fc20.mp3.lzma2", Size=57877, CRC32=4131201999, PackedSize=57103, PackedCRC32=2986608980}, AtlasWidth=2048, AtlasHeight=2048, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_4k-atlas-83a007a17f38.png.lzma2", Size=2379913, CRC32=1157111053, PackedSize=2380025, PackedCRC32=2446078258, PreviousSize=2417579, PreviousCRC32=1863320190}, Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{1107,1669,75,79,218,124},
{1940,461,82,96,214,115},
{569,1546,146,136,182,114},
{383,1546,182,184,164,98},
{917,1763,185,211,163,89},
{1370,436,186,213,162,89},
{1560,461,186,213,162,89},
{1750,461,186,213,162,89},
{1173,653,186,213,162,89},
{1363,653,186,213,162,89},
{1173,436,193,213,159,89},
{935,461,234,213,138,89},
{1804,2,235,213,137,89},
{696,461,235,213,137,89},
{681,688,257,223,127,79},
{408,461,284,223,113,79},
{392,870,285,233,113,69},
{383,1304,314,233,98,69},
{1705,219,341,238,85,64},
{382,1738,341,213,85,89},
{2,1738,376,213,64,89},
{2,870,386,213,62,89},
{2,1087,386,213,62,89},
{2,436,402,213,54,89},
{2,219,426,213,42,89},
{432,219,426,213,42,89},
{2,2,452,213,29,89},
{458,2,448,213,31,89},
{910,2,448,213,31,89},
{2,653,393,213,59,89},
{1284,219,417,213,47,89},
{862,219,418,213,46,89},
{1362,2,438,213,36,89},
{2,1304,377,213,66,89},
{2,1521,377,213,66,89},
{942,678,186,213,162,89},
{1553,678,186,213,162,89},
{1743,678,186,213,162,89},
{1132,870,186,213,162,89},
{942,895,186,213,162,89},
{1322,870,186,213,162,89},
{1512,895,186,213,162,89},
{681,915,186,215,162,87},
{1702,895,186,213,162,89},
{1132,1087,186,213,162,89},
{1322,1087,186,213,162,89},
{871,1112,186,213,162,89},
{701,1329,186,213,162,89},
{727,1546,186,213,162,89},
{727,1546,186,213,162,89},
{891,1329,186,213,162,89},
{727,1763,186,213,162,89},
{917,1546,186,213,162,89},
{1081,1304,186,213,162,89},
{1892,895,145,145,183,120},
{1892,1044,145,145,183,120},
{399,688,144,143,184,120},
{1106,1763,144,143,184,120},
{541,1134,145,143,183,120},
{701,1134,145,145,182,119},
{392,1134,145,145,182,119},
{1107,1521,142,144,184,119},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=225, Seconds=7.500000, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_5k-99ab96af78fd.mp3.lzma2", Size=180757, CRC32=2127879457, PackedSize=160923, PackedCRC32=4135586373}, AtlasWidth=2048, AtlasHeight=4096, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_5k-atlas-5c84e2d37e76.png.lzma2", Size=6406204, CRC32=1506816537, PackedSize=6406499, PackedCRC32=3829181709, PreviousSize=6485311, PreviousCRC32=1235371555}, Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{192,1861,83,94,214,115},
{335,3999,83,94,214,115},
{1975,1040,71,119,223,103},
{1863,1330,182,194,164,64},
{952,3514,184,212,163,63},
{1522,2868,186,212,162,63},
{1712,2868,186,212,162,63},
{1574,1566,186,213,162,63},
{1842,2,186,214,162,70},
{1842,220,186,214,162,78},
{1384,1343,186,214,162,84},
{1325,1779,186,213,162,89},
{1764,1566,186,213,162,89},
{1515,1783,186,213,162,89},
{1705,1783,186,213,162,89},
{764,1795,186,213,162,89},
{472,1832,186,213,162,89},
{1822,486,212,232,149,70},
{1647,1330,212,232,149,70},
{1400,1072,243,267,134,56},
{1111,1290,269,283,120,44},
{672,1327,269,283,120,44},
{2,1594,276,263,118,48},
{382,1210,286,286,112,35},
{1653,1040,318,286,96,35},
{789,1037,318,286,96,35},
{1653,737,352,299,79,28},
{1297,737,352,331,79,13},
{409,877,376,329,67,13},
{890,720,403,313,53,23},
{2,792,403,340,53,8},
{455,531,431,342,39,7},
{2,2,456,290,27,33},
{462,2,456,285,27,33},
{2,296,449,241,31,78},
{922,2,456,244,27,85},
{1382,2,456,238,27,88},
{1382,244,455,238,27,88},
{917,499,441,217,36,85},
{1377,486,441,247,36,75},
{2,541,429,247,40,75},
{922,250,451,245,30,73},
{462,291,451,236,30,82},
{2,1136,376,236,68,82},
{291,1500,279,237,97,72},
{2,1376,285,214,98,88},
{1111,1072,285,214,98,88},
{1384,1561,186,214,162,88},
{945,1577,186,214,162,88},
{1135,1577,186,214,162,88},
{574,1614,186,214,162,88},
{282,1741,186,214,162,88},
{282,1741,186,214,162,88},
{282,1741,186,214,162,88},
{282,1741,186,214,162,88},
{2,1861,186,214,162,88},
{2,1861,186,214,162,88},
{2,1861,186,214,162,88},
{1522,3084,186,212,162,90},
{1712,3084,186,212,162,90},
{1142,3085,186,212,162,90},
{1142,3085,186,212,162,90},
{1142,3085,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{952,3298,186,212,162,90},
{1332,3085,186,212,162,90},
{572,3314,186,212,162,90},
{382,3351,186,212,162,90},
{762,3314,186,212,162,90},
{382,3567,186,212,162,90},
{382,3783,186,212,162,90},
{1522,3300,186,212,162,90},
{1712,3300,186,212,162,90},
{192,1959,186,213,162,89},
{2,2079,186,213,162,89},
{954,1795,186,213,162,89},
{1144,1996,186,213,162,89},
{662,2012,186,213,162,89},
{382,2049,186,213,162,89},
{192,2176,186,213,162,89},
{2,2296,186,213,162,89},
{852,2012,186,213,162,89},
{1334,2000,186,213,162,89},
{1042,2213,186,213,162,89},
{572,2229,186,213,162,89},
{382,2266,186,213,162,89},
{192,2393,186,213,162,89},
{2,2513,186,213,162,89},
{762,2229,186,213,162,89},
{1524,2000,186,213,162,89},
{1714,2000,186,213,162,89},
{1232,2217,186,213,162,89},
{952,2430,186,213,162,89},
{572,2446,186,213,162,89},
{382,2483,186,213,162,89},
{192,2610,186,213,162,89},
{2,2730,186,213,162,89},
{762,2446,186,213,162,89},
{1422,2217,186,213,162,89},
{1612,2217,186,213,162,89},
{1802,2217,186,213,162,89},
{1142,2434,186,213,162,89},
{952,2647,186,213,162,89},
{572,2663,186,213,162,89},
{382,2700,186,213,162,89},
{192,2827,186,213,162,89},
{2,2947,186,213,162,89},
{762,2663,186,213,162,89},
{1332,2434,186,213,162,89},
{1522,2434,186,213,162,89},
{1712,2434,186,213,162,89},
{1142,3301,186,212,162,90},
{2,3164,186,213,162,89},
{2,3381,186,213,162,89},
{2,3598,186,213,162,89},
{2,3815,186,213,162,89},
{1142,2651,186,213,162,89},
{952,2864,186,213,162,89},
{572,2880,186,213,162,89},
{382,2917,186,213,162,89},
{192,3044,186,213,162,89},
{192,3044,186,213,162,89},
{192,3044,186,213,162,89},
{192,3044,186,213,162,89},
{192,3044,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{762,2880,186,213,162,89},
{1332,2651,186,213,162,89},
{1332,2651,186,213,162,89},
{1332,2651,186,213,162,89},
{1332,2651,186,213,162,89},
{1522,2651,186,213,162,89},
{1522,2651,186,213,162,89},
{1522,2651,186,213,162,89},
{1522,2651,186,213,162,89},
{1522,2651,186,213,162,89},
{1712,2651,186,213,162,89},
{1712,2651,186,213,162,89},
{1712,2651,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3261,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3478,186,213,162,89},
{192,3695,186,213,162,89},
{192,3695,186,213,162,89},
{1142,2868,186,213,162,89},
{952,3081,186,213,162,89},
{572,3097,186,213,162,89},
{572,3097,186,213,162,89},
{572,3097,186,213,162,89},
{382,3134,186,213,162,89},
{762,3097,186,213,162,89},
{1332,2868,186,213,162,89},
{1904,2074,140,137,186,120},
{1902,3299,140,137,186,120},
{1902,3440,139,139,186,118},
{945,1327,139,139,186,118},
{764,1614,139,139,186,118},
{1144,1795,139,139,186,118},
{192,3912,139,139,186,118},
{1332,3301,139,139,186,118},
{1332,3444,139,139,186,118},
{1140,3517,139,139,186,118},
{572,3730,139,139,186,118},
{572,3730,139,139,186,118},
{572,3730,139,139,186,118},
{572,3730,139,139,186,118},
{572,3530,139,139,186,118},
{572,3873,139,139,186,118},
{715,3816,138,139,186,118},
{715,3530,139,139,186,118},
{715,3673,139,139,186,119},
{1902,2867,139,140,186,119},
{1902,2579,140,140,185,119},
{1904,1929,140,141,185,118},
{1902,2434,140,141,185,119},
{1902,2723,140,140,185,119},
{1904,1783,139,142,186,118},
{1902,3011,138,140,186,119},
{1902,3155,138,140,186,119},
{857,3816,136,138,187,120},
{382,1959,58,83,196,121},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=217, Seconds=7.233333, Sound={Path="cheatgpt/v1/kill-effect/valorant/21_6k-5394497375b3.mp3.lzma2", Size=174488, CRC32=4175329492, PackedSize=161363, PackedCRC32=257121307}, AtlasWidth=2048, AtlasHeight=4096, Atlas={Path="cheatgpt/v1/kill-effect/valorant-atlas/21_6k-atlas-5e57cd5295fb.png.lzma2", Size=6464621, CRC32=1932173093, PackedSize=6464919, PackedCRC32=2896745141, PreviousSize=6577039, PreviousCRC32=1574312433}, Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{2044,2811,2,3,292,141},
{1252,831,84,87,213,120},
{1252,731,83,96,213,111},
{843,3965,76,111,217,110},
{382,3896,182,195,164,63},
{1711,3094,183,212,163,63},
{1522,3094,185,212,163,63},
{1842,220,186,213,162,62},
{586,1291,186,215,162,63},
{586,1510,186,214,162,78},
{1842,2,186,214,162,84},
{2,3711,186,212,162,90},
{192,3484,186,212,162,90},
{192,3700,186,212,162,90},
{382,3464,186,212,162,90},
{382,3680,186,212,162,90},
{1332,3094,186,212,162,90},
{952,3278,186,212,162,90},
{762,3300,186,212,162,90},
{1830,483,214,232,149,70},
{2,1522,214,232,149,70},
{1758,1304,243,267,134,56},
{1768,1016,270,284,121,43},
{1768,727,268,285,121,43},
{1477,1057,277,264,117,48},
{788,1282,286,286,112,35},
{1141,1057,332,286,96,35},
{788,979,349,299,81,28},
{2,1186,349,332,81,12},
{408,955,376,332,67,12},
{1362,727,402,326,54,8},
{2,841,402,341,54,8},
{2,496,430,341,40,8},
{922,2,456,238,27,87},
{462,2,456,241,27,78},
{1378,483,448,240,31,79},
{2,2,456,243,27,85},
{1382,2,456,236,27,90},
{1382,242,454,237,29,89},
{458,495,440,218,36,84},
{918,493,440,234,36,89},
{436,717,430,234,40,89},
{922,244,452,245,29,73},
{2,249,452,243,29,82},
{462,247,452,244,29,82},
{870,731,378,244,67,82},
{355,1291,227,236,148,73},
{1078,1347,240,213,143,89},
{1477,1325,241,213,142,89},
{220,1531,186,213,162,89},
{1322,1542,186,213,162,89},
{1078,1564,186,213,162,89},
{1512,1542,186,213,162,89},
{776,1572,186,213,162,89},
{1702,1575,186,213,162,89},
{776,1572,186,213,162,89},
{572,3308,186,212,162,90},
{410,1728,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{220,1748,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{2,1758,186,213,162,89},
{1268,1759,186,213,162,89},
{1458,1759,186,213,162,89},
{966,1781,186,213,162,89},
{600,1789,186,213,162,89},
{410,1945,186,213,162,89},
{192,1965,186,213,162,89},
{2,1975,186,213,162,89},
{1648,1792,186,213,162,89},
{1838,1792,186,213,162,89},
{1156,1976,186,213,162,89},
{1346,1976,186,213,162,89},
{790,1998,186,213,162,89},
{600,2006,186,213,162,89},
{382,2162,186,213,162,89},
{192,2182,186,213,162,89},
{2,2192,186,213,162,89},
{1536,2009,186,213,162,89},
{1726,2009,186,213,162,89},
{980,2193,186,213,162,89},
{790,2215,186,213,162,89},
{572,2223,186,213,162,89},
{382,2379,186,213,162,89},
{192,2399,186,213,162,89},
{2,2409,186,213,162,89},
{1170,2193,186,213,162,89},
{1360,2226,186,213,162,89},
{980,2410,186,213,162,89},
{1170,2410,186,213,162,89},
{762,2432,186,213,162,89},
{572,2440,186,213,162,89},
{382,2596,186,213,162,89},
{192,2616,186,213,162,89},
{2,2626,186,213,162,89},
{1550,2226,186,213,162,89},
{1740,2226,186,213,162,89},
{1360,2443,186,213,162,89},
{952,2627,186,213,162,89},
{762,2649,186,213,162,89},
{572,2657,186,213,162,89},
{382,2813,186,213,162,89},
{192,2833,186,213,162,89},
{1142,3278,186,212,162,90},
{2,2843,186,213,162,89},
{1142,2627,186,213,162,89},
{1550,2443,186,213,162,89},
{1740,2443,186,213,162,89},
{1332,2660,186,213,162,89},
{952,2844,186,213,162,89},
{762,2866,186,213,162,89},
{572,2874,186,213,162,89},
{382,3030,186,213,162,89},
{192,3050,186,213,162,89},
{2,3060,186,213,162,89},
{1142,2844,186,213,162,89},
{1142,2844,186,213,162,89},
{1142,2844,186,213,162,89},
{1522,2660,186,213,162,89},
{1522,2660,186,213,162,89},
{1712,2660,186,213,162,89},
{1712,2660,186,213,162,89},
{1712,2660,186,213,162,89},
{1332,2877,186,213,162,89},
{1332,2877,186,213,162,89},
{1332,2877,186,213,162,89},
{1332,2877,186,213,162,89},
{952,3061,186,213,162,89},
{762,3083,186,213,162,89},
{762,3083,186,213,162,89},
{762,3083,186,213,162,89},
{572,3091,186,213,162,89},
{572,3091,186,213,162,89},
{572,3091,186,213,162,89},
{382,3247,186,213,162,89},
{192,3267,186,213,162,89},
{192,3267,186,213,162,89},
{192,3267,186,213,162,89},
{192,3267,186,213,162,89},
{2,3277,186,213,162,89},
{2,3277,186,213,162,89},
{2,3277,186,213,162,89},
{1142,3061,186,213,162,89},
{1142,3061,186,213,162,89},
{1142,3061,186,213,162,89},
{1142,3061,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1522,2877,186,213,162,89},
{1712,2877,186,213,162,89},
{2,3494,186,213,162,89},
{980,1998,158,150,164,113},
{410,1531,158,150,164,113},
{790,1789,158,150,164,113},
{2,3927,158,150,164,113},
{164,3927,158,150,164,113},
{711,3671,134,143,188,120},
{847,3818,134,143,188,120},
{849,3671,134,143,188,120},
{850,3516,134,143,188,120},
{985,3818,134,143,188,120},
{987,3663,134,143,188,120},
{987,3663,134,143,188,120},
{987,3663,134,143,188,120},
{987,3663,134,143,188,120},
{987,3663,134,143,188,120},
{988,3494,134,143,188,120},
{572,3524,135,143,187,120},
{572,3671,135,143,187,120},
{708,3818,135,143,187,120},
{1322,1347,136,145,187,119},
{1902,2962,137,146,186,118},
{1892,1575,136,145,187,119},
{1902,2811,138,147,186,118},
{1898,3112,138,145,186,119},
{1902,2660,139,147,186,118},
{1898,3261,138,145,185,119},
{568,3896,136,145,187,119},
{711,3524,135,143,188,120},
{708,3965,131,118,188,139},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
}
    local collections = {["2021 Vandal"] = media,
["Recon"] = {
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/1k-atlas-d5c5a9d320f6.png.lzma2", Size=1110596, CRC32=4111726212, PackedSize=1110648, PackedCRC32=796054998, PreviousSize=1176374, PreviousCRC32=1312488611},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/1k-sound-e74137e5b92f.mp3.lzma2",Size=55943,CRC32=3266649106,PackedSize=55160,PackedCRC32=2074462093},Rects={
{0,0,0,0,0,0},
{297,1955,67,78,222,125},
{191,1955,102,87,219,121},
{1243,436,102,110,219,127},
{569,436,182,182,164,99},
{2,1165,185,213,163,88},
{2,1382,185,213,163,88},
{2,1599,185,213,163,88},
{2,1816,185,213,163,88},
{191,2,185,213,163,88},
{380,2,185,213,163,88},
{569,2,185,213,163,88},
{758,2,185,213,163,88},
{947,2,185,213,163,88},
{1136,2,185,213,163,88},
{2,715,185,221,163,80},
{2,940,185,221,163,80},
{2,243,185,232,163,69},
{2,479,185,232,163,69},
{2,2,185,237,163,64},
{1325,2,185,213,163,88},
{1514,2,185,213,163,88},
{1703,2,185,213,163,88},
{191,219,185,213,163,88},
{191,436,185,213,163,88},
{191,653,185,213,163,88},
{191,870,185,213,163,88},
{191,1087,185,213,163,88},
{191,1304,185,213,163,88},
{191,1521,185,213,163,88},
{191,1738,185,213,163,88},
{380,219,185,213,163,88},
{569,219,185,213,163,88},
{758,219,185,213,163,88},
{947,219,185,213,163,88},
{1136,219,185,213,163,88},
{1325,219,185,213,163,88},
{1325,219,185,213,163,88},
{1325,219,185,213,163,88},
{1514,219,185,213,163,88},
{1703,219,185,213,163,88},
{380,436,185,213,163,88},
{380,653,185,213,163,88},
{380,870,185,213,163,88},
{380,870,185,213,163,88},
{380,870,185,213,163,88},
{380,870,185,213,163,88},
{380,1087,185,213,163,88},
{380,1087,185,213,163,88},
{380,1087,185,213,163,88},
{380,1087,185,213,163,88},
{380,1087,185,213,163,88},
{380,1304,185,213,163,88},
{380,1521,185,213,163,88},
{380,1738,185,213,163,88},
{755,436,118,134,196,116},
{877,436,118,134,196,116},
{999,436,118,134,196,116},
{1121,436,118,134,196,116},
{1892,428,118,135,196,115},
{1892,146,120,138,195,114},
{1892,2,122,140,194,113},
{1892,288,119,136,195,114},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/2k-atlas-c70ae099b147.png.lzma2", Size=1791702, CRC32=4072482978, PackedSize=1791787, PackedCRC32=182558559, PreviousSize=1854702, PreviousCRC32=2330513670},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/2k-sound-a5d5cdf91b5c.mp3.lzma2",Size=55943,CRC32=3186597772,PackedSize=55123,PackedCRC32=2212355027},Rects={
{0,0,0,0,0,0},
{1057,1955,73,88,219,120},
{1134,1955,73,88,219,120},
{1356,1619,73,97,219,115},
{1356,1445,176,170,168,98},
{1220,1087,189,211,159,90},
{593,653,185,213,163,88},
{677,1765,186,213,163,88},
{867,1765,186,213,163,88},
{403,653,186,213,163,88},
{410,436,186,213,163,88},
{403,870,186,213,163,88},
{1813,2,187,213,162,88},
{1761,219,243,213,142,88},
{382,1087,267,213,122,88},
{374,1539,267,213,122,88},
{677,1539,297,222,108,79},
{347,1761,326,231,92,70},
{374,1304,325,231,93,70},
{2,1761,341,236,85,65},
{2,1304,368,236,71,65},
{2,1544,368,213,71,88},
{2,1087,376,213,67,88},
{2,653,397,213,57,88},
{2,870,397,213,57,88},
{1329,219,428,213,42,88},
{2,2,450,213,30,88},
{456,2,450,213,30,88},
{2,219,440,213,36,88},
{446,219,440,213,36,88},
{2,436,404,213,53,88},
{890,219,435,213,38,88},
{910,2,448,213,31,88},
{1362,2,447,213,32,88},
{600,436,185,213,163,88},
{593,870,185,213,163,88},
{653,1087,185,213,163,88},
{703,1304,185,213,163,88},
{782,653,185,213,163,88},
{789,436,185,213,163,88},
{782,870,185,213,163,88},
{842,1087,185,213,163,88},
{892,1304,185,213,163,88},
{978,1521,185,213,163,88},
{1057,1738,185,213,163,88},
{971,653,185,213,163,88},
{978,436,185,213,163,88},
{971,870,185,213,163,88},
{1031,1087,185,213,163,88},
{1081,1304,185,213,163,88},
{1167,1521,185,213,163,88},
{1246,1738,185,213,163,88},
{1160,653,185,213,163,88},
{1167,436,185,213,163,88},
{1160,870,185,213,163,88},
{1270,1302,181,139,165,111},
{1591,1870,152,118,180,132},
{1594,1745,152,118,180,132},
{1747,1867,152,118,180,132},
{1750,436,152,118,180,132},
{1435,1870,152,119,180,131},
{1435,1745,155,121,178,130},
{1435,1619,156,122,177,129},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=69,Seconds=2.3,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/3k-atlas-5c3f04fa4233.png.lzma2", Size=1897652, CRC32=1497664243, PackedSize=1897740, PackedCRC32=341922708, PreviousSize=1949960, PreviousCRC32=4084583379},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/3k-sound-49431dad6153.mp3.lzma2",Size=57197,CRC32=871280888,PackedSize=55801,PackedCRC32=526248730},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{695,1955,67,78,222,125},
{618,1955,73,87,219,121},
{1524,719,99,134,219,109},
{1187,436,183,182,164,99},
{1377,436,184,213,163,88},
{372,870,185,213,163,88},
{389,653,185,213,163,88},
{400,436,185,213,163,88},
{372,1087,185,213,163,88},
{561,870,185,213,163,88},
{618,1738,188,213,160,88},
{349,1521,226,213,142,88},
{1792,2,227,213,142,88},
{349,1304,267,213,122,88},
{317,1778,297,221,108,80},
{2,1778,311,222,94,79},
{1718,219,326,230,92,71},
{2,1544,343,230,85,71},
{2,1304,343,236,85,65},
{2,870,366,213,72,88},
{2,1087,366,213,72,88},
{2,653,383,213,61,88},
{2,436,394,213,59,88},
{443,219,429,213,41,88},
{876,219,429,213,41,88},
{2,2,451,213,31,88},
{457,2,442,213,35,88},
{903,2,442,213,35,88},
{1309,219,405,213,53,88},
{2,219,437,213,36,88},
{1349,2,439,213,36,88},
{579,1521,224,213,124,88},
{578,653,185,213,163,88},
{589,436,185,213,163,88},
{561,1087,185,213,163,88},
{620,1304,185,213,163,88},
{807,1521,185,213,163,88},
{810,1738,185,213,163,88},
{750,870,185,213,163,88},
{767,653,185,213,163,88},
{778,436,185,213,163,88},
{750,1087,185,213,163,88},
{809,1304,185,213,163,88},
{996,1521,185,213,163,88},
{999,1738,185,213,163,88},
{939,870,185,213,163,88},
{956,653,185,213,163,88},
{967,436,185,213,163,88},
{939,1087,185,213,163,88},
{967,436,185,213,163,88},
{956,653,185,213,163,88},
{998,1304,185,213,163,88},
{1185,1521,185,213,163,88},
{1188,1738,185,213,163,88},
{1714,453,143,137,184,113},
{1565,578,143,137,184,113},
{1377,653,143,137,184,113},
{1861,453,143,136,184,114},
{1712,594,143,135,184,115},
{1187,622,144,137,184,114},
{1565,436,145,138,184,114},
{1861,593,143,136,184,114},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/4k-atlas-32fa2af7f1c8.png.lzma2", Size=2472100, CRC32=129940721, PackedSize=2472215, PackedCRC32=1561836489, PreviousSize=2519180, PreviousCRC32=2421173223},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/4k-sound-963877d1f717.mp3.lzma2",Size=55943,CRC32=1539331,PackedSize=54909,PackedCRC32=1907725644},Rects={
{0,0,0,0,0,0},
{2,1955,74,87,218,121},
{80,1955,74,87,218,121},
{575,686,74,96,218,116},
{398,686,173,170,167,98},
{1080,1111,189,203,161,98},
{699,1111,188,213,161,88},
{699,1328,188,213,161,88},
{878,677,187,213,161,88},
{929,460,187,213,161,88},
{878,894,187,213,161,88},
{728,1545,187,213,161,88},
{683,677,191,213,160,88},
{683,894,191,213,160,88},
{1804,2,234,213,138,88},
{668,460,257,213,126,88},
{407,460,257,222,126,79},
{396,870,283,230,114,71},
{381,1304,314,230,100,71},
{1703,219,314,237,100,64},
{373,1738,351,237,73,64},
{2,1521,368,213,72,88},
{2,1738,367,213,72,88},
{2,1087,385,213,63,88},
{1297,219,402,213,54,88},
{2,436,401,213,54,88},
{445,219,428,213,41,88},
{457,2,448,213,32,88},
{909,2,448,213,32,88},
{2,2,451,213,30,88},
{2,653,392,213,59,88},
{2,870,390,213,61,88},
{877,219,416,213,48,88},
{1361,2,439,213,36,88},
{2,219,439,213,36,88},
{2,1304,375,213,69,88},
{728,1762,185,213,163,88},
{917,1762,185,213,163,88},
{891,1111,185,213,163,88},
{891,1328,185,213,163,88},
{919,1545,185,213,163,88},
{1106,1762,185,213,163,88},
{1069,677,185,213,163,88},
{1120,460,185,213,163,88},
{1120,460,185,213,163,88},
{1069,894,185,213,163,88},
{1309,436,185,213,163,88},
{1498,436,185,213,163,88},
{1498,436,185,213,163,88},
{1687,460,185,213,163,88},
{1687,460,185,213,163,88},
{1687,460,185,213,163,88},
{1687,460,185,213,163,88},
{1687,460,185,213,163,88},
{1309,653,185,213,163,88},
{529,1538,151,152,180,116},
{1653,677,151,152,180,116},
{1498,810,151,152,180,116},
{1498,653,151,153,180,115},
{391,1111,151,153,180,115},
{374,1545,151,153,180,115},
{1876,460,155,156,178,113},
{1876,620,154,155,179,115},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=227,Seconds=7.566666666666666,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/5k-atlas-36e72a2a9c93.png.lzma2", Size=8033095, CRC32=3388668315, PackedSize=8033465, PackedCRC32=4018899489, PreviousSize=8154480, PreviousCRC32=2808959144},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/5k-sound-375778dd6774.mp3.lzma2",Size=183212,CRC32=455001568,PackedSize=103371,PackedCRC32=862597182},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{2310,3255,73,90,219,118},
{2310,3255,73,90,219,118},
{1325,1666,66,129,223,98},
{2376,1651,182,182,164,72},
{1892,2953,185,210,163,64},
{947,3619,185,211,163,63},
{947,3834,185,211,163,63},
{2075,967,185,213,163,64},
{2075,1184,185,213,163,70},
{2264,1217,185,213,163,78},
{1175,1015,185,213,163,85},
{1364,1015,185,213,163,88},
{1553,1151,185,213,163,88},
{1742,1200,185,213,163,88},
{1931,1401,185,213,163,88},
{2120,1434,185,213,163,88},
{2309,1434,185,213,163,88},
{675,1121,185,213,163,88},
{1639,918,214,229,148,72},
{1857,967,214,229,148,72},
{2280,948,248,265,127,57},
{2277,2,269,285,120,44},
{2,1188,269,285,120,44},
{2280,679,277,265,116,48},
{1994,679,282,284,114,37},
{853,831,318,286,96,35},
{1316,493,351,298,82,28},
{2183,347,351,328,82,15},
{1805,347,374,328,69,15},
{448,728,401,313,54,21},
{911,486,401,341,54,8},
{1832,2,441,341,40,8},
{461,243,453,237,28,87},
{920,2,453,240,28,79},
{458,484,449,240,32,79},
{2,2,455,243,28,84},
{461,2,455,237,28,88},
{2,249,452,237,29,88},
{2,490,447,215,34,86},
{2,709,442,235,34,88},
{1373,254,428,235,42,88},
{1377,2,451,248,30,71},
{918,246,451,236,30,82},
{2,948,379,236,65,82},
{1671,679,319,235,96,72},
{1316,795,319,216,96,85},
{385,1045,286,216,97,85},
{864,1121,185,213,163,88},
{275,1265,185,213,163,88},
{464,1265,185,213,163,88},
{2,1477,185,213,163,88},
{1053,1232,185,213,163,88},
{1242,1232,185,213,163,88},
{1431,1368,185,213,163,88},
{1620,1417,185,213,163,88},
{1809,1618,185,213,163,88},
{653,1338,185,213,163,88},
{842,1338,185,213,163,88},
{1031,1449,185,213,163,88},
{1220,1449,185,213,163,88},
{1409,1585,185,213,163,88},
{1598,1634,185,213,163,88},
{191,1482,185,213,163,88},
{2,1694,185,213,163,88},
{380,1482,185,213,163,88},
{569,1555,185,213,163,88},
{758,1555,185,213,163,88},
{569,1555,185,213,163,88},
{191,1699,185,213,163,88},
{2,1911,185,213,163,88},
{380,1699,185,213,163,88},
{2,1911,185,213,163,88},
{947,1666,185,213,163,88},
{1136,1666,185,213,163,88},
{1325,1802,185,213,163,88},
{569,1772,185,213,163,88},
{758,1772,185,213,163,88},
{191,1916,185,213,163,88},
{2,2128,185,213,163,88},
{380,1916,185,213,163,88},
{947,1883,185,213,163,88},
{1136,1883,185,213,163,88},
{569,1989,185,213,163,88},
{758,1989,185,213,163,88},
{191,2133,185,213,163,88},
{2,2345,185,213,163,88},
{380,2133,185,213,163,88},
{1998,1651,185,213,163,88},
{1787,1835,185,213,163,88},
{1514,1851,185,213,163,88},
{1325,2019,185,213,163,88},
{2187,1651,185,213,163,88},
{947,2100,185,213,163,88},
{1136,2100,185,213,163,88},
{569,2206,185,213,163,88},
{758,2206,185,213,163,88},
{191,2350,185,213,163,88},
{2,2562,185,213,163,88},
{380,2350,185,213,163,88},
{1976,1868,185,213,163,88},
{1703,2052,185,213,163,88},
{1514,2068,185,213,163,88},
{1325,2236,185,213,163,88},
{947,2317,185,213,163,88},
{1136,2317,185,213,163,88},
{569,2423,185,213,163,88},
{758,2423,185,213,163,88},
{191,2567,185,213,163,88},
{2,2779,185,213,163,88},
{380,2567,185,213,163,88},
{2165,1868,185,213,163,88},
{2354,1868,185,213,163,88},
{1892,2085,185,213,163,88},
{1703,2269,185,213,163,88},
{1514,2285,185,213,163,88},
{1325,2453,185,213,163,88},
{947,2534,185,213,163,88},
{1136,2534,185,213,163,88},
{569,2640,185,213,163,88},
{758,2640,185,213,163,88},
{191,2784,185,213,163,88},
{2,2996,185,213,163,88},
{380,2784,185,213,163,88},
{2081,2085,185,213,163,88},
{2270,2085,185,213,163,88},
{1892,2302,185,213,163,88},
{1703,2486,185,213,163,88},
{1514,2502,185,213,163,88},
{1325,2670,185,213,163,88},
{947,2751,185,213,163,88},
{1136,2751,185,213,163,88},
{569,2857,185,213,163,88},
{758,2857,185,213,163,88},
{191,3001,185,213,163,88},
{2,3213,185,213,163,88},
{380,3001,185,213,163,88},
{2,3213,185,213,163,88},
{2081,2302,185,213,163,88},
{2270,2302,185,213,163,88},
{2,3430,185,213,163,88},
{2,3647,185,213,163,88},
{2,3864,185,213,163,88},
{1892,2519,185,213,163,88},
{1703,2703,185,213,163,88},
{1892,2519,185,213,163,88},
{1514,2719,185,213,163,88},
{1325,2887,185,213,163,88},
{947,2968,185,213,163,88},
{1325,2887,185,213,163,88},
{1136,2968,185,213,163,88},
{569,3074,185,213,163,88},
{758,3074,185,213,163,88},
{191,3218,185,213,163,88},
{380,3218,185,213,163,88},
{2081,2519,185,213,163,88},
{2270,2519,185,213,163,88},
{191,3435,185,213,163,88},
{191,3652,185,213,163,88},
{191,3869,185,213,163,88},
{380,3435,185,213,163,88},
{380,3652,185,213,163,88},
{380,3869,185,213,163,88},
{1892,2736,185,213,163,88},
{1703,2920,185,213,163,88},
{1892,2736,185,213,163,88},
{1514,2936,185,213,163,88},
{1325,3104,185,213,163,88},
{947,3185,185,213,163,88},
{1325,3104,185,213,163,88},
{1136,3185,185,213,163,88},
{569,3291,185,213,163,88},
{758,3291,185,213,163,88},
{569,3291,185,213,163,88},
{2081,2736,185,213,163,88},
{2270,2736,185,213,163,88},
{569,3508,185,213,163,88},
{569,3725,185,213,163,88},
{758,3508,185,213,163,88},
{758,3725,185,213,163,88},
{947,3402,185,213,163,88},
{1857,3167,147,145,182,116},
{1668,3290,147,145,182,116},
{1514,3305,147,145,182,116},
{1325,3321,147,145,182,116},
{1136,3402,147,145,182,116},
{2008,3254,147,145,182,116},
{1819,3316,147,145,182,116},
{1665,3439,147,145,182,116},
{1476,3454,147,145,182,116},
{1287,3470,147,145,182,116},
{1136,3551,147,145,182,116},
{2159,3255,147,145,182,116},
{1970,3403,147,145,182,116},
{1816,3465,147,145,182,116},
{1627,3588,147,145,182,116},
{1438,3603,147,145,182,116},
{2388,3251,148,145,181,116},
{2389,2953,150,145,180,116},
{2389,3102,150,145,180,116},
{2235,2953,150,146,180,115},
{2235,3103,149,148,181,114},
{1703,3137,150,149,180,114},
{569,3942,151,148,180,114},
{724,3942,151,147,180,115},
{1514,3153,150,148,181,114},
{2081,2953,150,147,181,115},
{2081,3104,149,146,182,115},
{1287,3619,147,145,182,116},
{1998,1618,93,28,199,232},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=215,Seconds=7.166666666666667,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/6k-atlas-91d6f8061e25.png.lzma2", Size=7569575, CRC32=2542907600, PackedSize=7569924, PackedCRC32=535935277, PreviousSize=7761596, PreviousCRC32=347471968},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/recon/6k-sound-acfee9b84685.mp3.lzma2",Size=173808,CRC32=4070587204,PackedSize=103293,PackedCRC32=76276864},Rects={
{0,0,0,0,0,0},
{2443,1679,102,90,219,121},
{2443,1773,102,90,219,121},
{1297,495,65,90,223,112},
{1514,3200,179,171,165,72},
{2270,3196,184,208,163,64},
{2270,2981,184,211,163,63},
{931,1050,185,213,163,61},
{1120,1235,185,213,163,62},
{742,1050,185,214,163,66},
{931,1267,185,213,163,74},
{742,1268,185,213,163,82},
{1309,1235,185,213,163,87},
{337,1346,185,213,163,88},
{526,1346,185,213,163,88},
{2,1407,185,213,163,88},
{2010,811,185,213,163,88},
{2199,811,185,213,163,88},
{2010,1028,185,213,163,88},
{1746,1030,185,213,163,88},
{2261,282,213,229,150,72},
{1764,762,242,264,134,58},
{1500,1004,242,264,134,58},
{2288,2,269,276,122,44},
{1500,735,260,265,126,48},
{1221,735,275,273,119,40},
{2112,521,318,286,97,36},
{2,1105,331,298,97,30},
{385,1044,353,298,80,30},
{2,771,379,330,67,13},
{838,733,379,313,67,22},
{435,727,399,313,56,22},
{1830,251,427,266,42,66},
{2,262,439,255,30,75},
{2,2,454,256,29,75},
{460,2,454,251,29,79},
{918,246,448,245,32,84},
{1832,2,452,245,29,84},
{1375,2,453,238,30,88},
{918,2,453,240,30,85},
{460,257,442,216,34,85},
{445,477,429,246,40,75},
{2,521,429,246,40,72},
{1375,244,451,246,30,72},
{878,495,415,234,65,84},
{1370,494,415,237,65,72},
{1789,521,319,237,96,72},
{1221,1012,223,219,160,88},
{2199,1028,185,213,163,88},
{1935,1245,185,213,163,88},
{1746,1247,185,213,163,88},
{1498,1272,185,213,163,88},
{1120,1452,185,213,163,88},
{931,1484,185,213,163,88},
{1309,1452,185,213,163,88},
{715,1485,185,213,163,88},
{2124,1245,185,213,163,88},
{2313,1245,185,213,163,88},
{191,1563,185,213,163,88},
{2,1624,185,213,163,88},
{380,1563,185,213,163,88},
{1935,1462,185,213,163,88},
{1687,1464,185,213,163,88},
{1498,1489,185,213,163,88},
{1120,1669,185,213,163,88},
{1309,1669,185,213,163,88},
{904,1701,185,213,163,88},
{569,1702,185,213,163,88},
{191,1780,185,213,163,88},
{2,1841,185,213,163,88},
{380,1780,185,213,163,88},
{2124,1462,185,213,163,88},
{2313,1462,185,213,163,88},
{1876,1679,185,213,163,88},
{1687,1681,185,213,163,88},
{1498,1706,185,213,163,88},
{1093,1886,185,213,163,88},
{1282,1886,185,213,163,88},
{758,1918,185,213,163,88},
{569,1919,185,213,163,88},
{191,1997,185,213,163,88},
{2,2058,185,213,163,88},
{380,1997,185,213,163,88},
{2065,1679,185,213,163,88},
{2254,1679,185,213,163,88},
{1876,1896,185,213,163,88},
{1687,1898,185,213,163,88},
{1471,1923,185,213,163,88},
{2065,1896,185,213,163,88},
{2254,1896,185,213,163,88},
{947,2103,185,213,163,88},
{758,2135,185,213,163,88},
{569,2136,185,213,163,88},
{1136,2103,185,213,163,88},
{191,2214,185,213,163,88},
{2,2275,185,213,163,88},
{380,2214,185,213,163,88},
{1876,2113,185,213,163,88},
{1660,2115,185,213,163,88},
{1325,2140,185,213,163,88},
{947,2320,185,213,163,88},
{758,2352,185,213,163,88},
{569,2353,185,213,163,88},
{1136,2320,185,213,163,88},
{191,2431,185,213,163,88},
{2,2492,185,213,163,88},
{380,2431,185,213,163,88},
{2065,2113,185,213,163,88},
{2254,2113,185,213,163,88},
{1849,2330,185,213,163,88},
{1514,2332,185,213,163,88},
{1325,2357,185,213,163,88},
{947,2537,185,213,163,88},
{758,2569,185,213,163,88},
{569,2570,185,213,163,88},
{1136,2537,185,213,163,88},
{191,2648,185,213,163,88},
{2,2709,185,213,163,88},
{380,2648,185,213,163,88},
{2038,2330,185,213,163,88},
{2227,2330,185,213,163,88},
{1703,2547,185,213,163,88},
{1514,2549,185,213,163,88},
{1325,2574,185,213,163,88},
{947,2754,185,213,163,88},
{758,2786,185,213,163,88},
{569,2787,185,213,163,88},
{1136,2754,185,213,163,88},
{191,2865,185,213,163,88},
{2,2926,185,213,163,88},
{380,2865,185,213,163,88},
{1892,2547,185,213,163,88},
{2081,2547,185,213,163,88},
{2270,2547,185,213,163,88},
{1703,2764,185,213,163,88},
{1514,2766,185,213,163,88},
{1325,2791,185,213,163,88},
{947,2971,185,213,163,88},
{758,3003,185,213,163,88},
{569,3004,185,213,163,88},
{1136,2971,185,213,163,88},
{191,3082,185,213,163,88},
{2,3143,185,213,163,88},
{380,3082,185,213,163,88},
{1892,2764,185,213,163,88},
{2081,2764,185,213,163,88},
{2270,2764,185,213,163,88},
{2,3360,185,213,163,88},
{2,3577,185,213,163,88},
{2,3794,185,213,163,88},
{191,3299,185,213,163,88},
{191,3516,185,213,163,88},
{191,3733,185,213,163,88},
{380,3299,185,213,163,88},
{380,3516,185,213,163,88},
{380,3733,185,213,163,88},
{569,3221,185,213,163,88},
{569,3438,185,213,163,88},
{569,3655,185,213,163,88},
{569,3872,185,213,163,88},
{758,3220,185,213,163,88},
{758,3437,185,213,163,88},
{758,3654,185,213,163,88},
{758,3871,185,213,163,88},
{1703,2981,185,213,163,88},
{1514,2983,185,213,163,88},
{1703,2981,185,213,163,88},
{1325,3008,185,213,163,88},
{947,3188,185,213,163,88},
{1136,3188,185,213,163,88},
{947,3188,185,213,163,88},
{947,3405,185,213,163,88},
{947,3622,185,213,163,88},
{947,3839,185,213,163,88},
{947,3622,185,213,163,88},
{1136,3405,185,213,163,88},
{1136,3622,185,213,163,88},
{1136,3839,185,213,163,88},
{1136,3622,185,213,163,88},
{1892,2981,185,213,163,88},
{2081,2981,185,213,163,88},
{1703,3198,181,156,165,111},
{2388,811,162,156,165,111},
{2388,971,161,154,166,113},
{2036,3513,143,151,184,116},
{2333,3408,143,151,184,116},
{2183,3563,143,151,184,116},
{2330,3563,143,151,184,116},
{1325,3718,143,151,184,116},
{1325,3541,143,151,184,116},
{1325,3873,143,151,184,116},
{1472,3718,143,151,184,116},
{1472,3541,143,151,184,116},
{1472,3873,143,151,184,116},
{1619,3718,143,151,184,116},
{1472,3718,143,151,184,116},
{1619,3533,143,151,184,116},
{1619,3873,143,151,184,116},
{1766,3516,143,151,184,116},
{2184,3408,145,151,183,116},
{2036,3357,144,152,184,116},
{1697,3358,145,154,183,115},
{1888,3198,144,155,184,114},
{2036,3198,144,155,184,114},
{1888,3357,144,155,184,114},
{1325,3225,145,155,183,114},
{1474,3375,145,154,183,114},
{1325,3384,145,153,183,115},
{191,3950,144,128,183,116},
{1120,1050,88,122,237,121},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
},
["Rogue"] = {
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=1024,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/1k-atlas-21916fe31696.png.lzma2", Size=997844, CRC32=2863467884, PackedSize=997893, PackedCRC32=1043100376, PreviousSize=1115992, PreviousCRC32=3842814485},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/1k-sound-3f0432df58b3.mp3.lzma2",Size=55996,CRC32=2620073694,PackedSize=55065,PackedCRC32=565424011},Rects={
{0,0,0,0,0,0},
{218,1651,67,83,221,123},
{216,1938,74,92,218,119},
{218,1528,178,119,181,109},
{216,1742,207,192,152,90},
{2,1742,210,209,150,86},
{2,237,212,211,150,86},
{2,452,212,211,150,86},
{434,233,212,211,150,86},
{650,442,212,211,150,86},
{434,448,212,211,150,86},
{218,453,212,211,150,86},
{2,667,212,211,150,86},
{650,657,212,211,150,86},
{650,2,212,216,150,81},
{650,222,212,216,150,81},
{218,233,212,216,150,81},
{218,2,212,227,150,70},
{434,2,212,227,150,70},
{2,2,212,231,150,66},
{434,663,212,211,150,86},
{218,668,212,211,150,86},
{2,882,212,211,150,86},
{650,872,212,211,150,86},
{434,878,212,211,150,86},
{218,883,212,211,150,86},
{2,1097,212,211,150,86},
{650,1087,212,211,150,86},
{434,1093,212,211,150,86},
{218,1098,212,211,150,86},
{2,1312,212,211,150,86},
{650,1302,212,211,150,86},
{434,1308,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{218,1313,212,211,150,86},
{2,1527,212,211,150,86},
{866,153,119,146,196,105},
{866,303,119,146,196,105},
{866,453,119,146,196,105},
{866,603,119,146,196,105},
{866,753,119,146,196,105},
{866,903,122,144,195,108},
{866,2,124,147,194,106},
{866,1051,122,144,194,107},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/2k-atlas-ed1c87fc7b62.png.lzma2", Size=1955441, CRC32=1356895873, PackedSize=1955532, PackedCRC32=542991561, PreviousSize=2050415, PreviousCRC32=3912477363},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/2k-sound-aa69b04a30e9.mp3.lzma2",Size=55996,CRC32=1853762414,PackedSize=55308,PackedCRC32=728426765},Rects={
{0,0,0,0,0,0},
{1446,647,74,92,218,119},
{897,432,74,92,218,119},
{1217,1631,117,92,175,123},
{1234,862,208,176,153,89},
{1233,1077,209,207,152,88},
{804,1077,211,211,150,86},
{897,1292,210,211,150,86},
{1019,1077,210,211,150,86},
{1020,862,210,211,150,86},
{1061,647,210,211,150,86},
{1003,1507,210,211,150,86},
{1111,1292,210,211,150,86},
{1798,2,226,211,143,86},
{992,1743,268,211,122,86},
{1264,432,268,211,122,86},
{1727,217,298,216,107,81},
{2,1778,326,226,93,71},
{2,1313,345,226,74,71},
{2,1543,337,231,86,66},
{2,862,366,232,73,65},
{2,1098,366,211,73,86},
{2,647,407,211,36,86},
{1305,217,418,211,36,86},
{2,432,418,211,36,86},
{2,217,437,211,32,86},
{2,2,450,211,31,86},
{456,2,450,211,31,86},
{910,2,440,211,36,86},
{1354,2,440,211,36,86},
{882,217,419,211,36,86},
{443,217,435,211,36,86},
{332,1778,326,211,36,86},
{343,1543,326,211,36,86},
{351,1313,326,211,36,86},
{662,1758,326,211,36,86},
{673,1528,326,211,36,86},
{1003,432,212,211,150,86},
{681,432,212,211,150,86},
{424,432,212,211,150,86},
{372,862,212,211,150,86},
{413,647,212,211,150,86},
{372,1077,212,211,150,86},
{588,862,212,211,150,86},
{629,647,212,211,150,86},
{588,1077,212,211,150,86},
{681,1292,212,211,150,86},
{681,1292,212,211,150,86},
{681,1292,212,211,150,86},
{681,1292,212,211,150,86},
{804,862,212,211,150,86},
{845,647,212,211,150,86},
{845,647,212,211,150,86},
{845,647,212,211,150,86},
{845,647,212,211,150,86},
{1217,1507,167,120,173,131},
{1325,1288,167,120,173,131},
{1708,437,167,120,173,131},
{1879,437,167,120,173,131},
{1536,559,167,120,173,131},
{1707,561,166,121,174,130},
{1536,432,168,123,173,129},
{1275,647,167,125,173,128},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=69,Seconds=2.3,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/3k-atlas-670cb9230f8d.png.lzma2", Size=2167207, CRC32=569258079, PackedSize=2167310, PackedCRC32=1167241201, PreviousSize=2246895, PreviousCRC32=716003440},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/3k-sound-29c38906f494.mp3.lzma2",Size=57250,CRC32=549206974,PackedSize=56106,PackedCRC32=268336495},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{723,1942,67,83,221,123},
{645,1942,74,92,218,119},
{1236,1292,205,153,153,99},
{1085,1507,209,195,152,87},
{918,1722,209,209,152,86},
{1490,432,210,211,150,86},
{380,862,212,211,150,86},
{396,647,212,211,150,86},
{410,432,212,211,150,86},
{596,862,212,211,150,86},
{612,647,212,211,150,86},
{1778,2,230,211,143,86},
{372,1077,227,211,142,86},
{645,1727,269,211,122,86},
{351,1507,298,216,107,81},
{343,1737,298,226,107,71},
{2,1507,345,226,74,71},
{1734,217,311,226,112,71},
{2,1737,337,231,86,66},
{2,1077,366,211,73,86},
{2,1292,366,211,73,86},
{2,862,374,211,69,86},
{2,647,390,211,61,86},
{872,217,427,211,43,86},
{1303,217,427,211,43,86},
{2,2,450,211,29,86},
{456,2,438,211,37,86},
{898,2,438,211,37,86},
{2,432,404,211,54,86},
{2,217,431,211,40,86},
{1340,2,434,211,37,86},
{437,217,431,211,40,86},
{626,432,212,211,150,86},
{372,1292,212,211,150,86},
{588,1292,212,211,150,86},
{603,1077,212,211,150,86},
{812,862,212,211,150,86},
{828,647,212,211,150,86},
{842,432,212,211,150,86},
{653,1507,212,211,150,86},
{804,1292,212,211,150,86},
{819,1077,212,211,150,86},
{1028,862,212,211,150,86},
{1044,647,212,211,150,86},
{1058,432,212,211,150,86},
{869,1507,212,211,150,86},
{1020,1292,212,211,150,86},
{1035,1077,212,211,150,86},
{1244,862,212,211,150,86},
{1244,862,212,211,150,86},
{1244,862,212,211,150,86},
{1244,862,212,211,150,86},
{1260,647,212,211,150,86},
{1274,432,212,211,150,86},
{1460,862,158,143,177,108},
{1476,647,158,143,177,108},
{1704,447,158,143,177,108},
{1866,447,158,143,177,108},
{1704,594,158,143,177,108},
{1415,1077,160,143,176,109},
{1251,1077,160,147,177,106},
{1866,594,156,143,180,108},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/4k-atlas-bf782e1e3c1d.png.lzma2", Size=2414615, CRC32=4124291339, PackedSize=2414727, PackedCRC32=4122409367, PreviousSize=2465578, PreviousCRC32=258849810},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/4k-sound-8ca8de653669.mp3.lzma2",Size=55996,CRC32=4174504055,PackedSize=55081,PackedCRC32=2600938558},Rects={
{0,0,0,0,0,0},
{661,1952,74,93,218,118},
{739,1952,74,93,218,118},
{817,1952,74,93,218,123},
{373,1524,208,185,153,89},
{1089,1077,207,203,152,88},
{1533,453,212,209,150,86},
{1311,647,210,211,152,86},
{1749,453,210,211,152,86},
{1525,666,210,211,152,86},
{1249,862,210,211,152,86},
{1739,668,210,211,152,86},
{1463,881,210,211,152,86},
{1677,883,210,211,152,86},
{1798,2,236,211,139,86},
{411,432,250,211,133,86},
{406,647,250,226,133,71},
{373,1292,278,228,117,69},
{343,1722,314,228,99,69},
{1712,217,314,232,99,65},
{2,1722,337,232,86,65},
{2,1292,367,211,72,86},
{2,1507,367,211,72,86},
{2,1077,375,211,69,86},
{2,647,400,211,56,86},
{2,862,400,211,56,86},
{443,217,426,211,45,86},
{2,2,448,211,31,86},
{454,2,448,211,31,86},
{906,2,446,211,33,86},
{873,217,416,211,33,86},
{1293,217,415,211,34,86},
{2,432,405,211,53,86},
{1356,2,438,211,37,86},
{2,217,437,211,38,86},
{381,1077,213,211,150,86},
{598,877,213,211,150,86},
{660,647,213,211,150,86},
{665,432,213,211,150,86},
{655,1092,213,211,150,86},
{815,862,213,211,150,86},
{877,647,213,211,150,86},
{882,432,213,211,150,86},
{655,1307,213,211,150,86},
{661,1522,213,211,150,86},
{661,1737,213,211,150,86},
{661,1737,213,211,150,86},
{872,1077,213,211,150,86},
{1032,862,213,211,150,86},
{1094,647,213,211,150,86},
{1099,432,213,211,150,86},
{872,1292,213,211,150,86},
{1316,432,213,211,150,86},
{872,1292,213,211,150,86},
{1316,432,213,211,150,86},
{1474,1096,167,167,173,108},
{1645,1098,167,167,173,108},
{1474,1267,167,167,173,108},
{1300,1269,167,167,173,108},
{1089,1284,167,167,173,108},
{1816,1098,167,167,173,108},
{1300,1096,170,169,172,107},
{406,877,170,170,171,107},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=227,Seconds=7.566666666666666,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/5k-atlas-907ab4c7066b.png.lzma2", Size=7711651, CRC32=2514367033, PackedSize=7712006, PackedCRC32=460352535, PreviousSize=7863628, PreviousCRC32=2630098784},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/5k-sound-d70c109eb1f9.mp3.lzma2",Size=183265,CRC32=1584408077,PackedSize=149616,PackedCRC32=739783914},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{2381,2699,74,92,218,119},
{2459,2699,74,92,218,119},
{2380,2795,178,97,181,113},
{650,3219,209,195,152,62},
{434,3653,212,208,150,62},
{649,3865,209,209,151,61},
{434,3865,211,209,151,61},
{1820,804,213,211,149,62},
{653,1929,212,211,150,68},
{436,1933,212,211,150,76},
{219,2107,212,211,150,82},
{2,2275,212,211,150,86},
{1740,1935,212,211,150,86},
{1361,2094,212,211,150,86},
{1087,2109,212,211,150,86},
{869,2136,212,211,150,86},
{652,2144,212,211,150,86},
{435,2148,212,211,150,86},
{2292,2,214,226,149,71},
{1602,804,214,226,149,71},
{1068,807,240,258,137,57},
{2,1145,270,266,121,45},
{381,975,270,268,121,45},
{787,807,277,262,118,49},
{1314,770,284,287,115,35},
{2134,787,318,284,97,37},
{2134,471,349,312,82,15},
{1780,471,350,329,81,14},
{2,812,375,329,69,14},
{910,493,400,310,57,24},
{1371,467,405,299,52,26},
{2,285,433,284,41,39},
{2,2,454,279,29,39},
{918,2,454,238,29,79},
{460,254,446,238,33,79},
{460,2,454,248,29,79},
{1376,2,454,226,29,80},
{1834,2,454,226,29,80},
{439,496,400,240,55,80},
{2,573,400,235,55,86},
{1830,232,428,235,43,86},
{918,244,449,245,31,73},
{1376,232,450,231,31,86},
{406,740,377,231,69,86},
{2262,232,277,234,98,73},
{1820,1019,213,211,150,86},
{1602,1034,213,211,150,86},
{1312,1061,213,211,150,86},
{1068,1069,213,211,150,86},
{655,1073,213,211,150,86},
{276,1247,213,211,150,86},
{2,1415,213,211,150,86},
{2037,1075,213,211,150,86},
{1819,1234,213,211,150,86},
{1529,1249,213,211,150,86},
{1285,1276,213,211,150,86},
{2254,1075,213,211,150,86},
{872,1284,213,211,150,86},
{493,1288,213,211,150,86},
{219,1462,213,211,150,86},
{2,1630,213,211,150,86},
{2036,1290,213,211,150,86},
{1746,1449,213,211,150,86},
{1502,1464,213,211,150,86},
{2253,1290,213,211,150,86},
{1089,1491,213,211,150,86},
{1089,1491,213,211,150,86},
{710,1499,213,211,150,86},
{436,1503,213,211,150,86},
{219,1677,213,211,150,86},
{2,1845,213,211,150,86},
{1963,1505,213,211,150,86},
{1719,1664,213,211,150,86},
{2180,1505,213,211,150,86},
{1306,1679,213,211,150,86},
{927,1706,213,211,150,86},
{653,1714,213,211,150,86},
{436,1718,213,211,150,86},
{219,1892,213,211,150,86},
{2,2060,213,211,150,86},
{1936,1720,213,211,150,86},
{2153,1720,213,211,150,86},
{1523,1879,213,211,150,86},
{1144,1894,213,211,150,86},
{870,1921,213,211,150,86},
{218,2322,212,211,150,86},
{2,2490,212,211,150,86},
{1956,1935,212,211,150,86},
{2172,1935,212,211,150,86},
{1577,2150,212,211,150,86},
{1303,2309,212,211,150,86},
{1085,2324,212,211,150,86},
{868,2351,212,211,150,86},
{651,2359,212,211,150,86},
{434,2363,212,211,150,86},
{218,2537,212,211,150,86},
{2,2705,212,211,150,86},
{1793,2150,212,211,150,86},
{2009,2150,212,211,150,86},
{2225,2150,212,211,150,86},
{1519,2365,212,211,150,86},
{1301,2524,212,211,150,86},
{1084,2539,212,211,150,86},
{867,2566,212,211,150,86},
{650,2574,212,211,150,86},
{434,2578,212,211,150,86},
{218,2752,212,211,150,86},
{2,2920,212,211,150,86},
{1735,2365,212,211,150,86},
{1951,2365,212,211,150,86},
{2167,2365,212,211,150,86},
{2,3135,212,211,150,86},
{2,3350,212,211,150,86},
{2,3565,212,211,150,86},
{2,3780,212,211,150,86},
{1517,2580,212,211,150,86},
{1300,2739,212,211,150,86},
{1083,2754,212,211,150,86},
{866,2781,212,211,150,86},
{650,2789,212,211,150,86},
{434,2793,212,211,150,86},
{218,2967,212,211,150,86},
{1733,2580,212,211,150,86},
{1949,2580,212,211,150,86},
{2165,2580,212,211,150,86},
{218,3182,212,211,150,86},
{218,3397,212,211,150,86},
{218,3612,212,211,150,86},
{218,3827,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1516,2795,212,211,150,86},
{1299,2954,212,211,150,86},
{1082,2969,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{866,2996,212,211,150,86},
{650,3004,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{434,3008,212,211,150,86},
{1732,2795,212,211,150,86},
{1948,2795,212,211,150,86},
{2164,2795,212,211,150,86},
{434,3223,212,211,150,86},
{434,3438,212,211,150,86},
{650,3418,165,161,173,108},
{650,3583,165,161,173,108},
{819,3418,165,161,173,108},
{863,3219,165,161,173,108},
{819,3583,165,161,173,108},
{862,3748,165,161,173,108},
{862,3913,165,161,173,108},
{988,3384,165,161,173,108},
{1032,3211,165,161,173,108},
{988,3549,165,161,173,108},
{1031,3714,165,161,173,108},
{1031,3879,165,161,173,108},
{1157,3376,165,161,173,108},
{1157,3541,165,161,173,108},
{1201,3184,165,161,173,108},
{1200,3706,165,161,173,108},
{1326,3349,164,161,174,108},
{1200,3871,165,161,174,108},
{872,1073,166,161,173,108},
{1523,1679,167,160,173,108},
{2380,2896,167,162,173,108},
{2388,1885,167,163,173,107},
{2383,2365,167,163,173,107},
{2383,2532,167,163,173,107},
{1306,1491,167,162,173,108},
{2388,1720,168,161,172,108},
{1089,1284,167,160,172,108},
{1144,1706,157,157,177,110},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=220,Seconds=7.333333333333333,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/6k-atlas-9af109e3c59d.png.lzma2", Size=7834032, CRC32=1528479140, PackedSize=7834393, PackedCRC32=2345938029, PreviousSize=7965612, PreviousCRC32=292801205},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/rogue/6k-sound-e3be6de5d765.mp3.lzma2",Size=176995,CRC32=2943352026,PackedSize=149457,PackedCRC32=2449186346},Rects={
{0,0,0,0,0,0},
{1157,757,74,92,218,119},
{1614,715,74,92,218,119},
{2454,811,96,58,183,136},
{2,3897,207,178,152,62},
{1500,2809,211,206,150,62},
{650,1872,212,208,150,62},
{655,1212,212,211,150,59},
{381,1259,212,211,150,60},
{1245,1734,212,210,150,65},
{866,1772,212,209,150,72},
{2,1317,212,211,150,80},
{1422,1089,212,211,150,85},
{1138,1127,212,211,150,86},
{871,1227,212,211,150,86},
{597,1427,212,211,150,86},
{218,1474,212,211,150,86},
{2,1532,212,211,150,86},
{1638,1089,212,211,150,86},
{1854,1089,212,211,150,86},
{920,997,214,226,149,71},
{1614,819,242,266,135,57},
{1860,819,242,266,135,57},
{381,988,270,267,121,45},
{1157,861,261,262,125,49},
{2259,2,280,262,117,49},
{1293,573,317,284,98,37},
{2133,811,317,302,98,25},
{2133,505,350,302,81,25},
{2,986,375,327,69,15},
{1754,505,375,310,69,23},
{1349,259,401,310,55,23},
{457,494,428,252,43,73},
{1827,2,428,249,43,74},
{918,2,453,247,30,76},
{2,248,453,241,30,76},
{1375,2,448,253,31,76},
{460,247,453,243,29,86},
{460,2,454,241,29,86},
{2,2,454,242,29,85},
{889,511,400,242,55,85},
{1827,255,428,246,42,81},
{917,253,428,254,42,73},
{2,493,451,254,29,73},
{2,751,377,231,69,86},
{457,750,377,234,69,74},
{838,757,315,236,99,73},
{2259,268,261,223,99,74},
{655,997,261,211,99,86},
{434,2072,210,211,150,86},
{218,2119,210,211,150,86},
{2,2177,210,211,150,86},
{1461,1734,210,211,150,86},
{1675,1734,210,211,150,86},
{1082,1948,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{648,2084,210,211,150,86},
{866,1985,210,211,150,86},
{432,2287,210,211,150,86},
{216,2334,210,211,150,86},
{2,2392,210,211,150,86},
{1889,1762,210,211,150,86},
{2,2392,210,211,150,86},
{2103,1762,210,211,150,86},
{2317,1762,210,211,150,86},
{1296,1949,210,211,150,86},
{1080,2163,210,211,150,86},
{862,2200,210,211,150,86},
{646,2299,210,211,150,86},
{430,2502,210,211,150,86},
{216,2549,210,211,150,86},
{2,2607,210,211,150,86},
{1510,1949,210,211,150,86},
{1724,1977,210,211,150,86},
{1294,2164,210,211,150,86},
{1508,2164,210,211,150,86},
{1076,2378,210,211,150,86},
{860,2415,210,211,150,86},
{644,2514,210,211,150,86},
{430,2717,210,211,150,86},
{216,2764,210,211,150,86},
{2,2822,210,211,150,86},
{1938,1977,210,211,150,86},
{2152,1977,210,211,150,86},
{1722,2192,210,211,150,86},
{1290,2379,210,211,150,86},
{1074,2593,210,211,150,86},
{858,2630,210,211,150,86},
{644,2729,210,211,150,86},
{430,2932,210,211,150,86},
{216,2979,210,211,150,86},
{2,3037,210,211,150,86},
{1504,2379,210,211,150,86},
{1936,2192,210,211,150,86},
{2150,2192,210,211,150,86},
{1718,2407,210,211,150,86},
{1288,2594,210,211,150,86},
{1072,2808,210,211,150,86},
{858,2845,210,211,150,86},
{644,2944,210,211,150,86},
{430,3147,210,211,150,86},
{216,3194,210,211,150,86},
{2,3252,210,211,150,86},
{1502,2594,210,211,150,86},
{1932,2407,210,211,150,86},
{2146,2407,210,211,150,86},
{2,3467,210,211,150,86},
{2,3682,210,211,150,86},
{216,3409,210,211,150,86},
{216,3624,210,211,150,86},
{216,3839,210,211,150,86},
{430,3362,210,211,150,86},
{430,3577,210,211,150,86},
{430,3792,210,211,150,86},
{1716,2622,210,211,150,86},
{1286,2809,210,211,150,86},
{1072,3023,210,211,150,86},
{858,3060,210,211,150,86},
{2070,1117,212,211,150,86},
{2286,1117,212,211,150,86},
{1354,1304,212,211,150,86},
{1087,1342,212,211,150,86},
{813,1442,212,211,150,86},
{434,1642,212,211,150,86},
{218,1689,212,211,150,86},
{2,1747,212,211,150,86},
{1570,1304,212,211,150,86},
{1786,1304,212,211,150,86},
{1786,1304,212,211,150,86},
{2002,1332,212,211,150,86},
{2002,1332,212,211,150,86},
{2218,1332,212,211,150,86},
{2218,1332,212,211,150,86},
{2218,1332,212,211,150,86},
{2218,1332,212,211,150,86},
{2218,1332,212,211,150,86},
{1303,1519,212,211,150,86},
{1029,1557,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{650,1657,212,211,150,86},
{434,1857,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{218,1904,212,211,150,86},
{2,1962,212,211,150,86},
{1519,1519,212,211,150,86},
{1519,1519,212,211,150,86},
{1519,1519,212,211,150,86},
{1735,1519,212,211,150,86},
{1735,1519,212,211,150,86},
{1735,1519,212,211,150,86},
{1951,1547,212,211,150,86},
{2167,1547,212,211,150,86},
{2094,2622,158,167,177,109},
{1930,2794,158,166,177,109},
{1715,2837,158,166,177,109},
{2256,2838,158,166,177,109},
{1877,2964,158,166,177,109},
{1715,3007,158,166,177,109},
{1500,3019,158,166,177,109},
{1286,3024,158,166,177,109},
{2039,2964,158,166,177,109},
{2201,3008,158,166,177,109},
{2363,3008,158,166,177,109},
{1877,3134,158,166,177,109},
{2039,3134,158,166,177,109},
{2039,3134,158,166,177,109},
{2039,3134,158,166,177,109},
{1662,3177,158,166,177,109},
{2256,2667,158,167,177,108},
{2094,2793,158,167,177,108},
{1082,1772,159,167,177,108},
{2360,2495,161,168,176,107},
{644,3159,161,168,176,108},
{2366,2150,161,169,176,107},
{2383,1547,162,169,176,107},
{1422,861,162,169,176,107},
{2366,1977,162,169,175,107},
{2364,2323,162,168,175,108},
{1930,2622,160,168,177,108},
{1448,3189,149,165,177,110},
{1614,573,134,138,181,110},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
},
["Singularity"] = {
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=1024,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/1k-atlas-88574e5aed4d.png.lzma2", Size=930806, CRC32=1833579601, PackedSize=930852, PackedCRC32=3062567556, PreviousSize=1044561, PreviousCRC32=3851406645},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/1k-sound-fd1a5cf88f72.mp3.lzma2",Size=55943,CRC32=2152539069,PackedSize=55124,PackedCRC32=3500722778},Rects={
{0,0,0,0,0,0},
{918,250,70,81,224,124},
{918,156,74,90,221,120},
{918,2,95,150,207,109},
{184,442,136,166,197,116},
{184,230,174,208,169,98},
{362,230,178,207,167,99},
{544,230,178,206,167,99},
{544,440,178,206,167,99},
{362,441,178,206,167,99},
{726,451,178,206,167,99},
{544,650,178,206,167,99},
{726,661,178,206,167,99},
{2,230,178,210,167,95},
{730,227,184,220,167,85},
{2,2,178,224,167,81},
{184,2,178,224,167,81},
{366,2,178,224,167,81},
{548,2,178,224,167,81},
{730,2,178,221,167,84},
{2,444,178,201,167,104},
{2,649,178,201,167,104},
{184,651,178,201,167,104},
{2,854,178,201,167,104},
{184,856,178,194,167,111},
{366,860,178,194,167,111},
{184,1054,178,194,167,111},
{2,1059,178,194,167,111},
{548,871,178,191,167,114},
{366,1058,178,191,167,114},
{184,1252,178,191,167,114},
{2,1257,178,191,167,114},
{730,871,178,191,167,114},
{548,1066,178,191,167,114},
{366,1253,178,191,167,114},
{548,1066,178,191,167,114},
{184,1447,178,191,167,114},
{2,1452,178,191,167,114},
{730,1066,178,191,167,114},
{2,1452,178,191,167,114},
{2,1647,178,191,167,114},
{2,1842,178,191,167,114},
{184,1642,178,191,167,114},
{2,1842,178,191,167,114},
{184,1837,178,191,167,114},
{548,1261,178,191,167,114},
{366,1448,178,191,167,114},
{730,1261,178,191,167,114},
{366,1643,178,191,167,114},
{366,1838,178,191,167,114},
{548,1456,178,191,167,114},
{366,1838,178,191,167,114},
{366,1643,178,191,167,114},
{366,1838,178,191,167,114},
{548,1456,178,191,167,114},
{855,1456,118,135,197,115},
{855,1595,118,135,197,115},
{730,1598,118,135,197,115},
{852,1734,118,135,197,115},
{548,1873,118,135,197,115},
{730,1456,121,138,196,114},
{366,651,123,139,195,114},
{670,1873,120,134,196,117},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/2k-atlas-a25907076edc.png.lzma2", Size=1884702, CRC32=1994406045, PackedSize=1884790, PackedCRC32=2670673280, PreviousSize=1948538, PreviousCRC32=3204742873},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/2k-sound-de627f7fe054.mp3.lzma2",Size=55943,CRC32=2400969879,PackedSize=55018,PackedCRC32=442101208},Rects={
{0,0,0,0,0,0},
{1721,1612,73,90,220,120},
{1721,1706,73,90,220,120},
{1951,1027,73,90,220,124},
{159,1614,150,122,182,146},
{1802,1417,183,190,165,114},
{1802,1611,183,190,165,114},
{1577,834,183,191,165,114},
{1764,1027,183,191,165,114},
{1269,839,183,191,165,114},
{1456,1029,183,191,165,114},
{1811,628,228,200,163,105},
{1577,628,230,202,161,103},
{1305,628,268,207,123,98},
{2,709,283,220,109,85},
{351,677,299,223,93,82},
{713,472,312,231,93,74},
{1129,238,324,232,93,73},
{1574,2,343,232,93,73},
{780,236,345,232,92,73},
{416,205,360,232,77,73},
{364,441,345,232,92,73},
{1215,2,355,232,82,73},
{2,237,358,232,78,73},
{2,473,345,232,76,73},
{2,2,410,231,41,74},
{816,2,395,230,58,75},
{416,2,396,199,57,106},
{1744,238,282,191,115,114},
{1457,238,283,191,116,114},
{1029,669,236,191,167,114},
{654,707,234,191,167,114},
{1457,433,278,191,120,114},
{1739,433,274,191,119,114},
{1029,474,272,191,120,114},
{1811,832,224,191,121,114},
{892,864,178,191,167,114},
{1074,864,178,191,167,114},
{1256,1034,178,191,167,114},
{654,902,178,191,167,114},
{289,904,178,191,167,114},
{471,904,178,191,167,114},
{2,933,178,191,167,114},
{1643,1222,178,191,167,114},
{1438,1224,178,191,167,114},
{1825,1222,178,191,167,114},
{836,1059,178,191,167,114},
{653,1097,178,191,167,114},
{1018,1059,178,191,167,114},
{1200,1229,178,191,167,114},
{835,1254,178,191,167,114},
{1017,1254,178,191,167,114},
{1620,1417,178,191,167,114},
{1382,1419,178,191,167,114},
{1382,1419,178,191,167,114},
{2,1805,153,119,179,132},
{2,1614,153,119,179,132},
{2,1449,153,119,179,132},
{2,1292,153,119,179,132},
{2,1128,153,119,179,132},
{159,1805,151,119,181,131},
{1564,1612,153,121,180,130},
{1199,1424,153,122,180,129},
{2,1800,1,1,181,193},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=69,Seconds=2.3,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/3k-atlas-f44e9b3d8ae8.png.lzma2", Size=2108955, CRC32=3047358181, PackedSize=2109055, PackedCRC32=872712878, PreviousSize=2151222, PreviousCRC32=1859434182},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/3k-sound-7aae6a7ce6af.mp3.lzma2",Size=57197,CRC32=1630347871,PackedSize=56139,PackedCRC32=1819112244},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{1306,439,65,80,224,125},
{1221,634,73,90,220,120},
{836,1040,133,149,191,108},
{1396,210,173,188,169,116},
{2,1040,178,207,167,98},
{1219,988,178,206,167,99},
{977,1024,178,206,167,99},
{1643,793,178,206,167,99},
{1825,793,178,206,167,99},
{472,1040,178,206,167,99},
{1459,793,180,206,165,99},
{184,1220,180,205,165,100},
{242,1011,226,205,143,100},
{700,620,277,221,112,84},
{1081,210,311,225,95,80},
{2,422,315,224,91,81},
{367,393,329,224,90,81},
{732,197,345,224,92,81},
{2,197,361,221,76,84},
{1265,2,364,204,73,101},
{1633,2,364,197,73,108},
{1633,203,363,196,74,109},
{367,197,361,192,76,113},
{432,2,424,191,46,114},
{2,2,426,191,44,114},
{860,2,401,191,54,114},
{1396,403,303,191,117,114},
{700,425,306,191,111,114},
{1703,403,294,191,109,114},
{1010,439,292,191,109,114},
{321,621,258,191,109,114},
{2,650,258,191,109,114},
{264,816,236,191,109,114},
{2,845,236,191,109,114},
{1306,598,236,191,109,114},
{981,634,236,191,109,114},
{1546,598,236,191,109,114},
{1786,598,235,191,110,114},
{1221,793,234,191,111,114},
{981,829,234,191,111,114},
{504,845,233,191,112,114},
{741,845,232,191,113,114},
{2,1251,178,191,167,114},
{654,1040,178,191,167,114},
{2,1446,178,191,167,114},
{2,1641,178,191,167,114},
{2,1836,178,191,167,114},
{184,1429,178,191,167,114},
{184,1624,178,191,167,114},
{184,1819,178,191,167,114},
{366,1429,178,191,167,114},
{366,1624,178,191,167,114},
{366,1819,178,191,167,114},
{1401,1003,178,191,167,114},
{368,1250,141,136,186,114},
{513,1250,141,136,186,114},
{1583,1003,141,136,186,114},
{1728,1003,141,136,186,114},
{1727,1143,140,136,186,114},
{1583,1143,140,138,186,114},
{1873,1003,140,139,186,114},
{836,1193,135,135,188,116},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=68,Seconds=2.2666666666666666,AtlasWidth=2048,AtlasHeight=2048,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/4k-atlas-29abe4422efd.png.lzma2", Size=2270581, CRC32=322206313, PackedSize=2270687, PackedCRC32=367767680, PreviousSize=2308123, PreviousCRC32=3373792372},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/4k-sound-a006a0e4e539.mp3.lzma2",Size=55943,CRC32=3592825152,PackedSize=55109,PackedCRC32=905449177},Rects={
{0,0,0,0,0,0},
{1966,1347,71,90,222,120},
{1966,1347,71,90,222,120},
{1966,1441,71,89,222,124},
{1030,1237,150,152,181,116},
{1821,420,184,207,165,99},
{1580,594,183,206,165,100},
{284,1024,184,204,165,100},
{1767,631,184,205,165,100},
{472,1024,184,204,165,100},
{2,1061,184,204,165,100},
{660,1030,184,204,165,100},
{1858,197,188,219,165,85},
{673,822,187,204,165,100},
{1043,815,239,223,134,81},
{1325,594,251,224,132,81},
{2,831,278,226,106,79},
{1043,587,278,224,117,81},
{724,587,315,231,99,74},
{356,788,313,232,100,73},
{2,596,350,231,81,74},
{1464,392,353,198,80,107},
{367,587,353,197,80,108},
{2,201,365,196,81,109},
{2,2,378,195,69,110},
{384,2,378,191,69,114},
{766,2,378,191,69,114},
{1148,2,373,191,70,114},
{1525,2,372,191,71,114},
{2,401,361,191,77,114},
{1491,197,363,191,75,114},
{1123,197,364,191,74,114},
{738,392,360,191,74,114},
{384,197,366,191,73,114},
{754,197,365,191,74,114},
{371,392,363,191,74,114},
{1102,392,358,191,76,114},
{1580,804,178,191,167,114},
{848,1030,178,191,167,114},
{1762,840,178,191,167,114},
{1286,822,178,191,167,114},
{1468,999,178,191,167,114},
{1286,1017,178,191,167,114},
{1030,1042,178,191,167,114},
{1030,1042,178,191,167,114},
{848,1225,178,191,167,114},
{848,1225,178,191,167,114},
{848,1225,178,191,167,114},
{848,1225,178,191,167,114},
{1650,1035,178,191,167,114},
{1650,1035,178,191,167,114},
{1650,1035,178,191,167,114},
{1650,1035,178,191,167,114},
{1650,1035,178,191,167,114},
{1468,1194,178,191,167,114},
{864,822,154,152,179,115},
{1832,1035,154,152,179,115},
{1832,1191,154,152,179,115},
{1650,1230,154,152,179,115},
{1808,1347,154,152,179,115},
{1212,1212,152,152,180,115},
{1650,1386,152,154,180,114},
{1806,1503,152,153,180,115},
{1184,1237,19,148,246,119},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=227,Seconds=7.566666666666666,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/5k-atlas-c65ac6ac560f.png.lzma2", Size=6860054, CRC32=16370639, PackedSize=6860370, PackedCRC32=1564678262, PreviousSize=7035098, PreviousCRC32=1649455659},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/5k-sound-ed81288ec7ca.mp3.lzma2",Size=183212,CRC32=1702505814,PackedSize=113857,PackedCRC32=2672748000},Rects={
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{366,3999,73,90,220,120},
{443,3999,73,90,220,120},
{1149,3950,97,144,208,97},
{1094,2828,144,163,189,88},
{730,2458,174,191,169,87},
{615,1662,178,193,167,87},
{797,1676,178,193,167,87},
{548,1859,178,192,167,90},
{2,1501,178,193,167,96},
{184,1501,178,193,167,104},
{366,1663,178,193,167,110},
{2,1698,178,192,167,113},
{184,1698,178,192,167,113},
{366,1860,178,192,167,113},
{431,1453,180,206,167,99},
{2286,255,181,206,166,99},
{615,1453,179,205,167,100},
{798,1468,179,204,167,101},
{1099,1457,214,233,149,72},
{1099,1219,216,234,148,71},
{862,1219,233,245,139,61},
{1345,1213,252,248,137,59},
{2290,2,259,249,133,58},
{2279,472,275,259,117,49},
{2151,1222,274,241,117,64},
{2226,935,316,283,98,37},
{1773,1171,374,268,60,37},
{1345,955,424,254,32,52},
{2,1230,425,267,31,39},
{432,1169,426,280,30,38},
{2,941,426,285,30,38},
{900,931,441,284,30,39},
{1376,2,453,282,30,40},
{2,2,454,236,29,81},
{460,2,454,236,30,81},
{451,936,441,229,30,78},
{918,235,453,229,29,77},
{918,2,454,229,29,77},
{1833,2,453,229,29,76},
{1797,935,425,232,30,74},
{2,475,445,232,32,74},
{1833,235,449,233,31,74},
{1375,288,449,231,31,74},
{1828,472,447,231,32,74},
{1352,523,445,229,33,76},
{2,242,446,229,33,76},
{452,242,446,228,33,77},
{902,468,446,228,33,77},
{452,474,446,227,33,78},
{902,700,445,227,34,78},
{451,705,445,227,34,78},
{2,711,445,226,34,79},
{1801,707,443,224,35,81},
{1351,756,442,195,36,110},
{2248,735,244,191,101,114},
{2,1894,178,191,167,114},
{184,1894,178,191,167,114},
{1601,1443,178,191,167,114},
{1317,1465,178,191,167,114},
{1783,1443,178,191,167,114},
{1965,1443,178,191,167,114},
{2147,1467,178,191,167,114},
{2329,1467,178,191,167,114},
{1499,1638,178,191,167,114},
{1317,1660,178,191,167,114},
{979,1694,178,191,167,114},
{730,1873,178,191,167,114},
{548,2055,178,191,167,114},
{366,2056,178,191,167,114},
{2,2089,178,191,167,114},
{2,2089,178,191,167,114},
{2,2089,178,191,167,114},
{184,2089,178,191,167,114},
{1681,1638,178,191,167,114},
{1863,1638,178,191,167,114},
{2045,1662,178,191,167,114},
{2227,1662,178,191,167,114},
{1499,1833,178,191,167,114},
{1161,1855,178,191,167,114},
{912,1889,178,191,167,114},
{730,2068,178,191,167,114},
{548,2250,178,191,167,114},
{366,2251,178,191,167,114},
{2,2284,178,191,167,114},
{184,2284,178,191,167,114},
{1681,1833,178,191,167,114},
{1863,1833,178,191,167,114},
{2045,1857,178,191,167,114},
{2227,1857,178,191,167,114},
{1343,2028,178,191,167,114},
{1094,2050,178,191,167,114},
{912,2084,178,191,167,114},
{730,2263,178,191,167,114},
{548,2445,178,191,167,114},
{366,2446,178,191,167,114},
{2,2479,178,191,167,114},
{184,2479,178,191,167,114},
{1525,2028,178,191,167,114},
{1707,2028,178,191,167,114},
{1889,2052,178,191,167,114},
{2071,2052,178,191,167,114},
{2253,2052,178,191,167,114},
{1276,2223,178,191,167,114},
{1094,2245,178,191,167,114},
{912,2279,178,191,167,114},
{548,2640,178,190,167,114},
{366,2641,178,190,167,114},
{2,2674,178,190,167,114},
{184,2674,178,190,167,114},
{1458,2223,178,190,167,114},
{1640,2223,178,190,167,114},
{1822,2247,178,190,167,114},
{1458,2417,178,190,167,114},
{1276,2418,178,190,167,114},
{1094,2440,178,190,167,114},
{1640,2417,178,190,167,114},
{908,2474,178,190,167,114},
{2004,2247,178,190,167,114},
{2186,2247,178,190,167,114},
{2368,2247,178,190,167,114},
{1822,2441,178,190,167,114},
{1458,2611,178,190,167,114},
{1276,2612,178,190,167,114},
{1640,2611,178,190,167,114},
{1090,2634,178,190,167,114},
{730,2668,178,190,167,114},
{548,2834,178,190,167,114},
{366,2835,178,190,167,114},
{2,2868,178,190,167,114},
{184,2868,178,190,167,114},
{2004,2441,178,190,167,114},
{2186,2441,178,190,167,114},
{2368,2441,178,190,167,114},
{1822,2635,178,190,167,114},
{1458,2805,178,190,167,114},
{1640,2805,178,190,167,114},
{1272,2806,178,190,167,114},
{912,2828,178,190,167,114},
{730,2862,178,190,167,114},
{730,2862,178,190,167,114},
{730,2862,178,190,167,114},
{548,3028,178,190,167,114},
{366,3029,178,190,167,114},
{2,3062,178,190,167,114},
{184,3062,178,190,167,114},
{2004,2635,178,190,167,114},
{2186,2635,178,190,167,114},
{2186,2635,178,190,167,114},
{2186,2635,178,190,167,114},
{2368,2635,178,190,167,114},
{1822,2829,178,190,167,114},
{1454,2999,178,190,167,114},
{1636,2999,178,190,167,114},
{1094,3000,178,190,167,114},
{912,3022,178,190,167,114},
{912,3022,178,190,167,114},
{912,3022,178,190,167,114},
{730,3056,178,190,167,114},
{548,3222,178,190,167,114},
{366,3223,178,190,167,114},
{2,3256,178,190,167,114},
{184,3256,178,190,167,114},
{2004,2829,178,190,167,114},
{2186,2829,178,190,167,114},
{2368,2829,178,190,167,114},
{2,3450,178,190,167,114},
{2,3644,178,190,167,114},
{2,3644,178,190,167,114},
{2,3644,178,190,167,114},
{2,3644,178,190,167,114},
{2,3838,178,190,167,114},
{2,3838,178,190,167,114},
{2,3838,178,190,167,114},
{184,3450,178,190,167,114},
{184,3644,178,190,167,114},
{184,3838,178,190,167,114},
{366,3417,178,190,167,114},
{366,3611,178,190,167,114},
{366,3805,178,190,167,114},
{548,3416,178,190,167,114},
{1094,3194,147,144,182,115},
{912,3216,147,144,182,115},
{730,3250,147,144,182,115},
{548,3610,147,144,182,115},
{548,3758,147,144,182,115},
{548,3906,147,144,182,115},
{699,3610,147,144,182,115},
{730,3398,147,144,182,115},
{699,3758,147,144,182,115},
{699,3906,147,144,182,115},
{850,3546,147,144,182,115},
{881,3364,147,144,182,115},
{850,3546,147,144,182,115},
{850,3694,147,144,182,115},
{850,3842,147,144,182,115},
{1001,3512,147,144,182,115},
{1032,3364,147,144,182,115},
{912,2668,148,144,182,115},
{2409,1811,148,145,182,114},
{1161,1694,148,145,182,114},
{1276,3146,147,145,182,114},
{2409,1662,149,145,181,114},
{1343,1855,148,145,182,114},
{1601,1213,148,144,182,115},
{1276,3000,148,142,182,116},
{1001,3660,146,142,183,116},
{1001,3806,145,140,184,117},
{1001,3950,144,139,185,117},
{2435,1960,123,77,203,178},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
{Frames=215,Seconds=7.166666666666667,AtlasWidth=2560,AtlasHeight=4096,Atlas={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/6k-atlas-a12c55e57bb5.png.lzma2", Size=7249086, CRC32=2996527057, PackedSize=7249420, PackedCRC32=3719474051, PreviousSize=7361400, PreviousCRC32=875019072},Sound={Path="cheatgpt/v1/kill-effect/valorant/collections/singularity/6k-sound-b33f1a7950d7.mp3.lzma2",Size=173181,CRC32=2872271805,PackedSize=113381,PackedCRC32=356867279},Rects={
{0,0,0,0,0,0},
{1736,1540,73,90,220,120},
{1736,1634,73,90,220,120},
{2188,1366,60,70,234,129},
{982,2876,104,120,206,122},
{2368,3003,174,190,169,87},
{548,1510,176,192,169,87},
{1008,1318,178,192,167,87},
{1190,1507,178,192,167,88},
{1008,1121,178,193,167,92},
{1372,1518,178,192,167,100},
{1554,1540,178,192,167,108},
{1190,1310,178,193,167,113},
{728,1515,178,191,167,114},
{184,1706,178,191,167,114},
{641,1115,178,195,167,110},
{2296,282,207,231,138,74},
{2252,1365,208,263,137,42},
{2252,1097,208,264,137,41},
{2035,1097,213,265,137,40},
{1437,1031,223,272,136,40},
{1195,1031,238,275,137,39},
{2297,2,241,276,136,39},
{2,1089,263,275,128,39},
{436,838,288,273,98,39},
{898,836,293,281,98,39},
{1714,829,317,283,97,39},
{1364,758,346,269,80,39},
{2160,825,360,268,71,39},
{2160,545,374,276,69,39},
{1782,545,374,280,69,39},
{458,556,436,278,32,39},
{919,544,441,288,30,39},
{2,2,457,268,29,39},
{2,274,456,268,29,39},
{463,2,456,278,30,39},
{1841,273,451,268,31,39},
{2,546,452,268,29,39},
{1383,2,454,268,29,39},
{923,272,454,268,29,39},
{462,284,453,268,29,39},
{1841,2,452,267,29,40},
{1381,274,447,267,30,40},
{923,2,456,266,31,41},
{2,818,430,267,35,41},
{1364,545,414,209,49,99},
{1664,1116,201,209,151,98},
{1437,1307,184,207,161,98},
{1625,1329,184,207,161,98},
{1813,1329,184,206,161,99},
{2001,1366,183,206,162,99},
{1813,1539,183,199,162,106},
{2000,1576,183,199,162,106},
{2187,1632,183,197,162,108},
{2374,1632,183,196,162,109},
{269,1115,182,195,163,110},
{2374,1832,182,196,163,109},
{455,1115,182,195,163,110},
{823,1121,181,194,164,111},
{269,1314,178,192,167,113},
{2,1368,178,192,167,113},
{451,1314,178,192,167,113},
{633,1314,178,192,167,113},
{815,1319,178,192,167,113},
{997,1514,178,192,167,113},
{997,1514,178,192,167,113},
{997,1514,178,192,167,113},
{1179,1703,178,192,167,113},
{1361,1714,178,192,167,113},
{1361,1714,178,192,167,113},
{1361,1714,178,192,167,113},
{1543,1736,178,192,167,113},
{1725,1742,178,192,167,113},
{1907,1779,178,192,167,113},
{2089,1833,178,192,167,113},
{184,1510,178,192,167,113},
{2,1564,178,192,167,113},
{366,1510,178,192,167,113},
{2,1760,178,191,167,114},
{366,1706,178,191,167,114},
{548,1710,178,191,167,114},
{184,1901,178,191,167,114},
{2,1955,178,191,167,114},
{366,1901,178,191,167,114},
{730,1710,178,191,167,114},
{912,1710,178,191,167,114},
{1094,1899,178,191,167,114},
{1276,1910,178,191,167,114},
{1458,1932,178,191,167,114},
{1640,1938,178,191,167,114},
{1822,1975,178,191,167,114},
{2004,2029,178,191,167,114},
{2186,2029,178,191,167,114},
{2368,2032,178,191,167,114},
{548,1905,178,191,167,114},
{184,2096,178,191,167,114},
{2,2150,178,191,167,114},
{366,2096,178,191,167,114},
{730,1905,178,191,167,114},
{912,1905,178,191,167,114},
{1094,2094,178,190,167,114},
{1276,2105,178,190,167,114},
{1458,2127,178,190,167,114},
{1640,2133,178,190,167,114},
{1822,2170,178,190,167,114},
{2004,2224,178,190,167,114},
{2186,2224,178,190,167,114},
{2368,2227,178,190,167,114},
{548,2100,178,190,167,114},
{184,2291,178,190,167,114},
{2,2345,178,190,167,114},
{366,2291,178,190,167,114},
{730,2100,178,190,167,114},
{912,2100,178,190,167,114},
{1094,2288,178,190,167,114},
{1276,2299,178,190,167,114},
{1458,2321,178,190,167,114},
{1640,2327,178,190,167,114},
{1822,2364,178,190,167,114},
{2004,2418,178,190,167,114},
{2186,2418,178,190,167,114},
{2368,2421,178,190,167,114},
{548,2294,178,190,167,114},
{184,2485,178,190,167,114},
{2,2539,178,190,167,114},
{366,2485,178,190,167,114},
{730,2294,178,190,167,114},
{912,2294,178,190,167,114},
{1094,2482,178,190,167,114},
{1276,2493,178,190,167,114},
{1458,2515,178,190,167,114},
{1640,2521,178,190,167,114},
{1822,2558,178,190,167,114},
{2004,2612,178,190,167,114},
{2186,2612,178,190,167,114},
{2368,2615,178,190,167,114},
{548,2488,178,190,167,114},
{184,2679,178,190,167,114},
{2,2733,178,190,167,114},
{366,2679,178,190,167,114},
{730,2488,178,190,167,114},
{912,2488,178,190,167,114},
{912,2488,178,190,167,114},
{912,2488,178,190,167,114},
{1094,2676,178,190,167,114},
{1276,2687,178,190,167,114},
{1276,2687,178,190,167,114},
{1276,2687,178,190,167,114},
{1458,2709,178,190,167,114},
{1640,2715,178,190,167,114},
{1822,2752,178,190,167,114},
{2004,2806,178,190,167,114},
{2186,2806,178,190,167,114},
{2368,2809,178,190,167,114},
{2368,2809,178,190,167,114},
{2368,2809,178,190,167,114},
{548,2682,178,190,167,114},
{184,2873,178,190,167,114},
{2,2927,178,190,167,114},
{366,2873,178,190,167,114},
{730,2682,178,190,167,114},
{912,2682,178,190,167,114},
{912,2682,178,190,167,114},
{912,2682,178,190,167,114},
{1094,2870,178,190,167,114},
{1276,2881,178,190,167,114},
{1458,2903,178,190,167,114},
{1640,2909,178,190,167,114},
{1822,2946,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2004,3000,178,190,167,114},
{2186,3000,178,190,167,114},
{2186,3000,178,190,167,114},
{2186,3000,178,190,167,114},
{2186,3000,178,190,167,114},
{2186,3000,178,190,167,114},
{184,3067,141,153,186,115},
{2,3121,141,153,186,115},
{329,3067,141,153,186,115},
{691,3034,141,153,186,115},
{836,3034,141,153,186,115},
{981,3064,141,153,186,115},
{1126,3064,141,153,186,115},
{1271,3075,141,153,186,115},
{1416,3097,141,153,186,115},
{1561,3103,141,153,186,115},
{691,3191,141,153,186,115},
{836,3191,141,153,186,115},
{474,3192,141,153,186,115},
{981,3221,141,153,186,115},
{474,3192,141,153,186,115},
{1126,3221,141,153,186,115},
{1271,3232,141,153,186,115},
{1706,3140,141,152,186,116},
{728,838,141,154,186,115},
{548,2876,141,154,186,115},
{1195,836,140,156,186,114},
{838,2876,140,154,186,115},
{1869,1116,141,156,186,114},
{693,2876,141,154,186,115},
{1416,3254,141,153,186,114},
{548,3034,139,154,187,113},
{1561,3260,139,152,187,114},
{1851,3140,136,150,188,116},
{147,3224,132,147,189,117},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
{0,0,0,0,0,0},
}},
},
    }
    app.killEffect = app.createKillEffectPlayer(media, collections)
end
-- END KILL EFFECT

-- Visual 标签页
local visualBody = app.createSection(visualFrame, "Visual")

-- Hit Marker 总开关(关闭时立刻隐藏所有池内标记并终止其动画,防止标记卡死在屏幕上)
createModernToggle(visualBody, "Hit Marker", app.HITMARKER_ENABLED, function(v)
    app.HITMARKER_ENABLED = v
    if not v and app.hitmarkerPool then
        app.hitmarkerSeq += 1 -- 使所有进行中的 token 校验失效,动画自行终止
        for _, m in ipairs(app.hitmarkerPool) do
            m.Gui.Visible = false
            m.Busy = false
        end
    end
end)

-- Hit Marker 位置模式:Centre 屏幕中心 / Impact Point 命中点跟随
app.createDropdown(visualBody, "Hit Marker", {"Centre", "Impact Point"}, app.HITMARKER_MODE, function(v)
    app.HITMARKER_MODE = v
end)

createModernToggle(visualBody, "Hit effect", app.HIT_EFFECT_ENABLED, function(v)
    app.HIT_EFFECT_ENABLED = v
    if not v and app.hideHitEffect then app.hideHitEffect() end
end)
app.createColorPickerRow(visualBody, "Hit effect Color", app.HIT_EFFECT_COLOR, function(c)
    app.HIT_EFFECT_COLOR = c
end, "HIT_EFFECT_COLOR", app.HIT_EFFECT_TRANSPARENCY, function(v)
    app.HIT_EFFECT_TRANSPARENCY = v
end, "HIT_EFFECT_TRANSPARENCY")

createModernToggle(visualBody, "Kill effect", app.KILL_EFFECT_ENABLED, function(v)
    app.KILL_EFFECT_ENABLED = v
    app.killEffect.OptionsChanged()
end)
do
    local collectionControl
    app.createDropdown(visualBody, "Kill effect style", {"Valorant", "Battlefield 1"}, app.KILL_EFFECT_STYLE, function(v)
        app.KILL_EFFECT_STYLE = v
        if collectionControl then collectionControl.Holder.Visible = v == "Valorant" end
        app.killEffect.OptionsChanged()
    end)
    collectionControl = app.createDropdown(visualBody, "Collection Style", app.KILL_EFFECT_COLLECTIONS, app.KILL_EFFECT_COLLECTION, function(v)
        app.KILL_EFFECT_COLLECTION = table.find(app.KILL_EFFECT_COLLECTIONS, v) and v or "2021 Vandal"
        app.killEffect.OptionsChanged()
    end)
    collectionControl.Holder.Visible = app.KILL_EFFECT_STYLE == "Valorant"
end
createSlider(visualBody, "Kill Sounds Volume", 0, 5, app.KILL_SOUNDS_VOLUME, 1, function(value)
    app.killEffect.SetVolume(value)
end, true)

createModernToggle(visualBody, "Show Impact", app.SHOW_IMPACT_ENABLED, function(v)
    app.SHOW_IMPACT_ENABLED = v
    if app.setImpactVisible then app.setImpactVisible(v) end
end)
app.createColorPickerRow(visualBody, "Impact Color", app.SHOW_IMPACT_COLOR, function(c)
    app.SHOW_IMPACT_COLOR = c
    if app.updateImpactMarker then app.updateImpactMarker() end
end, "SHOW_IMPACT_COLOR", app.SHOW_IMPACT_TRANSPARENCY, function(v)
    app.SHOW_IMPACT_TRANSPARENCY = v
    if app.updateImpactMarker then app.updateImpactMarker() end
end, "SHOW_IMPACT_TRANSPARENCY")
app.createDropdown(visualBody, "Impact Material", app.SHOW_IMPACT_MATERIAL_OPTIONS, app.SHOW_IMPACT_MATERIAL, function(v)
    app.SHOW_IMPACT_MATERIAL = v
    if app.updateImpactMarker then app.updateImpactMarker() end
end)
createSlider(visualBody, "Impact Size", 0.1, 5, app.SHOW_IMPACT_SIZE, 2, function(v)
    app.SHOW_IMPACT_SIZE = math.clamp(v, 0.1, 5)
    if app.updateImpactMarker then app.updateImpactMarker() end
end, true)

createModernToggle(visualBody, "Spread FOV", app.SPREAD_FOV_ENABLED, function(v)
    app.SPREAD_FOV_ENABLED = v
    if app.setSpreadVisible then app.setSpreadVisible(v) end
end)
app.createColorPickerRow(visualBody, "Spread FOV Color", app.SPREAD_FOV_COLOR, function(c)
    app.SPREAD_FOV_COLOR = c
    if app.updateSpreadFov then app.updateSpreadFov() end
end, "SPREAD_FOV_COLOR", app.SPREAD_FOV_TRANSPARENCY, function(v)
    app.SPREAD_FOV_TRANSPARENCY = v
    if app.updateSpreadFov then app.updateSpreadFov() end
end, "SPREAD_FOV_TRANSPARENCY")

-- 配置加载与手动点击共用同一个启用入口；控件创建本身不执行 callback。
do
    local function restoreArms()
        if armsChamsThread then
            armsChamsThread:Disconnect()
            armsChamsThread = nil
        end
        for part, props in pairs(app.armsOriginalProps) do
            if part and part.Parent then
                app.xpcallw(function()
                    part.Color = props.Color
                    part.Material = props.Material
                end, "ArmsChams恢复")
            end
        end
        table.clear(app.armsOriginalProps)
    end

    local function applyArms()
        if not armsChamsEnabled or not gui.Parent then return end
        local camera = Workspace.CurrentCamera
        local viewmodel = camera and camera:FindFirstChild("Viewmodel")
        for part in pairs(app.armsOriginalProps) do
            if not part.Parent then app.armsOriginalProps[part] = nil end
        end
        if not viewmodel then return end
        for _, name in ipairs({"Left Arm", "Right Arm"}) do
            local part = viewmodel:FindFirstChild(name)
            if part and part:IsA("BasePart") then
                app.xpcallw(function()
                    if not app.armsOriginalProps[part] then
                        app.armsOriginalProps[part] = {Color = part.Color, Material = part.Material}
                    end
                    part.Material = Enum.Material.ForceField
                    part.Color = app.armsChamsColor
                end, "ArmsChams")
            end
        end
    end

    local function setEnabled(value)
        armsChamsEnabled = value == true
        if armsChamsEnabled then
            if not armsChamsThread then armsChamsThread = RunService.RenderStepped:Connect(applyArms) end
            applyArms()
        else
            restoreArms()
        end
    end

    createModernToggle(visualBody, "Arms Chams", armsChamsEnabled, setEnabled, nil, {
        {app.armsChamsColor, function(c) app.armsChamsColor = c; applyArms() end, "armsChamsColor"},
    })
    setEnabled(armsChamsEnabled)
    gui.Destroying:Connect(restoreArms) -- 只清理效果，不把保存的开关改成 false。
end

function app.resetCharacterChams()
    for part, props in pairs(originalProperties) do
        if part and part.Parent then
            part.Material = props.Material
            part.Color = props.Color
        end
    end
    table.clear(originalProperties)
end

function app.applyCharacterChams()
    if not LocalPlayer.Character then return end
    local character = LocalPlayer.Character
    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            if not originalProperties[descendant] then
                originalProperties[descendant] = {
                    Material = descendant.Material,
                    Color = descendant.Color
                }
            end
            descendant.Material = Enum.Material.ForceField
            descendant.Color = app.characterChamsColor
        end
    end
end

local characterChamsToggleControl = createModernToggle(visualBody, "Character Chams", characterChamsEnabled, function(v)
    characterChamsEnabled = v
    if v then
        if not characterChamsThread then
            characterChamsThread = RunService.RenderStepped:Connect(function()
                if characterChamsEnabled and LocalPlayer.Character then
                    app.applyCharacterChams()
                end
            end)
        end
    else
        if characterChamsThread then
            characterChamsThread:Disconnect()
            characterChamsThread = nil
        end
        app.resetCharacterChams()
    end
end, nil, {
    {app.characterChamsColor, function(c) app.characterChamsColor = c end, "characterChamsColor"},
})

-- Tool Chams（do-end 块内 local 不占用顶层名额）
do
    local toolChamsEnabled = app.cheatGPTConfigValue("toolChamsEnabled", false)
    local toolChamsThread = nil
    local toolOriginalProps = {}

    local function applyToolChams()
        local camera = Workspace.CurrentCamera
        local viewmodel = camera and camera:FindFirstChild("Viewmodel")
        if not viewmodel then return end
        -- Viewmodel 下所有层级(含嵌套 Model)里的 BasePart 都改;逐部件 xpcallw:
        -- 某个部件改材质报错不会中断遍历(曾因此出现"颜色改了但材质没改"——错误中断了整帧循环)
        for _, sub in ipairs(viewmodel:GetDescendants()) do
            if sub:IsA("BasePart") then
                -- 只处理 Model 之下的部件(Left Arm/Right Arm 等直接子级是 Arms Chams 的活)
                local p = sub.Parent
                local underModel = false
                while p and p ~= viewmodel do
                    if p:IsA("Model") then
                        underModel = true
                        break
                    end
                    p = p.Parent
                end
                if underModel then
                    app.xpcallw(function()
                        if not toolOriginalProps[sub] then
                            toolOriginalProps[sub] = {Color = sub.Color, Material = sub.Material}
                        end
                        sub.Color = app.toolChamsColor
                        sub.Material = Enum.Material.ForceField
                    end, "ToolChams")
                end
            end
        end
    end

    createModernToggle(visualBody, "Tool Chams", toolChamsEnabled, function(v)
        toolChamsEnabled = v
        app.CONFIG_EXTRA.toolChamsEnabled = v
        if v then
            if not toolChamsThread then
                toolChamsThread = RunService.RenderStepped:Connect(function()
                    if toolChamsEnabled then
                        applyToolChams()
                    end
                end)
            end
        else
            if toolChamsThread then
                toolChamsThread:Disconnect()
                toolChamsThread = nil
            end
            -- 恢复原颜色和材质
            for part, props in pairs(toolOriginalProps) do
                if part and part.Parent then
                    part.Color = props.Color
                    part.Material = props.Material
                end
            end
            table.clear(toolOriginalProps)
        end
    end, nil, {
        {app.toolChamsColor, function(c) app.toolChamsColor = c end, "toolChamsColor"},
    })
end

-- Bullet Trace / Accelerate Muzzle Velocity：四变体共享 CastRay 发射入口，容器监听负责兜底。
-- 不枚举 GC、不 hook CreateBullet：避免把扫描到的原函数备份再次 hook 成递归链。
do
    local bulletTraceEnabled = app.cheatGPTConfigValue("bulletTraceEnabled", false)
    local traceShowSelection = type(app.cheatGPTConfigValue("traceShowSelection", nil)) == "table"
        and app.cheatGPTConfigValue("traceShowSelection", nil) or {Self = true, Others = true}
    local pipelineReady = false
    local generation = 0
    local watched = {}
    local seen = setmetatable({}, {__mode = "k"})
    local pending = 0
    local MAX_PENDING = 128
    local queue = {}
    local bridge = nil
    local worker = nil
    local remoteBindings = {}
    local recent = {parts = {}, remote = {}, fire = {}}
    local MAX_PER_FRAME = 24

    function app.isBulletTraceEnabled()
        return bulletTraceEnabled == true
    end

    createModernToggle(visualBody, "Bullet Trace", bulletTraceEnabled, function(v)
        bulletTraceEnabled = v
        app.CONFIG_EXTRA.bulletTraceEnabled = v
        app.refreshCreateBulletHookState()
    end)
    app.createColorPickerRow(visualBody, "Self Bullet Color", app.TRACE_SELF_COLOR, function(c)
        app.TRACE_SELF_COLOR = c
    end, "TRACE_SELF_COLOR", app.TRACE_SELF_TRANSPARENCY, function(v)
        app.TRACE_SELF_TRANSPARENCY = v
    end, "TRACE_SELF_TRANSPARENCY")
    app.createColorPickerRow(visualBody, "Others Bullet Color", app.TRACE_OTHERS_COLOR, function(c)
        app.TRACE_OTHERS_COLOR = c
    end, "TRACE_OTHERS_COLOR", app.TRACE_OTHERS_TRANSPARENCY, function(v)
        app.TRACE_OTHERS_TRANSPARENCY = v
    end, "TRACE_OTHERS_TRANSPARENCY")

    -- Show 多选：Self=自己的子弹，Others=其他玩家的子弹
    app.createMultiDropdown(visualBody, "Show", {"Self", "Others"}, traceShowSelection, function(selection)
        traceShowSelection = selection
        app.CONFIG_EXTRA.traceShowSelection = selection
    end, "traceShowSelection")

    -- Trace Lifetime 滑条（从 Rage 栏移到 Visual 栏）
    createSlider(visualBody, "Trace Lifetime", 0, 20, app.TRACE_LIFETIME, 1, function(v)
        app.TRACE_LIFETIME = v
    end)

    -- Trace Width 滑条（调整我们 beam 的粗细；textbox 输入也钳制在 0-3，不允许超过 3 或小于 0）
    createSlider(visualBody, "Trace Width", 0.05, 1, app.TRACE_WIDTH, 2, function(v)
        app.TRACE_WIDTH = math.clamp(v, 0, 3)
    end)

    -- Trace Style:Basic 保留 ACS 原版 tracer 纹理, Styled 使用自定义轨迹纹理。
    app.createDropdown(visualBody, "Trace Style", {"Basic", "Styled"}, app.TRACE_STYLE, function(v)
        app.TRACE_STYLE = v == "Styled" and "Styled" or "Basic"
    end)

    local function stripOriginalEffects(part)
        -- deferred 回调在 ACS 完成 Name/Shape/ApplyImpulse 后执行；无需为每颗子弹挂监听。
        for _, effect in ipairs(part:GetDescendants()) do
            if effect:IsA("Trail") or effect:IsA("Beam") or effect:IsA("BillboardGui") then
                effect:Destroy()
            end
        end
    end

    local function validVector(value)
        return typeof(value) == "Vector3" and value.X == value.X and value.Y == value.Y
            and value.Z == value.Z and value.Magnitude < math.huge
    end

    local function rememberShot(list, record)
        local now = os.clock()
        for i = #list, 1, -1 do
            if now - list[i].time > 0.35 or list[i].token ~= generation then table.remove(list, i) end
        end
        if #list >= MAX_PENDING then table.remove(list, 1) end
        list[#list + 1] = record
    end

    -- 广播和物理部件一对一配对；同一玩家的连发/霰弹不使用时间戳整批去重。
    local function pairShot(record, candidates)
        if record.pair then return record.pair end
        for _, other in ipairs(candidates) do
            if not other.pair and other.token == record.token and other.origin and record.origin
                and math.abs(record.time - other.time) <= 0.35
                and (record.owner == other.owner or record.owner == "Server" or other.owner == "Server")
                and (record.origin - other.origin).Magnitude <= 3
                and (not record.direction or not other.direction or record.direction:Dot(other.direction) >= 0.995) then
                record.pair, other.pair = other, record
                return other
            end
        end
    end

    local function findFire(record)
        local best, distance
        for _, fire in ipairs(recent.fire) do
            local delta = math.abs(record.time - fire.time)
            if not fire.claimed and fire.token == record.token and fire.owner == record.owner
                and delta <= 0.25 and (fire.origin - record.origin).Magnitude <= 8
                and (not distance or delta < distance) then
                best, distance = fire, delta
            end
        end
        return best
    end

    local function drawShot(record, selfBullet, endPos)
        local filter = {tracesFolder}
        if record.part then filter[#filter + 1] = record.part end
        if Workspace.CurrentCamera then filter[#filter + 1] = Workspace.CurrentCamera end
        local shooter = Players:FindFirstChild(record.owner)
        if shooter and shooter.Character then filter[#filter + 1] = shooter.Character end
        -- 他人的子弹仍可命中本地角色；只排除实际射手和 ACS 临时效果目录。
        local acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
        if acsWorkspace then
            for _, name in ipairs({"Client", "Server"}) do
                local folder = acsWorkspace:FindFirstChild(name)
                if folder then filter[#filter + 1] = folder end
            end
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = filter
        if not endPos then
            local ray = record.direction * 1000
            local result = Workspace:Raycast(record.origin, ray, params)
            endPos = result and result.Position or record.origin + ray
        end
        local fire = not selfBullet and not record.fallback and findFire(record)
        if fire and fire.drawn and fire.root and fire.root.Parent then
            -- 真实弹道迟到时修正已有预测线，不再叠画，也不重启淡入/淡出。
            fire.a0.WorldPosition, fire.a1.WorldPosition = record.origin, endPos
            record.drawn, record.root, record.a0, record.a1 = true, fire.root, fire.a0, fire.a1
        else
            record.drawn, record.root, record.a0, record.a1 = app.createForwardBeamToPoint(record.origin, endPos, selfBullet)
        end
        if record.drawn then
            if fire then fire.claimed, record.fire = true, fire end
            local part = record.part or (record.pair and record.pair.part)
            if part and part.Parent then stripOriginalEffects(part) end
        end
    end

    local function processFire(record)
        if record.token ~= generation or not pipelineReady or not gui.Parent
            or not bulletTraceEnabled or not traceShowSelection.Others or record.claimed then return end
        -- Atirar 可以比真实数据晚到；先复用已绘制的对应弹道。
        for _, list in ipairs({recent.remote, recent.parts}) do
            for _, shot in ipairs(list) do
                if shot.drawn and not shot.fire and not (shot.pair and shot.pair.fire)
                    and shot.token == record.token and shot.owner == record.owner
                    and math.abs(shot.time - record.time) <= 0.25
                    and (shot.origin - record.origin).Magnitude <= 8 then
                    record.claimed, shot.fire = true, record
                    return
                end
            end
        end
        drawShot(record, false)
    end

    local function processRemote(record)
        if record.token ~= generation or not pipelineReady or not gui.Parent
            or not bulletTraceEnabled or not traceShowSelection.Others then return end
        local partRecord = pairShot(record, recent.parts)
        if partRecord and partRecord.drawn then return end
        drawShot(record, false)
    end

    local function processBullet(record)
        local part = record.part
        if record.token ~= generation or not pipelineReady or not gui.Parent then return end
        if not (bulletTraceEnabled or muzzleBoostEnabled) then return end
        if typeof(part) ~= "Instance" or not part:IsA("Part") then return end
        if record.fromFramework then
            -- 游戏线程只传递引用；实例和相机的读取必须在本脚本的消费者线程内执行。
            local context = record.context
            record.shotOrigin = type(context) == "table" and context[1]
                or (Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position)
            if type(context) == "table" and validVector(context[2]) and context[2].Magnitude > 0 then
                record.direction = context[2].Unit
            end
        end
        if part.Name:sub(-6) == "_Laser" then return end
        for _ = 1, 3 do
            if part.Shape == Enum.PartType.Ball and part.Name:sub(-7) == "_Bullet" then break end
            if not part.Parent then return end
            task.wait()
            if record.token ~= generation then return end
        end
        if part.Shape ~= Enum.PartType.Ball or part.Name:sub(-7) ~= "_Bullet" then return end
        local selfBullet = part.Name == LocalPlayer.Name .. "_Bullet"
        local showTrace = bulletTraceEnabled and traceShowSelection[selfBullet and "Self" or "Others"] == true
        if not showTrace and not (selfBullet and muzzleBoostEnabled and record.fromFramework) then return end
        local origin = record.origin or part.Position
        record.origin, record.owner = origin, part.Name:sub(1, -8)
        local velocity = record.velocity or part.AssemblyLinearVelocity
        if velocity.Magnitude < 1 then velocity = part.AssemblyLinearVelocity end
        local direction = record.direction
        for _ = 1, 3 do
            if direction or velocity.Magnitude >= 1 or not part.Parent then break end
            task.wait()
            if record.token ~= generation then return end
            velocity = part.AssemblyLinearVelocity
        end
        if record.token ~= generation or not gui.Parent then return end
        showTrace = bulletTraceEnabled and traceShowSelection[selfBullet and "Self" or "Others"] == true
        direction = direction or (velocity.Magnitude >= 1 and velocity.Unit or nil)
        record.direction = direction
        if not selfBullet and showTrace then
            rememberShot(recent.parts, record)
            local remote = pairShot(record, recent.remote)
            if remote and (remote.drawn or not remote.finished) then
                if remote.drawn and part.Parent then stripOriginalEffects(part) end
                return -- 广播已持有方向，即使原生部件速度为 0 也由广播绘制。
            end
        end
        -- 已销毁部件仍可读取最终 Position；入口保存的枪口位置不会随物理步丢失。
        if not part.Parent then
            if showTrace and (part.Position - origin).Magnitude > 0.01 then
                drawShot(record, selfBullet, part.Position)
            elseif showTrace and direction then
                drawShot(record, selfBullet, origin + direction * 1000)
            end
            return
        end
        if not direction then return end
        if selfBullet and muzzleBoostEnabled and record.fromFramework and not record.cancelAcceleration then
            if app.doInstantHit(part, showTrace, origin, direction, record.shotOrigin, function()
                record.claimed = true -- 销毁后立即通知入口，不等待 InvokeServer 返回。
            end) then return end
        end
        if not showTrace then return end
        drawShot(record, selfBullet)
    end

    local function enqueueBullet(part)
        -- 此函数也由 ACS 游戏线程调用：只操作 Lua 状态，不读取任何 Instance，不派生任务。
        if not pipelineReady or not (bulletTraceEnabled or muzzleBoostEnabled) or part == nil then return nil end
        if seen[part] then return type(seen[part]) == "table" and seen[part] or nil end
        if pending >= MAX_PENDING then return nil end
        local record = {part = part, token = generation, time = os.clock()}
        seen[part] = record
        pending += 1
        queue[#queue + 1] = record
        return record
    end

    local function observeBullet(part)
        -- 监听在本脚本线程创建；这里才允许检查实例及派生快照任务。
        if typeof(part) ~= "Instance" or not part:IsA("Part") then return end
        local record = enqueueBullet(part)
        if not record or record.fromFramework or record.snapshotQueued then return end
        record.snapshotQueued = true
        -- 先挂父级再赋属性；配置完成即记录枪口，不能等下一次物理步后才取起点。
        task.defer(function()
            if record.token ~= generation or not pipelineReady or record.fromFramework then return end
            if part.Shape == Enum.PartType.Ball and part.Name:sub(-7) == "_Bullet" then
                record.origin = part.Position
                local velocity = part.AssemblyLinearVelocity
                if validVector(velocity) and velocity.Magnitude >= 1 then record.velocity = velocity end
            end
        end)
    end

    local function disconnectRemote()
        for name, binding in pairs(remoteBindings) do
            binding.connection:Disconnect()
            remoteBindings[name] = nil
        end
    end

    local function acceptRemoteShooter(shooter)
        return gui.Parent and pipelineReady and bulletTraceEnabled and traceShowSelection.Others
            and shooter ~= LocalPlayer and pending < MAX_PENDING
            and (shooter == nil or (typeof(shooter) == "Instance" and shooter:IsA("Player")))
    end

    local function onServerBullet(shooter, origin, direction)
        if not acceptRemoteShooter(shooter) then return end
        if not validVector(origin) or not validVector(direction) or direction.Magnitude < 0.001 then return end
        local record = {remote = true, owner = shooter and shooter.Name or "Server", origin = origin,
            direction = direction.Unit, token = generation, time = os.clock()}
        rememberShot(recent.remote, record)
        pending += 1
        queue[#queue + 1] = record
    end

    local function onRemoteFire(shooter, weapon)
        if not acceptRemoteShooter(shooter) or not shooter or not shooter.Character then return end
        if typeof(weapon) ~= "Instance" then return end
        -- 原生 Atirar 使用角色里的 S<武器名>.Handle.Muzzle；只使用已复制的枪口，不猜头部朝向。
        local character = shooter.Character
        local model = character:FindFirstChild("S" .. weapon.Name)
            or (weapon.Parent == character and weapon)
        local handle = model and model:FindFirstChild("Handle")
        local muzzle = handle and handle:FindFirstChild("Muzzle")
        if not muzzle then return end
        local cf = muzzle:IsA("Attachment") and muzzle.WorldCFrame or (muzzle:IsA("BasePart") and muzzle.CFrame)
        if not cf or not validVector(cf.Position) or not validVector(cf.LookVector) or cf.LookVector.Magnitude < 0.001 then return end
        local now = os.clock()
        local record = {fallback = true, owner = shooter.Name, origin = cf.Position, direction = cf.LookVector.Unit,
            token = generation, time = now, readyAt = now + 0.1}
        rememberShot(recent.fire, record)
        pending += 1
        queue[#queue + 1] = record
    end

    local function bindRemote()
        if not pipelineReady or not bulletTraceEnabled then disconnectRemote(); return end
        local engine = ReplicatedStorage:FindFirstChild("ACS_Engine")
        local events = engine and engine:FindFirstChild("Events")
        for name, handler in pairs({ServerBullet = onServerBullet, Atirar = onRemoteFire}) do
            local remote = events and events:FindFirstChild(name)
            if remote and not (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then remote = nil end
            local binding = remoteBindings[name]
            if binding and (binding.remote ~= remote or not binding.connection.Connected) then
                binding.connection:Disconnect()
                remoteBindings[name] = nil
                binding = nil
            end
            if remote and not binding then
                remoteBindings[name] = {remote = remote, connection = remote.OnClientEvent:Connect(handler)}
            end
        end
    end

    local function restoreBridge()
        if bridge then
            if bridge.env.CastRay == bridge.wrapper then
                app.ensureTableWritable(bridge.env)
                bridge.env.CastRay = bridge.original
            end
            bridge = nil
        end
    end

    local function bindBridge()
        if not pipelineReady then return end
        if not (bulletTraceEnabled or muzzleBoostEnabled) then restoreBridge(); return end
        -- 重生后只在框架对象变化时重新读取依赖，不逐发请求 AccessId。
        local current = app.findMainScript()
        if not current then restoreBridge(); return end
        if current ~= env or not modTable or not accessId then
            if not app.initEnvironment() then restoreBridge(); return end
            current = env
        end
        if bridge and bridge.env == current and current.CastRay == bridge.wrapper then return end
        restoreBridge()
        if type(current.CastRay) ~= "function" then return end
        local original = current.CastRay
        local wrapper = function(...)
            local part, origin, context = ...
            local record = enqueueBullet(part)
            if record then
                record.fromFramework = true
                record.origin = origin
                record.context = context
                if muzzleBoostEnabled then
                    -- 让执行器自己的 Heartbeat 消费队列先处理；原版飞行循环尚未开始。
                    -- 超时/关开关/队列异常均放行原版，绝不永久阻塞开枪。
                    local deadline = os.clock() + 0.25
                    while not record.finished and not record.claimed
                        and record.token == generation and pipelineReady and os.clock() < deadline do
                        task.wait() -- 不从游戏调用线程访问 RunService/Heartbeat 等 Instance。
                    end
                    if record.claimed then return end
                    record.cancelAcceleration = true
                end
            end
            return original(...)
        end
        app.ensureTableWritable(current)
        current.CastRay = wrapper
        bridge = {env = current, original = original, wrapper = wrapper}
    end

    local function disconnectContainers()
        for name, record in pairs(watched) do
            record.connection:Disconnect()
            watched[name] = nil
        end
    end

    local function bindContainers()
        local acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
        for _, name in ipairs({"Client", "Server"}) do
            local folder = acsWorkspace and acsWorkspace:FindFirstChild(name)
            local record = watched[name]
            if record and (record.folder ~= folder or not record.connection.Connected) then
                record.connection:Disconnect()
                watched[name] = nil
                record = nil
            end
            if folder and not record then
                watched[name] = {folder = folder, connection = folder.DescendantAdded:Connect(observeBullet)}
            end
        end
    end

    -- 保留现有开关入口名；统一维护容器监听和可还原的环境函数入口。
    function app.refreshCreateBulletHookState()
        generation += 1
        table.clear(recent.parts)
        table.clear(recent.remote)
        table.clear(recent.fire)
        if not pipelineReady then return end
        if bulletTraceEnabled or muzzleBoostEnabled then
            bindContainers()
            bindRemote()
            app.xpcallw(bindBridge, "弹道入口")
        else
            restoreBridge()
            disconnectContainers()
            disconnectRemote()
        end
        if not bulletTraceEnabled then app.clearAllBeams() end
    end

    -- 主脚本末尾启动，确保 Beam 工厂、瞬发命中及其依赖均已定义。
    function app.startBulletPipeline()
        if pipelineReady then return end
        pipelineReady = true
        gui.Destroying:Connect(function()
            pipelineReady = false -- 桥接入口只读此标记，不读取 gui.Parent。
            generation += 1
        end)
        -- 此连接在脚本自身上下文创建，绘制/伤害不在游戏函数调用线程内执行。
        worker = RunService.Heartbeat:Connect(function()
            if not pipelineReady or not gui.Parent then return end
            local count = math.min(#queue, MAX_PER_FRAME)
            for _ = 1, count do
                local record = table.remove(queue, 1)
                if record.token == generation and record.readyAt and os.clock() < record.readyAt then
                    queue[#queue + 1] = record
                else
                    task.spawn(function()
                        app.xpcallw(record.fallback and processFire or (record.remote and processRemote or processBullet), "BulletTrace", record)
                        record.finished = true
                        if record.part then seen[record.part] = true end
                        pending -= 1
                    end)
                end
            end
        end)
        app.refreshCreateBulletHookState()
        task.spawn(function()
            while pipelineReady and gui.Parent do
                task.wait(0.5)
                if pipelineReady and gui.Parent and (bulletTraceEnabled or muzzleBoostEnabled) then
                    app.xpcallw(bindContainers, "BulletTrace维护")
                    app.xpcallw(bindRemote, "远程弹道维护")
                    app.xpcallw(bindBridge, "弹道入口维护")
                end
            end
            pipelineReady = false
            generation += 1
            restoreBridge()
            if worker then worker:Disconnect() end
            for _, record in ipairs(queue) do record.finished = true; pending -= 1 end
            table.clear(queue)
            disconnectContainers()
            disconnectRemote()
            table.clear(recent.parts)
            table.clear(recent.remote)
            table.clear(recent.fire)
        end)
    end
end

-- PC 第三人称鼠标转向修复(do-end 块内 local 不占用顶层名额):
-- 部分 ACS 服开第三人称后鼠标被隐藏、镜头无法正常转动(装备时框架把 MouseIconEnabled 关了,
-- 而 Classic 相机默认要按住右键才转)。后台线程监听视角缩放:
-- PC(非触屏) + 相机距角色 > 1 studs(非第一人称) + 手持 ACS 枪(角色下存在 ACS_Client)
-- → 每帧强制 MouseBehavior=LockCenter,Roblox 默认相机脚本随即接管旋转,效果同第一人称;
-- 回到第一人称或收枪后停止并恢复 Default;GUI 打开期间不抢鼠标
do
    local tpLookForcing = false
    task.spawn(function()
        while true do
            app.xpcallw(function()
                if UserInputService.TouchEnabled then return end -- 触屏不需要,锁中还会挡住 UI 触摸
                local c = LocalPlayer.Character
                local cam = Workspace.CurrentCamera
                local hrp = c and c:FindFirstChild("HumanoidRootPart")
                local holdingGun = c ~= nil and c:FindFirstChild("ACS_Client") ~= nil
                local thirdPerson = cam ~= nil and hrp ~= nil
                    and (cam.CFrame.Position - hrp.Position).Magnitude > 1
                if holdingGun and thirdPerson and not mainGuiVisible then
                    tpLookForcing = true
                    if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
                        UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
                    end
                elseif tpLookForcing then
                    tpLookForcing = false
                    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end
            end, "第三人称鼠标")
            if tpLookForcing then
                RunService.Heartbeat:Wait() -- 激活期每帧重设,防游戏脚本改回
            else
                task.wait(0.25)
            end
        end
    end)
end

-- ========== LocalPlayer 标签页（含 Fly 和 Spin） ==========
local localBody = app.createSection(localFrame, "Movement")

-- Fly 功能
local flyToggleControl = createModernToggle(localBody, "Fly", flyEnabled, function(v)
    flyEnabled = v
    if v then
        startFly()
    else
        stopFly()
    end
end, "Fly")

local flySpeedSliderControl = createSlider(localBody, "Fly Speed", 1, 100, flySpeed, 0, function(v)
    flySpeed = v
end)

-- Speed（TP Walk，滑条数值≈每秒 studs）
createModernToggle(localBody, "Speed", speedEnabled, function(v)
    speedEnabled = v
end)

local walkSpeedSliderControl = createSlider(localBody, "Speed Value", 0, 80, targetWalkSpeed, 0, function(v)
    targetWalkSpeed = v
end)

-- Noclip（do-end 块内 local 不占用顶层名额）
do
    local noclipConn = nil
    local noclipEnabled = app.cheatGPTConfigValue("noclipEnabled", false)
    app.CONFIG_EXTRA.noclipEnabled = noclipEnabled
    createModernToggle(localBody, "Noclip", noclipEnabled, function(v)
        noclipEnabled = v
        app.CONFIG_EXTRA.noclipEnabled = v
        if v then
            if noclipConn then noclipConn:Disconnect() end
            noclipConn = RunService.Stepped:Connect(function()
                local c = LocalPlayer.Character
                if not c then return end
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end)
        else
            if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
            local c = LocalPlayer.Character
            if c then
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                        part.CanCollide = true
                    end
                end
            end
        end
    end, "Noclip")
end

-- Only the native ACS overlays and ringing are muted. Outgoing suppression
-- events (including Battlefield suppression assists) are left intact.
function app.createSuppressionGuard()
    local guard, records = {}, {}
    local playerGui, added, muteGroup
    local active = false
    local function release(object)
        local record = records[object]
        if not record then return end
        records[object] = nil
        for _, connection in ipairs(record.Connections) do connection:Disconnect() end
        pcall(function()
            if record.Sound then
                if object.SoundGroup == muteGroup then object.SoundGroup = record.Group end
            else
                object.Visible = record.Visible
            end
        end)
    end
    local function matches(object)
        if not playerGui or not object:IsDescendantOf(playerGui) then return false, false end
        local effects = object.Parent
        local isOverlay = object:IsA("ImageLabel") and (object.Name == "Suppress" or object.Name == "Dirty")
            and effects and effects.Name == "Efeitos" and effects.Parent
            and effects.Parent.Name == "StatusUI" and effects.Parent.Parent == playerGui
        local isRing = object:IsA("Sound") and object.Name == "EarRing" and object.Parent == playerGui
        return isOverlay, isRing
    end
    local function inspect(object)
        if not active or records[object] then return end
        local isOverlay, isRing = matches(object)
        if not isOverlay and not isRing then return end
        local record = {Connections = {}, Sound = isRing}
        records[object] = record
        if isRing then
            record.Group = object.SoundGroup
            object.SoundGroup = muteGroup -- native Volume tweens cannot undo this
        else
            record.Visible = object.Visible
            object.Visible = false
            record.Connections[#record.Connections + 1] = object:GetPropertyChangedSignal("Visible"):Connect(function()
                if active and object.Visible then object.Visible = false end
            end)
        end
        local function changedScope()
            local overlay, ring = matches(object)
            if not overlay and not ring then release(object) end
        end
        record.Connections[#record.Connections + 1] = object.AncestryChanged:Connect(changedScope)
        record.Connections[#record.Connections + 1] = object:GetPropertyChangedSignal("Name"):Connect(changedScope)
    end
    local function unbind()
        if added then added:Disconnect(); added = nil end
        for object in pairs(records) do release(object) end
        playerGui = nil
    end
    function guard.Refresh()
        if not active then return end
        local current = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui == current then return end
        unbind()
        playerGui = current
        if not playerGui then return end
        added = playerGui.DescendantAdded:Connect(function(object)
            inspect(object)
            task.defer(function() inspect(object) end) -- parent-before-name creation
        end)
        for _, object in ipairs(playerGui:GetDescendants()) do inspect(object) end
    end
    function guard.Set(value)
        active = value == true
        if not active then unbind(); return end
        if not muteGroup then
            muteGroup = Instance.new("SoundGroup")
            muteGroup.Name = "CGT_SuppressionMute"
            muteGroup.Volume = 0
            muteGroup.Parent = game:GetService("SoundService")
        end
        guard.Refresh()
    end
    function guard.Destroy()
        guard.Set(false)
        if muteGroup then muteGroup:Destroy(); muteGroup = nil end
    end
    return guard
end

-- Constants identify the render callback, NOT its upvalue ordering. Executor
-- builds may capture GunCFrame where an offline compiler captured walking bob.
function app.isSteadyRender(constants)
    local names = {}
    for _, value in pairs(constants) do if type(value) == "string" then names[value] = true end end
    return names.GunModelFixed and names.GetMouseDelta and names.sin and names.cos and names.Lerp
end

function app.steadySmallTransform(value)
    if typeof(value) ~= "CFrame" then return false end
    local _, angle = value:ToAxisAngle()
    return value.Position.Magnitude <= 0.5 and math.abs(angle) <= 0.3
end

-- Match the native simple/1-4 bob equations over several read-only frames.
-- Idle uses alpha 0.1 or 1; walking uses alpha 0.1 and the captured run speed.
function app.matchSteadyBob(before, after, startAt, endAt, speeds)
    if not app.steadySmallTransform(before) or not app.steadySmallTransform(after)
        or before == after or endAt - startAt > 0.02 then return false end
    local function close(expected)
        return (expected.Position - after.Position).Magnitude < 0.00008
            and (expected.LookVector - after.LookVector).Magnitude < 0.0003
            and (expected.UpVector - after.UpVector).Magnitude < 0.0003
    end
    for step = 0, 4 do
        local at = startAt + (endAt - startAt) * step / 4
        local idle = CFrame.new(math.sin(at * 1.5) * 0.005, math.cos(at * 2.5) * 0.005, 0)
        if close(before:Lerp(idle, 0.1)) or close(idle) then return true end
        for index, speed in pairs(speeds) do
            if speed > 0 and speed <= 128 then
                local walk = CFrame.new(speed * 0.0025 * math.sin(at * 8), speed * 0.0025 * math.cos(at * 16), 0)
                    * CFrame.Angles(math.rad(speed * 0.1 * math.sin(at * 16)), math.rad(speed * 0.1 * math.cos(at * 8)), 0)
                if close(before:Lerp(walk, 0.1)) then return true, index end
            end
        end
    end
    return false
end

function app.runSteadyFrame(record, status, ...)
    if not app.STEADY_AIM or not record.Enabled then return record.Original(...) end
    local before, speeds, saved, pinned = {}, {}, nil, false
    local observe = not record.Slot and os.clock() >= (record.NextSample or 0)
    local inspected, inspectError = pcall(function()
        if record.Slot then
            saved = debug.getupvalue(record.Original, record.Slot)
            -- A weapon/closure replacement must be learned again before writing.
            if saved ~= record.LastNative or not app.steadySmallTransform(saved) then
                record.Slot, record.Streak = nil, nil
                return
            end
            if record.SpeedSlot then
                local speed = debug.getupvalue(record.Original, record.SpeedSlot)
                if type(speed) == "number" then speeds[record.SpeedSlot] = speed end
            else
                for index in pairs(record.SpeedCandidates or {}) do
                    local speed = debug.getupvalue(record.Original, index)
                    if type(speed) == "number" then speeds[index] = speed end
                end
            end
            debug.setupvalue(record.Original, record.Slot, CFrame.new())
            pinned = true
        elseif observe then
            record.NextSample = os.clock() + 0.1
            local values = debug.getupvalues(record.Original)
            -- Read candidates through the same indexed API used for writes.
            -- Do not assume getupvalues array keys and getupvalue indices agree.
            local count = 0
            for index in pairs(values) do if type(index) == "number" then count = math.max(count, index) end end
            for index = 1, math.min(count, 200) do
                local value = debug.getupvalue(record.Original, index)
                if app.steadySmallTransform(value) then before[index] = value
                elseif type(value) == "number" and value >= 0 and value <= 128 then speeds[index] = value end
            end
        end
    end)
    if not inspected then status.State = "Bob inspection failed: " .. tostring(inspectError) end
    local startAt = tick()
    local result = table.pack(pcall(record.Original, ...))
    local endAt = tick()
    local checked, checkError = pcall(function()
        if pinned then
            local value = debug.getupvalue(record.Original, record.Slot)
            local valid, speedSlot = app.matchSteadyBob(CFrame.new(), value, startAt, endAt, speeds)
            if result[1] and valid then
                record.LastNative = value
                record.SpeedSlot = speedSlot or record.SpeedSlot
                status.Pins += 1
                status.LastPin, status.State = os.clock(), "Verified bob suppression"
            else
                -- A skipped/failed native update must not leave our identity in
                -- a persistent transform. Keep native writes when it did update.
                if value == CFrame.new() then debug.setupvalue(record.Original, record.Slot, saved) end
                record.Slot, record.Streak = nil, nil
                status.State = "Rechecking native bob"
            end
        elseif observe and inspected and result[1] then
            local matched, matchedSpeed, matches = nil, nil, 0
            for index, value in pairs(before) do
                local after = debug.getupvalue(record.Original, index)
                local valid, speedSlot = app.matchSteadyBob(value, after, startAt, endAt, speeds)
                if valid then matches += 1; matched, matchedSpeed = index, speedSlot end
            end
            if matches == 1 then
                record.Streak = record.Candidate == matched and (record.Streak or 0) + 1 or 1
                record.Candidate = matched
                if record.Streak >= 4 then
                    record.Slot, record.SpeedSlot = matched, matchedSpeed
                    record.SpeedCandidates = speeds
                    record.LastNative = debug.getupvalue(record.Original, matched)
                    status.State = "Native bob verified"
                end
            else record.Streak, record.Candidate = nil, nil end
        end
    end)
    if not checked then
        if pinned then
            local restored, err = pcall(function()
                if debug.getupvalue(record.Original, record.Slot) == CFrame.new() then
                    debug.setupvalue(record.Original, record.Slot, saved)
                end
            end)
            if not restored then status.State = "Bob restore failed: " .. tostring(err) end
        end
        record.Slot, record.Streak = nil, nil
        status.State = "Bob verification failed: " .. tostring(checkError)
    end
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

function app.createSteadyAimController()
    local control, hooks = {}, {}
    local nextGcScan = 0
    app.steadyAimStatus = {Hooks = 0, Pins = 0, State = "Off"}
    local status = app.steadyAimStatus
    local function refresh()
        if control.Stopped then return end
        if not app.STEADY_AIM then control.Clear(); return end
        if type(app.collectFrameworkEnvs) ~= "function" then return end
        local environments, scripts = {}, {}
        for _, e in ipairs(app.collectFrameworkEnvs()) do
            environments[e] = true
            if typeof(e.script) == "Instance" then scripts[e.script] = true end
        end
        local ok, connections = pcall(getconnections, RunService.RenderStepped)
        if not ok or type(connections) ~= "table" then connections = {} end
        local gcFunctions, hasReadableAcs = {}, false
        for _, connection in ipairs(connections) do
            local fnOK, fn = pcall(function() return connection.Function end)
            if fnOK and type(fn) == "function" then
                local envOK, e = pcall(getfenv, fn)
                if envOK and type(e) == "table" and (environments[e] or scripts[e.script]) then hasReadableAcs = true; break end
            end
        end
        -- Some mobile executors hide connection.Function. A throttled GC scan
        -- can still locate the same script-owned closure by its verified shape.
        if not hasReadableAcs and next(hooks) == nil and type(getgc) == "function" and os.clock() >= nextGcScan then
            nextGcScan = os.clock() + 5
            local gcOK, objects = pcall(getgc, false)
            if gcOK and type(objects) == "table" then
                local candidates = table.clone(connections)
                for index, object in ipairs(objects) do
                    if type(object) == "function" then
                        local envOK, e = pcall(getfenv, object)
                        if envOK and type(e) == "table" and (environments[e] or scripts[e.script]) then
                            candidates[#candidates + 1] = {Function = object}
                            gcFunctions[object] = true
                        end
                    end
                    if index % 500 == 0 then
                        task.wait()
                        if control.Stopped or not app.STEADY_AIM then return end
                    end
                end
                connections = candidates
            end
        end
        local seen = {}
        for fn, record in pairs(hooks) do
            if record.FromGC and record.Script and record.Script.Parent then
                record.Enabled, seen[fn] = true, true
            end
        end
        for _, connection in ipairs(connections) do
            local readable, fn = pcall(function() return connection.Function end)
            if readable and type(fn) == "function" then
                local existing = hooks[fn]
                if existing then
                    if not existing.Script or existing.Script.Parent then
                        existing.Enabled = true
                        seen[fn] = true
                    end
                else
                    local envOK, e = pcall(getfenv, fn)
                    if envOK and type(e) == "table" and (environments[e] or scripts[e.script]) then
                        local constantsOK, constants = pcall(debug.getconstants, fn)
                        if constantsOK and app.isSteadyRender(constants) then
                            local record = {Script = e.script, Enabled = true, FromGC = gcFunctions[fn] == true}
                            local original, hook = app.installHookFunction(fn, function(...)
                                return app.runSteadyFrame(record, status, ...)
                            end, "Steady Aim render")
                            if original and hook then
                                record.Original, record.Hook = original, hook
                                hooks[fn], seen[fn] = record, true
                            end
                        end
                    end
                end
            end
        end
        local count = 0
        for fn, record in pairs(hooks) do
            if not seen[fn] then
                record.Enabled = false
                if app.restoreHookFunction(record.Hook) then hooks[fn] = nil end
            else count += 1 end
        end
        status.Hooks = count
        if count == 0 then status.State = "Waiting for supported ACS viewmodel"
        elseif status.State == "Off" or status.State == "Waiting for supported ACS viewmodel" then
            status.State = "Observing native bob (no writes yet)"
        end
    end
    function control.Refresh()
        if control.Busy then return end
        control.Busy = true
        local ok, err = pcall(refresh)
        control.Busy = false
        if not ok then error(err) end
    end
    function control.Clear()
        for fn, record in pairs(hooks) do
            record.Enabled = false
            if app.restoreHookFunction(record.Hook) then hooks[fn] = nil end
        end
        status.Hooks, status.State = 0, "Off"
    end
    function control.Destroy()
        control.Stopped = true
        control.Clear()
    end
    return control
end

function app.createLocalWeaponOptions()
    local control, records = {}, {}
    local function clearJam(e)
        local settings = app.rapidFindSettings(e)
        if settings and settings.Jammed then
            app.ensureTableWritable(settings)
            settings.Jammed = false -- native mutable state, not CanBreak/JamChance tuning
            if type(e.UpdateGui) == "function" then pcall(e.UpdateGui) end
        end
        return settings
    end
    local function restore(e, record)
        app.ensureTableWritable(e)
        if record.Jam and e.JamChance == record.Jam then e.JamChance = record.OriginalJam end
        record.Jam, record.Settings = nil, nil
    end
    function control.Refresh()
        if type(app.collectFrameworkEnvs) ~= "function" or type(app.rapidFindSettings) ~= "function" then return end
        local seen = {}
        if app.NO_MALFUNCTION then
            for _, e in ipairs(app.collectFrameworkEnvs()) do
                seen[e] = true
                local record = records[e] or {}
                records[e] = record
                app.ensureTableWritable(e)
                if app.NO_MALFUNCTION and type(e.JamChance) == "function" then
                    if e.JamChance ~= record.Jam then
                        record.OriginalJam = e.JamChance
                        record.Jam = function() clearJam(e) end
                        e.JamChance = record.Jam
                    end
                    record.Settings = clearJam(e)
                elseif record.Jam then
                    if e.JamChance == record.Jam then e.JamChance = record.OriginalJam end
                    record.Jam, record.Settings = nil, nil
                end

            end
        end
        for e, record in pairs(records) do
            if not seen[e] then restore(e, record); records[e] = nil end
        end
    end
    function control.PinJam()
        if not app.NO_MALFUNCTION then return end
        for _, record in pairs(records) do
            if record.Settings and record.Settings.Jammed then
                app.ensureTableWritable(record.Settings)
                record.Settings.Jammed = false
            end
        end
    end
    function control.Destroy()
        for e, record in pairs(records) do restore(e, record); records[e] = nil end
    end
    return control
end

do
    local suppression = app.createSuppressionGuard()
    local weapons = app.createLocalWeaponOptions()
    local steady = app.createSteadyAimController()
    app.refreshSteadyAim = steady.Refresh
    createModernToggle(localBody, "No Suppression", app.NO_SUPPRESSION, function(value)
        app.NO_SUPPRESSION = value
        suppression.Set(value)
    end)
    app.gateExecutorToggle(createModernToggle(localBody, "No Malfunction", app.NO_MALFUNCTION, function(value)
        app.NO_MALFUNCTION = value
        weapons.Refresh()
    end), "getsenv", "debug.getupvalues")
    app.gateExecutorToggle(createModernToggle(localBody, "Steady Aim", app.STEADY_AIM, function(value)
        app.STEADY_AIM = value
        steady.Refresh()
    end), "getsenv", "getconnections/getgc", "getfenv", "debug.getconstants", "debug.getupvalues", "debug.getupvalue", "debug.setupvalue", "hookfunction", "newcclosure")
    suppression.Set(app.NO_SUPPRESSION)
    local elapsed = 0.5
    local heartbeat = RunService.Heartbeat:Connect(function(dt)
        app.xpcallw(weapons.PinJam, "No Malfunction")
        elapsed += dt
        if elapsed < 0.5 then return end
        elapsed = 0
        app.xpcallw(suppression.Refresh, "No Suppression")
        app.xpcallw(weapons.Refresh, "Local weapon options")
        app.xpcallw(steady.Refresh, "Steady Aim")
    end)
    gui.Destroying:Connect(function()
        heartbeat:Disconnect()
        suppression.Destroy()
        weapons.Destroy()
        steady.Destroy()
        app.lifetimeStats.Flush()
    end)
end

-- No Recoil（替换框架全局 Recoil + mod 表清零双保险）
local noRecoilToggleControl = app.gateExecutorToggle(createModernToggle(localBody, "No Recoil", noRecoilEnabled, function(v)
    noRecoilEnabled = v
    if v then
        app.xpcallw(app.applyNoRecoil, "NoRecoil")
    else
        app.xpcallw(app.restoreNoRecoil, "NoRecoil恢复")
    end
end), "getsenv", "debug.getupvalues")

-- No Spread
local noSpreadToggleControl = app.gateExecutorToggle(createModernToggle(localBody, "No Spread", noSpreadEnabled, function(v)
    noSpreadEnabled = v
    if v then
        app.xpcallw(app.refreshModTables, "NoSpread")
    end
    if not v then
        local ok = app.xpcallw(function()
            if env and type(env.resetMods) == "function" then env.resetMods() end
        end, "resetMods")
        if not ok and modTable then
            app.xpcallw(function()
                modTable.MinSpread = 1
                modTable.MaxSpread = 1
                modTable.SpreadRM = 1
                modTable.AimInaccuracyStepAmount = 1
                modTable.AimInaccuracyDecrease = 1
            end, "NoSpread恢复")
        end
    end
end), "getsenv", "debug.getupvalues")

-- Accelerate Muzzle Velocity：CastRay 入口暂缓原飞行循环，由自己的 Heartbeat 队列
-- 在初速就绪后射线接管；依赖缺失、关闭或超时则恢复原版处理。
local muzzleBoostToggleControl = app.gateExecutorToggle(createModernToggle(localBody, "Accelerate Muzzle Velocity", muzzleBoostEnabled, function(v)
    muzzleBoostEnabled = v
    app.refreshCreateBulletHookState()
end), "getsenv", "debug.getupvalues")

-- Rapid Fire（不改表版：hook wait 把射击节流替换为自定义射速；Settings 上值换浅拷贝副本 ShootType=3 实现全自动。
-- 旧版改 Settings 表 ShootRate 被服务器校验拒收,本版发送的表完全是原值）
local rapidFireToggleControl = app.gateExecutorToggle(createModernToggle(localBody, "Rapid Fire", rapidFireEnabled, function(v)
    rapidFireEnabled = v
    if v then
        app.xpcallw(app.installRapidFireWaitHook, "RapidFire")
        app.xpcallw(app.applyRapidFireMode, "RapidFire")
    else
        app.xpcallw(app.restoreRapidFireMode, "RapidFire还原")
    end
end), "getsenv", "hookfunction", "newcclosure", "getcallingscript", "debug.getupvalues", "debug.setupvalue")

-- Infinite Ammo（不改表:弹匣弹药是 Shoot 函数的脚本级上值,射击时内联自减(v_u_8 = v_u_8 - 1),
-- 没有"减子弹函数"可 hook;改为每帧把弹匣上值钉回满弹——自减被即刻覆盖丢弃,效果等同 hook 丢弃返回空。
-- 弹药状态纯客户端维护(重装备回满的 bug 证明服务器不校验),钉客户端上值即可）
local infiniteAmmoToggleControl = app.gateExecutorToggle(createModernToggle(localBody, "Infinite Ammo", infiniteAmmoEnabled, function(v)
    infiniteAmmoEnabled = v
    if v then
        app.xpcallw(app.identifyInfiniteAmmo, "InfiniteAmmo")
        app.xpcallw(app.pinInfiniteAmmo, "InfiniteAmmo")
    end
end), "getsenv", "debug.getupvalues", "debug.setupvalue")

-- Instant Aim（瞄准 FOV 补间时间归零;v1/v2 改共享 TweenInfo 上值,v3 钉 AimZoomSpeed 数值上值,见专节）
app.gateExecutorToggle(createModernToggle(localBody, "Instant Aim", instantAimEnabled, function(v)
    instantAimEnabled = v
    if v then
        app.xpcallw(app.applyInstantAim, "InstantAim")
    else
        app.xpcallw(app.restoreInstantAim, "InstantAim还原")
    end
end), "getsenv", "debug.getupvalues", "debug.getupvalue", "debug.setupvalue")

-- Instant Equip（替换框架 EquipAnim 为直接置"可行动"标志,跳过整段装备动画,拿枪零延迟）
app.gateExecutorToggle(createModernToggle(localBody, "Instant Equip", instantEquipEnabled, function(v)
    instantEquipEnabled = v
    if v then
        app.xpcallw(app.applyInstantEquip, "InstantEquip")
    else
        app.xpcallw(app.restoreInstantEquip, "InstantEquip还原")
    end
end), "getsenv", "debug.getupvalues", "debug.setupvalue", "hookfunction", "newcclosure")

-- 3rd Cam
local camToggleControl = createModernToggle(localBody, "3rd Cam", thirdPersonCamEnabled, function(v)
    if isApplyingCam then return end
    isApplyingCam = true
    thirdPersonCamEnabled = v
    if v then
        originalCamMinZoom = LocalPlayer.CameraMinZoomDistance
        originalCamMaxZoom = LocalPlayer.CameraMaxZoomDistance
        LocalPlayer.CameraMode = Enum.CameraMode.Classic
        LocalPlayer.CameraMinZoomDistance = 0.5
        LocalPlayer.CameraMaxZoomDistance = 999999
    else
        LocalPlayer.CameraMode = Enum.CameraMode.Classic
        LocalPlayer.CameraMinZoomDistance = originalCamMinZoom
        LocalPlayer.CameraMaxZoomDistance = originalCamMaxZoom
    end
    isApplyingCam = false
end)

-- SpinBot
local spinToggleControl = createModernToggle(localBody, "SpinBot", spinEnabled, function(v)
    spinEnabled = v
    if v then
        startSpin()
    else
        stopSpin()
    end
end, "SpinBot")

local spinSpeedSliderControl = createSlider(localBody, "Spin Speed", 0, 100, spinSpeed, 0, function(v)
    spinSpeed = v
    if spinning then
        -- 如果正在旋转，立即更新速度
        if spinBody and spinBody.Parent then
            spinBody.AngularVelocity = Vector3.new(0, spinSpeed, 0)
        end
    end
end)

-- ========== PlayersList 选项卡 ==========
local playersBody = app.createSection(playersFrame, "Players")

local roleStateByUserId = {}

local function getRoleForPlayer(player)
    if player == LocalPlayer then
        return "Local"
    end

    local saved = roleStateByUserId[player.UserId]
    if saved then
        return saved
    end

    local lowerName = player.Name:lower()
    if friendSet[lowerName] then
        return "Friend"
    end
    if enemySet[lowerName] then
        return "Enemy"
    end
    return "None"
end

local function applyRoleForPlayer(player, role)
    if player == LocalPlayer then
        return
    end

    roleStateByUserId[player.UserId] = role

    local lowerName = player.Name:lower()
    friendSet[lowerName] = nil
    enemySet[lowerName] = nil

    if role == "Friend" then
        friendSet[lowerName] = true
    elseif role == "Enemy" then
        enemySet[lowerName] = true
    end
    -- 角色修改同时更新持久化名单；saveCheatGPTConfig 内部再次清理交集。
    app.scheduleCheatGPTSave()
end

local function getRoleColor(role)
    if role == "Friend" then
        return app.THEME.green
    elseif role == "Enemy" then
        return app.THEME.red
    elseif role == "Local" then
        return app.THEME.accentSoft
    end
    return app.THEME.sub
end

-- 玩家列表用自动高度的普通 Frame(不用嵌套 ScrollingFrame):滚动统一交给外层页面,修复玩家多时内层列表拉不到最底部
local playerList = Instance.new("Frame")
playerList.Name = app.randomName()
playerList.Size = UDim2.new(1, 0, 0, 0)
playerList.AutomaticSize = Enum.AutomaticSize.Y
playerList.BackgroundTransparency = 1
playerList.BorderSizePixel = 0
playerList.Parent = playersBody

local playerLayout = Instance.new("UIListLayout")
playerLayout.Padding = UDim.new(0, 6)
playerLayout.SortOrder = Enum.SortOrder.LayoutOrder
playerLayout.Parent = playerList

-- Every player receives a renderable rbxthumb URI immediately, including players
-- already present at injection. Thumbnail generation/preload cannot block rows.
app.avatarThumbCache = {}
do
    local records, queries, stopped = {}, 0, false
    local warm = Instance.new("Frame")
    warm.Name = "AvatarPreload"
    warm.BackgroundTransparency = 1
    warm.Size = UDim2.fromOffset(2, 2)
    warm.Parent = gui
    function app.cachePlayerAvatar(player, image)
        if stopped or player.Parent ~= Players then return end
        local id = player.UserId
        local record = records[id]
        if not record then
            record = {Player = player, URI = "rbxthumb://type=AvatarHeadShot&id=" .. id .. "&w=150&h=150", NextQuery = 0, Images = {}, Generated = false}
            records[id] = record
            app.avatarThumbCache[id] = record.URI
            local preload = Instance.new("ImageLabel")
            preload.Name = "Avatar" .. id
            preload.BackgroundTransparency = 1
            preload.ImageTransparency = 0.999
            preload.Size = UDim2.fromOffset(2, 2)
            preload.Parent = warm
            record.Warm = preload
            app.cachePlayerAvatar(player, preload)
        end
        if not image or record.Images[image] then return end
        image.Image = record.URI
        record.Images[image] = image.Destroying:Connect(function() record.Images[image] = nil end)
        app.bindAsyncImage(image, function()
            if not record.Generated and not record.Querying and queries < 4 and os.clock() >= record.NextQuery then
                record.Querying = true
                queries += 1
                task.spawn(function()
                    local ok, uri, generated = pcall(Players.GetUserThumbnailAsync, Players, id, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
                    queries -= 1
                    record.Querying, record.NextQuery = false, os.clock() + 20
                    if stopped or records[id] ~= record then return end
                    if ok and generated and type(uri) == "string" and uri ~= "" then
                        record.Generated = true
                        record.URI, app.avatarThumbCache[id] = uri, uri
                        for target in pairs(record.Images) do target.Image = uri end
                    elseif not ok then app.recordDebugError("Avatar " .. id, uri) end
                end)
            end
            return record.URI
        end, "Avatar: " .. id, nil, function() return not record.Generated end)
    end
    local function release(record)
        for _, connection in pairs(record.Images) do connection:Disconnect() end
        table.clear(record.Images)
        record.Warm:Destroy()
    end
    local added = Players.PlayerAdded:Connect(app.cachePlayerAvatar)
    local removed = Players.PlayerRemoving:Connect(function(player)
        local record = records[player.UserId]
        records[player.UserId], app.avatarThumbCache[player.UserId] = nil, nil
        if record then release(record) end
    end)
    gui.Destroying:Connect(function()
        stopped = true
        added:Disconnect(); removed:Disconnect()
        for _, record in pairs(records) do release(record) end
        table.clear(records)
        warm:Destroy()
    end)
    for _, player in ipairs(Players:GetPlayers()) do app.cachePlayerAvatar(player) end
    if app.welcomeAvatar then app.cachePlayerAvatar(LocalPlayer, app.welcomeAvatar) end
end

local playerRows = {}

local function createRoleDropdown(player, roleButton)
    -- 浮动面板:与全部 Dropdown 统一样式/动画;选项固定 Friend/Enemy/None 顺序(LayoutOrder 排序,不再随机)
    local dropdown = app.createDropdownPanel(92)

    roleButton.InputBegan:Connect(function(input)
        if app.isPressInput(input) then
            dropdownPressGuard = os.clock()
        end
    end)

    local function setRole(role)
        applyRoleForPlayer(player, role)
        roleButton.Text = role
        roleButton.TextColor3 = getRoleColor(role)
        closeOpenedDropdown()
    end

    for index, role in ipairs({"Friend", "Enemy", "None"}) do
        local option = app.createDropdownOption(dropdown, index)
        option.Text = role
        option.TextColor3 = getRoleColor(role)

        option.Activated:Connect(function()
            setRole(role)
        end)
    end

    roleButton.Activated:Connect(function()
        if os.clock() < (roleButton:GetAttribute("ContextMenuUntil") or 0) then return end
        if player == LocalPlayer then
            return
        end

        if openedDropdown == dropdown then
            closeOpenedDropdown()
        else
            app.openDropdownAnimated(dropdown, roleButton, true)
        end
    end)

    return dropdown
end

-- 玩家复制菜单：全列表共享一个浮层；自己也可以选中并复制资料。
do
    local menu = app.createDropdownPanel(210)
    local selectedPlayer, selectedRow
    local press
    local heldMenuInput, heldMenuButton
    local fields = {
        {label = "Copy display name", key = "DisplayName"},
        {label = "Copy username", key = "Name"},
        {label = "Copy user ID", key = "UserId"},
    }
    local function selectPlayer(player, row)
        if selectedRow and selectedRow.Parent then selectedRow.BackgroundColor3 = app.THEME.panel end
        selectedPlayer, selectedRow = player, row
        row.BackgroundColor3 = app.THEME.section2
    end
    local function showMenu(player, row)
        if not row.Parent or not tabFrames.PlayersList.Visible then return end
        selectPlayer(player, row)
        dropdownPressGuard = os.clock()
        app.openDropdownAnimated(menu, row, true)
    end
    for index, field in ipairs(fields) do
        local option = app.createDropdownOption(menu, index)
        option.Text = field.label
        option.Size = UDim2.new(1, 0, 0, 44)
        if not app.EXEC_SUPPORT["setclipboard"] then option.TextTransparency = 0.55 end
        option.Activated:Connect(function()
            if not selectedPlayer then return end
            if not app.EXEC_SUPPORT["setclipboard"] then
                app.notifyUnsupportedFunc("setclipboard")
                return
            end
            local ok = app.xpcallw(setclipboard, "玩家复制", tostring(selectedPlayer[field.key]))
            if ok then
                closeOpenedDropdown()
                app.showNotification("CheatGPT.cc", "Copied: " .. tostring(selectedPlayer[field.key]), 2)
            end
        end)
    end
    -- 不为每行建立全局移动监听；触屏只维护当前一根手指的长按状态。
    UserInputService.InputChanged:Connect(function(input)
        if press and input == press.input and (input.Position - press.position).Magnitude > 10 then
            press = nil
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if press and input == press.input then press = nil end
        if input == heldMenuInput then
            if heldMenuButton and heldMenuButton.Parent then
                heldMenuButton:SetAttribute("ContextMenuUntil", os.clock() + 0.3)
            end
            heldMenuInput, heldMenuButton = nil, nil
        end
    end)
    tabFrames.PlayersList:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        press = nil
    end)
    tabFrames.PlayersList:GetPropertyChangedSignal("Visible"):Connect(function()
        if not tabFrames.PlayersList.Visible then press = nil end
    end)
    Players.PlayerRemoving:Connect(function(player)
        if press and press.player == player then press = nil end
        if selectedPlayer == player then
            if openedDropdown == menu then closeOpenedDropdown(true) end
            selectedPlayer, selectedRow = nil, nil
        end
    end)
    function app.bindPlayerContextMenu(player, row, roleButton)
        row.Active = true
        local function began(input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                showMenu(player, row)
            elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
                selectPlayer(player, row)
            elseif input.UserInputType == Enum.UserInputType.Touch then
                if press and press.input == input then return end
                selectPlayer(player, row)
                local current = {input = input, position = input.Position, player = player}
                press = current
                task.delay(0.5, function()
                    if press ~= current or not row.Parent or not mainGuiVisible then return end
                    if input.UserInputState == Enum.UserInputState.End
                        or input.UserInputState == Enum.UserInputState.Cancel then return end
                    if (input.Position - current.position).Magnitude > 10 then return end
                    press = nil
                    -- 抬手产生 Activated 时不要又打开角色下拉。
                    heldMenuInput, heldMenuButton = input, roleButton
                    roleButton:SetAttribute("ContextMenuUntil", math.huge)
                    showMenu(player, row)
                end)
            end
        end
        row.InputBegan:Connect(began)
        roleButton.InputBegan:Connect(began)
    end
end

local function createPlayerRow(player)
    local row = Instance.new("Frame")
    row.Name = app.randomName()
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BackgroundColor3 = app.THEME.panel
    row.BorderSizePixel = 0
    row.ClipsDescendants = false
    row.Parent = playerList
    app.addCorner(row, 7)
    app.addStroke(row, app.THEME.line, 1, 0.55)

    -- 玩家虚拟形象头像(异步加载,失败不阻塞列表)
    local avatar = Instance.new("ImageLabel")
    avatar.Name = "Avatar"
    avatar.Size = UDim2.new(0, 20, 0, 20)
    avatar.Position = UDim2.new(0, 5, 0.5, -10)
    avatar.BackgroundColor3 = app.THEME.section
    avatar.BorderSizePixel = 0
    avatar.Parent = row
    app.addCorner(avatar, 10) -- 圆形头像
    app.cachePlayerAvatar(player, avatar)

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = "NameLabel"
    nameLabel.Size = UDim2.new(1, -120, 1, 0)
    nameLabel.Position = UDim2.new(0, 30, 0, 0)
    nameLabel.BackgroundTransparency = 1
    app.applyFont(nameLabel, Enum.Font.GothamMedium)
    nameLabel.TextSize = 12
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.TextColor3 = (player == LocalPlayer) and app.THEME.green or app.THEME.text
    nameLabel.Text = (player.DisplayName or player.Name) .. " (@" .. player.Name .. ")"
    nameLabel.Parent = row

    local roleButton = Instance.new("TextButton")
    roleButton.Name = "RoleButton"
    roleButton.Size = UDim2.new(0, 78, 0, 20)
    roleButton.Position = UDim2.new(1, -84, 0.5, -10)
    roleButton.BackgroundColor3 = app.THEME.section
    roleButton.BorderSizePixel = 0
    app.applyFont(roleButton, Enum.Font.GothamMedium)
    roleButton.TextSize = 11
    roleButton.AutoButtonColor = false
    roleButton.Parent = row
    app.addCorner(roleButton, 6)
    app.addStroke(roleButton, app.THEME.line, 1, 0.45)

    local currentRole = getRoleForPlayer(player)
    roleButton.Text = currentRole
    roleButton.TextColor3 = getRoleColor(currentRole)

    if player == LocalPlayer then
        roleButton.BackgroundColor3 = app.THEME.panel
    else
        roleButton.MouseEnter:Connect(function()
            app.tween(roleButton, 0.1, {BackgroundColor3 = app.THEME.section2}):Play()
        end)

        roleButton.MouseLeave:Connect(function()
            app.tween(roleButton, 0.1, {BackgroundColor3 = app.THEME.section}):Play()
        end)
    end

    local dropdown = nil
    if player ~= LocalPlayer then
        dropdown = createRoleDropdown(player, roleButton)
    end

    app.bindPlayerContextMenu(player, row, roleButton)
    playerRows[player] = {
        Row = row,
        NameLabel = nameLabel,
        RoleButton = roleButton,
        Dropdown = dropdown,
    }
end

local function getSortedPlayers()
    local currentPlayers = Players:GetPlayers()

    table.sort(currentPlayers, function(a, b)
        if a == LocalPlayer then
            return true
        end
        if b == LocalPlayer then
            return false
        end
        return a.Name:lower() < b.Name:lower()
    end)

    return currentPlayers
end

function app.updatePlayerList()
    local currentPlayers = getSortedPlayers()

    for player, data in pairs(playerRows) do
        if not table.find(currentPlayers, player) then
            if openedDropdown == data.Dropdown then
                closeOpenedDropdown(true)
            end
            if data.Dropdown then
                data.Dropdown:Destroy()
            end
            data.Row:Destroy()
            playerRows[player] = nil
        end
    end

    for index, player in ipairs(currentPlayers) do
        if not playerRows[player] then
            createPlayerRow(player)
        end

        local data = playerRows[player]
        local currentRole = getRoleForPlayer(player)

        data.Row.LayoutOrder = index
        data.NameLabel.Text = (player.DisplayName or player.Name) .. " (@" .. player.Name .. ")"
        data.NameLabel.TextColor3 = (player == LocalPlayer) and app.THEME.green or app.THEME.text
        data.RoleButton.Text = currentRole
        data.RoleButton.TextColor3 = getRoleColor(currentRole)
    end
end

app.updatePlayerList()
Players.PlayerAdded:Connect(app.updatePlayerList)
Players.PlayerRemoving:Connect(app.updatePlayerList)

task.spawn(function()
    while gui.Parent do
        task.wait(1)
        app.updatePlayerList()
    end
end)

-- (滚动关闭已由 createPage 统一处理;外部点击关闭已由统一下拉层处理)

-- ========== Watermark ==========
app.WATERMARK_ITEMS = {"FPS", "PING", "PLAYERS", "USERNAME", "TIME", "CUSTOM", "Kills", "Score", "Runtime"}
-- Engine/client uptime, including time before this script was injected.
-- Older executors without elapsedTime fall back to the current game session.
app.clientRuntimeClock = type(elapsedTime) == "function" and elapsedTime or time
function app.orderWatermarkSelection(selection, previous)
    local ordered, seen = {}, {}
    local function append(key)
        if selection[key] == true and not seen[key] and table.find(app.WATERMARK_ITEMS, key) then
            seen[key] = true
            ordered[#ordered + 1] = key
        end
    end
    if type(previous) == "table" then for _, key in ipairs(previous) do append(key) end end
    for _, key in ipairs(app.WATERMARK_ITEMS) do append(key) end
    return ordered
end
function app.formatRuntime(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end
local watermarkEnabled = app.cheatGPTConfigValue("watermarkEnabled", true)
local watermarkCustomText = app.cheatGPTConfigValue("watermarkCustomText", "")
local watermarkSelection = type(app.cheatGPTConfigValue("watermarkSelection", nil)) == "table" and app.cheatGPTConfigValue("watermarkSelection", nil) or {
    ["FPS"] = true,
    ["PING"] = true,
    ["PLAYERS"] = false,
    ["USERNAME"] = false,
    ["TIME"] = false,
    ["CUSTOM"] = false,
}
app.CONFIG_EXTRA.watermarkEnabled = watermarkEnabled
app.CONFIG_EXTRA.watermarkCustomText = watermarkCustomText
app.CONFIG_EXTRA.watermarkSelection = watermarkSelection
app.watermarkOrder = app.orderWatermarkSelection(watermarkSelection, app.cheatGPTConfigValue("watermarkOrder", nil))
app.CONFIG_EXTRA.watermarkOrder = app.watermarkOrder
app.CONFIG_EXTRA.toolChamsEnabled = app.cheatGPTConfigValue("toolChamsEnabled", false)
app.CONFIG_EXTRA.bulletTraceEnabled = app.cheatGPTConfigValue("bulletTraceEnabled", false)

-- CanvasGroup:显隐用 GroupTransparency 淡入淡出(同主窗口),初始位置下移避开 Roblox 顶栏
local watermarkFrame = Instance.new("CanvasGroup")
watermarkFrame.Name = app.randomName()
watermarkFrame.AutomaticSize = Enum.AutomaticSize.XY
watermarkFrame.Size = UDim2.fromOffset(0, 0)
watermarkFrame.Position = UDim2.new(0, 12, 0, 44)
watermarkFrame.BackgroundColor3 = app.THEME.panel
watermarkFrame.BorderSizePixel = 0
watermarkFrame.Visible = false
watermarkFrame.GroupTransparency = 1
watermarkFrame.ZIndex = 500
watermarkFrame.Parent = gui
app.addCorner(watermarkFrame, 7)
app.addStroke(watermarkFrame, app.THEME.line, 1, 0.35)

local watermarkPadding = Instance.new("UIPadding")
watermarkPadding.PaddingLeft = UDim.new(0, 8)
watermarkPadding.PaddingRight = UDim.new(0, 10)
watermarkPadding.PaddingTop = UDim.new(0, 6)
watermarkPadding.PaddingBottom = UDim.new(0, 6)
watermarkPadding.Parent = watermarkFrame

local watermarkLayout = Instance.new("UIListLayout")
watermarkLayout.FillDirection = Enum.FillDirection.Horizontal
watermarkLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
watermarkLayout.VerticalAlignment = Enum.VerticalAlignment.Center
watermarkLayout.Padding = UDim.new(0, 6)
watermarkLayout.SortOrder = Enum.SortOrder.LayoutOrder
watermarkLayout.Parent = watermarkFrame

local watermarkLogo = Instance.new("ImageLabel")
watermarkLogo.Name = app.randomName()
watermarkLogo.Size = UDim2.fromOffset(14, 14)
watermarkLogo.BackgroundTransparency = 1
watermarkLogo.BorderSizePixel = 0
watermarkLogo.Image = "rbxassetid://93763775045380"
watermarkLogo.ScaleType = Enum.ScaleType.Crop
watermarkLogo.ZIndex = 501
watermarkLogo.Parent = watermarkFrame
app.addCorner(watermarkLogo, 4)

local watermarkLabel = Instance.new("TextLabel")
watermarkLabel.Name = app.randomName()
watermarkLabel.AutomaticSize = Enum.AutomaticSize.XY
watermarkLabel.Size = UDim2.fromOffset(0, 0)
watermarkLabel.BackgroundTransparency = 1
watermarkLabel.Text = ""
watermarkLabel.TextColor3 = app.THEME.text
app.applyFont(watermarkLabel, Enum.Font.GothamMedium)
watermarkLabel.TextSize = 12
watermarkLabel.TextXAlignment = Enum.TextXAlignment.Left
watermarkLabel.ZIndex = 501
watermarkLabel.Parent = watermarkFrame

function app.createRollingWatermark(label)
    local cells, previous = {}, ""
    label.TextTransparency = 1
    label.AutomaticSize = Enum.AutomaticSize.X
    label.Size = UDim2.fromOffset(0, label.TextSize + 4)
    local strip = Instance.new("Frame")
    strip.Name = "RollingNumbers"
    strip.BackgroundTransparency = 1
    strip.Size = UDim2.fromScale(1, 1)
    strip.Parent = label
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Parent = strip
    local function cancel(cell)
        for _, tween in ipairs(cell.Tweens) do tween:Cancel() end
        table.clear(cell.Tweens)
    end
    local function render(text, instant)
        local tokens, cursor = {}, 1
        while cursor <= #text do
            local first, last = text:find("%d+", cursor)
            if not first then tokens[#tokens + 1] = {Text = text:sub(cursor)}; break end
            if first > cursor then tokens[#tokens + 1] = {Text = text:sub(cursor, first - 1)} end
            tokens[#tokens + 1] = {Text = text:sub(first, last), Numeric = true}
            cursor = last + 1
        end
        for index, token in ipairs(tokens) do
            local cell = cells[index]
            if not cell then
                local clip = Instance.new("Frame")
                clip.BackgroundTransparency = 1
                clip.ClipsDescendants = true
                clip.ZIndex = label.ZIndex
                clip.AutomaticSize = Enum.AutomaticSize.X
                clip.Size = UDim2.new(0, 0, 1, 0)
                clip.LayoutOrder = index
                clip.Parent = strip
                cell = {Frame = clip, Tweens = {}}
                for _, name in ipairs({"Front", "Back"}) do
                    local glyph = Instance.new("TextLabel")
                    glyph.Name = name
                    glyph.BackgroundTransparency = 1
                    glyph.Size = UDim2.fromScale(1, 1)
                    if name == "Front" then
                        glyph.Size = UDim2.new(0, 0, 1, 0)
                        glyph.AutomaticSize = Enum.AutomaticSize.X
                    end
                    glyph.FontFace = label.FontFace
                    glyph.TextSize = label.TextSize
                    glyph.TextColor3 = label.TextColor3
                    glyph.TextXAlignment = Enum.TextXAlignment.Left
                    glyph.ZIndex = label.ZIndex
                    glyph.Parent = clip
                    cell[name] = glyph
                end
                cells[index] = cell
            end
            cell.Frame.Visible = true
            if cell.Text ~= token.Text then
                cancel(cell)
                local animate = not instant and cell.Numeric and token.Numeric and cell.Text ~= nil
                cell.Back.Text = cell.Text or token.Text
                cell.Front.Text = token.Text
                cell.Back.Position = UDim2.fromScale(0, 0)
                local direction = (tonumber(token.Text) or 0) >= (tonumber(cell.Text) or 0) and 1 or -1
                cell.Front.Position = UDim2.fromScale(0, animate and direction or 0)
                cell.Back.Visible = animate
                if animate then
                    cell.Tweens = {
                        app.tween(cell.Front, 0.22, {Position = UDim2.fromScale(0, 0)}),
                        app.tween(cell.Back, 0.22, {Position = UDim2.fromScale(0, -direction)}),
                    }
                    for _, tween in ipairs(cell.Tweens) do tween:Play() end
                end
            end
            cell.Text, cell.Numeric = token.Text, token.Numeric
        end
        for index = #tokens + 1, #cells do cancel(cells[index]); cells[index].Frame.Visible = false; cells[index].Text = nil end
        previous = text
    end
    local connection = label:GetPropertyChangedSignal("Text"):Connect(function()
        render(label.Text, previous == "")
    end)
    local fontChanged = label:GetPropertyChangedSignal("FontFace"):Connect(function()
        for _, cell in ipairs(cells) do
            cell.Front.FontFace, cell.Back.FontFace = label.FontFace, label.FontFace
        end
    end)
    label.Destroying:Connect(function()
        connection:Disconnect()
        fontChanged:Disconnect()
        for _, cell in ipairs(cells) do cancel(cell) end
    end)
    render(label.Text, true)
    return cells
end
app.watermarkRollingCells = app.createRollingWatermark(watermarkLabel)

app.registerResponsiveRoot(watermarkFrame, true)
watermarkLabel:GetPropertyChangedSignal("Text"):Connect(function()
    task.defer(app.refreshResponsiveUI)
end)

watermarkFrame.Active = true

local watermarkDragging = false
local watermarkDragInput = nil
local watermarkDragStart = nil
local watermarkStartPos = nil

watermarkFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        watermarkDragging = true
        watermarkDragInput = input
        watermarkDragStart = input.Position
        watermarkStartPos = watermarkFrame.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if watermarkDragging and watermarkDragInput and app.isSameDragInput(watermarkDragInput, input) then
        local delta = input.Position - watermarkDragStart
        watermarkFrame.Position = UDim2.new(
            watermarkStartPos.X.Scale,
            watermarkStartPos.X.Offset + delta.X,
            watermarkStartPos.Y.Scale,
            watermarkStartPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if watermarkDragInput and app.isDragEndInput(watermarkDragInput, input) then
        watermarkDragging = false
        watermarkDragInput = nil
        watermarkDragStart = nil
        watermarkStartPos = nil
    end
end)

local fpsValue = 0
local fpsCounter = 0
local fpsElapsed = 0

RunService.RenderStepped:Connect(function(dt)
    fpsCounter += 1
    fpsElapsed += dt
    if fpsElapsed >= 0.5 then
        fpsValue = math.floor(fpsCounter / fpsElapsed + 0.5)
        fpsCounter = 0
        fpsElapsed = 0
    end
end)

local function getPingText()
    local ok, result = app.xpcallw(function()
        local stats = game:GetService("Stats")
        local item = stats.Network.ServerStatsItem["Data Ping"]
        return item:GetValueString()
    end, "getPingText")

    if ok and result then
        local text = tostring(result)
        local num = text:match("([%d%.]+)")
        if num then
            local pingNumber = math.floor(tonumber(num) + 0.5)
            return tostring(pingNumber) .. "ms"
        end
    end

    return "N/A"
end

local function buildWatermarkText()
    local parts = {"CheatGPT.cc"}
    for _, key in ipairs(app.watermarkOrder) do
        if watermarkSelection[key] then
            local value
            if key == "FPS" then value = "FPS: " .. tostring(fpsValue)
            elseif key == "PING" then value = "Ping: " .. getPingText()
            elseif key == "PLAYERS" then value = "Players: " .. tostring(#Players:GetPlayers())
            elseif key == "USERNAME" then value = LocalPlayer.Name
            elseif key == "TIME" then value = "Time: " .. os.date("%H:%M:%S")
            elseif key == "CUSTOM" and watermarkCustomText ~= "" then value = watermarkCustomText
            elseif key == "Kills" then value = "Kills: " .. tostring(app.lifetimeStats.Kills)
            elseif key == "Score" then value = "Score: " .. tostring(app.lifetimeStats.Score)
            elseif key == "Runtime" then value = "Runtime: " .. app.formatRuntime(app.clientRuntimeClock()) end
            if value then parts[#parts + 1] = value end
        end
    end
    return table.concat(parts, " | ")
end

-- 显隐状态变量 + 淡入淡出(同主窗口模式:判断一律用状态变量,淡出动画期间 Visible 仍为 true)
app.watermarkVisible = false

function app.setWatermarkVisible(state)
    if app.watermarkVisible == state then
        return
    end
    app.watermarkVisible = state
    if state then
        watermarkFrame.Visible = true
        app.tween(watermarkFrame, 0.2, {GroupTransparency = 0}):Play()
    else
        local fadeOut = app.tween(watermarkFrame, 0.15, {GroupTransparency = 1})
        fadeOut.Completed:Connect(function()
            if not app.watermarkVisible then
                watermarkFrame.Visible = false
            end
        end)
        fadeOut:Play()
    end
end

local function refreshWatermark()
    app.setWatermarkVisible(watermarkEnabled)
    if watermarkEnabled then
        watermarkLabel.Text = buildWatermarkText()
    end
end

task.spawn(function()
    while gui.Parent do
        refreshWatermark()
        task.wait(0.25)
    end
end)

-- ========== Hitmarker（对象池：多目标同时命中各自独立显示，不再共用一个互相瞬移） ==========
do
    local POOL_SIZE = 4 -- 同时显示的标记上限,超出时抢占最旧的一个

    app.hitmarkerPool = {}
    app.hitmarkerSeq = 0

    local HM_RESET = {
        UDim2.new(0.5, -20, 0.5, -20), UDim2.new(0.5, 20, 0.5, -20),
        UDim2.new(0.5, -20, 0.5, 20), UDim2.new(0.5, 20, 0.5, 20),
    }
    local HM_ENTER = {
        UDim2.new(0.5, -12, 0.5, -12), UDim2.new(0.5, 12, 0.5, -12),
        UDim2.new(0.5, -12, 0.5, 12), UDim2.new(0.5, 12, 0.5, 12),
    }
    local HM_EXIT = {
        UDim2.new(0.5, -18, 0.5, -18), UDim2.new(0.5, 18, 0.5, -18),
        UDim2.new(0.5, -18, 0.5, 18), UDim2.new(0.5, 18, 0.5, 18),
    }

    local function createHitmarker()
        local markerGui = Instance.new("Frame")
        markerGui.Name = app.randomName()
        markerGui.Size = UDim2.fromOffset(60, 60)
        markerGui.AnchorPoint = Vector2.new(0.5, 0.5)
        markerGui.Position = UDim2.new(0.5, 0, 0.5, 0)
        markerGui.BackgroundTransparency = 1
        markerGui.Visible = false
        markerGui.ZIndex = 300
        markerGui.Parent = gui
        app.registerResponsiveRoot(markerGui, false)

        local parts = {}
        local corners = {
            {0.5, -14, 0.5, -14, 45}, {0.5, 14, 0.5, -14, -45},
            {0.5, -14, 0.5, 14, -45}, {0.5, 14, 0.5, 14, 45},
        }
        for _, c in ipairs(corners) do
            local line = Instance.new("Frame")
            line.Name = app.randomName()
            line.Size = UDim2.fromOffset(14, 2)
            line.AnchorPoint = Vector2.new(0.5, 0.5)
            line.Position = UDim2.new(c[1], c[2], c[3], c[4])
            line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
            line.BorderSizePixel = 0
            line.Rotation = c[5]
            line.BackgroundTransparency = 1
            line.ZIndex = 301
            line.Parent = markerGui

            local stroke = Instance.new("UIStroke")
            stroke.Color = Color3.fromRGB(0, 0, 0)
            stroke.Thickness = 1
            stroke.Transparency = 1
            stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            stroke.Parent = line

            table.insert(parts, {Line = line, Stroke = stroke})
        end

        return {Gui = markerGui, Parts = parts, Token = 0, Busy = false, FollowPart = nil}
    end

    local hitEffectEdges = {}
    local function createHitEffectEdge(size, position, rotation, reverse)
        local edge = Instance.new("Frame")
        edge.Name = app.randomName()
        edge.Size = size
        edge.Position = position
        edge.BackgroundColor3 = app.HIT_EFFECT_COLOR
        edge.BackgroundTransparency = 1
        edge.BorderSizePixel = 0
        edge.ZIndex = 280
        edge.Parent = gui
        local gradient = Instance.new("UIGradient")
        gradient.Rotation = rotation
        gradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, reverse and 1 or 0),
            NumberSequenceKeypoint.new(0.72, reverse and 0.45 or 0.45),
            NumberSequenceKeypoint.new(1, reverse and 0 or 1),
        })
        gradient.Parent = edge
        return edge
    end

    hitEffectEdges[1] = createHitEffectEdge(UDim2.new(1, 0, 0, 96), UDim2.new(0, 0, 0, 0), 90, false)
    hitEffectEdges[2] = createHitEffectEdge(UDim2.new(1, 0, 0, 96), UDim2.new(0, 0, 1, -96), 90, true)
    hitEffectEdges[3] = createHitEffectEdge(UDim2.new(0, 96, 1, -192), UDim2.new(0, 0, 0, 96), 0, false)
    hitEffectEdges[4] = createHitEffectEdge(UDim2.new(0, 96, 1, -192), UDim2.new(1, -96, 0, 96), 0, true)
    app.hitEffectToken = 0
    local hitFovTween
    local hitFovBase

    function app.hideHitEffect()
        app.hitEffectToken += 1
        for _, edge in ipairs(hitEffectEdges) do
            edge.Visible = false
            edge.BackgroundTransparency = 1
        end
        if hitFovTween then hitFovTween:Cancel(); hitFovTween = nil end
        local camera = Workspace.CurrentCamera
        if camera and hitFovBase then
            hitFovTween = TweenService:Create(camera, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                FieldOfView = hitFovBase,
            })
            hitFovTween:Play()
        end
        hitFovBase = nil
    end

    function app.showHitEffect()
        if not app.HIT_EFFECT_ENABLED then return end
        app.hitEffectToken += 1
        local token = app.hitEffectToken
        local camera = Workspace.CurrentCamera
        if camera then
            if not hitFovBase then hitFovBase = camera.FieldOfView end
            if hitFovTween then hitFovTween:Cancel() end
            hitFovTween = TweenService:Create(camera, TweenInfo.new(0.028, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                FieldOfView = math.min(120, hitFovBase + 3.5),
            })
            hitFovTween:Play()
            task.delay(0.045, function()
                if token ~= app.hitEffectToken or not camera.Parent or not hitFovBase then return end
                if hitFovTween then hitFovTween:Cancel() end
            hitFovTween = TweenService:Create(camera, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    FieldOfView = hitFovBase,
                })
                hitFovTween:Play()
                hitFovTween.Completed:Connect(function()
                    if token == app.hitEffectToken then hitFovTween = nil; hitFovBase = nil end
                end)
            end)
        end
        for _, edge in ipairs(hitEffectEdges) do
            edge.BackgroundColor3 = app.HIT_EFFECT_COLOR
            edge.BackgroundTransparency = math.min(1, app.HIT_EFFECT_TRANSPARENCY + 0.08)
            edge.Visible = true
            TweenService:Create(edge, TweenInfo.new(0.025, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                BackgroundTransparency = app.HIT_EFFECT_TRANSPARENCY,
            }):Play()
        end
        task.delay(0.08, function()
            if token ~= app.hitEffectToken then return end
            for _, edge in ipairs(hitEffectEdges) do
                local fade = TweenService:Create(edge, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                    BackgroundTransparency = 1,
                })
                fade.Completed:Connect(function()
                    if token == app.hitEffectToken then edge.Visible = false end
                end)
                fade:Play()
            end
        end)
    end

    for _ = 1, POOL_SIZE do
        table.insert(app.hitmarkerPool, createHitmarker())
    end

    -- 同一目标(followPart)连续命中→复用其标记(不闪);否则取空闲的;全忙时抢占序号最旧的(其动画被 token 校验自然取消)
    local function acquireHitmarker(followPart)
        if followPart then
            for _, m in ipairs(app.hitmarkerPool) do
                if m.Busy and m.FollowPart == followPart then
                    return m, true
                end
            end
        end
        local oldest, oldestToken = app.hitmarkerPool[1], math.huge
        for _, m in ipairs(app.hitmarkerPool) do
            if not m.Busy then
                return m, false
            end
            if m.Token < oldestToken then
                oldest, oldestToken = m, m.Token
            end
        end
        return oldest, false
    end

    local function resetMarker(m, color)
        for i, part in ipairs(m.Parts) do
            part.Line.Position = HM_RESET[i]
            part.Line.BackgroundTransparency = 1
            part.Line.Size = UDim2.fromOffset(14, 2)
            part.Line.BackgroundColor3 = color
            part.Stroke.Transparency = 1
        end
    end

    function app.showHitmarker(isHeadshot, worldPos, followPart)
        app.showHitEffect()
        -- 开关关闭直接返回。绝不能在这之前递增 hitmarkerSeq——曾在开关关闭后
        -- 每次命中都先递增 token 再返回,杀掉进行中的退出动画,标记卡死在最后位置不消失
        if not app.HITMARKER_ENABLED then return end

        app.hitmarkerSeq += 1
        local m, reused = acquireHitmarker(followPart)
        m.Token = app.hitmarkerSeq
        m.Busy = true
        m.FollowPart = followPart
        local token = m.Token

        local color = isHeadshot and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(255, 255, 255)

        m.Gui.Visible = true
        if not reused then
            resetMarker(m, color)
        else
            for _, part in ipairs(m.Parts) do
                part.Line.BackgroundColor3 = color
            end
        end

        -- Impact Point 模式:3D 命中点转 2D 屏幕位置,存活期间跟随目标移动,屏幕外钳制到边缘仍显示,回到视野内恢复真实投影位置
        if app.HITMARKER_MODE == "Impact Point" and worldPos then
            task.spawn(function()
                local cam = Workspace.CurrentCamera
                local life = 0.25 -- 略大于 hitmarker 动画总时长(0.08+0.13)
                local start = tick()
                while token == m.Token and tick() - start < life do
                    local wp = worldPos
                    if followPart and followPart.Parent then
                        wp = followPart.Position -- 跟随敌人当前位置
                    end
                    local screenPos = cam:WorldToViewportPoint(wp)
                    local viewport = cam.ViewportSize
                    local sx, sy
                    if screenPos.Z > 0 then
                        -- 视野内:真实投影点(可能在屏幕外,下方钳制到边缘)
                        sx, sy = screenPos.X, screenPos.Y
                    else
                        -- 命中点在摄像机背后:投影是翻转的,且正后方会落在屏幕中心(看着像 Centre 模式);
                        -- 改用摄像机本地坐标的方向,把标记压到对应的屏幕边缘,指示目标在身后哪个方向
                        local localOffset = cam.CFrame:PointToObjectSpace(wp)
                        local dirX, dirY = localOffset.X, localOffset.Y
                        if math.abs(dirX) < 0.001 and math.abs(dirY) < 0.001 then
                            dirY = -1 -- 正后方无水平方向分量,默认指向下边缘
                        end
                        local halfX, halfY = viewport.X / 2 - 14, viewport.Y / 2 - 14
                        local edgeScale = math.max(math.abs(dirX) / halfX, math.abs(dirY) / halfY)
                        sx = viewport.X / 2 + dirX / edgeScale
                        sy = viewport.Y / 2 - dirY / edgeScale -- 摄像机 +Y 向上,屏幕 +Y 向下
                    end
                    -- 屏幕外不隐藏:钳制到屏幕边缘(留 14px 边距);重新看到该位置时钳制自动失效,回到真实投影点
                    sx = math.clamp(sx, 14, viewport.X - 14)
                    sy = math.clamp(sy, 14, viewport.Y - 14)
                    m.Gui.Position = UDim2.fromOffset(sx, sy)
                    m.Gui.Visible = true
                    task.wait()
                end
                if token == m.Token then
                    m.Gui.Visible = false
                    m.Busy = false
                end
            end)
        else
            m.Gui.Position = UDim2.new(0.5, 0, 0.5, 0) -- Centre:屏幕中心
        end

        local enterInfo = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local exitInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

        for i, part in ipairs(m.Parts) do
            TweenService:Create(part.Line, enterInfo, {Position = HM_ENTER[i], BackgroundTransparency = 0}):Play()
            TweenService:Create(part.Stroke, enterInfo, {Transparency = 0.25}):Play()
        end

        task.delay(0.08, function()
            if token ~= m.Token then
                return
            end

            for i, part in ipairs(m.Parts) do
                TweenService:Create(part.Line, exitInfo, {Position = HM_EXIT[i], BackgroundTransparency = 1}):Play()
                TweenService:Create(part.Stroke, exitInfo, {Transparency = 1}):Play()
            end

            task.delay(0.13, function()
                if token ~= m.Token then
                    return
                end
                m.Gui.Visible = false
                m.Busy = false
            end)
        end)
    end
end

-- ========== Show Impact：显示当前准星射线预计命中的地图位置 ==========
do
    local impactPart = Instance.new("Part")
    impactPart.Name = app.randomName()
    impactPart.Shape = Enum.PartType.Ball
    impactPart.Anchored = true
    impactPart.CanCollide = false
    impactPart.CanTouch = false
    impactPart.CanQuery = false
    impactPart.CastShadow = false
    impactPart.Transparency = 1
    impactPart.Parent = Workspace

    local impactRayParams = RaycastParams.new()
    impactRayParams.FilterType = Enum.RaycastFilterType.Exclude
    impactRayParams.IgnoreWater = true
    local impactConnection = nil

    function app.updateImpactMarker()
        if not app.SHOW_IMPACT_ENABLED then
            impactPart.Transparency = 1
            return
        end
        local weapon = app.getCurrentWeapon and app.getCurrentWeapon()
        if not weapon or not weapon:IsA("Tool") or not weapon:FindFirstChild("ACS_Settings") then
            impactPart.Transparency = 1
            return
        end
        local material = Enum.Material[app.SHOW_IMPACT_MATERIAL] or Enum.Material.Neon
        impactPart.Color = app.SHOW_IMPACT_COLOR
        impactPart.Material = material
        impactPart.Size = Vector3.new(app.SHOW_IMPACT_SIZE, app.SHOW_IMPACT_SIZE, app.SHOW_IMPACT_SIZE)
        local camera = Workspace.CurrentCamera
        if not camera or mainGuiVisible then
            impactPart.Transparency = 1
            return
        end
        local filter = {LocalPlayer.Character, camera}
        local acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
        if acsWorkspace then filter[#filter + 1] = acsWorkspace end
        impactRayParams.FilterDescendantsInstances = filter
        local origin = camera.CFrame.Position
        local result = Workspace:Raycast(origin, camera.CFrame.LookVector * 7000, impactRayParams)
        if result then
            impactPart.CFrame = CFrame.new(result.Position)
            impactPart.Transparency = app.SHOW_IMPACT_TRANSPARENCY
        else
            impactPart.Transparency = 1
        end
    end

    function app.setImpactVisible(enabled)
        app.SHOW_IMPACT_ENABLED = enabled == true
        if app.SHOW_IMPACT_ENABLED then
            if not impactConnection then
                impactConnection = RunService.RenderStepped:Connect(function()
                    app.xpcallw(app.updateImpactMarker, "Show Impact")
                end)
            end
            app.updateImpactMarker()
        else
            if impactConnection then
                impactConnection:Disconnect()
                impactConnection = nil
            end
            impactPart.Transparency = 1
        end
    end

    gui.Destroying:Connect(function()
        if impactConnection then impactConnection:Disconnect(); impactConnection = nil end
        impactPart:Destroy()
    end)

    app.setImpactVisible(app.SHOW_IMPACT_ENABLED)
end

-- ========== Spread FOV：用当前武器的最大扩散角绘制准心圈 ==========
do
    local spreadCircle = Instance.new("Frame")
    spreadCircle.Name = app.randomName()
    spreadCircle.AnchorPoint = Vector2.new(0.5, 0.5)
    spreadCircle.Position = UDim2.fromScale(0.5, 0.5)
    spreadCircle.Size = UDim2.fromOffset(4, 4)
    spreadCircle.BackgroundTransparency = 1
    spreadCircle.BorderSizePixel = 0
    spreadCircle.Visible = false
    spreadCircle.ZIndex = 270
    spreadCircle.Parent = gui
    app.addCorner(spreadCircle, 999)
    local spreadStroke = app.addStroke(spreadCircle, app.SPREAD_FOV_COLOR, 1, app.SPREAD_FOV_TRANSPARENCY)
    local spreadConnection

    local function getCurrentSpreadDegrees()
        local spreadTable = modTable
        if type(spreadTable) ~= "table" then spreadTable = app.allModTables[1] end
        if type(spreadTable) ~= "table" then return 0 end
        local minimum = tonumber(rawget(spreadTable, "MinSpread")) or 0
        local maximum = tonumber(rawget(spreadTable, "MaxSpread")) or minimum
        local modifier = tonumber(rawget(spreadTable, "SpreadRM"))
        if modifier and modifier == modifier and modifier >= 0 then
            maximum *= modifier
        end
        if noSpreadEnabled then return 0 end
        return math.clamp(math.max(minimum, maximum), 0, 45)
    end

    function app.updateSpreadFov()
        if not app.SPREAD_FOV_ENABLED then
            spreadCircle.Visible = false
            return
        end
        local camera = Workspace.CurrentCamera
        local weapon = app.getCurrentWeapon and app.getCurrentWeapon()
        if not camera or mainGuiVisible or not weapon or not weapon:IsA("Tool") or not weapon:FindFirstChild("ACS_Settings") then
            spreadCircle.Visible = false
            return
        end
        local viewport = camera.ViewportSize
        local fov = math.max(1, tonumber(camera.FieldOfView) or 70)
        local angle = math.rad(getCurrentSpreadDegrees())
        local radius = viewport.Y * 0.5 * math.tan(angle) / math.tan(math.rad(fov * 0.5))
        radius = math.clamp(radius, 2, math.max(2, viewport.Y * 0.48))
        spreadCircle.Size = UDim2.fromOffset(radius * 2, radius * 2)
        spreadCircle.Position = UDim2.fromOffset(viewport.X * 0.5, viewport.Y * 0.5)
        spreadCircle.BackgroundTransparency = 1
        spreadStroke.Color = app.SPREAD_FOV_COLOR
        spreadStroke.Transparency = app.SPREAD_FOV_TRANSPARENCY
        spreadCircle.Visible = true
    end

    function app.setSpreadVisible(enabled)
        app.SPREAD_FOV_ENABLED = enabled == true
        if app.SPREAD_FOV_ENABLED then
            if not spreadConnection then
                spreadConnection = RunService.RenderStepped:Connect(function()
                    app.xpcallw(app.updateSpreadFov, "Spread FOV")
                end)
            end
            app.updateSpreadFov()
        else
            if spreadConnection then spreadConnection:Disconnect(); spreadConnection = nil end
            spreadCircle.Visible = false
        end
    end

    gui.Destroying:Connect(function()
        if spreadConnection then spreadConnection:Disconnect(); spreadConnection = nil end
        spreadCircle:Destroy()
    end)

    app.setSpreadVisible(app.SPREAD_FOV_ENABLED)
end

-- ========== HitLog ==========
local addHitLog
do
    local holder = Instance.new("Frame")
    holder.Name = app.randomName()
    holder.Size = UDim2.new(1, -24, 1, -84)
    holder.Position = UDim2.fromOffset(12, 72)
    holder.BackgroundTransparency = 1
    holder.BorderSizePixel = 0
    holder.ZIndex = 350
    holder.ClipsDescendants = true
    holder.Parent = gui
    local limit = Instance.new("UISizeConstraint")
    limit.MaxSize = Vector2.new(1100, 240)
    limit.Parent = holder
    app.registerResponsiveRoot(holder, false, function(viewport, scale)
        local top = math.min(72 * scale, viewport.Y * 0.2)
        holder.Position = UDim2.fromOffset(12, top)
        holder.Size = UDim2.fromOffset(math.max(0, viewport.X - 24) / scale, math.max(0, viewport.Y - top - 12) / scale)
    end)

    local entries, recent, surfaces = {}, {}, {}
    local gap = 5
    local accentColor = Color3.fromRGB(240, 240, 240)
    local renderName = "HitLogGlass_" .. app.randomName()
    local renderBound, disposed = false, false
    -- ScreenGui has no backdrop shader. Desktop uses actual camera-space Glass
    -- geometry; mobile keeps the optical rim below (Roblox disables refraction there).
    local nativeGlass = not UserInputService.TouchEnabled
    local function stopGlassRenderer()
        if renderBound then
            RunService:UnbindFromRenderStep(renderName)
            renderBound = false
        end
    end
    local function clearLens(entry)
        if entry.Lens then entry.Lens:Destroy(); entry.Lens = nil end
        entry.LensParts = nil
    end
    local function destroyEntry(entry)
        entry.Removing = true
        entry.MeasureToken = (entry.MeasureToken or 0) + 1
        for _, key in ipairs({"Expiry", "Exit"}) do
            if entry[key] then task.cancel(entry[key]); entry[key] = nil end
        end
        for _, key in ipairs({"Move", "Fade", "Shine"}) do
            if entry[key] then entry[key]:Cancel() end
        end
        for i = #entries, 1, -1 do
            if entries[i] == entry then table.remove(entries, i); break end
        end
        for i = #surfaces, 1, -1 do
            if surfaces[i] == entry then table.remove(surfaces, i); break end
        end
        clearLens(entry)
        entry.Frame:Destroy()
        if #surfaces == 0 then stopGlassRenderer() end
    end
    local function createLens(entry, camera)
        local lens = Instance.new("Folder")
        lens.Name = app.randomName()
        -- Store the owner before building children so partial failures can be cleaned.
        entry.Lens, entry.LensParts = lens, {}
        for i = 1, 3 do
            local part = Instance.new("Part")
            part.Name = app.randomName()
            part.Anchored = true
            part.CanCollide, part.CanTouch, part.CanQuery = false, false, false
            part.CastShadow = false
            part.Size = Vector3.new(1, 1, 1)
            part.Material = Enum.Material.Glass
            part.Color = Color3.fromRGB(235, 235, 235)
            part.Transparency = 1
            part.Reflectance = 0.06
            part.Parent = lens
            -- Mesh scaling permits sub-0.05-stud surfaces close to the near plane.
            local mesh = Instance.new("SpecialMesh")
            mesh.MeshType = i == 1 and Enum.MeshType.Cylinder or Enum.MeshType.Sphere
            mesh.Parent = part
            entry.LensParts[i] = {Part = part, Mesh = mesh}
        end
        lens.Parent = camera
    end
    local function updateGlass()
        local camera = Workspace.CurrentCamera
        for _, entry in ipairs(surfaces) do
            local glass = entry.Glass
            local position, size = glass.AbsolutePosition, glass.AbsoluteSize
            local inset, bounds = holder.AbsolutePosition, holder.AbsoluteSize
            local visible = camera and gui.Enabled and holder.Visible and entry.Frame.Visible
                and entry.Card.GroupTransparency < 0.995 and size.X >= size.Y and size.Y > 0
                and position.X >= inset.X and position.Y >= inset.Y
                and position.X + size.X <= inset.X + bounds.X
                and position.Y + size.Y <= inset.Y + bounds.Y
            if not visible then
                clearLens(entry)
            else
                if entry.Lens and entry.Lens.Parent ~= camera then clearLens(entry) end
                if not entry.Lens then createLens(entry, camera) end
                -- IgnoreGuiInset=true: AbsolutePosition is in viewport pixels. Cast
                -- onto a camera-parallel plane, not a constant-length radial ray.
                -- This also follows FOV changes and portrait/landscape resizing.
                local depth = math.max(0.6, math.abs(camera.NearPlaneZ) + 0.12)
                local function point(x, y)
                    local ray = camera:ViewportPointToRay(x, y)
                    local forward = camera.CFrame.LookVector
                    local plane = camera.CFrame.Position + forward * depth
                    return ray.Origin + ray.Direction * ((plane - ray.Origin):Dot(forward) / ray.Direction:Dot(forward))
                end
                local centre = point(position.X + size.X / 2, position.Y + size.Y / 2)
                local width = (point(position.X + size.X, position.Y) - point(position.X, position.Y)).Magnitude
                local height = (point(position.X, position.Y + size.Y) - point(position.X, position.Y)).Magnitude
                local bodyWidth = math.max(0.0001, width - height)
                local orientation = camera.CFrame - camera.CFrame.Position
                for i, component in ipairs(entry.LensParts) do
                    local offset = i == 1 and 0 or (i == 2 and -bodyWidth / 2 or bodyWidth / 2)
                    component.Part.CFrame = CFrame.new(centre + camera.CFrame.RightVector * offset) * orientation
                    component.Mesh.Scale = Vector3.new(i == 1 and bodyWidth or height, height, height)
                    component.Part.Transparency = 0.82 + 0.18 * entry.Card.GroupTransparency
                end
            end
        end
    end
    local function startGlassRenderer()
        if renderBound or not nativeGlass or disposed then return end
        renderBound = true
        RunService:BindToRenderStep(renderName, Enum.RenderPriority.Camera.Value + 1, function()
            local ok = app.xpcallw(updateGlass, "HitLogGlass")
            if not ok then
                -- Leave readable UI if the engine/executor cannot create Glass.
                nativeGlass = false
                for _, entry in ipairs(surfaces) do clearLens(entry) end
                stopGlassRenderer()
            end
        end)
    end
    local function metrics()
        local size = math.clamp(math.floor(hitLogSize + 0.5), 8, 24)
        return size + 10, size
    end
    local function escape(text)
        return tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
    end
    local function highlight(text)
        return '<font color="#FFFFFF">' .. escape(text) .. '</font>'
    end
    local function remove(entry, animated)
        if entry.Removing then return end
        entry.Removing = true
        entry.ExpiryToken = (entry.ExpiryToken or 0) + 1
        if entry.Expiry then task.cancel(entry.Expiry); entry.Expiry = nil end
        for i = #entries, 1, -1 do
            if entries[i] == entry then table.remove(entries, i); break end
        end
        if entry.Move then entry.Move:Cancel() end
        if entry.Fade then entry.Fade:Cancel() end
        if animated and entry.Frame.Parent then
            entry.Fade = app.tween(entry.Card, 0.18, {GroupTransparency = 1})
            entry.Fade:Play()
            entry.Exit = task.delay(0.19, function()
                entry.Exit = nil
                destroyEntry(entry)
            end)
        else
            destroyEntry(entry)
        end
    end

    local function fit(entry)
        if entry.Removing or not entry.Frame.Parent then return end
        entry.Frame.Size = UDim2.fromOffset(math.max(0, math.min(entry.Width or holder.AbsoluteSize.X / app.UI_SCALE, holder.AbsoluteSize.X / app.UI_SCALE - 2)), entry.Height)
    end
    local function measure(entry, size)
        local face = app.UI_FONT or Font.fromEnum(Enum.Font.GothamMedium)
        if entry.MeasuredSize == size and entry.MeasuredFace == face then return end
        entry.MeasuredSize, entry.MeasuredFace = size, face
        entry.MeasureToken = (entry.MeasureToken or 0) + 1
        local token = entry.MeasureToken
        task.defer(function()
            if entry.Removing or token ~= entry.MeasureToken then return end
            local params = Instance.new("GetTextBoundsParams")
            params.Text, params.Font, params.Size, params.Width = entry.PlainText, face, size, 100000
            local ok, bounds = pcall(TextService.GetTextBoundsAsync, TextService, params)
            params:Destroy()
            if ok and not entry.Removing and token == entry.MeasureToken then
                entry.Width = math.ceil(bounds.X) + 38
                fit(entry)
            end
        end)
    end

    local function scheduleExpiry(entry)
        local duration = math.clamp(app.HITLOG_DURATION, 0.5, 10)
        if entry.Duration == duration then return end
        entry.Duration = duration
        entry.ExpiryToken = (entry.ExpiryToken or 0) + 1
        local token = entry.ExpiryToken
        if entry.Expiry then task.cancel(entry.Expiry) end
        entry.Expiry = task.delay(math.max(0, entry.CreatedAt + duration - tick()), function()
            if entry.Removing or token ~= entry.ExpiryToken or not entry.Frame.Parent then return end
            entry.Expiry = nil
            remove(entry, true)
            relayoutHitLogs(true)
        end)
    end

    relayoutHitLogs = function(animated)
        if disposed or not holder.Parent then return end
        local height, size = metrics()
        local space = math.max(0, holder.AbsoluteSize.Y / app.UI_SCALE)
        local capacity = hitLogEnabled and math.max(0, math.min(5, math.floor((space - 2 + gap) / (height + gap)))) or 0
        while #entries > capacity do remove(entries[1], false) end
        if capacity == 0 then
            while #surfaces > 0 do destroyEntry(surfaces[1]) end
        end
        for i, entry in ipairs(entries) do
            entry.Height = height
            scheduleExpiry(entry)
            entry.Label.TextSize = size
            fit(entry)
            measure(entry, size)
            local position = UDim2.fromOffset(1, 1 + (i - 1) * (height + gap))
            if entry.Move then entry.Move:Cancel() end
            if animated and entry.Placed then
                entry.Move = app.tween(entry.Frame, 0.18, {Position = position})
                entry.Move:Play()
            else
                entry.Frame.Position = position
                entry.Placed = true
            end
        end
    end

    addHitLog = function(displayName, username, hitPart, distance, damage, isHeadshot, healthLeft)
        if disposed or not hitLogEnabled or not holder.Parent then return end
        local now = tick()
        for key, time in pairs(recent) do if now - time > 0.18 then recent[key] = nil end end
        local key = table.concat({username, hitPart, tostring(distance), tostring(damage), tostring(healthLeft)}, "\0")
        if recent[key] and now - recent[key] <= 0.12 then return end
        recent[key] = now
        -- Include exiting rows in the cap: rapid hits cannot accumulate Glass parts.
        while #surfaces >= 5 do destroyEntry(surfaces[1]) end
        local part = isHeadshot and "head" or string.lower(hitPart)
        local health = math.max(0, math.floor((tonumber(healthLeft) or 0) + 0.5))
        local plain = string.format("Hit %s in the %s for %s damage (%s health left)", displayName, part, damage, health)
        local rich = "Hit " .. highlight(displayName) .. " in the " .. highlight(part) .. " for " .. highlight(damage) .. " damage (" .. tostring(health) .. " health left)"

        local frame = Instance.new("Frame")
        frame.Name = app.randomName()
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.ZIndex = 351
        frame.Parent = holder
        local card = Instance.new("CanvasGroup")
        card.Name = app.randomName()
        card.Size = UDim2.fromScale(1, 1)
        card.Position = UDim2.fromOffset(0, 0)
        card.BackgroundColor3 = app.THEME.bg
        card.BackgroundTransparency = 1
        card.GroupTransparency = 1
        card.BorderSizePixel = 0
        card.ZIndex = 352
        card.Parent = frame
        -- Optical shell: clear centre, dark lower meniscus, paired specular rims.
        -- The tint is intentionally light enough to reveal the native lens behind it.
        local function layer(parent, color, transparency, position, size, z)
            local obj = Instance.new("Frame")
            obj.Name = app.randomName()
            obj.BackgroundColor3 = color
            obj.BackgroundTransparency = transparency
            obj.BorderSizePixel = 0
            obj.Position = position
            obj.Size = size
            obj.ZIndex = z
            obj.Parent = parent
            app.addCorner(obj, 100)
            return obj
        end
        layer(card, Color3.new(0, 0, 0), 0.88, UDim2.fromOffset(1, 3), UDim2.new(1, -2, 1, -3), 352)
        local glass = layer(card, Color3.fromRGB(28, 28, 28), 0.76, UDim2.fromOffset(1, 1), UDim2.new(1, -2, 1, -4), 353)
        local tint = Instance.new("UIGradient")
        tint.Rotation = 90
        tint.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.42, 0.2),
            NumberSequenceKeypoint.new(1, 0)
        })
        tint.Parent = glass
        local rim = app.addStroke(glass, Color3.new(1, 1, 1), 1, 0.12)
        local rimLight = Instance.new("UIGradient")
        rimLight.Rotation = 65
        rimLight.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(0.3, 0.62),
            NumberSequenceKeypoint.new(0.55, 0.95), NumberSequenceKeypoint.new(0.8, 0.55),
            NumberSequenceKeypoint.new(1, 0.12)
        })
        rimLight.Parent = rim
        local reflection = layer(glass, Color3.new(1, 1, 1), 0.72, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 354)
        local sheen = Instance.new("UIGradient")
        sheen.Rotation = 90
        sheen.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.18, 0.76),
            NumberSequenceKeypoint.new(0.48, 1), NumberSequenceKeypoint.new(0.8, 1),
            NumberSequenceKeypoint.new(1, 0.6)
        })
        sheen.Parent = reflection
        local inner = layer(glass, Color3.new(1, 1, 1), 1, UDim2.fromOffset(1, 1), UDim2.new(1, -2, 1, -2), 355)
        local innerRim = app.addStroke(inner, Color3.new(0, 0, 0), 1, 0.72)
        local innerLight = Instance.new("UIGradient")
        innerLight.Rotation = 90
        innerLight.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.55, 1),
            NumberSequenceKeypoint.new(1, 0)
        })
        innerLight.Parent = innerRim
        local glint = layer(glass, Color3.new(1, 1, 1), 0.9, UDim2.fromOffset(2, 1), UDim2.new(1, -4, 1, -2), 354)
        local glintLight = Instance.new("UIGradient")
        glintLight.Rotation = 25
        glintLight.Offset = Vector2.new(-0.35, 0)
        glintLight.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.4, 1),
            NumberSequenceKeypoint.new(0.5, 0.25), NumberSequenceKeypoint.new(0.6, 1),
            NumberSequenceKeypoint.new(1, 1)
        })
        glintLight.Parent = glint

        local icon = Instance.new("Frame")
        icon.Name = app.randomName()
        icon.AnchorPoint = Vector2.new(0, 0.5)
        icon.Position = UDim2.new(0, 8, 0.5, -1)
        icon.Size = UDim2.fromOffset(14, 14)
        icon.BackgroundTransparency = 1
        icon.BorderSizePixel = 0
        icon.ZIndex = 355
        icon.Parent = card
        -- Hollow aiming ring with four diagonal ticks, leaving the centre clear.
        local ring = Instance.new("Frame")
        ring.Name = app.randomName()
        ring.AnchorPoint = Vector2.new(0.5, 0.5)
        ring.Position = UDim2.fromScale(0.5, 0.5)
        ring.Size = UDim2.fromOffset(11, 11)
        ring.BackgroundTransparency = 1
        ring.BorderSizePixel = 0
        ring.ZIndex = 355
        ring.Parent = icon
        app.addCorner(ring, 99)
        app.addStroke(ring, accentColor, 1.2, 0)
        for _, angle in ipairs({45, 135, 225, 315}) do
            local radians = math.rad(angle)
            local line = Instance.new("Frame")
            line.Name = app.randomName()
            line.AnchorPoint = Vector2.new(0.5, 0.5)
            line.Position = UDim2.new(0.5, math.cos(radians) * 6, 0.5, math.sin(radians) * 6)
            line.Size = UDim2.fromOffset(5, 1.2)
            line.Rotation = angle
            line.BorderSizePixel = 0
            line.BackgroundColor3 = accentColor
            line.ZIndex = 356
            line.Parent = icon
        end
        local label = Instance.new("TextLabel")
        label.Name = app.randomName()
        label.BackgroundTransparency = 1
        label.BorderSizePixel = 0
        label.Position = UDim2.fromOffset(27, -1)
        label.Size = UDim2.new(1, -37, 1, 0)
        label.TextColor3 = Color3.fromRGB(225, 225, 225)
        label.TextStrokeColor3 = Color3.fromRGB(24, 24, 24)
        label.TextStrokeTransparency = 0.45
        label.TextScaled = false
        app.applyFont(label, Enum.Font.GothamMedium)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Center
        label.TextTruncate = Enum.TextTruncate.AtEnd
        label.TextWrapped = false
        label.RichText = true
        label.Text = rich
        label.ZIndex = 355
        label.Parent = card
        local entry = {Frame = frame, Card = card, Glass = glass, Label = label, PlainText = plain, CreatedAt = now}
        table.insert(entries, entry)
        table.insert(surfaces, entry)
        relayoutHitLogs(true)
        if entry.Removing then return end
        entry.Fade = app.tween(card, 0.2, {GroupTransparency = 0})
        entry.Fade:Play()
        entry.Shine = app.tween(glintLight, 0.65, {Offset = Vector2.new(0.35, 0)})
        entry.Shine:Play()
        startGlassRenderer()
    end
    holder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() relayoutHitLogs(false) end)
    holder.Destroying:Connect(function()
        disposed = true
        stopGlassRenderer()
        while #surfaces > 0 do destroyEntry(surfaces[1]) end
        table.clear(recent)
    end)
end

-- 每个玩家同时最多一个待决伤害监听:高频开火(每帧多轮)时防止 watch 无限堆积,
-- 一次掉血只产出一条 HitLog(伤害量为该监听挂起以来的累计值),不会被放大成几十条
app.hitlogWatchPending = {}

local function createDamageWatch(targetPlayer, hitPartName, distance, isHeadshot)
    -- 同目标已有待决监听则跳过(返回空的撤销函数,调用方逻辑不受影响)
    if app.hitlogWatchPending[targetPlayer] then
        return function() end
    end
    local character = targetPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return function() end
    end
    app.hitlogWatchPending[targetPlayer] = true

    local startHealth = humanoid.Health
    local resolved = false
    local conn = nil

    local function cleanup()
        app.hitlogWatchPending[targetPlayer] = nil
        if conn then
            conn:Disconnect()
            conn = nil
        end
    end

    conn = humanoid.HealthChanged:Connect(function(newHealth)
        if resolved then
            return
        end

        if newHealth < startHealth then
            resolved = true
            cleanup()

            local damageAmount = math.max(0, startHealth - newHealth)
            addHitLog(
                targetPlayer.DisplayName or targetPlayer.Name,
                targetPlayer.Name,
                tostring(hitPartName),
                math.floor(distance + 0.5),
                math.floor(damageAmount + 0.5),
                isHeadshot,
                math.max(0, newHealth)
            )
        end
    end)

    task.delay(0.7, function()
        if resolved then
            return
        end
        resolved = true
        cleanup()
    end)

    return function()
        if resolved then
            return
        end
        resolved = true
        cleanup()
    end
end

-- ========== Setting 选项卡（简化版） ==========
do
    local body = app.createSection(tabFrames.Debug, "Developer diagnostics")
    local report = Instance.new("TextLabel")
    report.Name = "DebugReport"
    report.BackgroundTransparency = 1
    report.Size = UDim2.new(1, 0, 0, 0)
    report.AutomaticSize = Enum.AutomaticSize.Y
    report.TextSize = 11
    app.applyFont(report, Enum.Font.Code)
    report.TextColor3 = app.THEME.text
    report.TextWrapped = true
    report.TextXAlignment = Enum.TextXAlignment.Left
    report.TextYAlignment = Enum.TextYAlignment.Top
    report.RichText = false
    report.LayoutOrder = 1
    report.Parent = body
    function app.buildDebugReport()
        local executor = "Unknown"
        if type(identifyexecutor) == "function" then
            local ok, name, version = pcall(identifyexecutor)
            if ok then executor = tostring(name) .. " " .. tostring(version or "") end
        end
        local status = app.steadyAimStatus or {}
        local ready, waiting, busy = 0, 0, 0
        local failures = {}
        for _, item in pairs(app.imageBindings) do
            if item.State == "Ready" then ready += 1 else waiting += 1 end
            if item.Busy then busy += 1 end
            if item.State ~= "Ready" and #failures < 8 then
                failures[#failures + 1] = item.Key .. ": " .. item.State .. " (" .. item.Attempts .. ")"
                    .. (item.Error and (" / " .. item.Error:sub(1, 160)) or "")
            end
        end
        local lines = {
            "Executor: " .. executor,
            "Viewport: " .. tostring(gui.AbsoluteSize) .. " / scale " .. tostring(app.UI_SCALE),
            "Steady Aim: " .. tostring(app.STEADY_AIM) .. " / " .. tostring(status.State),
            "Render hooks: " .. tostring(status.Hooks or 0) .. " / bob writes: " .. tostring(status.Pins or 0),
            "Images ready/waiting/busy: " .. ready .. "/" .. waiting .. "/" .. busy,
            "Download queue: " .. tostring(#app.RESOURCE_QUEUE),
            "Totals: " .. app.lifetimeStats.Kills .. " kills / " .. app.lifetimeStats.Score .. " score",
            "Storage: CheatGPT/ACS/misc.json",
            "Missing APIs: " .. table.concat(app.EXEC_UNSUPPORTED or {}, ", "),
        }
        for _, name in ipairs({"getconnections/getgc", "debug.getconstants", "debug.getupvalue", "debug.setupvalue", "hookfunction", "newcclosure"}) do
            if not app.EXEC_SUPPORT[name] then lines[#lines + 1] = "Steady Aim missing: " .. name end
        end
        for _, entry in ipairs(failures) do lines[#lines + 1] = entry end
        lines[#lines + 1] = "Recent errors (local only):"
        for i = math.max(1, #app.debugErrors - 7), #app.debugErrors do lines[#lines + 1] = app.debugErrors[i]:sub(1, 300) end
        return table.concat(lines, "\n")
    end
    local function refresh() report.Text = app.buildDebugReport() end
    local function action(text, order, callback)
        local button = app.createButton(body, text, callback)
        if typeof(button) == "Instance" then button.LayoutOrder = order end
    end
    action("Refresh diagnostics", 2, function()
        if app.refreshSteadyAim then app.refreshSteadyAim() end
        refresh()
    end)
    action("Retry unloaded images", 3, function()
        for _, item in pairs(app.imageBindings) do
            if item.State ~= "Ready" then item.NextAt = 0 end
        end
        refresh()
    end)
    action("Copy diagnostics", 4, function()
        if type(setclipboard) ~= "function" then app.notifyUnsupportedFunc("setclipboard"); return end
        setclipboard(app.buildDebugReport() .. "\n\nFull error ring:\n" .. table.concat(app.debugErrors, "\n"))
    end)
    action("Test notification / bug icon", 5, function()
        app.showNotification("Debug", "Notification and icon loading test", 5, {iconKey = "bug"})
    end)
    action("Clear error log", 6, function() table.clear(app.debugErrors); refresh() end)
    task.spawn(function()
        while gui.Parent do
            if app.DEBUG_UNLOCKED and app.activeTabName == "Debug" then refresh() end
            task.wait(1)
        end
    end)
end

local settingBody = app.createSection(settingFrame, "Setting")

local watermarkToggleControl = createModernToggle(settingBody, "Watermark", watermarkEnabled, function(v)
    watermarkEnabled = v
    app.CONFIG_EXTRA.watermarkEnabled = v
    refreshWatermark()
end)

local watermarkShowControl = app.createMultiDropdown(
    settingBody,
    "Show",
    app.WATERMARK_ITEMS,
    watermarkSelection,
    function(selection)
        watermarkSelection = selection
        app.CONFIG_EXTRA.watermarkSelection = selection
        app.watermarkOrder = app.orderWatermarkSelection(selection,
            app.CONFIG_RESETTING and app.DEFAULT_CONFIG.watermarkOrder or app.watermarkOrder)
        app.CONFIG_EXTRA.watermarkOrder = app.watermarkOrder
        refreshWatermark()
    end,
    "watermarkSelection"
)

local watermarkCustomControl = app.createInput(settingBody, "Custom", "Enter text...", watermarkCustomText, function(text)
    watermarkCustomText = text or ""
    app.CONFIG_EXTRA.watermarkCustomText = watermarkCustomText
    refreshWatermark()
end)

local enemyLeaveNotifyToggleControl = createModernToggle(settingBody, "Enemy leave notify", enemyLeaveNotifyEnabled, function(v)
    enemyLeaveNotifyEnabled = v
end)

local friendLeaveNotifyToggleControl = createModernToggle(settingBody, "Friend leave notify", friendLeaveNotifyEnabled, function(v)
    friendLeaveNotifyEnabled = v
end)

local enemyJoinNotifyToggleControl = createModernToggle(settingBody, "Enemy join notify", enemyJoinNotifyEnabled, function(v)
    enemyJoinNotifyEnabled = v
end)

local friendJoinNotifyToggleControl = createModernToggle(settingBody, "Friend join notify", friendJoinNotifyEnabled, function(v)
    friendJoinNotifyEnabled = v
end)

local guiKeybindControl = app.createKeybindPicker(settingBody, "GUI Key", guiToggleKey, function(v)
    guiToggleKey = v
end)

-- 自定义通知系统总开关(本脚本通知走同风格 Toast;关闭则回退原生)
createModernToggle(settingBody, "Notifications", notifyEnabled, function(v)
    notifyEnabled = v
end)

-- 清除配置：独立确认面板，取消/切页/隐藏窗口均不删除。
do
    local panel = app.createDropdownPanel(260)
    local prompt = Instance.new("TextLabel")
    prompt.Name = app.randomName()
    prompt.Size = UDim2.new(1, 0, 0, 74)
    prompt.BackgroundTransparency = 1
    prompt.Text = "Clear saved configuration and reset all controls?\nPlayer lists and cache will be kept."
    prompt.TextColor3 = app.THEME.text
    app.applyFont(prompt, Enum.Font.GothamMedium)
    prompt.TextSize = 12
    prompt.TextWrapped = true
    prompt.LayoutOrder = 0
    prompt.ZIndex = 202
    prompt.Parent = panel:FindFirstChildOfClass("ScrollingFrame")

    local cancel = app.createDropdownOption(panel, 1)
    cancel.Text = "Cancel"
    cancel.Size = UDim2.new(1, 0, 0, 38)
    local confirm = app.createDropdownOption(panel, 2)
    confirm.Text = "Clear and Reset"
    confirm.TextColor3 = app.THEME.red
    confirm.Size = UDim2.new(1, 0, 0, 38)
    local busy = false
    local button
    button = app.createButton(settingBody, "Clear Config", function()
        if busy then return end
        if openedDropdown == panel then
            closeOpenedDropdown(true)
            return
        end
        dropdownPressGuard = os.clock()
        app.openDropdownAnimated(panel, button, true)
    end)
    cancel.Activated:Connect(function()
        if openedDropdown == panel then closeOpenedDropdown(true) end
    end)
    confirm.Activated:Connect(function()
        if busy or openedDropdown ~= panel or not settingFrame.Visible or not mainGuiVisible then return end
        busy = true
        closeOpenedDropdown(true)
        if startup.runtime.phase ~= "ready" then
            busy = false
            app.startupReport(startup, "Please wait for initialization to finish before clearing configuration.", true)
            return
        end
        local ok, message = app.clearCheatGPTConfig()
        busy = false
        if app.showNotification then
            app.showNotification("CheatGPT.cc", message, 6, {error = not ok})
        end
    end)
end

-- ================= 自定义通知系统（同风格 Toast，我们自己的通知专用） =================
-- 只替换本脚本发出的通知,不拦截游戏的通知(游戏该弹原生还弹原生)。
-- 全部状态收进 do-end 块,不占顶层 local 名额;共享入口为 app.showNotification(title, text, duration)
do
    local activeToasts = {}
    local notifyQueue = {}   -- 超出同屏上限的排队
    local notifySeq = 0
    local MAX_TOASTS = 5
    local TOAST_WIDTH = 300

    -- 右上角堆叠层(独立于主窗口,主 GUI 隐藏时通知照常显示)
    local toastLayer = Instance.new("Frame")
    toastLayer.Name = app.randomName()
    toastLayer.AnchorPoint = Vector2.new(1, 0)
    toastLayer.Position = UDim2.new(1, -12, 0, 44)
    toastLayer.Size = UDim2.new(0, TOAST_WIDTH, 1, -56)
    toastLayer.BackgroundTransparency = 1
    toastLayer.Parent = gui

    -- PC 端 Toast 同步放大(锚点在右上角,放大后钉位不变;层透明不可见,高度随放大超屏无影响)
    app.registerResponsiveRoot(toastLayer, false, function(viewport, scale)
        toastLayer.Position = UDim2.new(1, -12, 0, math.min(44 * scale, viewport.Y * 0.12))
        toastLayer.Size = UDim2.fromOffset(TOAST_WIDTH, math.max(0, viewport.Y - 56 * scale) / scale)
    end)

    local toastLayout = Instance.new("UIListLayout")
    toastLayout.Padding = UDim.new(0, 8)
    toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    toastLayout.VerticalAlignment = Enum.VerticalAlignment.Top
    toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
    toastLayout.Parent = toastLayer

    local pushToast -- 前向声明(dismiss 完成后要消费队列)

    local function dismissToast(holder, card)
        -- 滑出 + 淡出后销毁,从活跃表移除并给队列补位
        -- (tween 只创建不播放,必须 :Play()——之前漏了,Completed 永不触发,通知永远不消失)
        local out = app.tween(card, 0.2, {Position = UDim2.new(1, 12, 0, 0), GroupTransparency = 1})
        out.Completed:Connect(function()
            for i, h in ipairs(activeToasts) do
                if h == holder then
                    table.remove(activeToasts, i)
                    break
                end
            end
            holder:Destroy()
            if #notifyQueue > 0 then
                local n = table.remove(notifyQueue, 1)
                pushToast(n.title, n.text, n.duration, n.icon, n.copyText, n.errorStyle, n.iconKey)
            end
        end)
        out:Play()
    end

    pushToast = function(title, text, duration, icon, copyText, errorStyle, iconKey)
        notifySeq += 1
        -- holder 负责在列表里占位(自动高度),card 在 holder 内做滑入滑出
        local holder = Instance.new("Frame")
        holder.Name = app.randomName()
        holder.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
        holder.AutomaticSize = Enum.AutomaticSize.Y
        holder.BackgroundTransparency = 1
        holder.ClipsDescendants = true
        holder.LayoutOrder = -notifySeq -- 最新在最上面
        holder.Parent = toastLayer

        local card = Instance.new("CanvasGroup")
        card.Name = app.randomName()
        card.Size = UDim2.new(0, TOAST_WIDTH, 0, 0)
        card.AutomaticSize = Enum.AutomaticSize.Y
        card.Position = UDim2.new(1, 12, 0, 0) -- 起始在右侧屏外
        card.BackgroundColor3 = app.THEME.section
        card.BackgroundTransparency = 0.08
        card.BorderSizePixel = 0
        card.GroupTransparency = 1
        card.Parent = holder
        app.addCorner(card, 8)
        app.addStroke(card, app.THEME.line, 1, 0.45)

        -- 左侧强调条：错误通知使用红色，普通通知继续使用主题强调色。
        local bar = Instance.new("Frame")
        bar.Name = app.randomName()
        bar.Size = UDim2.new(0, 3, 1, 0)
        bar.BackgroundColor3 = errorStyle and app.THEME.red or app.THEME.accentSoft
        bar.BorderSizePixel = 0
        bar.Parent = card

        -- 可选圆形头像(离开通知等带玩家的消息用),有头像时正文右移
        local bodyX = 13
        if icon or iconKey then
            local avatar = Instance.new("ImageLabel")
            avatar.Name = app.randomName()
            avatar.Size = UDim2.new(0, 36, 0, 36)
            avatar.Position = UDim2.new(0, 13, 0, 10)
            avatar.BackgroundColor3 = app.THEME.section2
            avatar.Image = icon or ""
            avatar.Parent = card
            if iconKey then app.bindTabIcon(avatar, iconKey)
            else app.bindAsyncImage(avatar, function() return icon end, "Toast avatar") end
            app.addCorner(avatar, 18) -- 半径=边长一半,圆形
            app.addStroke(avatar, app.THEME.line, 1, 0.45)
            bodyX = 57
        end

        local body = Instance.new("Frame")
        body.Name = app.randomName()
        body.Size = UDim2.new(1, -bodyX, 0, 0)
        body.AutomaticSize = Enum.AutomaticSize.Y
        body.Position = UDim2.new(0, bodyX, 0, 0)
        body.BackgroundTransparency = 1
        body.Parent = card

        local pad = Instance.new("UIPadding")
        pad.PaddingTop = UDim.new(0, 9)
        pad.PaddingBottom = UDim.new(0, 9)
        pad.PaddingLeft = UDim.new(0, 8)
        pad.PaddingRight = UDim.new(0, 10)
        pad.Parent = body

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 3)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = body

        local titleLabel = Instance.new("TextLabel")
        titleLabel.Name = app.randomName()
        titleLabel.Size = UDim2.new(1, 0, 0, 14)
        titleLabel.BackgroundTransparency = 1
        titleLabel.Text = title
        titleLabel.TextColor3 = app.THEME.text
        app.applyFont(titleLabel, Enum.Font.GothamBold)
        titleLabel.TextSize = 13
        titleLabel.TextXAlignment = Enum.TextXAlignment.Left
        titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
        titleLabel.LayoutOrder = 1
        titleLabel.Parent = body

        local textLabel = Instance.new("TextLabel")
        textLabel.Name = app.randomName()
        textLabel.Size = UDim2.new(1, 0, 0, 0)
        textLabel.AutomaticSize = Enum.AutomaticSize.Y
        textLabel.BackgroundTransparency = 1
        textLabel.Text = text
        textLabel.TextColor3 = app.THEME.sub
        app.applyFont(textLabel, Enum.Font.GothamMedium)
        textLabel.TextSize = 12
        textLabel.TextWrapped = true
        textLabel.TextXAlignment = Enum.TextXAlignment.Left
        textLabel.LayoutOrder = 2
        textLabel.Parent = body

        -- 可选复制按钮(报错通知用:一键复制错误内容到剪贴板)
        if copyText then
            local copyBtn = Instance.new("TextButton")
            copyBtn.Name = app.randomName()
            copyBtn.Size = UDim2.new(1, 0, 0, 24)
            copyBtn.BackgroundColor3 = app.THEME.section2
            copyBtn.Text = "Copy"
            copyBtn.TextColor3 = app.THEME.text
            app.applyFont(copyBtn, Enum.Font.GothamMedium)
            copyBtn.TextSize = 12
            copyBtn.AutoButtonColor = false
            copyBtn.LayoutOrder = 3
            copyBtn.Parent = body
            app.addCorner(copyBtn, 6)
            app.addStroke(copyBtn, app.THEME.line, 1, 0.45)
            if not app.EXEC_SUPPORT["setclipboard"] then
                copyBtn.TextTransparency = 0.55
                copyBtn.BackgroundTransparency = 0.45
            end
            copyBtn.Activated:Connect(function()
                if not app.EXEC_SUPPORT["setclipboard"] then
                    app.notifyUnsupportedFunc("setclipboard")
                    return
                end
                app.xpcallw(function()
                    setclipboard(copyText)
                end, "通知")
                copyBtn.Text = "Copied!"
                task.delay(1, function()
                    if copyBtn.Parent then
                        copyBtn.Text = "Copy"
                    end
                end)
            end)
        end

        table.insert(activeToasts, holder)
        app.tween(card, 0.25, {Position = UDim2.new(0, 0, 0, 0), GroupTransparency = 0}):Play()
        task.delay(math.max(0.5, duration or 4), function()
            if holder.Parent then
                dismissToast(holder, card)
            end
        end)
    end

    -- 私有共享入口:开关开着走自定义 Toast(超上限排队);关了回退原生通知
    -- opts: { icon = 图片id, copyText = 复制按钮内容 }
    function app.showNotification(title, text, duration, opts)
        local iconKey = opts and opts.iconKey
        local icon = opts and opts.icon
        local copyText = opts and opts.copyText
        local errorStyle = opts and opts.error == true
        if not notifyEnabled then
            app.xpcallw(function()
                StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration or 4})
            end, "通知")
            return
        end
        if #activeToasts >= MAX_TOASTS then
            table.insert(notifyQueue, {
                title = title,
                text = text,
                duration = duration,
                icon = icon, iconKey = iconKey,
                copyText = copyText,
                errorStyle = errorStyle,
            })
            return
        end
        app.xpcallw(pushToast, "通知", title, text, duration, icon, copyText, errorStyle, iconKey)
    end
end

-- ================= 离开通知逻辑 =================
local function sendLeaveNotification(player, role)
    task.spawn(function()
        local icon = nil
        app.xpcallw(function()
            icon = app.avatarThumbCache[player.UserId] or ("rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150")
        end, "离开通知头像")
        app.showNotification(role:lower() .. " leave notify", string.format("%s(@%s) [%s] Leave this server!", player.DisplayName, player.Name, role), 5, { icon = icon })
    end)
end

Players.PlayerRemoving:Connect(function(player)
    if player == LocalPlayer then
        return
    end

    local lowerName = player.Name:lower()

    if enemySet[lowerName] and enemyLeaveNotifyEnabled then
        sendLeaveNotification(player, "Enemy")
        return
    end

    if friendSet[lowerName] and friendLeaveNotifyEnabled then
        sendLeaveNotification(player, "Friend")
        return
    end
end)

-- ================= 加入通知逻辑 =================
local function sendJoinNotification(player, role)
    task.spawn(function()
        local icon = nil
        app.xpcallw(function()
            icon = app.avatarThumbCache[player.UserId]
                or ("rbxthumb://type=AvatarHeadShot&id=" .. player.UserId .. "&w=150&h=150")
        end, "加入通知头像")
        app.showNotification(role:lower() .. " join notify", string.format("%s(@%s) [%s] joined this server!", player.DisplayName, player.Name, role), 5, { icon = icon })
    end)
end

Players.PlayerAdded:Connect(function(player)
    if player == LocalPlayer then return end
    local lowerName = player.Name:lower()
    if enemySet[lowerName] and enemyJoinNotifyEnabled then
        sendJoinNotification(player, "Enemy")
    elseif friendSet[lowerName] and friendJoinNotifyEnabled then
        sendJoinNotification(player, "Friend")
    end
end)

-- ================= GUI 显隐控制 =================
local function setMainGuiVisible(state)
    mainGuiVisible = state
    if not state and app.stopScrollbarDrag then app.stopScrollbarDrag() end

    if state then
        -- 淡入
        mainFrame.Visible = true
        TweenService:Create(mainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 0}):Play()
    else
        -- 淡出,动画结束后再隐藏(期间若重新打开则取消隐藏)
        if closeOpenedDropdown then
            closeOpenedDropdown()
        end
        local fadeOut = TweenService:Create(mainFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {GroupTransparency = 1})
        fadeOut:Play()
        fadeOut.Completed:Connect(function()
            if not mainGuiVisible then
                mainFrame.Visible = false
            end
        end)
    end
end

-- 启动淡入
task.defer(function()
    if mainGuiVisible then
        TweenService:Create(mainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 0}):Play()
    end
end)

setMainGuiVisible(true)

-- 启动汇总:执行器缺失的自定义函数一次性通知(对应功能已禁用或回退;等主窗淡入+通知系统就绪后再弹)
task.defer(function()
    task.wait(1.5)
    if #app.EXEC_UNSUPPORTED > 0 then
        app.notifyUnsupportedFunc(app.EXEC_UNSUPPORTED)
    end
end)

UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    if input.KeyCode == guiToggleKey then
        app.xpcallw(function()
            local focused = UserInputService:GetFocusedTextBox()
            if focused then
                focused:ReleaseFocus()
            end
            -- 以 mainGuiVisible 状态变量为准(淡出动画期间 mainFrame.Visible 仍为 true,用它会误判)
            setMainGuiVisible(not mainGuiVisible)
        end, "GUI开关")
        return
    end
end)

-- ========== 手机端悬浮最小化按钮（do-end 块内 local 不占用顶层名额） ==========
do
    local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
    if isMobile then
        local floatBtn = Instance.new("ImageButton")
        floatBtn.Name = app.randomName()
        floatBtn.Size = UDim2.fromOffset(52, 52)
        floatBtn.Position = UDim2.new(0, 24, 0.5, -26)
        floatBtn.BackgroundColor3 = app.THEME.panel
        floatBtn.Image = ""
        floatBtn.AutoButtonColor = false
        floatBtn.Active = true
        floatBtn.ZIndex = 10
        floatBtn.Parent = gui
        app.registerResponsiveRoot(floatBtn, true)
        app.addCorner(floatBtn, 26) -- 圆形
        app.addStroke(floatBtn, app.THEME.line, 1, 0.25)

        -- 图标内嵌居中,比按钮小一圈(不再铺满整个按钮)
        local floatIcon = Instance.new("ImageLabel")
        floatIcon.Name = app.randomName()
        floatIcon.Size = UDim2.fromOffset(34, 34)
        floatIcon.Position = UDim2.new(0.5, -17, 0.5, -17)
        floatIcon.BackgroundTransparency = 1
        floatIcon.Image = "rbxassetid://93763775045380" -- 与标题栏同一个 logo
        floatIcon.ScaleType = Enum.ScaleType.Fit
        floatIcon.ZIndex = 11
        floatIcon.Parent = floatBtn
        app.addCorner(floatIcon, 17)

        -- 图标缩放动画(按下收缩/松开恢复/点击脉冲)
        local function floatIconTween(size)
            TweenService:Create(floatIcon, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Size = UDim2.fromOffset(size, size),
                Position = UDim2.new(0.5, -size / 2, 0.5, -size / 2),
            }):Play()
        end

        local floatDragInput = nil
        local floatDragStart = nil
        local floatStartPos = nil
        local floatMoved = false

        floatBtn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                -- 新手指按下时以当前位置为起点重新记录，两根手指交替也不会瞬移
                floatDragInput = input
                floatDragStart = input.Position
                floatStartPos = floatBtn.Position
                floatMoved = false
                floatIconTween(28) -- 按下收缩动画
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if floatDragInput and app.isSameDragInput(floatDragInput, input) then
                local delta = input.Position - floatDragStart
                if math.abs(delta.X) > 8 or math.abs(delta.Y) > 8 then
                    floatMoved = true
                end
                -- 拖动时直接夹在屏幕内，拖不出屏幕
                local vp = Workspace.CurrentCamera.ViewportSize
                local sizeX = floatBtn.AbsoluteSize.X
                local sizeY = floatBtn.AbsoluteSize.Y
                local newX = math.clamp(floatStartPos.X.Offset + delta.X, 0, math.max(0, vp.X - sizeX))
                local newY = math.clamp(floatStartPos.Y.Offset + delta.Y, 0, math.max(0, vp.Y - sizeY))
                floatBtn.Position = UDim2.fromOffset(newX, newY)
            end
        end)

        UserInputService.InputEnded:Connect(function(input)
            if floatDragInput and app.isDragEndInput(floatDragInput, input) then
                if not floatMoved then
                    -- 位移小于 8px 视为点击：隐藏/打开 GUI(以 mainGuiVisible 状态变量为准)
                    setMainGuiVisible(not mainGuiVisible)
                    -- 点击脉冲动画:先弹大再回正常
                    floatIconTween(40)
                    task.delay(0.12, function()
                        floatIconTween(34)
                    end)
                else
                    floatIconTween(34) -- 拖动结束恢复
                end
                floatDragInput = nil
                floatDragStart = nil
                floatStartPos = nil
                floatMoved = false
            end
        end)

        -- 掉出屏幕检测：一旦越界（如旋转屏幕/分辨率变化），传回屏幕中心点
        -- 用 Position 偏移值 + 2px 容差判定(AbsolutePosition 有渲染延迟会误判),拖动中不检测
        task.spawn(function()
            while gui and gui.Parent do
                app.xpcallw(function()
                    if floatDragInput then return end -- 拖动中不检测,避免拖动过程被误判回中
                    local vp = Workspace.CurrentCamera.ViewportSize
                    local size = floatBtn.AbsoluteSize
                    local x = floatBtn.Position.X.Offset
                    local y = floatBtn.Position.Y.Offset
                    local TOL = 2
                    if x < -TOL or y < -TOL or x + size.X > vp.X + TOL or y + size.Y > vp.Y + TOL then
                        floatBtn.Position = UDim2.fromOffset(
                            math.max(0, (vp.X - size.X) / 2),
                            math.max(0, (vp.Y - size.Y) / 2)
                        )
                    end
                end, "悬浮按钮回中")
                task.wait(1)
            end
        end)
    end
end

-- ========== ACS 环境初始化 ==========
function app.tryGetEnv(scriptObj)
    if not app.EXEC_SUPPORT["getsenv"] then return nil end -- 执行器缺 getsenv:直接失败,避免 xpcallw 报错刷 Toast
    if not scriptObj or not scriptObj:IsA("LocalScript") then return nil end
    local success, envTemp = app.xpcallw(getsenv, "tryGetEnv", scriptObj)
    if success and envTemp and type(envTemp.setMods) == "function" then
        return envTemp
    end
    return nil
end

function app.findMainScript()
    char = LocalPlayer.Character
    for _, scriptObj in ipairs(app.collectACSScripts()) do
        local e = app.tryGetEnv(scriptObj)
        if e then return e, scriptObj end
    end
    return nil
end

function app.findModTable(env)
    if not env or not env.setMods then return nil end
    local ups = debug.getupvalues(env.setMods)
    for _, up in ipairs(ups) do
        if type(up) == "table" and up.camRecoilMod and type(up.camRecoilMod) == "table" then
            return up
        end
    end
    return nil
end

-- 收集角色 ACS_Client 下所有框架 env（可能有多个 LocalScript，重生后实例会重建）
function app.collectFrameworkEnvs()
    local envs = {}
    if not app.EXEC_SUPPORT["getsenv"] then return envs end -- 缺 getsenv:统一返回空,所有 env 依赖功能自动空转
    for _, s in ipairs(app.collectACSScripts()) do
        local ok, e = app.xpcallw(getsenv, "collectFrameworkEnvs", s)
        if ok and e and type(e.setMods) == "function" then
            table.insert(envs, e)
        end
    end
    return envs
end

-- RepValues itself may replicate before its children. In simple/2 the native
-- Equip remote must run FIRST; loadAttachment is the last global call before
-- setup reads Mag/StoredAmmo. Guard that boundary, never invent ammo objects.
function app.createAmmoSetupGuard()
    local control, records = {}, {}
    local cancelled = {}
    local function restore(e, record)
        record.Stopped = true
        app.ensureTableWritable(e)
        if e.setup == record.Setup then e.setup = record.OriginalSetup end
        if e.loadAttachment == record.Attachment then e.loadAttachment = record.OriginalAttachment end
    end
    function control.Refresh()
        if control.Stopped or type(debug.getconstants) ~= "function" then return end
        local seen = {}
        for _, e in ipairs(app.collectFrameworkEnvs()) do
            seen[e] = true
            local record = records[e]
            if record and (e.setup ~= record.Setup or e.loadAttachment ~= record.Attachment) then
                restore(e, record); records[e] = nil; record = nil
            end
            if not record and type(e.setup) == "function" and type(e.loadAttachment) == "function" then
                local ok, constants = pcall(debug.getconstants, e.setup)
                local names = {}
                if ok and type(constants) == "table" then
                    for _, value in pairs(constants) do if type(value) == "string" then names[value] = true end end
                end
                if names.RepValues and names.Mag and names.StoredAmmo and names.loadAttachment then
                    record = {OriginalSetup = e.setup, OriginalAttachment = e.loadAttachment, Generation = 0, Calls = {}}
                    local current = record
                    current.Setup = function(tool, ...)
                        current.Generation += 1
                        local thread = coroutine.running()
                        local context = {Tool = tool, Character = LocalPlayer.Character, Generation = current.Generation}
                        current.Calls[thread] = context
                        local result = table.pack(pcall(current.OriginalSetup, tool, ...))
                        current.Calls[thread] = nil
                        if not result[1] then
                            if result[2] == cancelled then return end
                            error(result[2], 0)
                        end
                        return table.unpack(result, 2, result.n)
                    end
                    current.Attachment = function(...)
                        local result = table.pack(current.OriginalAttachment(...))
                        local context = current.Calls[coroutine.running()]
                        if context then
                            local deadline = os.clock() + 15
                            while true do
                                local character, tool = context.Character, context.Tool
                                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                                if current.Stopped or current.Generation ~= context.Generation
                                    or LocalPlayer.Character ~= character or not humanoid or humanoid.Health <= 0
                                    or typeof(tool) ~= "Instance" or tool.Parent ~= character then error(cancelled, 0) end
                                local values = tool:FindFirstChild("RepValues")
                                local mag = values and values:FindFirstChild("Mag")
                                local stored = values and values:FindFirstChild("StoredAmmo")
                                if mag and stored and (mag:IsA("IntValue") or mag:IsA("NumberValue"))
                                    and (stored:IsA("IntValue") or stored:IsA("NumberValue")) then break end
                                if os.clock() >= deadline then
                                    app.recordDebugError("ACS setup", "RepValues ammo missing after 15s; re-equip " .. tool.Name)
                                    error(cancelled, 0)
                                end
                                task.wait()
                            end
                        end
                        return table.unpack(result, 1, result.n)
                    end
                    app.ensureTableWritable(e)
                    e.setup, e.loadAttachment = current.Setup, current.Attachment
                    records[e] = current
                end
            end
        end
        for e, record in pairs(records) do
            if not seen[e] then restore(e, record); records[e] = nil end
        end
    end
    function control.Destroy()
        control.Stopped = true
        for e, record in pairs(records) do restore(e, record) end
        table.clear(records)
    end
    return control
end

do
    local guard = app.createAmmoSetupGuard()
    app.xpcallw(guard.Refresh, "ACS ammo setup guard")
    local elapsed = 0
    local connection = RunService.Heartbeat:Connect(function(dt)
        elapsed += dt
        if elapsed < 0.25 then return end
        elapsed = 0
        app.xpcallw(guard.Refresh, "ACS ammo setup guard")
    end)
    gui.Destroying:Connect(function() connection:Disconnect(); guard.Destroy() end)
end

-- 收集所有框架 env 的 mod 表（setMods 的 upvalue），去重
app.allModTables = {}
function app.refreshModTables()
    table.clear(app.allModTables)
    local seen = {}
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        local ok, ups = app.xpcallw(debug.getupvalues, "refreshModTables", e.setMods)
        if ok and ups then
            for _, up in ipairs(ups) do
                if type(up) == "table" and type(up.camRecoilMod) == "table" and not seen[up] then
                    seen[up] = true
                    table.insert(app.allModTables, up)
                end
            end
        end
    end
end

-- No Recoil 主手段：把所有框架 env 的全局 Recoil 替换为空操作（框架按名字从 env 取 Recoil，变体1/2/3通用）
app.recoilNoop = function() end
app.recoilEnvBackup = {}
function app.applyNoRecoil()
    app.refreshModTables()
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        if type(e.Recoil) == "function" and e.Recoil ~= app.recoilNoop then
            app.recoilEnvBackup[e] = e.Recoil
            app.ensureTableWritable(e) -- env 可能是 readonly,先解锁再改
            e.Recoil = app.recoilNoop
        end
    end
end
function app.restoreNoRecoil()
    for e, orig in pairs(app.recoilEnvBackup) do
        app.xpcallw(function()
            app.ensureTableWritable(e)
            e.Recoil = orig
        end, "NoRecoil恢复")
    end
    table.clear(app.recoilEnvBackup)
    -- 顺带恢复 mod 表（调框架 resetMods + 手动归 1 双保险）
    app.xpcallw(function()
        if env and type(env.resetMods) == "function" then env.resetMods() end
    end, "resetMods")
    for _, mt in ipairs(app.allModTables) do
        app.xpcallw(function()
            app.ensureTableWritable(mt)
            app.ensureTableWritable(mt.camRecoilMod)
            app.ensureTableWritable(mt.gunRecoilMod)
            mt.camRecoilMod.RecoilUp = 1
            mt.camRecoilMod.RecoilLeft = 1
            mt.camRecoilMod.RecoilRight = 1
            mt.camRecoilMod.RecoilTilt = 1
            mt.gunRecoilMod.RecoilUp = 1
            mt.gunRecoilMod.RecoilLeft = 1
            mt.gunRecoilMod.RecoilRight = 1
            mt.gunRecoilMod.RecoilTilt = 1
            mt.MinRecoilPower = 1
            mt.MaxRecoilPower = 1
            mt.RecoilPowerStepAmount = 1
        end, "NoRecoil恢复")
    end
end

-- ========== Rapid Fire（不改表版） ==========
-- 旧版 Rapid Fire 直接改 Settings 表的 ShootRate,Damage 把改过的表发给服务器被校验拒收(无伤害),已删除。
-- 本版两个机制都不改原表:
-- 1) 射速:ACS 射击节奏靠 wait(60/ShootRate) 节流(v1/v2 全局 wait,v3 task.wait)。hook 这两个函数,
--    仅当"调用方是 ACS 框架脚本 且 参数≈当前武器 60/ShootRate"时替换为自定义间隔 60/RAPID_FIRE_RATE,
--    其余调用原样放行;Damage 发送的 Settings 完全是原值。
-- 2) 射击模式改 auto:把每个框架 env 的共享 Settings 上值 box 换成浅拷贝副本(仅 ShootType=3,其余字段原样)。
--    Firemode 原生就会运行时改写 ShootType(1↔2↔3),该字段动态变化属游戏正常行为,不像 ShootRate 会被校验。
--    换武器时 setup() 重新 require 会重赋 box → 下方 0.5s 周期检测并重挂。
app.rapidForgeReal = {}         -- env -> 被替换的原表(还原用)
app.rapidForgeCopy = {}         -- env -> 当前换入的副本表(弹药镜像用)
app.rapidAmmoShadow = {}        -- env -> {copyMag, realMag, copyStored, realStored} 弹药镜像快照
app.rapidForgedSet = {}         -- 副本表 -> true(识别用,防重复包装)
app.rapidAcsScripts = {}        -- ACS 框架脚本集合(getcallingscript 过滤用,0.5s 刷新)
app.rapidExpectedInterval = nil -- 当前武器 60/ShootRate(0.5s 刷新)
app.rapidWaitHookInstalled = false

function app.rapidFindSettings(e)
    local candidates = {"Shoot", "CastRay", "handleAction", "setup"}
    for _, name in ipairs(candidates) do
        local fn = rawget(e, name)
        if type(fn) == "function" then
            local ok, ups = app.xpcallw(debug.getupvalues, "RapidFire识别", fn)
            if ok and type(ups) == "table" then
                for _, up in pairs(ups) do
                    if type(up) == "table" and rawget(up, "ShootType") ~= nil and rawget(up, "ShootRate") ~= nil then
                        return up
                    end
                end
            end
        end
    end
end

app.rapidForgeFunctions = {} -- env -> {real, copy, patches, shadow}

function app.restoreRapidEntry(entry)
    for _, patch in ipairs(entry and entry.patches or {}) do
        app.xpcallw(function()
            local ups = debug.getupvalues(patch.func)
            if ups and ups[patch.index] == entry.copy then
                debug.setupvalue(patch.func, patch.index, patch.original)
            end
        end, "RapidFire还原")
    end
end

function app.applyRapidFireMode()
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        local old = app.rapidForgeFunctions[e]
        if old then
            local intact = true
            for _, patch in ipairs(old.patches) do
                local ok, ups = app.xpcallw(debug.getupvalues, "RapidFire检查", patch.func)
                if not ok or not ups or ups[patch.index] ~= old.copy then
                    intact = false
                    break
                end
            end
            if intact then
                app.rapidForgeReal[e], app.rapidForgeCopy[e] = old.real, old.copy
                app.rapidAmmoShadow[e] = old.shadow
                continue
            end
            app.restoreRapidEntry(old)
            app.rapidForgeFunctions[e] = nil
        end

        local real = app.rapidFindSettings(e)
        if real then
            local copy = {}
            for k, v in pairs(real) do copy[k] = v end
            copy.ShootType = 3
            local patches, seen = {}, {}
            for _, fn in pairs(e) do
                if type(fn) == "function" and not seen[fn] then
                    seen[fn] = true
                    local ok, ups = app.xpcallw(debug.getupvalues, "RapidFire识别", fn)
                    if ok and type(ups) == "table" then
                        for i, up in pairs(ups) do
                            if up == real then
                                local written = app.xpcallw(debug.setupvalue, "RapidFire", fn, i, copy)
                                if written then
                                    table.insert(patches, {func = fn, index = i, original = real})
                                end
                            end
                        end
                    end
                end
            end
            if #patches > 0 then
                local shadow = {
                    copyMag = copy.AmmoInGun, realMag = real.AmmoInGun,
                    copyStored = copy.StoredAmmo, realStored = real.StoredAmmo,
                }
                local entry = {real = real, copy = copy, patches = patches, shadow = shadow}
                app.rapidForgeFunctions[e] = entry
                app.rapidForgeReal[e], app.rapidForgeCopy[e] = real, copy
                app.rapidAmmoShadow[e] = shadow
                app.rapidForgedSet[copy] = true
            end
        end
    end
end

function app.restoreRapidFireMode()
    for e, entry in pairs(app.rapidForgeFunctions) do
        app.restoreRapidEntry(entry)
        app.rapidForgeFunctions[e] = nil
    end
    table.clear(app.rapidForgeReal)
    table.clear(app.rapidForgeCopy)
    table.clear(app.rapidAmmoShadow)
    table.clear(app.rapidForgedSet)
end

-- Rapid Fire 弹药镜像(last-writer-wins):卸载时 ACS 把弹匣/备弹写回 v_u_12 表(v2@1093),
-- 但 box 被我们换成了副本 → 写进副本,重装备时 setup 重 require 原表 → 弹药"回满"(bug)。
-- 每帧双向同步副本↔原表的 AmmoInGun/StoredAmmo:哪边变了传播哪边,原表始终最新,重装不再回满;
-- 补给箱写原表 StoredAmmo(v2@2732)也会反向传播进副本,两个方向都不丢
function app.syncRapidAmmoTables()
    for e, real in pairs(app.rapidForgeReal) do
        local copy = app.rapidForgeCopy[e]
        local sh = app.rapidAmmoShadow[e]
        if copy and sh then
            if rawget(copy, "AmmoInGun") ~= sh.copyMag then
                rawset(real, "AmmoInGun", rawget(copy, "AmmoInGun"))
            elseif rawget(real, "AmmoInGun") ~= sh.realMag then
                rawset(copy, "AmmoInGun", rawget(real, "AmmoInGun"))
            end
            if rawget(copy, "StoredAmmo") ~= sh.copyStored then
                rawset(real, "StoredAmmo", rawget(copy, "StoredAmmo"))
            elseif rawget(real, "StoredAmmo") ~= sh.realStored then
                rawset(copy, "StoredAmmo", rawget(real, "StoredAmmo"))
            end
            sh.copyMag = rawget(copy, "AmmoInGun")
            sh.realMag = rawget(real, "AmmoInGun")
            sh.copyStored = rawget(copy, "StoredAmmo")
            sh.realStored = rawget(real, "StoredAmmo")
        end
    end
end

-- ===== Infinite Ammo:每帧把弹匣上值钉回满弹 =====
-- 识别规则:优先使用 Settings/RepValues 中当前弹匣值作为评分基准，
-- 再从 Shoot 的数字上值中选择落在弹容范围内且最接近当前弹匣的候选；
-- 没有客户端弹匣读数时才退回捕获顺序，兼容三种 ACS 变体。
app.infiniteAmmoCache = {} -- env -> {func=Shoot, idx=弹匣上值序号, settings=配置表(副本或原表)}

function app.identifyInfiniteAmmo()
    table.clear(app.infiniteAmmoCache)
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        if type(e.Shoot) == "function" then
            local okS, upsS = app.xpcallw(debug.getupvalues, "InfiniteAmmo", e.Shoot)
            if okS and type(upsS) == "table" then
                local settings = app.rapidForgeReal[e] or app.rapidFindSettings(e)
                local magCap = settings and (
                    tonumber(rawget(settings, "Ammo")) or tonumber(rawget(settings, "MaxAmmo"))
                    or tonumber(rawget(settings, "MagazineSize"))
                )
                local expected = settings and tonumber(rawget(settings, "AmmoInGun"))
                local weapon = app.getCurrentWeapon and app.getCurrentWeapon()
                local repValues = weapon and weapon:FindFirstChild("RepValues")
                local repMag = repValues and repValues:FindFirstChild("Mag")
                if repMag and type(repMag.Value) == "number" then expected = repMag.Value end
                local bestIndex, bestScore
                for i, up in ipairs(upsS) do
                    if type(up) == "number" and up >= 0 and up == up
                        and (not magCap or up <= magCap + 1) then
                        local score = expected and math.abs(up - expected) or (up == 0 and 1000000 or i)
                        if not bestScore or score < bestScore then
                            bestIndex, bestScore = i, score
                        end
                    end
                end
                if bestIndex then
                    app.infiniteAmmoCache[e] = {
                        func = e.Shoot, idx = bestIndex, settings = settings, magCap = magCap,
                    }
                end
            end
        end
    end
end

function app.pinInfiniteAmmo()
    for e, rec in pairs(app.infiniteAmmoCache) do
        app.xpcallw(function()
            local magCap = tonumber(rec.magCap) or (rec.settings and (tonumber(rawget(rec.settings, "Ammo")) or tonumber(rawget(rec.settings, "MaxAmmo")) or tonumber(rawget(rec.settings, "MagazineSize")))) or 30
            -- 卡壳时钉 0:换弹守卫要求弹匣 < 弹容才放行(v2@1844),Reload 是唯一解卡途径,
            -- 满弹钉死会导致永远无法按 R 解卡;钉 0 放行换弹,解卡后下一帧恢复钉满
            local jammed = rec.settings and rawget(rec.settings, "Jammed") == true
            debug.setupvalue(rec.func, rec.idx, jammed and 0 or (magCap + 1))
        end, "InfiniteAmmo")
    end
end

-- ===== Instant Equip：在 hook 返回的原 Lua closure 上修改可行动标志 =====
app.instantEquipBackup = {} -- env -> hook record

function app.applyInstantEquip()
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        local f = rawget(e, "EquipAnim")
        local previous = app.instantEquipBackup[e]
        if previous and previous.target ~= f then
            app.restoreHookFunction(previous)
            app.instantEquipBackup[e] = nil
            previous = nil
        end
        if not previous and type(f) == "function" then
            -- 更新版 v1 和旧 v1/v2/v3 均只有一个直接捕获的 boolean（可行动状态）。
            -- 在 hook 前识别，不能对 hook 后的 C closure 使用原 Lua upvalue 索引。
            local ok, upvalues = app.xpcallw(debug.getupvalues, "InstantEquip识别", f)
            local readyIndex, count = nil, 0
            if ok and type(upvalues) == "table" then
                for index, value in pairs(upvalues) do
                    if type(index) == "number" and type(value) == "boolean" then
                        readyIndex = index
                        count += 1
                    end
                end
            end
            if count == 1 then
                local original
                local old, record = app.installHookFunction(f, function(...)
                    if not original then return end
                    if not instantEquipEnabled then return original(...) end
                    local written = app.xpcallw(debug.setupvalue, "InstantEquip写入", original, readyIndex, true)
                    if not written then return original(...) end -- 不把装备状态卡死
                end, "InstantEquip")
                if record then
                    original = old
                    record.readyIndex = readyIndex
                    app.instantEquipBackup[e] = record
                end
            end
        end
    end
end

function app.restoreInstantEquip()
    for e, record in pairs(app.instantEquipBackup) do
        app.xpcallw(function()
            app.ensureTableWritable(e)
            if not app.restoreHookFunction(record) and e.EquipAnim == record.target then
                e.EquipAnim = record.original
            end
        end, "InstantEquip恢复")
    end
    table.clear(app.instantEquipBackup)
end

-- ===== Instant Aim:瞄准 FOV 补间时间归零 =====
-- v1/v2:瞄准 FOV 补间共用脚本级常量 TweenInfo 上值(v_u_71@143,0.2s)——setupvalue 成 0 时长即可,常量不被重写,一次到位。
-- v3:补间是渲染循环内联 TweenInfo.new(v_u_83) 创建,时间是脚本数值上值(setup 时从 Settings.AimZoomSpeed 重读,默认 0.3)
--     ——识别:数值==AimZoomSpeed(非整数,避开弹匣)且被 ≥3 个函数捕获(共享脚本级 local 的特征);装备会被重写,需要每 0.5s 重钉。
app.instantAimBackup = {} -- env -> { {f=函数, i=上值索引, v=原值, num=是否数值型}, ... }

-- 找武器的 Settings 表(与 infinite ammo 同一识别:Shoot/CastRay 上值里带 ShootType+ShootRate 的表)
function app.findAcsSettings(e)
    for _, fname in ipairs({"Shoot", "CastRay"}) do
        local f = rawget(e, fname)
        if type(f) == "function" then
            for _, uv in ipairs(debug.getupvalues(f)) do
                if type(uv) == "table" and rawget(uv, "ShootType") ~= nil and rawget(uv, "ShootRate") ~= nil then
                    return uv
                end
            end
        end
    end
    return nil
end

function app.applyInstantAim()
    for _, e in ipairs(app.collectFrameworkEnvs()) do
        if not app.instantAimBackup[e] then
            local recs = {}
            for _, v in pairs(e) do
                if type(v) == "function" then
                    for i, uv in ipairs(debug.getupvalues(v)) do
                        if typeof(uv) == "TweenInfo" and uv.Time > 0 then
                            table.insert(recs, {f = v, i = i, v = uv, num = false})
                        end
                    end
                end
            end
            if #recs == 0 then
                -- v3 分支:数值上值
                local settings = app.findAcsSettings(e)
                local aimSpeed = settings and rawget(settings, "AimZoomSpeed") or 0.3
                if type(aimSpeed) == "number" and aimSpeed > 0 and aimSpeed % 1 ~= 0 then
                    for _, v in pairs(e) do
                        if type(v) == "function" then
                            for i, uv in ipairs(debug.getupvalues(v)) do
                                if type(uv) == "number" and math.abs(uv - aimSpeed) < 1e-6 then
                                    table.insert(recs, {f = v, i = i, v = uv, num = true})
                                end
                            end
                        end
                    end
                    if #recs < 3 then
                        recs = {} -- 捕获函数数不足,不是共享的瞄准时间上值,不动(防误伤)
                    end
                end
            end
            if #recs > 0 then
                app.instantAimBackup[e] = recs
                for _, rec in ipairs(recs) do
                    if rec.num then
                        debug.setupvalue(rec.f, rec.i, 0)
                    else
                        debug.setupvalue(rec.f, rec.i, TweenInfo.new(0, Enum.EasingStyle.Linear))
                    end
                end
            end
        end
    end
end

-- v3 的瞄准时间上值会在每次装备时被 setup 重写,周期性重钉 0(并刷新备份值,关闭时还原到最新)
function app.pinInstantAim()
    for _, recs in pairs(app.instantAimBackup) do
        for _, rec in ipairs(recs) do
            if rec.num then
                local cur = debug.getupvalue(rec.f, rec.i)
                if type(cur) == "number" and cur ~= 0 then
                    rec.v = cur
                    debug.setupvalue(rec.f, rec.i, 0)
                end
            end
        end
    end
end

function app.restoreInstantAim()
    for e, recs in pairs(app.instantAimBackup) do
        for _, rec in ipairs(recs) do
            app.xpcallw(function()
                debug.setupvalue(rec.f, rec.i, rec.v)
            end, "InstantAim恢复")
        end
    end
    table.clear(app.instantAimBackup)
end

-- hook wait/task.wait(幂等,只装一次):只拦截 ACS 脚本的射击节流调用,其余原样放行
function app.installRapidFireWaitHook()
    if app.rapidWaitHookInstalled then return end
    app.rapidWaitHookInstalled = true
    local function shouldAccelerate(t)
        if not rapidFireEnabled or type(t) ~= "number" or not app.rapidExpectedInterval then
            return false
        end
        if math.abs(t - app.rapidExpectedInterval) > 0.001 then
            return false
        end
        local cs = getcallingscript()
        return cs ~= nil and app.rapidAcsScripts[cs] == true
    end
    local oldW
    local waitHook
    waitHook = app.makeHookCClosure(wait, function(...)
        local t = select(1, ...)
        if shouldAccelerate(t) then
            return oldW(60 / app.RAPID_FIRE_RATE)
        end
        return oldW(...)
    end)
    if not waitHook then
        app.rapidWaitHookInstalled = false
        return
    end
    local okW
    okW, oldW = pcall(hookfunction, wait, waitHook)
    if not okW or type(oldW) ~= "function" then
        app.rapidWaitHookInstalled = false
        return
    end
    app.HOOK_CLOSURE_RECORDS[wait] = {
        target = wait,
        original = oldW,
        replacement = waitHook,
        tag = "RapidFire.wait",
    }
    local oldTW
    local taskWaitHook
    taskWaitHook = app.makeHookCClosure(task.wait, function(...)
        local t = select(1, ...)
        if shouldAccelerate(t) then
            return oldTW(60 / app.RAPID_FIRE_RATE)
        end
        return oldTW(...)
    end)
    if not taskWaitHook then
        app.restoreHookFunction(app.HOOK_CLOSURE_RECORDS[wait])
        app.rapidWaitHookInstalled = false
        return
    end
    local okTW
    okTW, oldTW = pcall(hookfunction, task.wait, taskWaitHook)
    if not okTW or type(oldTW) ~= "function" then
        app.restoreHookFunction(app.HOOK_CLOSURE_RECORDS[wait])
        app.rapidWaitHookInstalled = false
        return
    end
    app.HOOK_CLOSURE_RECORDS[task.wait] = {
        target = task.wait,
        original = oldTW,
        replacement = taskWaitHook,
        tag = "RapidFire.task.wait",
    }
end

-- Rapid Fire 周期维护(0.5s):刷新 ACS 脚本集合 + 当前武器射击间隔期望值 + 重挂 ShootType 副本
task.spawn(function()
    while true do
        task.wait(0.5)
        if rapidFireEnabled then
            table.clear(app.rapidAcsScripts)
            for _, scriptObj in ipairs(app.collectACSScripts()) do
                app.rapidAcsScripts[scriptObj] = true
            end
            app.xpcallw(function()
                -- getWeaponConfig 走 require 拿模块缓存原表,ShootRate 是真实值(不受 ShootType 副本影响)
                local w = app.getCurrentWeapon and app.getCurrentWeapon()
                local cfg = w and app.getWeaponConfig and app.getWeaponConfig(w)
                local sr = cfg and tonumber(cfg.ShootRate)
                if sr and sr > 0 then
                    app.rapidExpectedInterval = 60 / sr
                end
            end, "RapidFire")
            app.xpcallw(app.applyRapidFireMode, "RapidFire")
        end
    end
end)

function app.getAccessId(env)
    local Events = ReplicatedStorage:FindFirstChild("ACS_Engine") and ReplicatedStorage.ACS_Engine:FindFirstChild("Events")
    if Events then
        local acessRemote = Events:FindFirstChild("AcessId") or Events:FindFirstChild("AccessId")
        if acessRemote and acessRemote:IsA("RemoteFunction") then
            local success, result = app.xpcallw(function()
                return acessRemote:InvokeServer(LocalPlayer.UserId)
            end, "getAccessId")
            if success and type(result) == "string" then
                return result
            end
        end
    end
    if env and env.CastRay then
        local ups = debug.getupvalues(env.CastRay)
        for _, up in ipairs(ups) do
            if type(up) == "string" and (up:match("%x+%-%x+%-%x+%-%x+%-%x+") or up:match("%x+")) then
                return up
            end
        end
    end
    if env and env.Shoot then
        local ups = debug.getupvalues(env.Shoot)
        for _, up in ipairs(ups) do
            if type(up) == "string" and (up:match("%x+%-%x+%-%x+%-%x+%-%x+") or up:match("%x+")) then
                return up
            end
        end
    end
    return nil
end

function app.initEnvironment()
    local e = app.findMainScript()
    if not e then return false end
    env = e
    modTable = app.findModTable(env)
    accessId = app.getAccessId(env)
    return modTable ~= nil and accessId ~= nil
end

startup.stage = "读取 ACS 模组与 AccessId"
app.startupReport(startup, "正在读取 ACS 模组与 AccessId…", false)
environmentLoaded = app.initEnvironment()
if not environmentLoaded then
    error("ACS 已识别，但 modTable 或 AccessId 未就绪。请重新进入服务器后重试。", 0)
end
if not firstSuccessShown then
    app.showNotification("CheatGPT.cc", "ACS 环境加载成功", 3)
    firstSuccessShown = true
end
startup.stage = "连接功能与事件"

local Events = ReplicatedStorage:FindFirstChild("ACS_Engine") and ReplicatedStorage.ACS_Engine:FindFirstChild("Events")
local Damage = Events and Events:FindFirstChild("Damage")
app.suppressionRemote = Events and Events:FindFirstChild("Suppression")
local isDamageFunction = Damage and Damage:IsA("RemoteFunction")

-- 已更新样本：变体 1 的姿态函数组 + 无 CreateShell 对应 10 参数；2/3 为 9 参数；
-- 变体 4 的 recapSpot/hitRegion 对应 14 参数。未知框架保留旧的 9 参数路径。
function app.getDamageArgumentCount()
    if env and type(env.recapSpot) == "function" and type(env.hitRegion) == "function" then return 14 end
    if env and type(env.HighReady) == "function" and type(env.LowReady) == "function"
        and type(env.Patrol) == "function" and type(env.CreateShell) ~= "function" then return 10 end
    return 9
end

function app.buildDamageArgs(weapon, humanoid, distance, zone, config, hitPart, hitPos, shotOrigin, shotDirection)
    if not hitPart or not hitPart.Parent or not modTable or not accessId then return nil end
    local count = app.getDamageArgumentCount()
    if count == 14 then
        local ok, region = app.xpcallw(env.hitRegion, "Damage区域", hitPart)
        if not ok or not region then return nil end
        zone = region
    end
    local args = table.pack(weapon, humanoid, distance, zone, config, modTable, nil, nil, accessId .. "-" .. LocalPlayer.UserId)
    if count >= 10 then args[10] = hitPart.Name end
    if count == 14 then
        local ok, spot = app.xpcallw(env.recapSpot, "Damage落点", hitPart, hitPos)
        if not ok or not spot then return nil end
        args[11] = spot
        args[12] = shotOrigin
        args[13] = shotDirection
        args[14] = hitPos
    end
    args.n = count -- nil 占位必须保留，不能依赖含空洞数组的 # / 默认 unpack 上界。
    return args
end

function app.sendDamage(args)
    if not args or not Damage then return false end
    -- Presentation metadata only; damage arguments and acceptance remain unchanged.
    if app.killEffect then pcall(app.killEffect.ObserveHit, args[2], args[1], args[4]) end
    local ok, result = app.xpcallw(function()
        if isDamageFunction then return Damage:InvokeServer(table.unpack(args, 1, args.n)) end
        Damage:FireServer(table.unpack(args, 1, args.n))
        return true
    end, "Damage")
    -- 变体 4 原版明确要求 true；网络调用没报错不等于服务器接受命中。
    return ok and result ~= false and (args.n ~= 14 or result == true)
end

-- 获取当前武器工具
function app.getCurrentWeapon()
    if not char then char = LocalPlayer.Character end
    if not char then return nil end
    for _, tool in ipairs(char:GetChildren()) do
        if tool:IsA("Tool") and tool:FindFirstChild("ACS_Settings") then
            return tool
        end
    end
    return nil
end

function app.getWeaponConfig(weapon)
    local settings = weapon and weapon:FindFirstChild("ACS_Settings")
    return settings and require(settings)
end

-- 改进的 getWeaponFirePoint：返回道具部件的 Position、CFrame 和部件引用，供 RageBot 缓存发射点。
local function getWeaponFirePoint(weapon)
    if not weapon then
        return nil
    end

    if weapon.PrimaryPart and weapon.PrimaryPart:IsA("BasePart") then
        return weapon.PrimaryPart.Position, weapon.PrimaryPart.CFrame, weapon.PrimaryPart
    end

    local handle = weapon:FindFirstChild("Handle")
    if handle and handle:IsA("BasePart") then
        return handle.Position, handle.CFrame, handle
    end

    for _, obj in ipairs(weapon:GetDescendants()) do
        if obj:IsA("BasePart") then
            return obj.Position, obj.CFrame, obj
        end
    end

    return nil
end

-- 辅助函数
function app.getHead(player)
    local c = player.Character
    return c and c:FindFirstChild("Head")
end

-- RageBot 的 UI 使用 R6 命名；R15 角色没有同名部件时，使用语义对应的部件作为兼容回退。
function app.getRageHitPartFromCharacter(character, selectedName)
    if not character then return nil end

    local fallbacks = app.RAGE_HIT_PART_FALLBACKS
    for _, partName in ipairs(fallbacks[selectedName] or fallbacks.Head) do
        local part = character:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            return part
        end
    end
    return nil
end

function app.getRageHitPart(player, selectedName)
    return app.getRageHitPartFromCharacter(player and player.Character, selectedName)
end

function app.getRageCharacterState(player)
    local character = player and player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return nil
    end
    return character, humanoid
end

function app.isAlive(player)
    local c = player.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0
end

function app.hasShield(player, character)
    local c = character or (player and player.Character)
    if not c then return false end
    if c:FindFirstChildOfClass("ForceField") then
        return true
    end
    local shield = c:FindFirstChild("Shield", true)
    if shield and (shield:IsA("BasePart") or shield:IsA("Model")) then
        return true
    end
    return false
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist
rayParams.IgnoreWater = true

function app.raycastToTarget(origin, targetPart)
    rayParams.FilterDescendantsInstances = {char}
    local direction = targetPart.Position - origin
    local result = Workspace:Raycast(origin, direction, rayParams)
    return result and result.Instance:IsDescendantOf(targetPart.Parent) and result or nil
end

function app.canPenetrate(origin, targetPart)
    -- 已弃用:WallBang 开启时不再做穿透检测,直接攻击
    return true
end

function app.getHitZone(part)
    if app.getDamageArgumentCount() == 14 then return env.hitRegion(part) or 2 end
    local name = part.Name
    if name == "Head" or name:find("Face") then return 1 end
    if name:find("Torso") or name:find("Arm") or name:find("Hand") then return 2 end
    if name:find("Leg") or name:find("Foot") then return 3 end
    return 2
end

-- ===== 瞬发命中(Accelerate Muzzle Velocity 的核心):初速就绪后直接完成整条弹道 =====
-- 机制:读取子弹实际初速方向 → 从枪口做一条连续 raycast(无步进,不可能跨过目标,根治空枪;
-- 原版割线步进每帧飞 (弹速/帧率) studs,弹速一高就整步跨过目标,旧 9000 折中方案就此废弃)
-- → 依赖就绪时先销毁原子弹，再按当前框架的参数布局发 Damage。游戏 CastRay 循环每轮在
-- Heartbeat:Wait() 后检查 bullet.Parent；接管后原循环退出，不再继续处理这颗子弹。
-- 穿透规则逐项镜像 ACS 原版(v2@1330-1364):饰品/护甲/不可碰撞杂件跳过,20 个身体部位名除外。
app.instantHitBodyPartNames = {
    Head = true, ["Right Arm"] = true, ["Left Arm"] = true, ["Right Leg"] = true, ["Left Leg"] = true,
    UpperTorso = true, LowerTorso = true,
    RightUpperArm = true, RightLowerArm = true, RightHand = true,
    LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
    RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
    LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
}
app.instantHitArmorParentNames = {
    Top = true, Helmet = true, Up = true, Down = true, Face = true, Olho = true,
    Headset = true, Numero = true, Vest = true, Chest = true, Waist = true,
    Back = true, Belt = true, Leg1 = true, Leg2 = true, Arm1 = true, Arm2 = true,
}

-- 命中部位分区：变体 4 使用框架 hitRegion，其余保留旧版分区。
function app.instantHitZone(inst)
    if app.getDamageArgumentCount() == 14 then return env.hitRegion(inst) or 2 end
    local n = inst.Name
    local pn = inst.Parent and inst.Parent.Name or ""
    if n == "Head" or pn == "Top" or pn == "Headset" or pn == "Olho" or pn == "Face" or pn == "Numero" then
        return 1
    end
    if n == "Right Leg" or n == "Left Leg" or n:find("Leg") or n:find("Foot") then
        return 3
    end
    return 2
end

function app.doInstantHit(part, showTrace, launchOrigin, launchDirection, cameraOrigin, onClaim)
    if not part or not part.Parent then return end
    local origin = launchOrigin or part.Position
    local velocity = part.AssemblyLinearVelocity
    if not modTable or not accessId or not Damage then return end
    if not char or not char.Parent then char = LocalPlayer.Character end
    if not char then return end
    local weapon = app.getCurrentWeapon()
    if not weapon then return end
    local weaponConfig = app.getWeaponConfig(weapon)
    if not weaponConfig then return end
    local direction = launchDirection or ((velocity and velocity.Magnitude >= 1) and velocity.Unit)
    if not direction then return false end
    local shotOrigin = cameraOrigin or (Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position) or origin
    -- 依赖就绪后才接管；否则保留游戏子弹，避免初始化/换枪期间吞掉正常射击。
    if not app.xpcallw(function() part:Destroy() end, "InstantHit") then return false end
    if onClaim then onClaim() end

    -- 连续射线 + 穿透循环(规则镜像 ACS 原版),最多 16 段,射程上限取原版 7000 杀线
    local ignore = { part, char, Workspace.CurrentCamera }
    local acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
    if acsWorkspace then
        table.insert(ignore, acsWorkspace)
    end
    local rayParamsInstant = RaycastParams.new()
    rayParamsInstant.FilterType = Enum.RaycastFilterType.Exclude
    rayParamsInstant.IgnoreWater = true
    local rayOrigin = origin
    local hitPart, hitPos, hitNormal, hitMaterial = nil, nil, nil, nil
    for _ = 1, 16 do
        rayParamsInstant.FilterDescendantsInstances = ignore
        local result = Workspace:Raycast(rayOrigin, direction * 7000, rayParamsInstant)
        if not result then break end
        local inst = result.Instance
        local pn = inst.Parent and inst.Parent.Name or ""
        local passThrough = false
        if inst.Parent and (inst.Parent:IsA("Accessory") or inst.Parent:IsA("Hat")) then
            passThrough = true
        elseif inst.Name == "Ignorable" or inst.Name == "Glass" or inst.Name == "Ignore" or app.instantHitArmorParentNames[pn] then
            passThrough = true
        elseif (inst.Transparency >= 1 or not inst.CanCollide)
            and not app.instantHitBodyPartNames[inst.Name]
            and inst.Name ~= "Armor" and inst.Name ~= "EShield" then
            passThrough = true
        end
        if passThrough then
            table.insert(ignore, inst)
            rayOrigin = result.Position + direction * 0.01 -- 越过已命中面,防同点重复命中
        else
            hitPart, hitPos, hitNormal, hitMaterial = inst, result.Position, result.Normal, result.Material
            break
        end
    end

    -- 未命中任何东西:beam 画到弹道尽头,无伤害
    if not hitPart then
        if showTrace then app.createForwardBeamToPoint(origin, origin + direction * 7000) end
        return true
    end

    -- 轨迹描述已经发生的射击，不依赖 Damage 的返回值，拒绝命中也不应吞掉 Self 轨迹。
    if showTrace then app.createForwardBeamToPoint(origin, hitPos) end

    -- 冲击特效(与原版一致转发服务器,其他玩家也能看到血花/火花)
    app.xpcallw(function()
        local hitEffect = Events and Events:FindFirstChild("HitEffect")
        if hitEffect then
            hitEffect:FireServer(hitPos, hitPart, hitNormal, hitMaterial, app.getDamageArgumentCount() == 14 and {} or weaponConfig)
        end
    end, "InstantHit")

    -- 命中角色:构造对应变体的参数,weaponConfig/modTable 保持原表。
    local model = hitPart:FindFirstAncestorOfClass("Model")
    local humanoid = model and model:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 then
        local distance = (hitPos - origin).Magnitude
        local zone = app.instantHitZone(hitPart)
        local targetPlayer = Players:GetPlayerFromCharacter(model)
        local cancelWatch = targetPlayer and createDamageWatch(targetPlayer, hitPart.Name, distance, zone == 1) or function() end
        local args = app.buildDamageArgs(weapon, humanoid, distance, zone, weaponConfig, hitPart, hitPos, shotOrigin, direction)
        local success = app.sendDamage(args)
        if success then
            app.playHitsound()
            app.showHitmarker(args[4] == 1, hitPos, hitPart)
        else
            cancelWatch()
        end
    end
    return true
end

function app.randomOrbitPoint(pos, radius)
    local theta = math.rad(math.random(0, 360))
    local phi = math.rad(math.random(-90, 90))
    return pos + Vector3.new(
        math.cos(theta) * math.cos(phi),
        math.sin(phi),
        math.sin(theta) * math.cos(phi)
    ) * radius
end

-- Beam 总量管控:同时最多存在 64 条 beam root,超出时按 FIFO 删除最旧的再登记新的;
-- 并提供一次性清空全部 beam 的入口。queue/limit 收进 do-end 块,不占 top-level local 名额
do
    local beamQueue = {}
    local queueHead = 1
    local queueTail = 0
    local MAX_BEAM_COUNT = 64
    local beamWindowAt = 0
    local beamWindowCount = 0
    local BEAM_WINDOW = 0.05
    local MAX_NEW_BEAMS_PER_WINDOW = 6

    -- 登记一条新 beam root:用 head 指针代替 table.remove(1)，避免高射速下反复搬移整个队列。
    function app.registerBeamRoot(root)
        local now = os.clock()
        if now - beamWindowAt >= BEAM_WINDOW then
            beamWindowAt = now
            beamWindowCount = 0
        end
        if beamWindowCount >= MAX_NEW_BEAMS_PER_WINDOW then
            return false
        end
        beamWindowCount += 1
        while queueHead <= queueTail do
            local oldest = beamQueue[queueHead]
            if oldest and oldest.Parent then break end
            beamQueue[queueHead] = nil
            queueHead += 1
        end
        if queueHead > queueTail then
            table.clear(beamQueue)
            queueHead = 1
            queueTail = 0
        end
        while queueTail - queueHead + 1 >= MAX_BEAM_COUNT do
            local oldest = beamQueue[queueHead]
            beamQueue[queueHead] = nil
            queueHead += 1
            if oldest and oldest.Parent then
                oldest:Destroy()
            end
        end
        queueTail += 1
        beamQueue[queueTail] = root
        -- 长时间运行后压缩已消费的前缀，保持队列本身较小。
        if queueHead > 64 and queueHead > queueTail / 2 then
            local compacted = {}
            for i = queueHead, queueTail do
                compacted[#compacted + 1] = beamQueue[i]
            end
            beamQueue = compacted
            queueHead = 1
            queueTail = #compacted
        end
        return true
    end

    -- 立即销毁队列中所有仍存活的 beam root 并清空队列
    function app.clearAllBeams()
        for i = queueHead, queueTail do
            local b = beamQueue[i]
            if b and b.Parent then
                b:Destroy()
            end
        end
        table.clear(beamQueue)
        queueHead = 1
        queueTail = 0
    end
end

-- 创建光束
app.TRACE_BASIC_TEXTURE = "rbxassetid://232918622"
app.TRACE_STYLED_TEXTURE = "rbxassetid://446111271"
function app.getTraceTexture()
    return app.TRACE_STYLE == "Styled" and app.TRACE_STYLED_TEXTURE or app.TRACE_BASIC_TEXTURE
end

function app.createBeamWithFade(a0, a1, root, width0, width1, holdTime, selfBullet)
    local texture = app.getTraceTexture()
    local color = selfBullet == false and app.TRACE_OTHERS_COLOR or app.TRACE_SELF_COLOR
    local transparency = selfBullet == false and app.TRACE_OTHERS_TRANSPARENCY or app.TRACE_SELF_TRANSPARENCY
    local glow = Instance.new("Beam")
    glow.Name = app.randomName()
    glow.Attachment0 = a0
    glow.Attachment1 = a1
    glow.Color = ColorSequence.new(color)
    glow.Transparency = NumberSequence.new(transparency)
    glow.LightEmission = 0.25
    glow.LightInfluence = 0
    glow.FaceCamera = true
    glow.Texture = texture
    glow.TextureMode = Enum.TextureMode.Stretch
    glow.Parent = a0

    local core = Instance.new("Beam")
    core.Name = app.randomName()
    core.Attachment0 = a0
    core.Attachment1 = a1
    core.Color = ColorSequence.new(color)
    core.Transparency = NumberSequence.new(transparency)
    core.FaceCamera = true
    core.Texture = texture
    core.TextureMode = Enum.TextureMode.Stretch
    core.Parent = a0

    -- 保留原有淡入/淡出动画，但不使用 Completed 回调链和 task.wait：
    -- 淡入立即开始，按 holdTime 延迟淡出，root 仍由调用方统一销毁。
    glow.Width0 = 0
    glow.Width1 = 0
    core.Width0 = 0
    core.Width1 = 0

    local fadeIn = TweenService:Create(glow, TweenInfo.new(app.FADE_TIME, Enum.EasingStyle.Linear), {
        Width0 = width0,
        Width1 = width1,
    })
    local fadeInCore = TweenService:Create(core, TweenInfo.new(app.FADE_TIME, Enum.EasingStyle.Linear), {
        Width0 = width0 * 0.64,
        Width1 = width1 * 0.625,
    })
    fadeIn:Play()
    fadeInCore:Play()

    task.delay(app.FADE_TIME + math.max(0, holdTime), function()
        if not (root and root.Parent) then return end
        local fadeOut = TweenService:Create(glow, TweenInfo.new(app.FADE_TIME, Enum.EasingStyle.Linear), {
            Width0 = 0,
            Width1 = 0,
        })
        local fadeOutCore = TweenService:Create(core, TweenInfo.new(app.FADE_TIME, Enum.EasingStyle.Linear), {
            Width0 = 0,
            Width1 = 0,
        })
        fadeOut:Play()
        fadeOutCore:Play()
    end)
end

-- 轨迹绘制
-- 从 origin 到任意终点的直线 beam(瞬发命中的弹道视觉也用它)
function app.createForwardBeamToPoint(origin, endPos, selfBullet)
    if not app.isBulletTraceEnabled() then return end -- Bullet Trace 总开关关闭:不创建任何 beam
    local root = Instance.new("Attachment")
    root.Name = app.randomName()
    root.Parent = tracesFolder
    if app.registerBeamRoot(root) == false then
        root:Destroy()
        return false
    end

    local a0 = Instance.new("Attachment")
    a0.Name = app.randomName()
    a0.WorldPosition = origin
    a0.Parent = root

    local a1 = Instance.new("Attachment")
    a1.Name = app.randomName()
    a1.WorldPosition = endPos
    a1.Parent = root

    local holdTime = math.max(0, app.TRACE_LIFETIME - 2 * app.FADE_TIME)

    -- 轨迹永远为直线
    app.createBeamWithFade(a0, a1, root, app.TRACE_WIDTH, app.TRACE_WIDTH * 0.57, holdTime, selfBullet)
    task.delay(app.TRACE_LIFETIME, root.Destroy, root)
    return true, root, a0, a1
end

-- 每个目标部位各自独立的 beam 冷却(私有状态表字段,不增加 local 名额):
-- 多目标齐射时每个目标的 beam 都能同帧显示,不再被全局单时间戳压成"一次只出一条"
app.traceBeamLastPerPart = {}

function app.createForwardBeam(origin, targetHead)
    if not app.isBulletTraceEnabled() then return end -- Bullet Trace 总开关关闭:不创建任何 beam
    local now = tick()
    local last = app.traceBeamLastPerPart[targetHead]
    if last and now - last < app.TRACE_COOLDOWN then return end
    app.traceBeamLastPerPart[targetHead] = now
    -- 条目超 128 时清掉已过期的(含已死亡目标的残留 key),防表无限增长
    local count = 0
    for _ in pairs(app.traceBeamLastPerPart) do
        count += 1
        if count > 128 then break end
    end
    if count > 128 then
        for part, t in pairs(app.traceBeamLastPerPart) do
            if now - t >= app.TRACE_COOLDOWN then
                app.traceBeamLastPerPart[part] = nil
            end
        end
    end

    app.createForwardBeamToPoint(origin, targetHead.Position)
end

-- 播放命中音效
local lastHitSoundTime = 0
function app.playHitsound(preview)
    if not app.HITSOUND_ENABLED then return end
    local now = tick()
    if now - lastHitSoundTime < app.HITSOUND_COOLDOWN then return end
    lastHitSoundTime = now
    if app.HITSOUND_KEY == "Glass" then
        app.playGlassSound(preview)
        return
    end
    local sound = Instance.new("Sound")
    sound.Name = app.randomName()
    sound.SoundId = app.getHitsoundId(app.HITSOUND_KEY)
    sound.Volume = app.HITSOUND_VOLUME
    sound.Parent = secureParent
    sound:Play()
    sound.Ended:Once(function() sound:Destroy() end)
    game:GetService("Debris"):AddItem(sound, 10)
end

-- Preview bypasses the hit cooldown, with no separate preload gate.
function app.previewHitsound()
    if not app.HITSOUND_ENABLED then return end
    lastHitSoundTime = 0
    app.playHitsound(true)
end

-- 给角色 Humanoid 挂血量监听:血量归零时立即清空全部 beam
function app.hookDeathBeamClear(character)
    if not character then return end
    local hum = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
    if hum then
        hum.HealthChanged:Connect(function(hp)
            if hp <= 0 then
                app.clearAllBeams()
            end
        end)
    end
end

-- 角色重生处理（含 Fly 和 Spin 自动停止）
LocalPlayer.CharacterAdded:Connect(function(newChar)
    char = newChar
    app.clearAllBeams() -- 重生瞬间清空上一具角色残留的全部 beam
    task.wait(0.2)
    table.clear(originalProperties)
    if characterChamsEnabled then
        app.applyCharacterChams()
    end
    -- 重生时自动停止飞行和旋转
    if flying then
        stopFly()
    end
    if spinning then
        stopSpin()
    end
    -- 新角色血量归零时清空全部 beam
    app.hookDeathBeamClear(newChar)
end)

-- 脚本执行时已存在的当前角色也挂同样的监听(异步调用,避免 WaitForChild 阻塞主流程)
task.spawn(app.hookDeathBeamClear, LocalPlayer.Character)

-- 第三人称强制刷新
task.spawn(function()
    while environmentLoaded do
        if thirdPersonCamEnabled then
            if LocalPlayer.CameraMode ~= Enum.CameraMode.Classic or LocalPlayer.CameraMinZoomDistance ~= 0.5 or LocalPlayer.CameraMaxZoomDistance < 999 then
                LocalPlayer.CameraMode = Enum.CameraMode.Classic
                LocalPlayer.CameraMinZoomDistance = 0.5
                LocalPlayer.CameraMaxZoomDistance = 999999
            end
        end
        task.wait(0.5)
    end
end)

-- ========== TP Walk（替代 WalkSpeed 修改） ==========
if tpwalkConn then
    app.xpcallw(function() tpwalkConn:Disconnect() end, "TPWalk")
    tpwalkConn = nil
end

tpwalkConn = RunService.Heartbeat:Connect(function(delta)
    if not speedEnabled then
        return -- Speed 开关关闭
    end
    local c = LocalPlayer.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if not (c and h and h.Parent) then
        return
    end
    if flying then
        return -- 飞行时不叠加 TP Walk
    end
    if h.MoveDirection.Magnitude > 0 then
        -- targetWalkSpeed 即每秒 studs（绝对速度）
        c:TranslateBy(h.MoveDirection * targetWalkSpeed * delta)
    end
end)

-- ========== No Recoil / No Spread 强制应用 ==========
RunService.Heartbeat:Connect(function()
    -- 无后坐力：每帧清零所有 mod 表后座倍率 + 每0.5秒重新收集 env/替换 Recoil（覆盖重生后的新脚本实例）
    if noRecoilEnabled then
        for _, mt in ipairs(app.allModTables) do
            app.xpcallw(function()
                app.ensureTableWritable(mt)
                app.ensureTableWritable(mt.camRecoilMod)
                app.ensureTableWritable(mt.gunRecoilMod)
                mt.camRecoilMod.RecoilUp = 0
                mt.camRecoilMod.RecoilLeft = 0
                mt.camRecoilMod.RecoilRight = 0
                mt.camRecoilMod.RecoilTilt = 0
                mt.gunRecoilMod.RecoilUp = 0
                mt.gunRecoilMod.RecoilLeft = 0
                mt.gunRecoilMod.RecoilRight = 0
                mt.gunRecoilMod.RecoilTilt = 0
                mt.MinRecoilPower = 0
                mt.MaxRecoilPower = 0
                mt.RecoilPowerStepAmount = 0
            end, "NoRecoil")
        end
        if os.clock() - (app.__lastNoRecoilApply or 0) > 0.5 then
            app.__lastNoRecoilApply = os.clock()
            app.xpcallw(app.applyNoRecoil, "NoRecoil")
        end
    end

    -- 无扩散：每帧清零所有 mod 表扩散倍率
    if noSpreadEnabled then
        for _, mt in ipairs(app.allModTables) do
            app.xpcallw(function()
                app.ensureTableWritable(mt)
                mt.MinSpread = 0
                mt.MaxSpread = 0
                mt.SpreadRM = 0
                mt.AimInaccuracyStepAmount = 0
            end, "NoSpread")
        end
        if os.clock() - (app.__lastNoSpreadApply or 0) > 0.5 then
            app.__lastNoSpreadApply = os.clock()
            app.xpcallw(app.refreshModTables, "NoSpread")
        end
    end

    -- 子弹加速已改为瞬发命中(doInstantHit,接管 CreateBullet 同帧演算完整弹道),
    -- 不再每帧改写 mod 表 MuzzleVelocity——旧方案的两条死路:倍率过大首帧越出 7000 杀线 → 无伤害;
    -- 步进太粗割线跨过目标 → 系统性空枪。瞬发连续射线两条都绕开。

    -- Rapid Fire 弹药镜像:每帧同步副本↔原表的 AmmoInGun/StoredAmmo(修复重装备弹药回满 bug)
    if rapidFireEnabled then
        app.xpcallw(app.syncRapidAmmoTables, "RapidFire弹药同步")
    end

    -- Infinite Ammo:每帧把弹匣上值钉回满弹(0.5s 重识别,覆盖换枪/重生后的新脚本实例)
    if infiniteAmmoEnabled then
        app.xpcallw(app.pinInfiniteAmmo, "InfiniteAmmo")
        if os.clock() - (app.__lastInfAmmoIdentify or 0) > 0.5 then
            app.__lastInfAmmoIdentify = os.clock()
            app.xpcallw(app.identifyInfiniteAmmo, "InfiniteAmmo")
        end
    end

    -- Instant Aim:v3 瞄准时间上值装备时会被重写,每帧重钉;0.5s 重扫覆盖重生后的新脚本实例
    if instantAimEnabled then
        app.xpcallw(app.pinInstantAim, "InstantAim")
        if os.clock() - (app.__lastInstantAimApply or 0) > 0.5 then
            app.__lastInstantAimApply = os.clock()
            app.xpcallw(app.applyInstantAim, "InstantAim")
        end
    end

    -- Instant Equip:env 替换持久生效,0.5s 重扫只为覆盖重生后的新脚本实例
    if instantEquipEnabled and os.clock() - (app.__lastInstantEquipApply or 0) > 0.5 then
        app.__lastInstantEquipApply = os.clock()
        app.xpcallw(app.applyInstantEquip, "InstantEquip")
    end
end)

-- ========== RageBot 多线程主循环 ==========
-- 架构：扫描（筛选→排序→命中精修→写共享表，三个事件入口每帧去重），射击（fireVolley 由三事件循环驱动、每事件连发 RAGE_FIRE_BURST 轮，每个目标再开 RAGE_THREADS_PER_TARGET 个并发子线程打 InvokeServer，在途请求超 RAGE_MAX_PENDING 自动暂停）
-- 共享状态（扫描线程写、射击线程读）
app.rageTargets = {}          -- 有序目标表 {player, targetPart, humanoid, hitPart, hitPos, hitZone, distance}
app.rageFireOrigin = nil      -- 武器发射点（每帧由扫描线程刷新）
app.rageWeaponRef = nil       -- 当前武器
app.rageWeaponConfigRef = nil -- 当前武器配置（共享原表，从未被改动，直接发送即可）
app.ragePending = 0           -- 在途攻击请求数（每个并发子线程进入时 +1、InvokeServer 返回后 -1），超 RAGE_MAX_PENDING 暂停开火防堆积

if environmentLoaded then
    -- 可见性 raycast 结果缓存（约 0.05s 有效，避免每帧对同一玩家重复检测）
    local visCache = {}
    local VIS_CACHE_TTL = 0.05
    local lastScanFrame = nil
    local lastScanTime = 0
    local frameNumberAvailable = pcall(function() return RunService.FrameNumber end)
    local cachedRageWeapon = nil
    local cachedRageSettings = nil
    local cachedRageWeaponConfig = nil
    local cachedRageFirePart = nil
    local ragePlayers = Players:GetPlayers()
    local ragePlayerNames = {}
    Players.PlayerAdded:Connect(function(player)
        ragePlayers[#ragePlayers + 1] = player
    end)
    Players.PlayerRemoving:Connect(function(player)
        for index = #ragePlayers, 1, -1 do
            if ragePlayers[index] == player then
                table.remove(ragePlayers, index)
                ragePlayerNames[player] = nil
                break
            end
        end
    end)

    local function cachedVisible(origin, player, targetPart)
        if app.WALLBANG then return true, nil end
        local now = os.clock()
        local entry = visCache[player]
        if entry and entry.part == targetPart and (now - entry.t) < VIS_CACHE_TTL then
            return entry.ok, entry.result
        end
        local result = app.raycastToTarget(origin, targetPart)
        local ok = result ~= nil
        visCache[player] = {t = now, ok = ok, part = targetPart, result = result}
        return ok, result
    end

    -- ===== 目标扫描（三事件入口、每帧只执行一次；连接先于射击循环建立，保证同事件内先扫描后射击）=====
    local function scanTargets()
        -- 三个事件仍然保持扫描入口，但同一渲染帧只执行一次，避免重复清表、排序和 raycast。
        if frameNumberAvailable then
            local frameNumber = RunService.FrameNumber
            if frameNumber == lastScanFrame then return end
            lastScanFrame = frameNumber
        else
            local now = os.clock()
            if now - lastScanTime < (1 / 60) then return end
            lastScanTime = now
        end

        table.clear(app.rageTargets)
        app.rageWeaponRef = nil
        if not rageEnabled or not env or not char then return end
        if not modTable or not accessId then return end

        local weapon = app.getCurrentWeapon()
        if not weapon then return end
        local weaponSettings = weapon:FindFirstChild("ACS_Settings")
        local weaponConfig
        if cachedRageWeapon == weapon and cachedRageSettings == weaponSettings and cachedRageWeaponConfig then
            weaponConfig = cachedRageWeaponConfig
        else
            weaponConfig = weaponSettings and require(weaponSettings)
            cachedRageWeapon = weapon
            cachedRageSettings = weaponSettings
            cachedRageWeaponConfig = weaponConfig
        end
        if not weaponConfig then return end

        -- 武器发射点只算一次，射击线程共用
        local origin
        local firePos
        if cachedRageWeapon == weapon and cachedRageFirePart and cachedRageFirePart.Parent then
            firePos = cachedRageFirePart.Position
        else
            local resolvedPos, _, resolvedPart = getWeaponFirePoint(weapon)
            cachedRageWeapon = weapon
            cachedRageFirePart = resolvedPart
            firePos = resolvedPos
        end
        if firePos then
            origin = firePos
        else
            -- 如果武器没有部件，退到本地玩家根部
            local localRoot = char and char:FindFirstChild("HumanoidRootPart")
            if localRoot and localRoot:IsA("BasePart") then
                origin = localRoot.Position
            else
                return
            end
        end
        app.rageFireOrigin = origin
        app.rageWeaponRef = weapon
        app.rageWeaponConfigRef = weaponConfig

        local cam = Workspace.CurrentCamera
        -- 确定可见性检测原点：优先使用角色 RootPart，其次是 Head，最后退到摄像机
        local localRoot = char:FindFirstChild("HumanoidRootPart")
        local localHead = char:FindFirstChild("Head")
        local visibilityOrigin
        if localRoot and localRoot:IsA("BasePart") then
            visibilityOrigin = localRoot.Position
        elseif localHead and localHead:IsA("BasePart") then
            visibilityOrigin = localHead.Position
        else
            visibilityOrigin = cam.CFrame.Position
        end

        local screenCenter = (app.TARGET_PRIORITY == "Centre") and Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2) or nil
        local localTeam = LocalPlayer.Team

        -- 筛选候选（单表收集 + 一次排序，替代原双表两次线性扫描）
        local candidates = {}
        for _, player in ipairs(ragePlayers) do
            local character, humanoid
            if player ~= LocalPlayer then
                character, humanoid = app.getRageCharacterState(player)
            end
            if character and humanoid then
                local nameLower = ragePlayerNames[player]
                if not nameLower then
                    nameLower = player.Name:lower()
                    ragePlayerNames[player] = nameLower
                end
                -- Team Check 动态判定:队伍可能开局/回合开始后才创建或分配,不能只在脚本启动时查一次(hasTeams 静态值曾导致过滤永久失效);
                -- 双方都有 Team 且相同才算队友(无队游戏 player.Team 为 nil,不该被当队友排除)
                local sameTeam = player.Team ~= nil and localTeam ~= nil and player.Team == localTeam
                -- 朋友 / 护盾 / Only Enemy / Team Check 过滤
                if not friendSet[nameLower]
                    and not app.hasShield(player, character)
                    and not (onlyEnemyEnabled and not enemySet[nameLower])
                    and not (teamCheckEnabled and sameTeam and not enemySet[nameLower]) then
                    local targetPart = app.getRageHitPartFromCharacter(character, app.RAGE_HIT_PART)
                    -- WallBang 关:不攻击墙后的敌人(需可见); 开:跳过可见性检测
                    local visible, rayResult = false, nil
                    if targetPart then
                        visible, rayResult = cachedVisible(visibilityOrigin, player, targetPart)
                    end
                    if targetPart and visible then
                        local val
                        if app.TARGET_PRIORITY == "Distance" then
                            val = (targetPart.Position - visibilityOrigin).Magnitude
                        else
                            -- WorldToViewportPoint 对相机背后的点会镜像投影(正后方恰好落在屏幕中心),
                            -- onScreen 只判投影坐标在不在视口内,不判前后——必须再查 Z>0(深度为正=在相机前方),
                            -- 否则背后的近敌镜像到准星附近拿到最高 Centre 优先级,看起来就像仍在按距离选
                            -- (与 Impact Point hitmarker 背对目标钉屏幕中心是同一个 API 坑)
                            local screenPos, onScreen = cam:WorldToViewportPoint(targetPart.Position)
                            if onScreen and screenPos.Z > 0 then
                                val = (Vector2.new(screenPos.X, screenPos.Y) - screenCenter).Magnitude
                            else
                                val = math.huge
                            end
                        end
                        table.insert(candidates, {
                            player = player,
                            character = character,
                            humanoid = humanoid,
                            targetPart = targetPart,
                            rayResult = rayResult,
                            val = val,
                            isEnemy = enemySet[nameLower] == true,
                        })
                    end
                end
            end
        end

        -- Enemy 绝对优先，组内按优先级值升序
        table.sort(candidates, function(a, b)
            if a.isEnemy ~= b.isEnemy then return a.isEnemy end
            return a.val < b.val
        end)

        -- 精修数量取扫描上限与 Multi Target 的较大者（命中部位/落点/区域/距离）——
        -- 否则 Multi Target 调得比 RAGE_SCAN_LIMIT 大时,目标表被截断,多出来的目标永远不打
        local limit = math.min(#candidates, math.max(app.RAGE_SCAN_LIMIT, app.RAGE_MULTI_TARGET))
        for i = 1, limit do
            local cand = candidates[i]
            local hitPos = cand.targetPart.Position
            local hitPart = cand.targetPart
            if not app.WALLBANG then
                local rayResult = cand.rayResult
                if rayResult then
                    hitPart = rayResult.Instance
                    hitPos = rayResult.Position
                else
                    continue -- 从发射点打不到该候选，跳过
                end
            end
            if cand.humanoid and cand.humanoid.Health > 0 and cand.character.Parent then
                table.insert(app.rageTargets, {
                    player = cand.player,
                    targetPart = cand.targetPart,
                    humanoid = cand.humanoid,
                    hitPart = hitPart,
                    hitPos = hitPos,
                    hitZone = app.getHitZone(cand.targetPart),
                    distance = (hitPos - origin).Magnitude,
                })
            end
        end
    end
    RunService.Stepped:Connect(scanTargets)
    RunService.PreAnimation:Connect(scanTargets)
    RunService.Heartbeat:Connect(scanTargets)

    -- ===== 射击（独立函数；扫描的排序/raycast 开销不再拖慢射速）=====
    local function fireVolley()
        if not rageEnabled or not app.rageWeaponRef or #app.rageTargets == 0 then return end
        if not env or not char or not modTable or not accessId then return end
        if app.ragePending >= math.max(1, app.RAGE_MAX_PENDING) then return end -- 在途请求堆积过多,暂停本轮等回落

        local origin = app.rageFireOrigin
        local weapon = app.rageWeaponRef
        local weaponConfig = app.rageWeaponConfigRef
        local shotOrigin = Workspace.CurrentCamera and Workspace.CurrentCamera.CFrame.Position or origin
        local maxTargets = math.min(app.RAGE_MULTI_TARGET, #app.rageTargets)
        local threadCount = math.max(1, app.RAGE_THREADS_PER_TARGET) -- 无论如何不能小于 1

        for i = 1, maxTargets do
            local t = app.rageTargets[i]
            -- 每个目标并发 threadCount 个攻击线程同时发送 Damage;
            -- 反馈(beam/音效/hitmarker)只由首个成功的线程播放一次,HitLog 伤害监听每目标只挂一次(全部线程失败才撤销)
            local feedbackDone = false
            local failCount = 0
            local hitPartName = (t.hitPart and t.hitPart.Name) or "Unknown"
            local cancelDamageWatch = createDamageWatch(t.player, hitPartName, t.distance, t.hitZone == 1)

            for _ = 1, threadCount do
                -- 每个线程一个并发子线程：多个 InvokeServer 互不等待，真正并行开火
                task.spawn(function()
                    app.ragePending += 1
                    local success = false
                    -- 发射前再校验一次：目标可能在扫描后的瞬间死亡/离场
                    if t.player and t.player.Character and app.isAlive(t.player) and Damage then
                        local direction = t.hitPos - origin
                        if direction.Magnitude > 0 then
                            local args = app.buildDamageArgs(weapon, t.humanoid, t.distance, t.hitZone, weaponConfig,
                                t.hitPart, t.hitPos, shotOrigin, direction.Unit)
                            success = app.sendDamage(args)
                        end
                    end
                    app.ragePending -= 1

                    if success and not feedbackDone then
                        feedbackDone = true -- 首个成功线程播反馈,后续线程不再播
                        app.createForwardBeam(origin, t.targetPart)
                        app.playHitsound()
                        app.showHitmarker(t.hitZone == 1, t.hitPos, t.hitPart)
                    elseif not success then
                        failCount += 1
                        if failCount >= threadCount then
                            cancelDamageWatch() -- 全部线程都失败才撤销监听,否则留给 HealthChanged 判定
                        end
                    end
                end)
            end
        end
    end
    -- 每个帧事件触发时连续开火 RAGE_FIRE_BURST 轮(至少 1 轮)
    local function fireDriver()
        local burst = math.max(1, math.floor(app.RAGE_FIRE_BURST + 0.5))
        for _ = 1, burst do
            fireVolley()
        end
    end
    -- Stepped(物理步前) + PreAnimation(动画更新前) + Heartbeat(渲染后) 三个循环各自独立驱动,
    -- 总请求速率 ≈ 帧率 × 3 事件 × RAGE_FIRE_BURST × Thread,成倍放大
    task.spawn(function()
        while true do
            RunService.Stepped:Wait()
            fireDriver()
        end
    end)
    task.spawn(function()
        while true do
            RunService.PreAnimation:Wait()
            fireDriver()
        end
    end)
    task.spawn(function()
        while true do
            RunService.Heartbeat:Wait()
            fireDriver()
        end
    end)
end

-- 手动开枪命中反馈去重时间戳(hook 和被动检测共用,避免双重播放)
app.manualFeedbackLast = 0
-- hook 主通道是否安装成功:成功则下方被动检测整段不启用
-- (被动通道无法区分伤害来源——你开枪后 0.6s 内,旁边的人被【别人】打掉血也会误触发 hitmarker;
--  只有 hook 安装失败/被整块删除(如 Adonis 环境)时才需要它兜底)
app.manualHookActive = false
-- hook 反馈的兜底队列:主手段是 syn.secure_call 伪造环境直接执行;
-- 仅当 syn.secure_call 不可用时,hook 把命中数据(纯数据,不碰 Instance 属性)塞进这里,
-- 由下方的顶级 Heartbeat 消费者执行——hook 上下文衍生的普通线程权限不够,访问 Instance 会报 lacking capability Plugin
app.manualHitQueue = {}

-- ========== 手动开枪命中反馈·主手段：隐形 __namecall hook ==========
-- 满足 Adonis isMethamethodValid 四项校验:makeHookCClosure 使用 newcclosure + 零声明参数的 vararg 函数
-- → debug.info: source="[C]" line=-1 name="" nparams=0,与原生 C 元方法特征一致；Potassium 的
--    debug.setinfo 可用时同时写入 source/short_src/currentline/name 元信息。
-- (注意:Adonis 还有 checkStack 调用栈对比和错误消息指纹对比两道后续校验,需实测)
do
    -- syn.secure_call 需要一个 LocalScript 作为环境伪造来源:优先用 ACS 客户端脚本,兜底 PlayerScripts 任意 LocalScript
    local secureCallScript = nil
    app.xpcallw(function()
        local c = LocalPlayer.Character
        local acsClient = c and c:FindFirstChild("ACS_Client")
        if acsClient and acsClient:IsA("LocalScript") then
            secureCallScript = acsClient
        elseif acsClient then
            for _, ch in ipairs(acsClient:GetChildren()) do
                if ch:IsA("LocalScript") then secureCallScript = ch break end
            end
        end
        if not secureCallScript then
            local ps = LocalPlayer:FindFirstChild("PlayerScripts")
            for _, d in ipairs(ps and ps:GetDescendants() or {}) do
                if d:IsA("LocalScript") then secureCallScript = d break end
            end
        end
    end, "secure_call脚本")

    -- 命中反馈本体:经 syn.secure_call 伪造脚本环境调用,可正常访问 Instance
    local function doManualFeedback(humanoid, hitZone, tool)
        if typeof(humanoid) ~= "Instance" or not humanoid.Parent then return end
        if app.killEffect then app.killEffect.ObserveHit(humanoid, tool, hitZone) end
        local targetChar = humanoid.Parent
        local hitPart = (hitZone == 1 and targetChar:FindFirstChild("Head"))
            or targetChar:FindFirstChild("HumanoidRootPart")
            or targetChar:FindFirstChild("Torso")
        if not hitPart then return end
        app.manualFeedbackLast = os.clock() -- 记录反馈时间,被动检测据此去重
        app.showHitmarker(hitZone == 1, hitPart.Position, hitPart)
        if app.HITSOUND_ENABLED then
            app.playHitsound()
        end
    end

    -- 缺任一 hook 必需函数:跳过安装,被动检测自动兜底(manualHookActive 保持 false)
    if app.executorSupports("getrawmetatable", "setreadonly", "newcclosure", "getnamecallmethod", "getcallingscript") then
    app.xpcallw(function()
        local mt = getrawmetatable(game)
        local oldNamecall = mt.__namecall
        setreadonly(mt, false)
        local namecallHook = app.makeHookCClosure(oldNamecall, function(...)
            -- getnamecallmethod 在非 namecall 上下文(反作弊直接 pcall 探测)可能报错,pcall 保护
            -- 保证探测调用的报错文本与原生元方法完全一致(错误消息指纹校验)
            local ok, method = pcall(getnamecallmethod)
            if ok and (method == "InvokeServer" or method == "FireServer") then
                local self = ...
                if method == "FireServer" and app.suppressionRemote and self == app.suppressionRemote
                    and app.KILL_EFFECT_ENABLED and app.KILL_EFFECT_STYLE == "Battlefield 1" then
                    local _, targetPlayer, kind = ...
                    if kind == 1 then
                        table.insert(app.manualHitQueue, {suppressionPlayer = targetPlayer, sentAt = os.clock()})
                    end
                end
                local callerOk, callingScript = pcall(getcallingscript)
                local triggerWindow = type(app.triggerFeedbackUntil) == "number"
                    and os.clock() <= app.triggerFeedbackUntil and app.triggerFeedbackTarget ~= nil
                -- 手动 ACS 调用优先使用 calling script；Trigger 的原生手机/电脑入口可能异步发送
                -- Damage，此时 calling script 为空，只在本轮 Trigger 的短时间窗口内放行。
                if Damage and self == Damage and ((callerOk and callingScript ~= nil) or triggerWindow) then
                    -- 参数布局:(Damage=self, tool, humanoid, distance, hitZone, ...)
                    -- 之前错一位把 tool 当 humanoid、distance 当 hitZone,导致爆头永不红(humanoid.Parent 恰好也是角色才没报错)
                    local _, tool, humanoid, _, hitZone = ...
                    -- hook 上下文不能读取 Instance 属性；只在 Trigger 的短窗口内放行，
                    -- 具体 humanoid/部位解析交给 secure_call 或 Heartbeat 队列。
                    do
                        -- syn.secure_call 伪造脚本环境调用,上下文无缝、不会报权限错
                        -- (hook 衍生的普通线程没有访问 Instance 的权限,直接用会 lacking capability Plugin)
                        if syn and syn.secure_call and secureCallScript then
                            app.xpcallw(syn.secure_call, "手动命中反馈", doManualFeedback, secureCallScript, humanoid, hitZone, tool)
                        else
                            -- 兜底:syn.secure_call 不可用时入队,由顶级 Heartbeat 消费者(exploit 权限)执行
                            table.insert(app.manualHitQueue, {humanoid = humanoid, hitZone = hitZone, tool = tool, sentAt = os.clock()})
                        end
                    end
                end
            end
            -- 全部原样转发,namecall 方法名由 VM 寄存器保留,行为与原生一致
            return oldNamecall(...)
        end)
        if not namecallHook then
            setreadonly(mt, true)
            error("newcclosure did not return a C closure")
        end
        mt.__namecall = namecallHook
        setreadonly(mt, true)
        app.HOOK_CLOSURE_RECORDS[oldNamecall] = {
            target = oldNamecall,
            original = oldNamecall,
            replacement = namecallHook,
            tag = "__namecall",
            metatable = mt,
        }
        app.manualHookActive = true -- 精确通道已就位,被动检测不再启用(防止旁人被打时误报)
    end, "NamecallHook")
    end
end

-- 消费 hook 入队的命中数据:顶级连接回调运行在 exploit 权限,可以正常访问 Instance
RunService.Heartbeat:Connect(function()
    if #app.manualHitQueue == 0 then return end
    local pending = app.manualHitQueue
    app.manualHitQueue = {} -- 换新表,消费期间 hook 新入队的数据进下一帧处理
    for _, item in ipairs(pending) do
        app.xpcallw(function()
            if item.suppressionPlayer then
                if app.killEffect then app.killEffect.ObserveSuppression(item.suppressionPlayer, item.sentAt) end
                return
            end
            local humanoid = item.humanoid
            local hitZone = item.hitZone
            if typeof(humanoid) ~= "Instance" or not humanoid.Parent then return end
            if app.killEffect then app.killEffect.ObserveHit(humanoid, item.tool, hitZone, item.sentAt) end
            local targetChar = humanoid.Parent
            local hitPart = (hitZone == 1 and targetChar:FindFirstChild("Head"))
                or targetChar:FindFirstChild("HumanoidRootPart")
                or targetChar:FindFirstChild("Torso")
            if not hitPart then return end
            app.manualFeedbackLast = os.clock() -- 记录反馈时间,被动检测据此去重
            app.showHitmarker(hitZone == 1, hitPart.Position, hitPart)
            if app.HITSOUND_ENABLED then
                app.playHitsound()
            end
        end, "手动命中反馈")
    end
end)

-- ========== 手动开枪命中反馈（被动检测版，零 hook，兼容 Adonis 反作弊） ==========
-- 原理：手动开枪会在 ACS_WorkSpace.Client 生成子弹部件(只读记录时间戳)，
-- 之后 0.6s 内若有敌人 humanoid 掉血，判定为“我们命中”，播 hitsound + hitmarker
-- （RageBot 直发 Damage 不产生子弹部件，不会触发这里，不会重复反馈；
--   Adonis 的 namecallInstance 检测会校验 game 的 __namecall 元方法，任何全局 namecall hook 都会被踢，故不用 hook）
-- 仅在 __namecall hook 主通道未安装成功时才启用：该通道无法区分伤害来源，
-- 你开枪后 0.6s 内旁边的人被【别人】打掉血也会误触发 hitmarker（曾有此误报）
if not app.manualHookActive then
    local recentSelfShot = 0

    -- 监听自己的子弹部件，只记录时间戳，不修改任何东西
    task.spawn(function()
        app.xpcallw(function()
            local acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
            while not acsWorkspace do
                task.wait(2)
                acsWorkspace = Workspace:FindFirstChild("ACS_WorkSpace")
            end
            local clientFolder = acsWorkspace:FindFirstChild("Client")
            while not clientFolder do
                task.wait(2)
                clientFolder = acsWorkspace:FindFirstChild("Client")
            end
            clientFolder.ChildAdded:Connect(function(child)
                -- 同样的时序坑:ACS 先挂父级再改名,ChildAdded 时名字还是 "Part",
                -- 必须 defer 等名字配置完再判,否则 recentSelfShot 永远不更新
                if not child:IsA("BasePart") then return end
                task.defer(function()
                    app.xpcallw(function()
                        if child.Parent and child.Name:sub(-7) == "_Bullet" then
                            recentSelfShot = os.clock()
                        end
                    end, "手动命中监听")
                end)
            end)
        end, "手动命中监听")
    end)

    -- 监听所有玩家 humanoid 掉血
    local watchedHumanoids = {}

    local function watchPlayerCharacter(player, character)
        if not character then return end
        local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
        if not humanoid or watchedHumanoids[humanoid] then return end
        watchedHumanoids[humanoid] = true
        local lastHealth = humanoid.Health
        humanoid.HealthChanged:Connect(function(newHealth)
            app.xpcallw(function()
                local dropped = newHealth < lastHealth
                lastHealth = newHealth
                if not dropped then return end -- 回血/无变化不算
                if os.clock() - recentSelfShot > 0.6 then return end -- 最近 0.6s 自己没开枪
                if os.clock() - app.manualFeedbackLast < 0.4 then return end -- hook 已反馈过这次命中,去重
                if not char then return end
                local targetChar = humanoid.Parent
                if not targetChar then return end
                local hitPart = targetChar:FindFirstChild("Head") or targetChar:FindFirstChild("HumanoidRootPart")
                if not hitPart then return end
                -- 被动方式无法得知命中部位，统一按非爆头(白色)反馈
                app.manualFeedbackLast = os.clock()
                app.showHitmarker(false, hitPart.Position, hitPart)
                if app.HITSOUND_ENABLED then
                    app.playHitsound()
                end
            end, "手动命中反馈")
        end)
    end

    local function watchPlayer(player)
        if player == LocalPlayer then return end
        if player.Character then
            task.spawn(watchPlayerCharacter, player, player.Character)
        end
        player.CharacterAdded:Connect(function(character)
            task.spawn(watchPlayerCharacter, player, character)
        end)
    end

    for _, player in ipairs(Players:GetPlayers()) do
        watchPlayer(player)
    end
    Players.PlayerAdded:Connect(watchPlayer)
end

-- Aim Assist：共享部位/开镜判定；只调整本地相机，不修改武器或输入事件。
do
    local state = {focused = true, nextScopeProbe = 0, random = Random.new(),
        acquireTime = 0, reaction = 0, phaseX = 0, phaseY = 0}
    local weaponConfigs = setmetatable({}, {__mode = "k"})
    local partMap = {
        Head = {"Head"}, Torso = {"Torso", "UpperTorso", "LowerTorso"},
        ["Left Arm"] = {"Left Arm", "LeftUpperArm", "LeftLowerArm", "LeftHand"},
        ["Right Arm"] = {"Right Arm", "RightUpperArm", "RightLowerArm", "RightHand"},
        ["Left Leg"] = {"Left Leg", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot"},
        ["Right Leg"] = {"Right Leg", "RightUpperLeg", "RightLowerLeg", "RightFoot"},
    }

    function app.resetAimAssist()
        state.target, state.part, state.camera = nil, nil, nil
        state.acquireTime, state.reaction = 0, 0
    end

    function app.getAimPart(character)
        local names = partMap[app.AIM_PART == "Body" and "Torso" or app.AIM_PART]
        if not character or not names then return nil end
        for _, name in ipairs(names) do
            local part = character:FindFirstChild(name)
            if part and part:IsA("BasePart") then return part end
        end
        return nil -- 指定部位缺失时不偷偷改瞄头部。
    end

    function app.isLegitScoped()
        local character = LocalPlayer.Character
        local weapon = character and character:FindFirstChildOfClass("Tool")
        if not weapon then return false end
        for _, containerName in ipairs({"Values", "RepValues"}) do
            local values = weapon:FindFirstChild(containerName)
            local aimDown = values and values:FindFirstChild("AimDown")
            if aimDown and aimDown:IsA("BoolValue") then return aimDown.Value == true end
        end
        for _, key in ipairs({"AimDown", "IsAiming", "Aiming", "ADS"}) do
            local value = weapon:GetAttribute(key)
            if type(value) == "boolean" then return value end
        end
        -- v1/v2/v3 的 SetAimpart 捕获 [开镜布尔, 瞄具编号, 武器模型, AimPart]。
        -- 只读且校验布局；未知布局返回 false，不用 FOV/鼠标右键猜测开镜。
        local now = os.clock()
        if state.scopeWeapon ~= weapon or state.scopeCharacter ~= character or now >= state.nextScopeProbe then
            state.scopeWeapon, state.scopeCharacter = weapon, character
            state.nextScopeProbe = now + 0.25
            state.scopeEnv = app.findMainScript()
        end
        local framework = state.scopeEnv
        local fn = type(framework) == "table" and framework.SetAimpart
        if type(fn) ~= "function" or type(debug.getupvalues) ~= "function" then return false end
        local ok, values = pcall(debug.getupvalues, fn)
        if not ok or type(values) ~= "table" or type(values[1]) ~= "boolean"
            or (values[2] ~= 1 and values[2] ~= 2) or typeof(values[3]) ~= "Instance" then return false end
        if not values[3]:FindFirstChild("AimPart") and not values[3]:FindFirstChild("AimPart2") then return false end
        return values[1]
    end

    local function hasEquippedAcsGun(character)
        if not character then return false end
        for _, weapon in ipairs(character:GetChildren()) do
            if weapon:IsA("Tool") and weapon.Parent == character then
                local settings = weapon:FindFirstChild("ACS_Settings")
                if settings and settings:IsA("ModuleScript") then
                    local cached = weaponConfigs[settings]
                    if not cached or (cached.failed and os.clock() >= cached.retryAt) then
                        cached = {}
                        weaponConfigs[settings] = cached
                        -- 首次 require 可能 yield；不在 RenderStepped 内等待武器模块。
                        task.spawn(function()
                            local ok, config = pcall(require, settings)
                            cached.config = ok and type(config) == "table" and config or nil
                            cached.failed = not ok
                            cached.retryAt = os.clock() + 1
                        end)
                    end
                    local config = cached.config
                    if config and config.Type == "Gun" and type(config.ShootRate) == "number"
                        and config.ShootRate > 0 and config.ShootRate < math.huge then return true end
                end
            end
        end
        return false
    end

    function app.aimCanRun(camera)
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        return app.AIM_ENABLED and gui.Parent and state.focused and not mainGuiVisible
            and not UserInputService:GetFocusedTextBox() and camera and camera == Workspace.CurrentCamera
            and humanoid and humanoid.Health > 0 and hasEquippedAcsGun(character)
            and (not app.AIM_ONLY_SCOPE or app.isLegitScoped())
    end

    function app.isAimPlayerAllowed(player, character)
        if player == LocalPlayer or not character or friendSet[player.Name:lower()] then return false end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not humanoid or humanoid.Health <= 0 or app.hasShield(player, character) then return false end
        if app.AIM_ONLY_ENEMY and not enemySet[player.Name:lower()] then return false end
        if app.AIM_TEAM_CHECK and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team then
            return false
        end
        return true
    end

    -- 只跳过角色装饰、持有工具及不可见的根部件，不跳过地图墙体。
    function app.legitRaycast(origin, direction, camera)
        local excluded = {}
        for _, item in pairs({LocalPlayer.Character, camera, tracesFolder}) do
            if item then excluded[#excluded + 1] = item end
        end
        local acs = Workspace:FindFirstChild("ACS_WorkSpace")
        if acs then
            for _, name in ipairs({"Client", "Server"}) do
                local folder = acs:FindFirstChild(name)
                if folder then excluded[#excluded + 1] = folder end
            end
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local hit
        for _ = 1, 8 do
            params.FilterDescendantsInstances = excluded
            hit = Workspace:Raycast(origin, direction, params)
            if not hit then return nil end
            local ancestor, ignored = hit.Instance, nil
            while ancestor and ancestor ~= Workspace do
                if ancestor:IsA("Accessory") or ancestor:IsA("Tool") then ignored = ancestor; break end
                ancestor = ancestor.Parent
            end
            if not ignored and hit.Instance.Name == "HumanoidRootPart" and hit.Instance.Transparency == 1
                and Players:GetPlayerFromCharacter(hit.Instance.Parent) then ignored = hit.Instance end
            if not ignored then return hit end
            excluded[#excluded + 1] = ignored
        end
        return hit -- 达到上限时保留遮挡，不能把未检查完的路径当作可见。
    end

    function app.isAimPartVisible(camera, part)
        local hit = app.legitRaycast(camera.CFrame.Position, part.Position - camera.CFrame.Position, camera)
        return not hit or hit.Instance == part
    end

    function app.getAimTarget(camera)
        if not app.aimCanRun(camera) or app.AIM_FOV_SIZE <= 0 or app.AIM_MAX_DISTANCE <= 0 then return nil end
        local viewport = camera.ViewportSize
        if viewport.X <= 0 or viewport.Y <= 0 then return nil end
        local best, bestDistance = nil, app.AIM_FOV_SIZE * app.AIM_FOV_SIZE
        for _, player in ipairs(Players:GetPlayers()) do
            local character = player.Character
            if not app.isAimPlayerAllowed(player, character) then continue end
            local part = app.getAimPart(character)
            if not part then continue end
            if (part.Position - camera.CFrame.Position).Magnitude > app.AIM_MAX_DISTANCE then continue end
            local projected, onScreen = camera:WorldToViewportPoint(part.Position)
            if not onScreen or projected.Z <= 0 then continue end
            local dx, dy = projected.X - viewport.X * 0.5, projected.Y - viewport.Y * 0.5
            local distance = dx * dx + dy * dy
            if distance > bestDistance then continue end
            if app.AIM_WALL_CHECK and not app.isAimPartVisible(camera, part) then continue end
            bestDistance = distance
            best = {TargetPlayer = player, TargetPart = part}
        end
        return best
    end

    local function getLocalVelocity()
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        return root and root.AssemblyLinearVelocity or Vector3.zero
    end

    local function approachAngle(currentVec, targetVec, maxAngleStep)
        local cur, tgt = currentVec.Unit, targetVec.Unit
        local angle = math.acos(math.clamp(cur:Dot(tgt), -1, 1))
        if angle < 1e-5 then return tgt end
        local t, sinA = math.min(1, maxAngleStep / angle), math.sin(angle)
        if sinA < 1e-5 then return tgt end
        return (cur * (math.sin((1 - t) * angle) / sinA) + tgt * (math.sin(t * angle) / sinA)).Unit
    end

-- Preserve the ACS camera bank (lean) while changing only the aiming direction.
function app.aimCameraWithLean(reference, direction)
    if direction.Magnitude < 1e-6 then return reference end
    local position = reference.Position
    local unbanked = CFrame.lookAt(position, position + reference.LookVector)
    local bankFrame = unbanked:ToObjectSpace(reference)
    local bank = math.atan2(bankFrame.RightVector.Y, bankFrame.UpVector.Y)
    return CFrame.lookAt(position, position + direction.Unit) * CFrame.Angles(0, 0, bank)
end

    -- 移植自附件 simple.lua：延迟、warmup、减速、摆动、过冲和垂直跟随比例。
    function app.computeAdaptiveAim(camera,bestTarget,predictedPos,dt)
        local camCFrame=camera.CFrame; local camPos=camCFrame.Position; local currentLook=camCFrame.LookVector
        local targetDir=(predictedPos-camPos)
        if targetDir.Magnitude<1e-3 then return camCFrame end
        if state.target~=bestTarget.TargetPlayer then
            state.target=bestTarget.TargetPlayer; state.acquireTime=0
            state.reaction=state.random:NextNumber(math.max(0.02,0.12*0.6),math.min(0.4,0.12*1.4))
            state.phaseX=state.random:NextNumber(0,math.pi*2); state.phaseY=state.random:NextNumber(0,math.pi*2)
        end
        if state.reaction>0 then state.reaction=state.reaction-dt; return camCFrame end
        state.acquireTime=state.acquireTime+dt
        local targetUnit=targetDir.Unit; local dotLook=math.clamp(currentLook:Dot(targetUnit),-1,1); local angularError=math.acos(dotLook)
        local relSpeed=0
        if bestTarget.TargetPart:IsA("BasePart") then relSpeed=(bestTarget.TargetPart.AssemblyLinearVelocity-getLocalVelocity()).Magnitude end
        local baseSlew=1.2+((math.clamp(app.AIM_SPEED,1,30)-1)/29)*5.5
        local warmup=math.clamp(state.acquireTime/0.4,0,1); warmup=warmup*warmup*(3-2*warmup)
        local errorFactor=math.tanh(angularError*3.0); local speedFactor=math.clamp(relSpeed/25,0,1)*0.5
        local t=os.clock(); local speedNoise=1+math.sin(t*2.7)*0.25+math.cos(t*4.1)*0.15
        local angleStep=baseSlew*(0.35+errorFactor*0.65+speedFactor)*warmup*speedNoise*dt
        if angularError<0.03 then angleStep=angleStep*0.55 elseif angularError<0.08 then angleStep=angleStep*0.75 end
        state.phaseX=state.phaseX+dt*(1.8+math.sin(t*0.5)*0.6); state.phaseY=state.phaseY+dt*(1.2+math.cos(t*0.7)*0.4)
        local settle=1-math.min(angularError/0.08,1)
        local wobbleMagX=math.rad(0.20)*settle*(0.5+0.5*math.sin(t*1.3)); local wobbleMagY=math.rad(0.10)*settle*(0.5+0.5*math.sin(t*1.3))
        local microJitterX=math.rad(0.07)*(1-settle*0.6); local microJitterY=math.rad(0.035)*(1-settle*0.6)
        local rightVec=camCFrame.RightVector; local upVec=camCFrame.UpVector
        local wobble=rightVec*(math.sin(state.phaseX)*wobbleMagX+math.sin(state.phaseX*3.7)*wobbleMagX*0.35+state.random:NextNumber(-microJitterX,microJitterX))+upVec*(math.sin(state.phaseY*1.4)*wobbleMagY+math.cos(state.phaseY*2.3)*wobbleMagY*0.35+state.random:NextNumber(-microJitterY,microJitterY))
        local overshoot=Vector3.zero
        if state.acquireTime<0.3 and angularError>0.05 then
            local overshootMag=math.rad(0.5)*(1-state.acquireTime/0.3)*math.sin(t*10)
            overshoot=rightVec*overshootMag*state.random:NextNumber(-0.8,0.8)+upVec*overshootMag*state.random:NextNumber(-0.4,0.4)
        end
        local centerOffset=Vector3.zero
        if angularError<0.12 then
            centerOffset=rightVec*math.sin(t*0.9)*math.rad(0.12)*settle+upVec*math.cos(t*0.65)*math.rad(0.04)*settle
        end
        local desiredDir=(targetUnit+wobble+overshoot+centerOffset).Unit
        local incompleteTrackingFactor=0.88; local currentToDesired=desiredDir-currentLook; local trackedDir=(currentLook+currentToDesired*incompleteTrackingFactor).Unit
        local horizontalStep=angleStep; local verticalStep=angleStep*0.65
        local newLookHorizontal=approachAngle(currentLook,trackedDir,horizontalStep)
        local blendY=math.clamp(verticalStep/(horizontalStep+1e-6),0,1)
        local finalLook=Vector3.new(newLookHorizontal.X,currentLook.Y*(1-blendY*0.5)+newLookHorizontal.Y*blendY*0.5,newLookHorizontal.Z).Unit
        return app.aimCameraWithLean(camCFrame, finalLook)
    end


    function app.stepAimAssist(camera, dt)
        local best = app.getAimTarget(camera)
        if not best then app.resetAimAssist(); return end
        dt = math.clamp(dt, 0, 0.1)
        if state.camera ~= camera or state.part ~= best.TargetPart then app.resetAimAssist() end
        state.camera, state.part = camera, best.TargetPart
        if (best.TargetPart.Position - camera.CFrame.Position).Magnitude < 0.001 then return end
        if app.AIM_MODE == "Adaptive" then
            camera.CFrame = app.computeAdaptiveAim(camera, best, best.TargetPart.Position, dt)
        else
            local alpha = 1 - math.exp(-math.clamp(app.AIM_SPEED, 1, 30) * dt)
            local current = camera.CFrame
            local desired = app.aimCameraWithLean(current, best.TargetPart.Position - current.Position)
            camera.CFrame = app.aimCameraWithLean(current, current:Lerp(desired, alpha).LookVector)
        end
    end

    -- 独立于窗口 UIScale，半径按屏幕像素计算；原生 UI 不依赖 Drawing API。
    local circle = Instance.new("Frame")
    circle.Name = app.randomName()
    circle.AnchorPoint = Vector2.new(0.5, 0.5)
    circle.BackgroundTransparency = 1
    circle.BorderSizePixel = 0
    circle.Visible = false
    circle.ZIndex = 269
    circle.Parent = gui
    app.addCorner(circle, 999)
    local stroke = app.addStroke(circle, app.AIM_FOV_COLOR, 1, app.AIM_FOV_TRANSPARENCY)
    local connections = {}
    connections[1] = RunService.RenderStepped:Connect(function(dt)
        local ok = app.xpcallw(function()
            local camera = Workspace.CurrentCamera
            circle.Visible = camera ~= nil and app.AIM_DRAW_FOV and app.AIM_FOV_SIZE > 0
            if circle.Visible then
                circle.Position = UDim2.fromOffset(camera.ViewportSize.X * 0.5, camera.ViewportSize.Y * 0.5)
                circle.Size = UDim2.fromOffset(app.AIM_FOV_SIZE * 2, app.AIM_FOV_SIZE * 2)
                stroke.Color, stroke.Transparency = app.AIM_FOV_COLOR, app.AIM_FOV_TRANSPARENCY
            end
            app.stepAimAssist(camera, dt)
        end, "Aim Assist")
        if not ok then app.resetAimAssist() end
    end)
    connections[2] = UserInputService.WindowFocusReleased:Connect(function()
        state.focused = false; app.resetAimAssist()
    end)
    connections[3] = UserInputService.WindowFocused:Connect(function() state.focused = true end)
    connections[4] = LocalPlayer.CharacterRemoving:Connect(function()
        state.scopeEnv, state.scopeWeapon, state.scopeCharacter = nil, nil, nil
        app.resetAimAssist()
    end)
    connections[5] = gui.Destroying:Connect(function()
        app.resetAimAssist()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        circle:Destroy()
    end)
end

-- Trigger：只调用游戏开火/结束函数，不发送伤害、不模拟鼠标，也不修改武器设置。
do
    -- 每次 Begin 都有自己的 End 和超时；旧调用返回前不会再启动另一个调用。
    local state = {epoch = 0, focused = true, nextProbe = 0}

    function app.resolveTriggerDriver(framework)
        if type(framework) ~= "table" then return nil end
        if type(framework.handleAction) == "function" then
            local action = framework.handleAction
            return {source = action, finish = action,
                beginFire = function() return action("Fire", Enum.UserInputState.Begin, nil) end,
                endFire = function() return action("Fire", Enum.UserInputState.End, nil) end}
        end
        if type(framework.FireButtonStart) == "function" and type(framework.FireButtonEnd) == "function" then
            return {source = framework.FireButtonStart, finish = framework.FireButtonEnd,
                beginFire = framework.FireButtonStart, endFire = framework.FireButtonEnd}
        end
        return nil
    end

    local function stopJob(job, handOff)
        if not job or not job.started then return end
        if handOff == false then job.forceStop, job.handoff = true, false end
        if not job.forceStop and handOff ~= false and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
            job.handoff = true -- 保留待释放对象，真实按键松开后仍会补发 End。
            return
        end
        if job.released or job.stopping then return end
        job.stopping = true
        local ok = app.xpcallw(job.driver.endFire, "Trigger结束")
        job.stopping = false
        job.released = ok -- 失败时保留任务，下一帧重试释放，禁止启动新开火。
    end

    function app.resetTrigger(handOff)
        state.epoch += 1
        state.target, state.weapon, state.driver, state.mode = nil, nil, nil, nil
        state.acquiredAt, state.nextShot = nil, nil
        if state.job then
            state.job.cancelled = true
            stopJob(state.job, handOff)
        end
    end

    local function serviceJob()
        local job = state.job
        if not job then return end
        if job.cancelled or job.expired then stopJob(job, job.handoff) end
        if job.done and (job.released or not job.started) then state.job = nil end
    end

    function app.stepTrigger(now, target, weapon, driver, config)
        serviceJob()
        if not app.TRIGGER_ENABLED or not target or not weapon or not driver or not config or config.Type ~= "Gun"
            or (app.TRIGGER_ONLY_SCOPE and not app.isLegitScoped())
            or app.getTriggerTarget(Workspace.CurrentCamera) ~= target then
            app.resetTrigger()
            return
        end
        if state.target ~= target or state.weapon ~= weapon or state.driver ~= driver or state.mode ~= config.ShootType then
            app.resetTrigger()
            state.target, state.weapon, state.driver, state.mode = target, weapon, driver, config.ShootType
            state.acquiredAt, state.nextShot = now, now
        end
        if state.job or now - state.acquiredAt < app.TRIGGER_DELAY_MS / 1000 or now < state.nextShot then return end
        local rate = tonumber(config.ShootRate) or 600
        if rate ~= rate or rate <= 0 or rate == math.huge then rate = 600 end
        local period = 60 / rate
        local burst = tonumber(config.BurstShot) or 1
        if burst ~= burst or burst == math.huge or burst < 1 then burst = 1 end
        local holdTime = config.ShootType == 2 and math.clamp(period * burst, 1 / 60, 1)
            or (config.ShootType == 3 and 0.1 or 1 / 60)
        -- 原生 Shoot 自己管射速；被装填/冷却临时拒绝时短间隔重试，不重置反应计时。
        state.nextShot = now + math.clamp(period * 0.25, 1 / 60, 0.1)
        local job = {driver = driver, epoch = state.epoch}
        state.job = job
        task.spawn(function()
            if job.cancelled or job.epoch ~= state.epoch or not app.TRIGGER_ENABLED
                or not gui.Parent or not state.focused or mainGuiVisible or UserInputService:GetFocusedTextBox()
                or app.getTriggerTarget(Workspace.CurrentCamera) ~= target then
                job.done = true
                app.resetTrigger()
                return
            end
            app.triggerFeedbackTarget, app.triggerFeedbackUntil = target, os.clock() + 1.5
            job.started = true
            -- 先装释放计时器：beginFire 自身 yield/跑自动射击循环也不会阻止 End。
            task.delay(holdTime, function()
                if job.released and job.done then return end
                job.expired = true
                stopJob(job, job.handoff)
            end)
            local ok = app.xpcallw(driver.beginFire, "Trigger开火")
            job.done = true
            if job.cancelled or job.expired or job.epoch ~= state.epoch or not ok then
                job.released = false -- 原生调用 yield 后可能重新置位，返回时必须再次清理。
                stopJob(job, job.handoff)
            end
        end)
    end

    function app.getTriggerTarget(camera)
        if not camera or app.TRIGGER_MAX_DISTANCE <= 0 or (app.TRIGGER_ONLY_SCOPE and not app.isLegitScoped()) then return nil end
        local viewport = camera.ViewportSize
        if viewport.X <= 0 or viewport.Y <= 0 then return nil end
        local ray = camera:ViewportPointToRay(viewport.X * 0.5, viewport.Y * 0.5)
        local result = app.legitRaycast(ray.Origin, ray.Direction * app.TRIGGER_MAX_DISTANCE, camera)
        local ancestor = result and result.Instance
        while ancestor and ancestor ~= Workspace do
            if ancestor:IsA("Model") then
                local player = Players:GetPlayerFromCharacter(ancestor)
                if player then
                    local humanoid = ancestor:FindFirstChildOfClass("Humanoid")
                    local nameLower = player.Name:lower()
                    local sameTeam = app.TRIGGER_TEAM_CHECK
                        and player.Team ~= nil and LocalPlayer.Team ~= nil and player.Team == LocalPlayer.Team
                    if player ~= LocalPlayer and humanoid and humanoid.Health > 0
                        and not app.hasShield(player, ancestor)
                        and not friendSet[nameLower]
                        and (not app.TRIGGER_ONLY_ENEMY or enemySet[nameLower])
                        and not (sameTeam and not enemySet[nameLower]) then
                        return player
                    end
                    return nil
                end
            end
            ancestor = ancestor.Parent
        end
        return nil -- 首个遮挡不是玩家时不穿墙，也不以屏幕距离近似代替准星射线。
    end

    local function updateTrigger()
        serviceJob()
        if not app.TRIGGER_ENABLED or not gui.Parent or not state.focused or mainGuiVisible or UserInputService:GetFocusedTextBox() then
            if state.target or state.job then app.resetTrigger() end
            return
        end
        -- 只读取真实输入状态，把手动射击留给游戏自己的处理器；不产生任何鼠标输入。
        if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
            app.resetTrigger(true)
            return
        end
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local camera = Workspace.CurrentCamera
        if not humanoid or humanoid.Health <= 0 or not camera then app.resetTrigger(); return end
        local now = os.clock()
        if state.character ~= character or now >= state.nextProbe then
            state.nextProbe, state.character = now + 0.25, character
            local framework = app.findMainScript()
            local nextDriver = app.resolveTriggerDriver(framework)
            if not state.cachedDriver or not nextDriver or framework ~= state.framework
                or nextDriver.source ~= state.cachedDriver.source or nextDriver.finish ~= state.cachedDriver.finish then
                app.resetTrigger()
                state.cachedDriver = nextDriver
            end
            state.framework = framework
        end
        local weapon
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") and child:FindFirstChild("ACS_Settings") then weapon = child; break end
        end
        local config = weapon and app.getWeaponConfig(weapon)
        local target = app.getTriggerTarget(camera)
        if target and not state.cachedDriver and state.unsupported ~= state.framework then
            state.unsupported = state.framework
            app.showNotification("CheatGPT.cc", "Trigger: this ACS framework has no supported fire/release functions.", 6, {error = true})
        end
        app.stepTrigger(now, target, weapon, state.cachedDriver, config)
    end

    local connections = {}
    connections[1] = RunService.Heartbeat:Connect(function()
        local ok = app.xpcallw(updateTrigger, "Trigger")
        if not ok then app.resetTrigger() end
    end)
    connections[2] = UserInputService.WindowFocusReleased:Connect(function()
        state.focused = false
        app.resetTrigger(false)
    end)
    connections[3] = UserInputService.WindowFocused:Connect(function() state.focused = true end)
    connections[4] = LocalPlayer.CharacterRemoving:Connect(function() app.resetTrigger(false) end)
    connections[5] = gui.Destroying:Connect(function()
        app.resetTrigger(false)
        for _, connection in ipairs(connections) do connection:Disconnect() end
    end)
end

-- 所有弹道依赖已就绪后再启用配置中保存的开关。
app.startBulletPipeline()
task.defer(function() app.xpcallw(app.ensureClientId, "ClientId") end)

startup.runtime.phase = "ready"
startup.runtime.reveal = function()
    gui.Enabled = true
    setMainGuiVisible(true)
end
end, function(err)
    return debug.traceback(tostring(err), 2)
end)

if not startupOK then
    startup.failure = tostring(startupError)
    startup.runtime.phase = "failed"
    if startup.retrySafe then
        -- 尚未创建控件/安装功能，可安全释放锁后重试。
        app.cheatGPTReleaseRuntimeState(startup.runtime)
        if startup.traceFolder then startup.traceFolder:Destroy() end
        if startup.secureParent then startup.secureParent:Destroy() end
    else
        startup.failure = startup.failure .. "\n部分初始化已执行，请退出并重新进入服务器后重试。"
    end
    if startup.gui then startup.gui.Enabled = false end
    app.startupReport(startup, startup.failure, true)
end
