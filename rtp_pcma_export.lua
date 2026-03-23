-- rtp_pcma_export.lua
-- Dissector + exporter for G.711 A-law (PCMA) audio in RTP streams.
-- RTP payload type 8 (static).
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local proto = Proto("pcma", "PCMA")
    proto.fields = { ProtoField.bytes("pcma.payload", "Raw") }

    function proto.dissector(tvb, pinfo, tree)
        tree:add(proto, tvb()):append_text(
            string.format(" (Len: %d)", tvb:len()))
        pinfo.columns.protocol = "PCMA"
    end

    local pt_table = DissectorTable.get("rtp.pt")
    function proto.init()
        pt_table:add(8, proto)
    end

    -- Export
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name  = "pcma",
        field_name  = "pcma",
        file_ext    = ".pcma.raw",
        menu_path   = "Audio/Export PCMA",
        ffplay_hint = "ffplay -ar 8000 -ac 1 -f alaw -autoexit ",
    })
end
