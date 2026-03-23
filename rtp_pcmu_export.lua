-- rtp_pcmu_export.lua
-- Dissector + exporter for G.711 mu-law (PCMU) audio in RTP streams.
-- RTP payload type 0 (static).
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local proto = Proto("pcmu", "PCMU")
    proto.fields = { ProtoField.bytes("pcmu.payload", "Raw") }

    function proto.dissector(tvb, pinfo, tree)
        tree:add(proto, tvb()):append_text(
            string.format(" (Len: %d)", tvb:len()))
        pinfo.columns.protocol = "PCMU"
    end

    local pt_table = DissectorTable.get("rtp.pt")
    function proto.init()
        pt_table:add(0, proto)
    end

    -- Export
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
    build({
        proto_name  = "pcmu",
        field_name  = "pcmu",
        file_ext    = ".pcmu.raw",
        menu_path   = "Audio/Export PCMU",
        ffplay_hint = "ffplay -ar 8000 -ac 1 -f mulaw -autoexit ",
    })
end
