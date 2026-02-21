-- play.lua (最终版，帧率显示基于帧间隔)
local gpu = peripheral.wrap("tm_gpu_9")
gpu.refreshSize()
gpu.setSize(64)
local w, h = gpu.getSize()

server_url = "https://newgmapi.liulikeji.cn"

-- 手动加载 speakerlib.lua 并确保返回模块表
local speakerlib
local file = fs.open("speakerlib.lua", "r")
if not file then
    error("speakerlib.lua not found")
end
local content = file.readAll()
file.close()

-- 创建一个新环境，以 _G 为原型，并显式注入 require
local env = setmetatable({ require = require }, { __index = _G })
local fn, err = load(content, "speakerlib.lua", nil, env)
if not fn then
    error("Failed to compile speakerlib.lua: " .. tostring(err))
end
local ok, result = pcall(fn)
if not ok then
    error("Error executing speakerlib.lua: " .. tostring(result))
end
if type(result) ~= "table" then
    error("speakerlib.lua did not return a table (returned " .. type(result) .. ")")
end
speakerlib = result
print("[OK] speakerlib loaded successfully")

-- 检查命令行参数
local videoUrl = ...
if not videoUrl then
    print("Usage: video_player <video URL>")
    print("Example: video_player https://example.com/video.mp4")
    return
end

_G.audio_ready = false
local task_id
local status_url

if videoUrl:sub(1,4) ~= "http" then
    task_id = videoUrl
    status_url = server_url .. "/api/task/" .. task_id
else
    print("Submitting video frame extraction task...")
    local requestData = {
        video_url = videoUrl,
        w = w,
        h = h,
        force_resolution = false,
        pad_to_target = true,
        fps = 20
    }

    local response = http.post(
        server_url .. "/api/video_frame/async",
        textutils.serializeJSON(requestData),
        {["Content-Type"] = "application/json"}
    )

    if not response then
        error("Failed to connect to API server")
    end

    local respBody = response.readAll()
    response.close()

    local createResult = textutils.unserialiseJSON(respBody)
    if not createResult or createResult.status ~= "success" then
        error("Task creation failed: " .. (createResult and createResult.message or "Unknown error"))
    end

    task_id = createResult.task_id
    status_url = createResult.status_url
end

term.clear()
term.setCursorPos(1,1)
print("task_id: " .. task_id)

-- 轮询任务状态直到获取足够帧数（200帧后开始播放）
local total_logs_printed = 0
while true do
    local response = http.get(status_url, {["Content-Type"] = "application/json"})
    if not response then
        error("Failed to fetch task status")
    end

    local respBody = response.readAll()
    response.close()

    local task_info = textutils.unserialiseJSON(respBody)

    term.clear()
    term.setCursorPos(1,1)
    print("task_id: " .. task_id)
    print("Status: " .. (task_info.status or "unknown"))
    print("Progress: " .. (task_info.progress or 0) .. "%")
    if task_info.message then
        print("Message: " .. task_info.message)
    end

    if task_info.new_logs and #task_info.new_logs > 0 then
        for i = 1, #task_info.new_logs do
            print(task_info.new_logs[i])
        end
        total_logs_printed = total_logs_printed + #task_info.new_logs
    end

    if task_info.result.current_frames and task_info.result.current_frames >= 200 then
        break
    end

    sleep(1)
end

-- 获取最终任务信息
local response = http.get(status_url, {["Content-Type"] = "application/json"})
local finalResp = textutils.unserialiseJSON(response.readAll())
response.close()

videoInfo = finalResp.result
videoInfo.fps = 20
videoInfo.frame_urls = {}

for i = 1, videoInfo.total_frames - 10 do
    videoInfo.frame_urls[i] = "/frames/"..task_id.."/frame_" .. string.format("%06d", i) .. ".png"
end

----------------------------------------------------------------
-- 音频播放协程
----------------------------------------------------------------
local function audioPlayer()
    print("[AUDIO] audioPlayer started")

    if not videoInfo.audio_urls then
        print("[AUDIO] No audio URLs provided, skipping playback.")
        _G.audio_ready = true
        return
    end
    print("[AUDIO] Audio URLs found")

    local mono = videoInfo.audio_urls.audio_dfpwm_url and (server_url .. videoInfo.audio_urls.audio_dfpwm_url) or nil
    local left = videoInfo.audio_urls.audio_dfpwm_left_url and (server_url .. videoInfo.audio_urls.audio_dfpwm_left_url) or nil
    local right = videoInfo.audio_urls.audio_dfpwm_right_url and (server_url .. videoInfo.audio_urls.audio_dfpwm_right_url) or nil

    print("[AUDIO] mono: " .. tostring(mono))
    print("[AUDIO] left: " .. tostring(left))
    print("[AUDIO] right: " .. tostring(right))

    -- 强制开启 speakerlib 内部日志
    _G.Playprint = true

    -- 调用播放
    speakerlib.play(mono, left, right)
    print("[AUDIO] Playback finished normally")
end

-- 以下为视频播放相关函数
local function readU32(s, pos)
    if pos + 3 > #s then return nil end
    local b1, b2, b3, b4 = s:byte(pos, pos + 3)
    return bit32.bor(
        bit32.lshift(b1, 24),
        bit32.lshift(b2, 16),
        bit32.lshift(b3, 8),
        b4
    )
end

local function unpackFramePack(data)
    local frames = {}
    local pos = 1
    local frameCount = readU32(data, pos)
    if not frameCount then error("Invalid framepack header") end
    pos = pos + 4

    for i = 1, frameCount do
        local size = readU32(data, pos)
        if not size then error("Truncated framepack at frame " .. i) end
        pos = pos + 4
        if pos + size - 1 > #data then error("Frame " .. i .. " out of bounds") end
        local frameData = data:sub(pos, pos + size - 1)
        frames[i] = frameData
        pos = pos + size
    end

    return frames
end

-- 配置参数
local BATCH_SIZE = 20
local PRELOAD_SECONDS = 20
local CACHE_WINDOW_SECONDS = 10
local totalFramesToPlay = #videoInfo.frame_urls
local preloadFrames = math.min(videoInfo.fps * PRELOAD_SECONDS, totalFramesToPlay)
local allFrameData = {}

-- 分批下载预加载帧
print("Pre-caching first " .. preloadFrames .. " frames...")
local initBatches = {}
for startIdx = 1, preloadFrames, BATCH_SIZE do
    local endIdx = math.min(startIdx + BATCH_SIZE - 1, preloadFrames)
    local urls = {}
    for i = startIdx, endIdx do
        table.insert(urls, videoInfo.frame_urls[i])
    end
    table.insert(initBatches, { start = startIdx, urls = urls })
end

-- 并发下载所有预加载批次
local initTasks = {}
for _, batch in ipairs(initBatches) do
    table.insert(initTasks, function()
        while true do
            local resp = http.post({
                url = server_url .. "/api/framepack?" .. batch.urls[1],
                headers = { ["Content-Type"] = "application/json" },
                body = textutils.serializeJSON({ urls = batch.urls }),
                timeout = 3,
                binary = true
            })

            if resp then
                local binData = resp.readAll()
                resp.close()

                local batchFrames = unpackFramePack(binData)
                for idx = 1, #batchFrames do
                    local globalIdx = batch.start + idx - 1
                    allFrameData[globalIdx] = batchFrames[idx]
                end
                print("Cached init batch: " .. batch.start .. " - " .. (batch.start + #batchFrames - 1))
                break
            else
                print("Retry init batch starting at " .. batch.start)
                sleep(0.5)
            end
        end
    end)
end

parallel.waitForAll(table.unpack(initTasks))
print("Initial caching completed.")

-- 播放循环参数
local frameDelay = 1 / videoInfo.fps
print("Starting playback (FPS: " .. videoInfo.fps .. ")")

local starttime1 = os.clock()
local running = true
local frameIndex = 1

-- 共享状态
local pendingRequests = {}
local downloadedFrames = {}

-- 缓存协程：动态预取未来 CACHE_WINDOW_SECONDS 秒的帧
local function cacheAhead()
    while running do
        local currentStart = frameIndex
        local currentEnd = math.min(frameIndex + videoInfo.fps * CACHE_WINDOW_SECONDS - 1, totalFramesToPlay)

        local batches = {}
        local i = currentStart
        while i <= currentEnd do
            if not allFrameData[i] and not downloadedFrames[i] then
                local batchStart = i
                local batchEnd = math.min(batchStart + BATCH_SIZE - 1, currentEnd)
                local urls = {}
                for j = batchStart, batchEnd do
                    if not allFrameData[j] and not downloadedFrames[j] then
                        table.insert(urls, videoInfo.frame_urls[j])
                        downloadedFrames[j] = true
                    end
                end
                if #urls > 0 then
                    table.insert(batches, {
                        start = batchStart,
                        urls = urls,
                        retry = 0
                    })
                end
                i = batchEnd + 1
            else
                i = i + 1
            end
        end

        for _, batch in ipairs(batches) do
            local url = server_url .. "/api/framepack?" .. batch.urls[1]
            local body = textutils.serializeJSON({ urls = batch.urls })
            http.request({
                url = url,
                headers = { ["Content-Type"] = "application/json" },
                body = body,
                timeout = 2,
                binary = true
            })
            pendingRequests[url] = batch
        end

        if next(batches) == nil then
            sleep(0.5)
        end
    end
end

-- HTTP 响应处理协程
local function httpResponseHandler()
    while running do
        local event, url, handleOrErr = os.pullEvent()

        if event == "http_success" then
            local batch = pendingRequests[url]
            if batch then
                pendingRequests[url] = nil
                local binData = handleOrErr.readAll()
                handleOrErr.close()

                local success, batchFrames = pcall(unpackFramePack, binData)
                if success then
                    for idx = 1, #batchFrames do
                        local globalIdx = batch.start + idx - 1
                        if not allFrameData[globalIdx] then
                            allFrameData[globalIdx] = batchFrames[idx]
                        end
                    end
                    print("[V] Cached batch: " .. batch.start .. " - " .. (batch.start + #batchFrames - 1))
                else
                    print("[R] Unpack failed for batch " .. batch.start .. ": " .. tostring(batchFrames))
                    for j = batch.start, batch.start + #batch.urls - 1 do
                        downloadedFrames[j] = nil
                    end
                end
            end

        elseif event == "http_failure" then
            local batch = pendingRequests[url]
            if batch then
                pendingRequests[url] = nil
                batch.retry = (batch.retry or 0) + 1
                if batch.retry < 3 then
                    print("[R] Retrying batch " .. batch.start .. " (attempt " .. (batch.retry + 1) .. ")")
                    for j = batch.start, batch.start + #batch.urls - 1 do
                        downloadedFrames[j] = nil
                    end
                else
                    print("[X] Giving up on batch " .. batch.start)
                    for j = batch.start, batch.start + #batch.urls - 1 do
                        downloadedFrames[j] = true
                    end
                end
            end
        end
    end
end

-- 视频渲染协程（基于帧间隔的实时帧率显示）
local function renderVideo()
    -- 等待音频准备就绪
    repeat
        sleep(0.05)
    until _G.audio_ready
    os.queueEvent("audio_start")

    local frameDelay = 1 / videoInfo.fps
    local startTime = os.clock()
    local totalFrames = #videoInfo.frame_urls
    local textUpdateCounter = 0
    local lastFrameTime = os.clock()
    local stallCount = 0
    local lastFrameIndex = 0
    local lastFrameStart = nil  -- 上一帧开始时间

    while running and frameIndex <= totalFrames do
        local frame_start = os.clock()

        -- 检查是否长时间没有新帧（可能卡住）
        if frame_start - lastFrameTime > 2.0 then
            print("[RENDER] Warning: No new frame for " .. string.format("%.2f", frame_start - lastFrameTime) .. "s, frameIndex=" .. frameIndex)
        end
        if frameIndex == lastFrameIndex then
            stallCount = stallCount + 1
            if stallCount > 10 then
                print("[RENDER] Frame index stuck at " .. frameIndex .. " for too long, forcing advance")
                frameIndex = frameIndex + 1
                stallCount = 0
                goto continue
            end
        else
            stallCount = 0
        end
        lastFrameIndex = frameIndex
        lastFrameTime = frame_start

        -- 获取当前帧数据
        local data = allFrameData[frameIndex]
        if not data then
            -- 如果数据不存在，等待并重试，但不要无限等待
            local retry = 0
            while not data and retry < 20 and running do
                sleep(0.1)
                data = allFrameData[frameIndex]
                retry = retry + 1
            end
            if not data then
                print("[RENDER] Frame " .. frameIndex .. " data missing after retries, skipping")
                frameIndex = frameIndex + 1
                goto continue
            end
        end

        -- 解码图像
        local imgBin = { data:byte(1, #data) }
        local success, image = pcall(gpu.decodeImage, table.unpack(imgBin))

        if success and image then
            gpu.drawImage(0, 0, image.ref())

            textUpdateCounter = textUpdateCounter + 1
            if textUpdateCounter % 5 == 1 then
                -- 计算基于帧间隔的播放帧率
                local play_fps = videoInfo.fps  -- 默认值
                if lastFrameStart then
                    local interval = frame_start - lastFrameStart
                    if interval > 0 then
                        play_fps = 1 / interval
                    end
                end
                gpu.drawText(1, 1,
                    frameIndex .. " / " .. totalFrames ..
                    " fps: " .. string.format("%.1f", play_fps),
                    0xffffff)
            end

            -- 更新上一帧开始时间（必须在定时器之前，因为下一帧开始时间就是当前帧开始时间）
            lastFrameStart = frame_start

            -- 等待下一帧（使用定时器，但设置超时保护）
            if frameIndex > 1 then
                local event, id
                local timerStarted = os.startTimer(frameDelay)
                -- 等待定时器事件，但最多等待 2 倍帧间隔
                local timeoutTimer = os.startTimer(frameDelay * 2)
                local gotTimer = false
                while not gotTimer and running do
                    event, id = os.pullEvent()
                    if event == "timer" and id == timerStarted then
                        gotTimer = true
                    elseif event == "timer" and id == timeoutTimer then
                        print("[RENDER] Timer timeout, continuing anyway")
                        gotTimer = true
                    end
                end
            end

            gpu.sync()
            image:free()
        else
            print("[RENDER] Failed to decode frame " .. frameIndex .. ": " .. tostring(image))
            -- 跳过此帧
        end

        -- 释放已渲染帧内存
        for i = 1, frameIndex - 3 do
            allFrameData[i] = nil
        end

        -- 基于实际播放时间调整帧索引
        local elapsed = os.clock() - startTime
        local expectedFrame = math.floor(elapsed / frameDelay) + 1
        if expectedFrame > frameIndex + 10 then
            print("[RENDER] Skipping ahead from " .. frameIndex .. " to " .. expectedFrame)
            frameIndex = expectedFrame
        else
            frameIndex = frameIndex + 1
        end

        ::continue::
    end

    -- 视频结束，通知音频停止
    _G.Playopen = false
    running = false
    print("[RENDER] Render loop ended")
end

-- 启动四个协程
parallel.waitForAll(renderVideo, cacheAhead, httpResponseHandler, audioPlayer)

-- 播放结束统计
local endtime = os.clock()
local time = endtime - starttime1
print("Playback finished")
print("Play_Time: " .. time)
local fps = totalFramesToPlay / time
print("Final_FPS: " .. fps)
print("Average Frame Interval: " .. 1/fps)