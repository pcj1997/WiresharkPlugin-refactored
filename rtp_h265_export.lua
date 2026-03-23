-- rtp_h265_export.lua
-- Export RTP H.265 payload to raw Annex-B bitstream (*.265).
-- Supports Single NAL Unit (type 0-47), Aggregation Packets AP (type 48),
-- and Fragmentation Units FU (type 49).
-- Reference: RFC 7798
-- Author:     Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local M   = dofile(PLUGIN_DIR .. "common.lua")
    local bit = M.make_bit()

    local f_h265 = Field.new("h265")

    local filter_string = nil

    -- -----------------------------------------------------------------------
    -- Helpers
    -- -----------------------------------------------------------------------

    local function write_annex_b(info, bytes)
        info.file:write("\x00\x00\x00\x01")
        info.file:write(bytes)
    end

    --- Extract H.265 NAL unit type from the first 2-byte NALU header.
    --- Bits [9..15] of the 16-bit header (big-endian) = bits[1..6] of byte 0.
    local function nalu_type_h265(byte0)
        return bit.band(bit.rshift(byte0, 1), 0x3F)
    end

    local function write_nalu(info, bytes, is_nalu_start, first_run, pgtw)
        if first_run then
            info.counter = info.counter + 1
            if is_nalu_start then
                local t = nalu_type_h265(bytes:byte(1))  -- Lua byte() is 1-based
                if not info.vps and t == 32 then info.vps = bytes end
                if not info.sps and t == 33 then info.sps = bytes end
                if not info.pps and t == 34 then info.pps = bytes end
            end
            return
        end

        -- Second pass
        if not info.writed_nalu_begin then
            if not is_nalu_start then return end
            info.writed_nalu_begin = true
        end

        if info.counter2 == 0 and is_nalu_start then
            local t = nalu_type_h265(bytes:byte(1))
            if t ~= 32 then   -- not VPS – prepend parameter sets
                if info.vps then write_annex_b(info, info.vps)
                else info.twappend("VPS not found – playback may fail") end
                if info.sps then write_annex_b(info, info.sps)
                else info.twappend("SPS not found – playback may fail") end
                if info.pps then write_annex_b(info, info.pps)
                else info.twappend("PPS not found – playback may fail") end
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
    -- RFC 7798 packet types
    -- -----------------------------------------------------------------------

    local function process_single_nalu(info, h265, first_run, pgtw)
        write_nalu(info, h265:tvb():raw(), true, first_run, pgtw)
    end

    local function process_ap(info, h265, first_run, pgtw)
        local tvb    = h265:tvb()
        local offset = 2    -- skip 2-byte AP NAL unit header
        while offset < tvb:len() do
            local size = tvb(offset, 2):uint()
            if size == 0 or offset + 2 + size > tvb:len() then break end
            write_nalu(info, tvb:raw(offset + 2, size), true, first_run, pgtw)
            offset = offset + 2 + size
        end
    end

    local function process_fu(info, h265, first_run, pgtw)
        local tvb       = h265:tvb()
        -- FU header is at byte index 2 (0-based); bits: S=0, E=1
        local fu_hdr    = tvb:range(2, 1):uint()
        local is_start  = bit.band(fu_hdr, 0x80) ~= 0
        local is_end    = bit.band(fu_hdr, 0x40) ~= 0   -- reserved for future use

        if is_start then
            -- Reconstruct 2-byte NALU header from PayloadHdr + FU header.
            -- PayloadHdr byte0: forbidden(1) | layer_id_high(6) | type_high(1)
            -- NALU type lives in FU header bits [5..0].
            local hdr0 = bit.bor(
                bit.band(h265:get_index(0), 0x81),          -- keep F + layer_id_high
                bit.lshift(bit.band(h265:get_index(2), 0x3F), 1))
            local hdr1 = h265:get_index(1)
            write_nalu(info, string.char(hdr0, hdr1) .. tvb:raw(3), true, first_run, pgtw)
        else
            write_nalu(info, tvb:raw(3), false, first_run, pgtw)
        end
    end

    -- -----------------------------------------------------------------------
    -- Export window
    -- -----------------------------------------------------------------------

    local function open_export_window()
        local temp_path   = M.get_temp_path()
        local ffmpeg_path = M.get_ffmpeg_path()

        local function on_done(done, tw, twappend, ffmpeg_path, temp_path)
            if #done == 0 then
                twappend("No H.265 over RTP streams found.")
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
            local h265s = { f_h265() }
            for _, h265_f in ipairs(h265s) do
                if h265_f.len < 5 then return end
                local h265     = h265_f.range:bytes()
                -- NAL unit type: bits [1..6] of byte 0 (RFC 7798 §1.1.4)
                local hdr_type = bit.band(bit.rshift(h265:get_index(0), 1), 0x3F)
                local info     = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".265", twappend)
                -- Store twappend on info for parameter-set warnings in write_nalu
                info.twappend  = twappend

                if hdr_type >= 0 and hdr_type <= 47 then
                    process_single_nalu(info, h265, first_run, pgtw)
                elseif hdr_type == 48 then
                    process_ap(info, h265, first_run, pgtw)
                elseif hdr_type == 49 then
                    process_fu(info, h265, first_run, pgtw)
                else
                    twappend(string.format(
                        "Warning: pkt#%s unknown NAL type=%d (expected 0-47/48/49)",
                        tostring(pinfo.number), hdr_type))
                end
            end
        end

        M.build_export_window({
            title           = "Export H.265 to File",
            tap_filter_base = "h265",
            filter_string   = filter_string,
            temp_path       = temp_path,
            ffmpeg_path     = ffmpeg_path,
            two_pass        = true,
            on_packet       = on_packet,
            on_done         = on_done,
            dialog_reopen   = function()
                new_dialog("H.265 Filter", function(s)
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

    register_menu("Video/Export H265", menu_default, MENU_TOOLS_UNSORTED)
end
