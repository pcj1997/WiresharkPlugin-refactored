-- rtp_ps_export.lua
-- Export raw PS bitstream from RTP packets to *.ps files.
-- Requires rtp_ps_assemble.lua or rtp_ps_no_assemble.lua to be loaded so
-- the "ps" display filter field is available.
--
-- Fixes vs original:
--   - bit module scope bug fixed (via common.lua)
--   - string.ends() no longer patches string metatable
--   - msg variable in io.open is now local (via M.get_or_create_stream)
--   - two_pass export uses M.build_export_window for consistent UI
--
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local M   = dofile(PLUGIN_DIR .. "common.lua")
    local bit = M.make_bit()

    local f_ps = Field.new("ps")

    local filter_string = nil

    -- -----------------------------------------------------------------------
    -- Export window
    -- -----------------------------------------------------------------------
    local function open_export_window()
        local temp_path   = M.get_temp_path()
        local ffmpeg_path = M.get_ffmpeg_path()

        local function on_done(done, tw, twappend, ffmpeg_path, temp_path)
            if #done == 0 then
                twappend("No PS over RTP streams found.")
                return
            end
            for i, info in ipairs(done) do
                local fp = info.filepath
                tw:add_button("Play " .. i, function()
                    twappend("ffplay -x 640 -y 640 -autoexit " .. info.filename)
                    os.execute(ffmpeg_path .. "ffplay -x 640 -y 640 -autoexit " .. fp)
                end)
            end
            tw:add_button("Browse", function() browser_open_data_file(temp_path) end)
        end

        local function on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local ps_fields = { f_ps() }
            for _, data_f in ipairs(ps_fields) do
                local info = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".ps", twappend)
                if info and info.file then
                    if first_run then
                        -- Pass 1: just count packets for progress bar.
                        info.counter = info.counter + 1
                    else
                        -- Pass 2: write raw PS bytes.
                        info.file:write(data_f.range:bytes():tvb():raw())
                        info.counter2 = info.counter2 + 1
                        if pgtw and info.counter > 0 and info.counter2 < info.counter then
                            pgtw:update(info.counter2 / info.counter)
                        end
                    end
                end
            end
        end

        M.build_export_window({
            title           = "Export PS to File",
            tap_filter_base = "ps",
            filter_string   = filter_string,
            temp_path       = temp_path,
            ffmpeg_path     = ffmpeg_path,
            two_pass        = true,
            on_packet       = on_packet,
            on_done         = on_done,
            dialog_reopen   = function()
                new_dialog("PS Filter", function(s)
                    filter_string = s
                    open_export_window()
                end, "Filter")
            end,
        })
    end

    local function menu_default()
        filter_string = get_filter()
        open_export_window()
    end

    register_menu("Video/Export PS", menu_default, MENU_TOOLS_UNSORTED)
end
