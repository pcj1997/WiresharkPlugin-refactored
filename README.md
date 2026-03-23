# WiresharkPlugin

Wireshark 音视频解析与导出插件（Lua）

支持 Wireshark 4.4.0+（Lua 5.4）

---

## 文件说明

### 公共模块（必须与所有插件放在同一目录）

| 文件 | 说明 |
|------|------|
| `common.lua` | 公共工具库：bit 兼容、路径工具、stream 管理、导出 UI 构建器 |
| `audio_export_base.lua` | 音频导出通用基类，由各音频插件 `dofile` 加载 |
| `ps_dissector_core.lua` | PS 协议字段定义和解析函数，由两个 PS dissector 共用 |

### 视频插件

| 文件 | 说明 |
|------|------|
| `rtp_h264_export.lua` | 解析 RTP 中的 H.264 数据，导出为 Annex-B 裸流（`.264`） |
| `rtp_h265_export.lua` | 解析 RTP 中的 H.265 数据，导出为 Annex-B 裸流（`.265`） |
| `rtp_ps_assemble.lua` | PS 流 dissector：将 RTP 分片组装后再解析（推荐用于顺序包） |
| `rtp_ps_no_assemble.lua` | PS 流 dissector：逐包直接解析（不组装，适合乱序场景） |
| `rtp_ps_export.lua` | 将 PS 裸流导出为 `.ps` 文件 |

> ⚠️ `rtp_ps_assemble.lua` 与 `rtp_ps_no_assemble.lua` **不能同时加载**，两者都注册了同名的 `ps` proto。

### 音频插件

| 文件 | 说明 |
|------|------|
| `rtp_pcma_export.lua` | G.711 A-law（PCMA），静态 PT=8 |
| `rtp_pcmu_export.lua` | G.711 µ-law（PCMU），静态 PT=0 |
| `rtp_g729_export.lua` | G.729，静态 PT=18 |
| `rtp_aac_export.lua` | AAC，动态 PT（96-127），需在 Wireshark 首选项中配置 |
| `rtp_silk_export.lua` | SILK（微信语音），动态 PT，导出含 WeChat `#!SILK_V3` 文件头 |
| `rtp_amr_export.lua` | AMR-NB，仅支持 bandwidth-efficient 模式，导出标准 `.amr` 文件 |

---

## 安装方法

1. 打开 Wireshark → 菜单 **Help → About Wireshark → Folders**
2. 找到 **Personal Lua Plugins** 对应的目录
3. 将所有 `.lua` 文件复制到该目录（**所有文件必须在同一目录，不支持子目录**）
4. 重启 Wireshark 或按 `Ctrl+Shift+L` 重新加载 Lua 脚本

---

## 使用方法

### 导出视频/音频到文件

菜单 **Tools → Video** 或 **Tools → Audio**，选择对应格式：

- **Export All**：导出当前 pcap 中所有匹配的 RTP 流
- **Set Filter**：输入额外的 Wireshark 过滤条件（如 `ip.src == 192.168.1.1`）

导出完成后，文件保存在系统临时目录（`~/wireshark_temp/`）。点击 **Play** 按钮可直接用 ffplay 播放（需配置 `$FFMPEG` 环境变量），点击 **Browse** 可打开文件目录。

### 配置 ffmpeg 播放

```bash
# Linux / macOS
export FFMPEG=/opt/ffmpeg

# Windows
set FFMPEG=C:\ffmpeg
```

设置后可运行 `$FFMPEG/bin/ffplay -version` 验证。

ffmpeg 下载：https://github.com/BtbN/FFmpeg-Builds/releases

### 动态 PT 配置（AAC / SILK）

1. Wireshark → **Edit → Preferences → Protocols → AAC**（或 SILK）
2. 在 "dynamic payload type" 中填入实际的 PT 值，如 `96` 或 `96-100`

---

## 主要改动（vs 原版）

### 🔴 Bug 修复

| 问题 | 修复方式 |
|------|---------|
| `bit` 模块用 `local` 声明在 `if` 块内，导致 Lua 5.4 下所有位操作崩溃 | 抽取到 `common.lua` 的 `make_bit()`，正确声明作用域 |
| H.265 中 `bit.rshift` 未定义（仅定义了 `band/bor/lshift`） | `make_bit()` 补充了 `rshift` |
| H.265 单 NALU 类型判断 `> 0` 漏掉了合法的 type 0（TRAIL_N） | 改为 `>= 0` |
| PS `dis_pes` 中 ES rate 打印用了未初始化变量 `dts` | 改为打印正确的 `es_rate` |
| `stream_info_map` 是模块级全局，多次加载 pcap 会残留旧数据 | 在 `proto.init()` 中清空 |
| `completeRTP` 表只删不清，大 pcap 下内存持续增长 | 在 `proto.init()` 中重置 |
| `io.open` 的 `msg` 未声明为 `local`，泄漏为全局变量 | 改由 `M.get_or_create_stream` 封装，内部使用 `local` |

### 🟡 结构重构

- 提取 `common.lua`：消除了所有插件中重复的 `get_temp_path`、`get_ffmpeg_path`、`getArray`、stream 管理代码
- 提取 `audio_export_base.lua`：PCMA/PCMU/G729/AAC/SILK/AMR 六个插件共用同一套导出逻辑
- 提取 `ps_dissector_core.lua`：PS ProtoField 定义和解析函数由 assemble/no_assemble 共享，消除约 400 行重复
- `twappend`、`get_stream_info`、`dialog_menu` 等函数全部改为 `local`，不再污染全局命名空间
- `string.starts` / `string.ends` 不再 patch 标准库 `string` 元表，改为 `M.str_starts` / `M.str_ends`

---

## 协议参考

- H.264 RTP 封装：RFC 3984
- H.265 RTP 封装：RFC 7798
- PS 流格式：RFC 2250 / ISO/IEC 13818-1
- AMR 封装：RFC 3267
- SILK 封装：draft-spittka-silk-payload-format-00
