-- rtp_ps_assemble.lua
-- PS dissector: assembles RTP fragments into complete PS frames then dissects.
-- Registers proto "ps" as a dynamic RTP payload type dissector.
--
-- ⚠️  Cannot be used simultaneously with rtp_ps_no_assemble.lua —
--     both register the same "ps" proto.  Pick one and remove the other.
--
-- Fixes vs original:
--   - bit module scope bug fixed
--   - stream_id_map cleared in proto.init() (cross-pcap pollution fix)
--   - complete_rtp table reset in proto.init() (memory leak fix)
--   - io.open error variable is local
--
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------
do
    local PLUGIN_DIR = debug.getinfo(1,"S").source:match("@(.*[/\\])") or ""
    local M   = dofile(PLUGIN_DIR .. "common.lua")
    local bit = M.make_bit()

    -- -----------------------------------------------------------------------
    -- Lookup tables
    -- -----------------------------------------------------------------------
    local stream_type_vals = {
        [0x0f]="AAC",        [0x10]="MPEG-4 Video",
        [0x1b]="H.264",      [0x24]="H.265",
        [0x80]="SVAC Video", [0x90]="G.711A",
        [0x91]="G.711U",     [0x92]="G.722.1",
        [0x93]="G.723.1",    [0x99]="G.729",
        [0x9b]="SVAC Audio",
    }
    local stream_id_vals = {
        [0xbc]="Program Stream Map",[0xbd]="Private Stream-1",
        [0xbe]="Padding Stream",    [0xbf]="Private Stream-2",
        [0xf0]="ECM Stream",        [0xf1]="EMM Stream",
        [0xf2]="DSMCC Stream",      [0xff]="Program Stream Directory",
    }
    for i=0xc0,0xdf do stream_id_vals[i]="Audio stream" end
    for i=0xe0,0xef do stream_id_vals[i]="Video stream" end

    local function enum_name(tbl,idx) return tbl[idx] or string.format("Unknown (0x%02x)",idx) end
    local function i64s(hi,lo) return string.format("%x%08x",hi,lo) end

    -- -----------------------------------------------------------------------
    -- Proto + fields
    -- -----------------------------------------------------------------------
    local proto_ps = Proto("ps","PS")
    local F = {}
    F.hdr            = ProtoField.none  ("ps.pack_header",    "PS Header")
    F.start_code     = ProtoField.bytes ("ps.pack_start_code","Start code",base.SPACE)
    F.scr_base       = ProtoField.none  ("ps.scr_base",       "SCR base")
    F.scr_ext        = ProtoField.none  ("ps.scr_ext",        "SCR extension")
    F.mux_rate       = ProtoField.new("Multiplex rate", "ps.multiplex_rate",  ftypes.UINT24,nil,base.DEC,0xfffffc)
    F.stuffing_len   = ProtoField.new("Stuffing length","ps.stuffing_length", ftypes.UINT8, nil,base.DEC,0x07)
    F.stuffing_bytes = ProtoField.bytes ("ps.stuffing_bytes","Stuffing bytes")
    F.sys_hdr        = ProtoField.none  ("ps.system_header","System Header")
    F.sys_start      = ProtoField.bytes ("ps.system_header.start_code","Start code",base.SPACE)
    F.sys_len        = ProtoField.new("Header length","ps.system_header.header_length",  ftypes.UINT16,nil,base.DEC)
    F.sys_rate_bound = ProtoField.new("Rate bound",   "ps.system_header.rate_bound",     ftypes.UINT24,nil,base.DEC,0x7ffffe)
    F.sys_audio_bnd  = ProtoField.new("Audio bound",  "ps.system_header.audio_bound",    ftypes.UINT8, nil,base.DEC,0xfc)
    F.sys_fixed      = ProtoField.new("Fixed flag",   "ps.system_header.fixed_flag",     ftypes.UINT8, nil,base.DEC,0x02)
    F.sys_csps       = ProtoField.new("CSPS flag",    "ps.system_header.csps_flag",      ftypes.UINT8, nil,base.DEC,0x01)
    F.sys_aud_lock   = ProtoField.new("Audio lock",   "ps.system_header.system_audio_lock_flag",ftypes.UINT8,nil,base.DEC,0x80)
    F.sys_vid_lock   = ProtoField.new("Video lock",   "ps.system_header.system_video_lock_flag",ftypes.UINT8,nil,base.DEC,0x40)
    F.sys_vid_bnd    = ProtoField.new("Video bound",  "ps.system_header.vedio_bound",    ftypes.UINT8, nil,base.DEC,0x1f)
    F.sys_pkt_rate   = ProtoField.new("Pkt rate restr","ps.system_header.packet_rate_restriction_flag",ftypes.UINT8,nil,base.DEC,0x80)
    F.sys_stream_id  = ProtoField.new("Stream ID",    "ps.system_header.stream_id",      ftypes.UINT8, nil,base.HEX)
    F.sys_std_scale  = ProtoField.new("P-STD scale",  "ps.system_header.buffer_bound_scale",ftypes.UINT16,nil,base.DEC,0x2000)
    F.sys_std_bound  = ProtoField.new("P-STD bound",  "ps.system_header.buffer_size_bound", ftypes.UINT16,nil,base.DEC,0x1fff)
    F.psm            = ProtoField.none  ("ps.program_map","Program Stream Map")
    F.psm_start      = ProtoField.bytes ("ps.program_map.start_code","Start code",base.SPACE)
    F.psm_sid        = ProtoField.new("Stream ID",   "ps.program_map.stream_id",          ftypes.UINT8, nil,base.HEX)
    F.psm_len        = ProtoField.new("Header length","ps.program_map.header_length",     ftypes.UINT16,nil,base.DEC)
    F.psm_cni        = ProtoField.new("Current/next","ps.program_map.current_next_indicator",ftypes.UINT8,nil,base.DEC,0x80)
    F.psm_ver        = ProtoField.new("Version",     "ps.program_map.version",             ftypes.UINT8, nil,base.DEC,0x1f)
    F.psm_info_len   = ProtoField.new("Info length", "ps.program_map.info_length",         ftypes.UINT16,nil,base.DEC)
    F.psm_map_len    = ProtoField.new("Map length",  "ps.program_map.map_length",          ftypes.UINT16,nil,base.DEC)
    F.psm_es_type    = ProtoField.new("ES type",     "ps.program_map.map.stream_type",     ftypes.UINT8, stream_type_vals,base.HEX)
    F.psm_es_id      = ProtoField.new("ES stream ID","ps.program_map.map.stream_id",       ftypes.UINT8, nil,base.HEX)
    F.psm_es_info_len= ProtoField.new("ES info len", "ps.program_map.map.stream_info_length",ftypes.UINT16,nil,base.DEC)
    F.psm_crc        = ProtoField.bytes ("ps.program_map.crc","CRC",base.SPACE)
    F.pes            = ProtoField.none  ("ps.pes","PES Packet")
    F.pes_start      = ProtoField.bytes ("ps.pes.start_code","Start code",base.SPACE)
    F.pes_sid        = ProtoField.new("Stream ID",  "ps.pes.stream_id",          ftypes.UINT8, stream_id_vals,base.HEX)
    F.pes_len        = ProtoField.new("Length",     "ps.pes.packet_length",      ftypes.UINT16,nil,base.DEC)
    F.pes_scramble   = ProtoField.new("Scrambling", "ps.pes.scrambing_control",  ftypes.UINT8, nil,base.DEC,0x30)
    F.pes_priority   = ProtoField.new("Priority",   "ps.pes.priority",           ftypes.UINT8, nil,base.DEC,0x08)
    F.pes_align      = ProtoField.new("Alignment",  "ps.pes.alignment",          ftypes.UINT8, nil,base.DEC,0x04)
    F.pes_copyright  = ProtoField.new("Copyright",  "ps.pes.copyright",          ftypes.UINT8, nil,base.DEC,0x02)
    F.pes_original   = ProtoField.new("Original",   "ps.pes.original",           ftypes.UINT8, nil,base.DEC,0x01)
    F.pes_pts_dts    = ProtoField.new("PTS/DTS",    "ps.pes.pts_dts_flag",       ftypes.UINT8, nil,base.DEC,0xc0)
    F.pes_escr_flag  = ProtoField.new("ESCR flag",  "ps.pes.escr_flag",          ftypes.UINT8, nil,base.DEC,0x20)
    F.pes_esrate_flag= ProtoField.new("ES rate flag","ps.pes.es_rate_flag",      ftypes.UINT8, nil,base.DEC,0x10)
    F.pes_dsm_flag   = ProtoField.new("DSM flag",   "ps.pes.dsm_trick_mode_flag",ftypes.UINT8, nil,base.DEC,0x08)
    F.pes_add_flag   = ProtoField.new("Add.info flag","ps.pes.additional_info_flag",ftypes.UINT8,nil,base.DEC,0x04)
    F.pes_crc_flag   = ProtoField.new("CRC flag",   "ps.pes.crc_flag",           ftypes.UINT8, nil,base.DEC,0x02)
    F.pes_ext_flag   = ProtoField.new("Ext flag",   "ps.pes.extension_flag",     ftypes.UINT8, nil,base.DEC,0x01)
    F.pes_hdr_len    = ProtoField.new("Hdr data len","ps.pes.header_data_length",ftypes.UINT8, nil,base.DEC)
    F.pes_hdr_bytes  = ProtoField.bytes ("ps.pes.header_data_bytes","Header data",base.SPACE)
    F.pes_pts        = ProtoField.none  ("ps.pes.pts","PTS")
    F.pes_dts        = ProtoField.none  ("ps.pes.dts","DTS")
    F.pes_escr       = ProtoField.none  ("ps.pes.escr","ESCR")
    F.pes_es_rate    = ProtoField.none  ("ps.pes.es_rate","ES rate")
    F.pes_dsm_mode   = ProtoField.new("DSM mode",   "ps.pes.dsm_trick_mode",     ftypes.UINT8, nil,base.HEX)
    F.pes_add_info   = ProtoField.new("Add.info",   "ps.pes.additional_info",    ftypes.UINT8, nil,base.HEX)
    F.pes_crc        = ProtoField.new("CRC",        "ps.pes.crc",                ftypes.UINT16,nil,base.HEX)
    F.pes_ext        = ProtoField.new("Extension",  "ps.pes.extension",          ftypes.UINT8, nil,base.HEX)
    F.pes_data       = ProtoField.bytes ("ps.pes.data_bytes","Data bytes")
    F.raw_data       = ProtoField.bytes ("ps.data","Data")

    proto_ps.fields = {
        F.hdr,F.start_code,F.scr_base,F.scr_ext,F.mux_rate,F.stuffing_len,F.stuffing_bytes,
        F.sys_hdr,F.sys_start,F.sys_len,F.sys_rate_bound,F.sys_audio_bnd,F.sys_fixed,
        F.sys_csps,F.sys_aud_lock,F.sys_vid_lock,F.sys_vid_bnd,F.sys_pkt_rate,
        F.sys_stream_id,F.sys_std_scale,F.sys_std_bound,
        F.psm,F.psm_start,F.psm_sid,F.psm_len,F.psm_cni,F.psm_ver,
        F.psm_info_len,F.psm_map_len,F.psm_es_type,F.psm_es_id,F.psm_es_info_len,F.psm_crc,
        F.pes,F.pes_start,F.pes_sid,F.pes_len,F.pes_scramble,F.pes_priority,
        F.pes_align,F.pes_copyright,F.pes_original,F.pes_pts_dts,F.pes_escr_flag,
        F.pes_esrate_flag,F.pes_dsm_flag,F.pes_add_flag,F.pes_crc_flag,F.pes_ext_flag,
        F.pes_hdr_len,F.pes_hdr_bytes,F.pes_pts,F.pes_dts,F.pes_escr,F.pes_es_rate,
        F.pes_dsm_mode,F.pes_add_info,F.pes_crc,F.pes_ext,F.pes_data,F.raw_data,
    }

    -- -----------------------------------------------------------------------
    -- Start-code detectors
    -- -----------------------------------------------------------------------
    local function has4(tvb,off,b3)
        if tvb:len()<off+4 then return false end
        return tvb:range(off,1):uint()==0x00 and tvb:range(off+1,1):uint()==0x00
           and tvb:range(off+2,1):uint()==0x01 and tvb:range(off+3,1):uint()==b3
    end
    local function is_ps_header(tvb,off)     return has4(tvb,off,0xba) end
    local function is_system_header(tvb,off) return has4(tvb,off,0xbb) end
    local function is_pes_header(tvb,off)
        if tvb:len()<off+4 then return false end
        return tvb:range(off,1):uint()==0x00 and tvb:range(off+1,1):uint()==0x00
           and tvb:range(off+2,1):uint()==0x01 and tvb:range(off+3,1):uint()>=0xbc
    end

    -- -----------------------------------------------------------------------
    -- Parse helpers
    -- -----------------------------------------------------------------------
    local function dis_pack_header(tvb,tree,off)
        local st=tvb:range(off+13,1):bitfield(5,3)
        local t=tree:add(F.hdr,tvb:range(off,14+st))
        t:add(F.start_code,tvb:range(off,4))
        local s1=tvb:range(off+4,1):bitfield(2,3)
        local s2=tvb:range(off+4,3):bitfield(6,15)
        local s3=tvb:range(off+6,3):bitfield(6,15)
        local se=tvb:range(off+8,2):bitfield(6,9)
        t:add(F.scr_base,tvb:range(off+4,6)):append_text(": "..(bit.lshift(s1,30)+bit.lshift(s2,15)+s3))
        t:add(F.scr_ext, tvb:range(off+4,6)):append_text(": "..se)
        t:add(F.mux_rate,tvb:range(off+10,3))
        t:add(F.stuffing_len,tvb:range(off+13,1))
        if st>0 then t:add(F.stuffing_bytes,tvb:range(off+14,st)) end
        return 14+st
    end

    local function dis_system_header(tvb,tree,off)
        local hlen=tvb:range(off+4,2):uint()
        local t=tree:add(F.sys_hdr,tvb:range(off,hlen+6))
        t:add(F.sys_start,    tvb:range(off,4))
        t:add(F.sys_len,      tvb:range(off+4,2))
        t:add(F.sys_rate_bound,tvb:range(off+6,3))
        t:add(F.sys_audio_bnd,tvb:range(off+9,1));  t:add(F.sys_fixed,   tvb:range(off+9,1))
        t:add(F.sys_csps,     tvb:range(off+9,1))
        t:add(F.sys_aud_lock, tvb:range(off+10,1)); t:add(F.sys_vid_lock,tvb:range(off+10,1))
        t:add(F.sys_vid_bnd,  tvb:range(off+10,1)); t:add(F.sys_pkt_rate,tvb:range(off+11,1))
        if hlen>6 then
            local r=hlen-6; local p=off+12
            while r>=3 do
                t:add(F.sys_stream_id,tvb:range(p,1))
                t:add(F.sys_std_scale,tvb:range(p+1,2))
                t:add(F.sys_std_bound,tvb:range(p+1,2))
                p=p+3; r=r-3
            end
        end
        return hlen+6
    end

    local function dis_stream_map(tvb,tree,off,sid_map)
        local plen=tvb:range(off+4,2):uint()
        local t=tree:add(F.psm,tvb:range(off,plen+6))
        t:add(F.psm_start,  tvb:range(off,3));    t:add(F.psm_sid,    tvb:range(off+3,1))
        t:add(F.psm_len,    tvb:range(off+4,2));  t:add(F.psm_cni,    tvb:range(off+6,1))
        t:add(F.psm_ver,    tvb:range(off+6,1));  t:add(F.psm_info_len,tvb:range(off+8,2))
        local ilen=tvb:range(off+8,2):uint()
        t:add(F.psm_map_len,tvb:range(off+10+ilen,2))
        local mlen=tvb:range(off+10+ilen,2):uint()
        local r=mlen; local p=off+12+ilen
        while r>=4 do
            local st=tvb:range(p,1):uint(); local sid=tvb:range(p+1,1):uint()
            t:add(F.psm_es_type,    tvb:range(p,1))
            t:add(F.psm_es_id,      tvb:range(p+1,1))
            t:add(F.psm_es_info_len,tvb:range(p+2,2))
            local eil=tvb:range(p+2,2):uint()
            sid_map[sid]=enum_name(stream_type_vals,st)
            p=p+4+eil; r=r-4-eil
        end
        t:add(F.psm_crc,tvb:range(off+12+ilen+mlen,4))
        return plen+6
    end

    local function dis_pes(tvb,tree,off,pinfo,sid_map,h264_dis,h265_dis,pcma_dis,pcmu_dis)
        local pes_len=tvb:range(off+4,2):uint()
        local tvb_len=tvb:len()
        local complete=tvb_len>=(off+pes_len+6)
        local t=tree:add(F.pes,tvb:range(off,complete and (pes_len+6) or (tvb_len-off)))
        t:add(F.pes_start,tvb:range(off,3)); t:add(F.pes_sid,tvb:range(off+3,1))
        local lt=t:add(F.pes_len,tvb:range(off+4,2))
        t:add(F.pes_scramble,tvb:range(off+6,1));  t:add(F.pes_priority, tvb:range(off+6,1))
        t:add(F.pes_align,   tvb:range(off+6,1));  t:add(F.pes_copyright,tvb:range(off+6,1))
        t:add(F.pes_original,tvb:range(off+6,1))
        t:add(F.pes_pts_dts, tvb:range(off+7,1));  t:add(F.pes_escr_flag,   tvb:range(off+7,1))
        t:add(F.pes_esrate_flag,tvb:range(off+7,1));t:add(F.pes_dsm_flag,   tvb:range(off+7,1))
        t:add(F.pes_add_flag,tvb:range(off+7,1));  t:add(F.pes_crc_flag,    tvb:range(off+7,1))
        t:add(F.pes_ext_flag,tvb:range(off+7,1))
        local hdl=tvb:range(off+8,1):uint()
        local ht=t:add(F.pes_hdr_len,tvb:range(off+8,1))
        if hdl>0 then ht:add(F.pes_hdr_bytes,tvb:range(off+9,hdl)) end
        local dlen=complete and (pes_len-3-hdl) or (tvb_len-off-9-hdl)
        if complete then lt:append_text(string.format(" (Data: %d)",dlen))
        else lt:append_text(string.format(" (Data: %d|Actual: %d)",pes_len-3-hdl,dlen)) end

        local idx=off+9
        local ptsdts=tvb:range(off+7,1):bitfield(0,2)
        if ptsdts==2 or ptsdts==3 then
            local hi=tvb:range(idx,1):bitfield(4,1)
            local pts=bit.lshift(tvb:range(idx,1):bitfield(5,2),30)+bit.lshift(tvb:range(idx+1,2):bitfield(0,15),15)+tvb:range(idx+3,2):bitfield(0,15)
            t:add(F.pes_pts,tvb:range(idx,5)):append_text(": 0x"..i64s(hi,pts)); idx=idx+5
        end
        if ptsdts==3 then
            local hi=tvb:range(idx,1):bitfield(4,1)
            local dts=bit.lshift(tvb:range(idx,1):bitfield(5,2),30)+bit.lshift(tvb:range(idx+1,2):bitfield(0,15),15)+tvb:range(idx+3,2):bitfield(0,15)
            t:add(F.pes_dts,tvb:range(idx,5)):append_text(": 0x"..i64s(hi,dts)); idx=idx+5
        end
        if tvb:range(off+7,1):bitfield(2,1)==1 then
            local hi=tvb:range(idx,1):bitfield(2,1)
            local escr=bit.lshift(tvb:range(idx,1):bitfield(3,2),30)+bit.lshift(tvb:range(idx,3):bitfield(6,15),15)+tvb:range(idx+2,3):bitfield(6,15)
            local ee=tvb:range(idx+4,2):bitfield(6,9)
            t:add(F.pes_escr,tvb:range(idx,6)):append_text(string.format(": 0x%s, ext: %d",i64s(hi,escr),ee)); idx=idx+6
        end
        if tvb:range(off+7,1):bitfield(3,1)==1 then
            t:add(F.pes_es_rate,tvb:range(idx,3)):append_text(": "..tvb:range(idx,3):bitfield(1,22)); idx=idx+3
        end
        if tvb:range(off+7,1):bitfield(4,1)==1 then idx=idx+1 end
        if tvb:range(off+7,1):bitfield(5,1)==1 then idx=idx+1 end
        if tvb:range(off+7,1):bitfield(6,1)==1 then idx=idx+2 end
        if tvb:range(off+7,1):bitfield(7,1)==1 then idx=idx+1 end

        local ds=off+9+hdl
        if ds>=tvb_len or dlen<=0 then return pes_len+6 end
        local es=tvb:bytes(ds,dlen):tvb()
        local sname=sid_map[tvb:range(off+3,1):uint()]
        if     sname=="H.264"  and h264_dis then h264_dis:call(es:len()>4 and es:bytes(4):tvb() or es,pinfo,t)
        elseif sname=="H.265"  and h265_dis then h265_dis:call(es:len()>4 and es:bytes(4):tvb() or es,pinfo,t)
        elseif sname=="G.711A" and pcma_dis then pcma_dis:call(es,pinfo,t)
        elseif sname=="G.711U" and pcmu_dis then pcmu_dis:call(es,pinfo,t)
        else
            local raw=t:add(F.pes_data,tvb:range(ds,dlen))
            raw:set_text(sname or string.format("0x%02x",tvb:range(off+3,1):uint()))
            raw:append_text(string.format(" (%d bytes)",dlen))
        end
        return pes_len+6
    end

    -- -----------------------------------------------------------------------
    -- Per-pcap state
    -- -----------------------------------------------------------------------
    local stream_id_map={};local complete_rtp={};local temp_array=nil;local last_number=0
    local h264_dis,h265_dis,pcma_dis,pcmu_dis;local sub_dis_loaded=false

    -- -----------------------------------------------------------------------
    -- Dissector
    -- -----------------------------------------------------------------------
    function proto_ps.dissector(tvb,pinfo,tree)
        if not sub_dis_loaded then
            local dl=Dissector.list()
            local function safe(n) for _,v in ipairs(dl) do if v==n then return Dissector.get(n) end end end
            h264_dis=Dissector.get("h264"); h265_dis=Dissector.get("h265")
            pcma_dis=safe("pcma"); pcmu_dis=safe("pcmu"); sub_dis_loaded=true
        end
        if not pinfo.visited then
            if is_ps_header(tvb,0) then temp_array=nil end
            if temp_array==nil then temp_array=ByteArray.new() end
            temp_array:append(tvb:bytes())
            complete_rtp[pinfo.number]=temp_array
            if not is_ps_header(tvb,0) and last_number>0 then complete_rtp[last_number]=nil end
            last_number=pinfo.number; return
        end
        pinfo.columns.protocol="PS"
        local buf=complete_rtp[pinfo.number]; if not buf then return end
        local rtvb=buf:tvb(); local pt=tree:add(proto_ps,rtvb:range()); local off=0
        if is_ps_header(rtvb,off) then
            local st=rtvb:range(off+13,1):bitfield(5,3)
            dis_pack_header(rtvb,pt,off); off=off+14+st
            if is_system_header(rtvb,off) then
                off=off+dis_system_header(rtvb,pt,off)
                if off+4<=rtvb:len() and rtvb:range(off+3,1):uint()==0xbc then
                    off=off+dis_stream_map(rtvb,pt,off,stream_id_map)
                end
            end
        end
        while is_pes_header(rtvb,off) do
            local step=dis_pes(rtvb,pt,off,pinfo,stream_id_map,h264_dis,h265_dis,pcma_dis,pcmu_dis)
            if not step or step==0 then break end; off=off+step
        end
    end

    -- -----------------------------------------------------------------------
    -- Preferences + registration
    -- -----------------------------------------------------------------------
    local prefs=proto_ps.prefs
    prefs.dyn_pt=Pref.range("PS dynamic payload type","","Dynamic RTP payload types for PS (96-127)",127)
    DissectorTable.get("rtp_dyn_payload_type"):add("ps",proto_ps)
    local pt_table=DissectorTable.get("rtp.pt")
    local old_dyn_pt=nil; local old_dissector=nil

    function proto_ps.init()
        stream_id_map={}; complete_rtp={}; temp_array=nil; last_number=0; sub_dis_loaded=false
        if prefs.dyn_pt==old_dyn_pt then return end
        if old_dyn_pt and #tostring(old_dyn_pt)>0 then
            M.unregister_dyn_pt(pt_table,M.parse_pt_range(tostring(old_dyn_pt)),proto_ps,old_dissector)
        end
        old_dyn_pt=prefs.dyn_pt
        if prefs.dyn_pt and #tostring(prefs.dyn_pt)>0 then
            old_dissector=M.register_dyn_pt(pt_table,M.parse_pt_range(tostring(prefs.dyn_pt)),proto_ps)
        end
    end
end
