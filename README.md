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

## 原始项目

本项目基于 [hongch911/WiresharkPlugin](https://github.com/hongch911/WiresharkPlugin) 进行重构，感谢原作者的贡献。

## 使用方法

将 `.lua` 文件复制到 Wireshark 插件目录：

- Linux: `~/.local/lib/wireshark/plugins/`
- macOS: `~/Library/LaunchServices/`
- Windows: `%APPDATA%\Wireshark\plugins\`

或者在 Wireshark 中通过 `分析` -> `Lua` -> `Reload` 加载插件。

## 许可证

继承自原项目许可证。
