-- rtp_g729_export.lua
-- Dissector + exporter for G.729 audio in RTP streams.
-- RTP payload type 18 (static).
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local proto = Proto("g729", "G.729")
    proto.fields = { ProtoField.bytes("g729.payload", "Raw") }

    function proto.dissector(tvb, pinfo, tree)
        tree:add(proto, tvb()):append_text(
            string.format(" (Len: %d)", tvb:len()))
        pinfo.columns.protocol = "G.729"
    end

    local pt_table = DissectorTable.get("rtp.pt")
    function proto.init()
        pt_table:add(18, proto)
    end

    -- Export
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name  = "g729",
        field_name  = "g729",
        file_ext    = ".g729",
        menu_path   = "Audio/Export G729",
        ffplay_hint = "ffplay -ar 8000 -ac 1 -f g729 -acodec g729 -autoexit ",
    })
end
