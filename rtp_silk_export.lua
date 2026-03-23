-- rtp_silk_export.lua
-- Dissector + exporter for SILK audio in RTP streams (dynamic PT).
-- Output format: 2-byte WeChat SILK header (0x02) + "#!SILK_V3" + framed blocks.
-- Each block = [len_lo, len_hi, payload...].
-- Reference: draft-spittka-silk-payload-format-00
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local proto  = Proto("silk", "Audio SILK")

    function proto.dissector(tvb, pinfo, tree)
        tree:add(proto, tvb()):append_text(
            string.format(" (Len: %d)", tvb:len()))
        pinfo.columns.protocol = "SILK"
    end

    local prefs  = proto.prefs
    prefs.dyn_pt = Pref.range("SILK dynamic payload type", "",
        "Dynamic payload types for SILK (range 96-127)", 127)

    local dyn_table = DissectorTable.get("rtp_dyn_payload_type")
    dyn_table:add("silk", proto)

    local pt_table      = DissectorTable.get("rtp.pt")
    local old_dyn_pt    = nil
    local old_dissector = nil

    function proto.init()
        if prefs.dyn_pt == old_dyn_pt then return end
        local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
        local M = dofile(PLUGIN_DIR .. "common.lua")
        if old_dyn_pt and #tostring(old_dyn_pt) > 0 then
            M.unregister_dyn_pt(pt_table,
                M.parse_pt_range(tostring(old_dyn_pt)), proto, old_dissector)
        end
        old_dyn_pt = prefs.dyn_pt
        if prefs.dyn_pt and #tostring(prefs.dyn_pt) > 0 then
            old_dissector = M.register_dyn_pt(pt_table,
                M.parse_pt_range(tostring(prefs.dyn_pt)), proto)
        end
    end

    -- SILK file header: WeChat variant prepends 0x02 before the standard magic.
    local SILK_FILE_HEADER = "\x02\x23\x21\x53\x49\x4C\x4B\x5F\x56\x33"  -- \x02#!SILK_V3

    -- Custom on_packet: prefix each frame with 2-byte LE length.
    local function make_packet_cb(bit, f_data, M, temp_path)
        return function(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local frames = { f_data() }
            for _, data_f in ipairs(frames) do
                if data_f.len < 1 then return end
                local info = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".silk", twappend, SILK_FILE_HEADER)
                if info and info.file then
                    local data = data_f.range:bytes()
                    local len  = data:len()
                    info.file:write(string.char(len % 256))
                    info.file:write(string.char(math.floor(len / 256) % 256))
                    info.file:write(data:raw())
                end
            end
        end
    end

    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name      = "silk",
        field_name      = "silk",
        file_ext        = ".silk",
        menu_path       = "Audio/Export SILK",
        make_packet_cb  = make_packet_cb,
    })
end
