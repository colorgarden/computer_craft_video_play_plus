-- SPDX-FileCopyrightText: 2021 The CC: Tweaked Developers
--
-- SPDX-License-Identifier: MPL-2.0

-- 全局控制变量（与主程序共享）
_G.getPlaymax = 0
_G.getPlay = 0
_G.setPlay = 0
_G.Playopen = true
_G.Playstop = false
_G.Playprint = false
_G.setVolume = 1

-- 扬声器配置
local speakerlist = {
    main = {},
    left = {},
    right = {}
}

local function printlog(...)
    if _G.Playprint then
        print(...)
    end
end

local function loadSpeakerConfig()
    speakerlist = { 
        main = { peripheral.find("speaker") },
        left = {}, 
        right = {}
    }

    local speaker_groups = fs.open("speaker_groups.cfg","r")
    if speaker_groups then
        local content = speaker_groups.readAll()
        speaker_groups.close()
        if content then
            local success, tableData = pcall(textutils.unserialise, content)
            if success and type(tableData) == "table" then
                speakerlist = { main = {}, left = {}, right = {} }
                for group_name, speakers in pairs(tableData) do
                    if speakerlist[group_name] then
                        for _, speaker_name in ipairs(speakers) do
                            local speaker = peripheral.wrap(speaker_name)
                            if speaker and peripheral.hasType(speaker_name, "speaker") then
                                table.insert(speakerlist[group_name], speaker)
                            end
                        end
                    end
                end
                return
            end
        end
    end
end

local function get_total_duration(url)
    if _G.Playprint then printlog("Calculating duration...") end
    local handle, err = http.get(url,{["Content-Type"] = "application/json"}, true)
    if not handle then
        error(url .. " Could not get duration: " .. (err or "Unknown error"))
    end
    
    local data = handle.readAll()
    handle.close()
    
    local total_length = (#data * 8) / 48000
    return total_length, #data
end

local function play_audio_chunk(speakers, buffer)
    if #speakers > 0 and buffer and #buffer > 0 then
        for _, speaker in pairs(speakers) do
            local success = false
            while not success and _G.Playopen do
                success = speaker.playAudio(buffer, _G.setVolume)
                if not success then
                    os.pullEvent("speaker_audio_empty")
                end
            end
        end
    end
end

-- 模块导出表
local M = {}

function M.stop()
    local all_speakers = {}
    for _, group in pairs(speakerlist) do
        for _, speaker in pairs(group) do
            table.insert(all_speakers, speaker)
        end
    end
    
    for _, speaker in pairs(all_speakers) do
        speaker.stop()
    end
end

function M.play(mono_url, left_url, right_url)
    -- 加载扬声器配置
    loadSpeakerConfig()

    print("main speaker:"..#speakerlist.main)
    print("left speaker:"..#speakerlist.left)
    print("right speaker:"..#speakerlist.right)

    -- 检查是否有扬声器
    local has_speakers = false
    for _, group in pairs(speakerlist) do
        if #group > 0 then
            has_speakers = true
            break
        end
    end
    
    if not has_speakers then
        error("No speakers attached")
    end

    -- 检查是否至少有一个音频URL
    if not mono_url and not left_url and not right_url then
        error("At least one audio URL is required")
    end

    -- 计算总时长（使用任意一个通道）
    local total_length, total_size
    if mono_url then
        total_length, total_size = get_total_duration(mono_url)
    elseif left_url then
        total_length, total_size = get_total_duration(left_url)
    elseif right_url then
        total_length, total_size = get_total_duration(right_url)
    end

    -- 设置总时间
    _G.getPlaymax = total_length
    _G.getPlay = 0

    if _G.Playprint then
        printlog("Playing audio (" .. math.ceil(total_length) .. "s)")
    end

    -- 创建HTTP连接
    local mono_httpfile, left_httpfile, right_httpfile
    
    if mono_url and #speakerlist.main > 0 then
        mono_httpfile = http.get(mono_url,{["Content-Type"] = "application/json"}, true)
        if not mono_httpfile then
            error("Could not open mono audio stream")
        end
    end

    if left_url and #speakerlist.left > 0 then
        left_httpfile = http.get(left_url,{["Content-Type"] = "application/json"}, true)
        if not left_httpfile then
            error("Could not open left audio stream")
        end
    end

    if right_url and #speakerlist.right > 0 then
        right_httpfile = http.get(right_url,{["Content-Type"] = "application/json"}, true)
        if not right_httpfile then
            error("Could not open right audio stream")
        end
    end

    -- 初始化DFPWM解码器（使用 require 加载）
    local dfpwm_module = require "cc.audio.dfpwm"
    local decoder = dfpwm_module.make_decoder()
    local left_decoder = dfpwm_module.make_decoder()
    local right_decoder = dfpwm_module.make_decoder()

    local chunk_size = 6000
    local bytes_read = 0

    -- 初始化播放位置
    if _G.setPlay > 0 then
        local skip_bytes = math.floor(_G.setPlay * 6000)
        if skip_bytes < total_size then
            local skipped = 0
            while skipped < skip_bytes and _G.Playopen do
                local to_skip = math.min(8192, skip_bytes - skipped)
                if mono_httpfile then mono_httpfile.read(to_skip) end
                if left_httpfile then left_httpfile.read(to_skip) end
                if right_httpfile then right_httpfile.read(to_skip) end
                skipped = skipped + to_skip
                bytes_read = bytes_read + to_skip
            end
            _G.getPlay = _G.setPlay
            _G.setPlay = 0
        end
    end

    -- 主播放循环
    _G.audio_ready = true
    os.pullEvent("audio_start")
    while bytes_read < total_size and _G.Playopen do
        -- 检查是否需要设置播放位置
        if _G.setPlay > 0 then
            if mono_httpfile then mono_httpfile.close() end
            if left_httpfile then left_httpfile.close() end
            if right_httpfile then right_httpfile.close() end

            if mono_url and #speakerlist.main > 0 then
                mono_httpfile = http.get(mono_url,{["Content-Type"] = "application/json"}, true)
                if not mono_httpfile then error("Could not reopen mono stream") end
            end

            if left_url and #speakerlist.left > 0 then
                left_httpfile = http.get(left_url,{["Content-Type"] = "application/json"}, true)
                if not left_httpfile then error("Could not reopen left stream") end
            end

            if right_url and #speakerlist.right > 0 then
                right_httpfile = http.get(right_url,{["Content-Type"] = "application/json"}, true)
                if not right_httpfile then error("Could not reopen right stream") end
            end

            local skip_bytes = math.floor(_G.setPlay * 6000)
            if skip_bytes < total_size then
                local skipped = 0
                while skipped < skip_bytes and _G.Playopen do
                    local to_skip = math.min(8192, skip_bytes - skipped)
                    if mono_httpfile then mono_httpfile.read(to_skip) end
                    if left_httpfile then left_httpfile.read(to_skip) end
                    if right_httpfile then right_httpfile.read(to_skip) end
                    skipped = skipped + to_skip
                    bytes_read = skip_bytes
                end
                _G.getPlay = _G.setPlay
                _G.setPlay = 0
            end
        end

        while _G.Playstop and _G.Playopen do
            os.sleep(0.1)
        end

        if not _G.Playopen then
            break
        end

        local mono_chunk, left_chunk, right_chunk
        local mono_buffer, left_buffer, right_buffer

        if mono_httpfile then
            mono_chunk = mono_httpfile.read(chunk_size)
        end

        if left_httpfile then
            left_chunk = left_httpfile.read(chunk_size)
        end

        if right_httpfile then
            right_chunk = right_httpfile.read(chunk_size)
        end

        if (not mono_chunk or #mono_chunk == 0) and 
           (not left_chunk or #left_chunk == 0) and 
           (not right_chunk or #right_chunk == 0) then
            break
        end

        if mono_chunk and #mono_chunk > 0 then
            mono_buffer = decoder(mono_chunk)
        end

        if left_chunk and #left_chunk > 0 then
            left_buffer = left_decoder(left_chunk)
        end

        if right_chunk and #right_chunk > 0 then
            right_buffer = right_decoder(right_chunk)
        end

        parallel.waitForAll(
            function() 
                if mono_buffer and #mono_buffer > 0 then
                    play_audio_chunk(speakerlist.main, mono_buffer)
                end
            end,
            function() 
                if right_buffer and #right_buffer > 0 then
                    play_audio_chunk(speakerlist.right, right_buffer)
                end
            end,
            function() 
                if left_buffer and #left_buffer > 0 then
                    play_audio_chunk(speakerlist.left, left_buffer)
                end
            end
        )

        local max_chunk_size = math.max(
            mono_chunk and #mono_chunk or 0,
            left_chunk and #left_chunk or 0,
            right_chunk and #right_chunk or 0
        )
        bytes_read = bytes_read + max_chunk_size
        _G.getPlay = bytes_read / 6000
        
        if _G.Playprint then
            term.setCursorPos(1, term.getCursorPos())
            printlog(("Playing: %ds / %ds"):format(math.floor(_G.getPlay), math.ceil(total_length)))
        end
    end

    if mono_httpfile then mono_httpfile.close() end
    if left_httpfile then left_httpfile.close() end
    if right_httpfile then right_httpfile.close() end

    if _G.Playprint and _G.Playopen then
        printlog("Playback finished.")
    end
    
    _G.Playopen = true
    _G.Playstop = false
    _G.getPlay = 0
end

return M