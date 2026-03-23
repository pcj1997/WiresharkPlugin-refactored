-- rtp_h264_export.lua
-- Export RTP H.264 payload to raw Annex-B bitstream (*.264).
-- Supports Single NALU (type 1-23), STAP-A (type 24) and FU-A (type 28).
-- Reference: RFC 3984
-- Original author: Huang Qiangxiong (qiangxiong.huang@gmail.com)
-- Refactored:      Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    -- Load common utilities (same directory as this script).
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local M   = dofile(PLUGIN_DIR .. "common.lua")
    local bit = M.make_bit()

    -- Wireshark field extractors
    local f_h264 = Field.new("h264")

    local filter_string = nil   -- persists between menu activations

    -- -----------------------------------------------------------------------
    -- NALU helpers
    -- -----------------------------------------------------------------------

    --- Write Annex-B start code + NALU bytes to file (second pass only).
    --- first_run / counter book-keeping happens in write_nalu().
    local function write_annex_b(info, bytes)
        info.file:write("\x00\x00\x00\x01")
        info.file:write(bytes)
    end

    --- Central write gate.
    ---   info            stream_info record
    ---   bytes           raw string of NALU bytes (starting at NALU header)
    ---   is_nalu_start   true when bytes begins at the NALU header byte
    ---   first_run       bool
    ---   pgtw            ProgDlg|nil
    local function write_nalu(info, bytes, is_nalu_start, first_run, pgtw)
        if first_run then
            info.counter = info.counter + 1
            if is_nalu_start then
                local nalu_type = bit.band(bytes:byte(1), 0x1F)  -- Lua byte() is 1-based
                if not info.sps and nalu_type == 7 then info.sps = bytes end
                if not info.pps and nalu_type == 8 then info.pps = bytes end
            end
            return
        end

        -- Second pass --------------------------------------------------------
        -- Skip leading fragments until we see a NALU start.
        if not info.writed_nalu_begin then
            if not is_nalu_start then return end
            info.writed_nalu_begin = true
        end

        -- Prepend SPS+PPS before the very first NALU (if not already SPS).
        if info.counter2 == 0 and is_nalu_start then
            local nalu_type = bit.band(bytes:byte(1), 0x1F)
            if nalu_type ~= 7 then
                if info.sps then write_annex_b(info, info.sps)
                else tw_warn(info, "SPS not found – playback may fail") end
                if info.pps then write_annex_b(info, info.pps)
                else tw_warn(info, "PPS not found – playback may fail") end
            end
        end

        if is_nalu_start then
            write_annex_b(info, bytes)
        else
            info.file:write(bytes)
        end

        info.counter2 = info.counter2 + 1
        if pgtw and info.counter > 0 and info.counter2 < info.counter then
            pgtw:update(info.counter2 / info.counter)
        end
    end

    -- -----------------------------------------------------------------------
    -- RFC 3984 packet types
    -- -----------------------------------------------------------------------

    local function process_single_nalu(info, h264, first_run, pgtw)
        write_nalu(info, h264:tvb():raw(), true, first_run, pgtw)
    end

    local function process_stap_a(info, h264, first_run, pgtw)
        local tvb    = h264:tvb()
        local offset = 1           -- skip STAP-A indicator byte (index 0)
        while offset < tvb:len() do
            local size = tvb(offset, 2):uint()
            if size == 0 or offset + 2 + size > tvb:len() then break end
            write_nalu(info, tvb:raw(offset + 2, size), true, first_run, pgtw)
            offset = offset + 2 + size
        end
    end

    local function process_fu_a(info, h264, first_run, pgtw)
        local tvb    = h264:tvb()
        local fu_ind = h264:get_index(0)
        local fu_hdr = h264:get_index(1)
        local is_start = bit.band(fu_hdr, 0x80) ~= 0

        if is_start then
            -- Reconstruct NALU header from FU indicator + FU header.
            local nalu_hdr = bit.bor(
                bit.band(fu_ind, 0xE0),   -- forbidden_zero_bit | NRI
                bit.band(fu_hdr, 0x1F))   -- nal_unit_type
            write_nalu(info, string.char(nalu_hdr) .. tvb:raw(2), true, first_run, pgtw)
        else
            write_nalu(info, tvb:raw(2), false, first_run, pgtw)
        end
    end

    -- -----------------------------------------------------------------------
    -- Export window
    -- -----------------------------------------------------------------------

    local function open_export_window()
        local temp_path   = M.get_temp_path()
        local ffmpeg_path = M.get_ffmpeg_path()

        -- on_done: add Play buttons for each exported stream
        local function on_done(done, tw, twappend, ffmpeg_path, temp_path)
            if #done == 0 then
                twappend("No H.264 over RTP streams found.")
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

        -- on_packet: tap callback
        local function on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local h264s = { f_h264() }
            for _, h264_f in ipairs(h264s) do
                if h264_f.len < 2 then return end
                local h264    = h264_f.range:bytes()
                local hdr_type = bit.band(h264:get_index(0), 0x1F)
                local info    = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".264", twappend)

                if hdr_type >= 1 and hdr_type <= 23 then
                    process_single_nalu(info, h264, first_run, pgtw)
                elseif hdr_type == 24 then
                    process_stap_a(info, h264, first_run, pgtw)
                elseif hdr_type == 28 then
                    process_fu_a(info, h264, first_run, pgtw)
                else
                    twappend(string.format(
                        "Warning: pkt#%s unknown NAL type=%d (expected 1-23/24/28)",
                        tostring(pinfo.number), hdr_type))
                end
            end
        end

        -- Re-init per-stream state at start of second pass
        -- (writed_nalu_begin must be reset between passes)
        -- We piggyback on the first call to get_or_create_stream per pass.
        -- Reset is done by clearing stream_infos before each retap (handled
        -- in build_export_window when two_pass=true).

        M.build_export_window({
            title           = "Export H.264 to File",
            tap_filter_base = "h264",
            filter_string   = filter_string,
            temp_path       = temp_path,
            ffmpeg_path     = ffmpeg_path,
            two_pass        = true,
            on_packet       = on_packet,
            on_done         = on_done,
            dialog_reopen   = function()
                new_dialog("H.264 Filter", function(s)
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

    register_menu("Video/Export H264", menu_default, MENU_TOOLS_UNSORTED)
end
