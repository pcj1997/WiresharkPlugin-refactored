# WiresharkPlugin-refactored

> Wireshark RTP 音视频流导出插件（代码重构版本）

## 项目简介

本项目是对 [hongch911/WiresharkPlugin](https://github.com/hongch911/WiresharkPlugin) 的代码重构版本。

在保留原项目核心功能的基础上，进行了以下改进：

- 代码结构优化
- 模块化重构
- 提升可维护性和可读性
- 修复部分已知问题

## 功能特性

- RTP 音频流导出（PCMU、PCMA、G729、SILK、AAC、AMR）
- RTP 视频流导出（H.264、H.265）
- PS 流解析与导出
- 支持多种音视频格式的导出

## 项目文件架构

```
WiresharkPlugin/
├── README.md                      # 项目说明文档
├── audio_export_base.lua          # 音频导出基类（所有音频格式的公共父类）
├── common.lua                     # 公共工具函数库
│
├── rtp_audio_export/             # RTP 音频导出模块
│   ├── rtp_pcmu_export.lua       # PCMU (G.711 μ-law) 音频导出
│   ├── rtp_pcma_export.lua       # PCMA (G.711 A-law) 音频导出
│   ├── rtp_g729_export.lua       # G.729 音频导出
│   ├── rtp_silk_export.lua       # SILK (Skype) 音频导出
│   ├── rtp_aac_export.lua        # AAC 音频导出
│   └── rtp_amr_export.lua        # AMR 音频导出
│
├── rtp_video_export/             # RTP 视频导出模块
│   ├── rtp_h264_export.lua       # H.264 视频导出
│   └── rtp_h265_export.lua       # H.265 (HEVC) 视频导出
│
└── ps_stream_export/             # PS (Program Stream) 导出模块
    ├── rtp_ps_export.lua         # PS 流基础导出
    ├── rtp_ps_assemble.lua       # PS 流组装导出（支持完整帧组装）
    └── rtp_ps_no_assemble.lua   # PS 流非组装导出（不进行帧组装）
```

### 文件详细说明

| 文件名 | 功能说明 |
|--------|----------|
| `audio_export_base.lua` | 音频导出的基类，定义通用接口和逻辑 |
| `common.lua` | 公共工具函数，提供编解码、格式转换等辅助功能 |
| `rtp_pcmu_export.lua` | 导出 PCMU (G.711 μ-law) 格式的 RTP 音频流 |
| `rtp_pcma_export.lua` | 导出 PCMA (G.711 A-law) 格式的 RTP 音频流 |
| `rtp_g729_export.lua` | 导出 G.729 编码的 RTP 音频流 |
| `rtp_silk_export.lua` | 导出 SILK (Skype) 编码的 RTP 音频流 |
| `rtp_aac_export.lua` | 导出 AAC 编码的 RTP 音频流 |
| `rtp_amr_export.lua` | 导出 AMR 编码的 RTP 音频流 |
| `rtp_h264_export.lua` | 导出 H.264 编码的 RTP 视频流 |
| `rtp_h265_export.lua` | 导出 H.265 (HEVC) 编码的 RTP 视频流 |
| `rtp_ps_export.lua` | PS 流基础导出功能 |
| `rtp_ps_assemble.lua` | PS 流组装导出，支持将分片 RTP 包组装成完整帧 |
| `rtp_ps_no_assemble.lua` | PS 流非组装导出，直接导出 RTP 包，不进行组装 |

## ⚠️ 重要注意事项

### 互斥文件

**`rtp_ps_no_assemble.lua` 与 `rtp_ps_assemble.lua` 不能同时使用！**

- `rtp_ps_assemble.lua`：进行 RTP 包的组装，将分片的数据组装成完整的帧后再导出
- `rtp_ps_no_assemble.lua`：不进行组装，直接导出原始 RTP 包数据

同时加载这两个文件会导致冲突和不可预期的行为。请根据实际需求选择其中一个：

- 如果需要完整的帧数据用于播放 → 使用 `rtp_ps_assemble.lua`
- 如果只需要原始 RTP 数据用于分析 → 使用 `rtp_ps_no_assemble.lua`

## 使用方法

将 `.lua` 文件复制到 Wireshark 插件目录：

- Linux: `~/.local/lib/wireshark/plugins/`
- macOS: `~/Library/LaunchServices/`
- Windows: `%APPDATA%\Wireshark\plugins\`

或者在 Wireshark 中通过 `分析` → `Lua` → `Reload` 加载插件。

## 原始项目

本项目基于 [hongch911/WiresharkPlugin](https://github.com/hongch911/WiresharkPlugin) 进行重构，感谢原作者的贡献。

## 许可证

继承自原项目许可证。
