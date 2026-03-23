-- audio_export_base.lua
-- Generic single-pass audio stream exporter.
-- Called by PCMA, PCMU, G.729, AAC, SILK plugins via:
--   local build = dofile(PLUGIN_DIR .. "audio_export_base.lua")
--   build(opts)
--
-- Required opts:
--   proto_name      string    e.g. "pcma"
--   field_name      string    Wireshark field, e.g. "pcma"
--   file_ext        string    output extension, e.g. ".pcma.raw"
--   menu_path       string    e.g. "Audio/Export PCMA"
--   file_header     string|nil  bytes prepended at file creation (e.g. AMR magic)
--   ffplay_hint     string|nil  ffplay command hint shown after export
--
-- Optional opts:
--   make_packet_cb  function(bit, f_data, M)
--     Returns a replacement on_packet callback for custom processing (AMR).
--     Signature: on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
--
-- Author: Yang Xing (hongch_911@126.com)  2025
--------------------------------------------------------------------------------

if _G.__ws_audio_export_base then return _G.__ws_audio_export_base end

local function build(opts)
    local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local M   = dofile(PLUGIN_DIR .. "common.lua")
    local bit = M.make_bit()

    local f_data = Field.new(opts.field_name)

    local filter_string = nil

    local function open_export_window()
        local temp_path   = M.get_temp_path()
        local ffmpeg_path = M.get_ffmpeg_path()

        local function on_done(done, tw, twappend, ffmpeg_path, temp_path)
            if #done == 0 then
                twappend("No " .. opts.proto_name:upper() .. " over RTP streams found.")
                return
            end
            if opts.ffplay_hint then
                for _, info in ipairs(done) do
                    twappend(opts.ffplay_hint .. info.filename)
                end
            end
            tw:add_button("Browse", function() browser_open_data_file(temp_path) end)
        end

        -- Default on_packet: write raw payload bytes verbatim
        local function default_on_packet(pinfo, tvb, stream_infos, first_run, pgtw, twappend)
            local frames = { f_data() }
            for _, data_f in ipairs(frames) do
                if data_f.len < 1 then return end
                local info = M.get_or_create_stream(
                    stream_infos, pinfo, temp_path,
                    opts.file_ext, twappend, opts.file_header)
                if info and info.file then
                    info.file:write(data_f.range:bytes():raw())
                end
            end
        end

        local on_packet = (opts.make_packet_cb
            and opts.make_packet_cb(bit, f_data, M, temp_path))
            or default_on_packet

        M.build_export_window({
            title           = "Export " .. opts.proto_name:upper() .. " to File",
            tap_filter_base = opts.field_name,
            filter_string   = filter_string,
            temp_path       = temp_path,
            ffmpeg_path     = ffmpeg_path,
            two_pass        = false,
            on_packet       = on_packet,
            on_done         = on_done,
            dialog_reopen   = function()
                new_dialog(opts.proto_name:upper() .. " Filter", function(s)
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

    register_menu(opts.menu_path, menu_default, MENU_TOOLS_UNSORTED)
end

return build
