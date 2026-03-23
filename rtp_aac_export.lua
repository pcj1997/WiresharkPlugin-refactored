-- rtp_aac_export.lua
-- Dissector + exporter for AAC audio in RTP streams (dynamic PT).
-- Each frame is stored as [len_lo, len_hi, payload...] so a player can
-- re-frame the raw concatenation (same as original).
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local proto = Proto("aac", "Audio AAC")

    function proto.dissector(tvb, pinfo, tree)
        tree:add(proto, tvb()):append_text(
            string.format(" (Len: %d)", tvb:len()))
        pinfo.columns.protocol = "AAC"
    end

    local prefs   = proto.prefs
    prefs.dyn_pt  = Pref.range("AAC dynamic payload type", "",
        "Dynamic payload types for AAC (range 96-127)", 127)

    local dyn_table = DissectorTable.get("rtp_dyn_payload_type")
    dyn_table:add("aac", proto)

    local pt_table     = DissectorTable.get("rtp.pt")
    local old_dyn_pt   = nil
    local old_dissector = nil

    function proto.init()
        if prefs.dyn_pt == old_dyn_pt then return end
        local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
        local M = dofile(PLUGIN_DIR .. "common.lua")
        -- Restore old dissectors
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

    -- Custom on_packet: prefix each AAC frame with a 2-byte little-endian length.
    local function make_packet_cb(bit, f_data, M, temp_path)
        return function(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local frames = { f_data() }
            for _, data_f in ipairs(frames) do
                if data_f.len < 1 then return end
                local info = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path, ".aac", twappend)
                if info and info.file then
                    local data  = data_f.range:bytes()
                    local len   = data:len()
                    local b_lo  = string.char(len % 256)
                    local b_hi  = string.char(math.floor(len / 256) % 256)
                    info.file:write(b_lo, b_hi)
                    info.file:write(data:raw())
                end
            end
        end
    end

    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name      = "aac",
        field_name      = "aac",
        file_ext        = ".aac",
        menu_path       = "Audio/Export AAC",
        make_packet_cb  = make_packet_cb,
    })
end
