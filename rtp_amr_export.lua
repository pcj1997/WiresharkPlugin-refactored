-- rtp_amr_export.lua
-- Dissector + exporter for AMR-NB audio in RTP streams (dynamic PT).
-- Supports bandwidth-efficient mode only (same as original).
-- Output: standard .amr file with "#!AMR\n" header + framed speech blocks.
-- Reference: RFC 3267
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    -- AMR-NB frame sizes in bytes (including TOC byte) indexed by FT (0-8).
    -- FT 9-14 = SID / NO_DATA – skipped.
    local FRAME_BYTES = {
        [0] = 13, [1] = 14, [2] = 16, [3] = 18,
        [4] = 20, [5] = 21, [6] = 27, [7] = 32, [8] = 6,
    }

    local AMR_FILE_HEADER = "\x23\x21\x41\x4D\x52\x0A"  -- "#!AMR\n"

    local f_amr_data    = Field.new("amr")
    local f_amr_mode    = Field.new("amr.payload_decoded_as")
    local f_amr_ft      = Field.new("amr.nb.toc.ft")

    local filter_string = nil

    local function make_packet_cb(bit, f_data, M, temp_path)
        return function(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local frames = { f_data() }
            for _, data_f in ipairs(frames) do
                if data_f.len < 1 then return end

                local mode_field = f_amr_mode()
                if not mode_field or mode_field.value ~= 1 then
                    -- Only bandwidth-efficient mode (value==1) is supported.
                    return
                end

                local ft_field = f_amr_ft()
                if not ft_field then return end
                local ft    = ft_field.value
                local valid = FRAME_BYTES[ft]
                if not valid then return end

                local info = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".amr", twappend, AMR_FILE_HEADER)
                if not (info and info.file) then return end

                local data = data_f.range:bytes()

                -- Build AMR TOC frame header byte: Q=1, FT[3:0], P=0 -> 0b0FT[3]FT[2]FT[1]FT[0]00
                local frame_hdr = bit.bor(0x04, bit.lshift(ft, 3))
                data:set_index(0, frame_hdr)

                -- Left-shift all payload bits by 2 (bandwidth-efficient alignment).
                local last = data:len() - 1
                for i = 1, last - 1 do
                    local hi = bit.lshift(data:get_index(i),   2)
                    local lo = bit.rshift(data:get_index(i+1), 6)
                    data:set_index(i, bit.band(bit.bor(hi, lo), 0xFF))
                end
                data:set_index(last, bit.band(bit.lshift(data:get_index(last), 2), 0xFF))

                info.file:write(data:raw(0, valid))
            end
        end
    end

    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name      = "amr",
        field_name      = "amr",
        file_ext        = ".amr",
        menu_path       = "Audio/Export AMR",
        ffplay_hint     = "ffplay -f amr -acodec amrnb -autoexit ",
        make_packet_cb  = make_packet_cb,
    })
end
