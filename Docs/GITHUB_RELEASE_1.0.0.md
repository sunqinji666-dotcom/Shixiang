# 拾响 1.0.0 · Build 111

这是拾响的第一个 GitHub 正式版本：一款面向影视创作者、完全本地优先的原生 macOS 音效管理器。

## 你可以用它做什么

- 将硬盘或外接盘中的音效包整理成可搜索、可试听、可收藏的本地资料库。
- 用自然语言描述镜头、情绪、远近、材质和时长，在本机完成 AI 搜索。
- 查看波形、建立 A/B 区间、比较相似声音，并在声音工作台分析 BPM、响度和调性。
- 将原音频或 A/B 片段直接拖入 Final Cut Pro。
- 在数万条声音规模下使用增量扫描、惰性目录和窗口化列表。

## Build 111 专项修复

- 赞助铜钱改为稳定的单一按钮事件链路，每次点击都能可靠显示微信二维码。
- 铜钱按六级逐次缩小，第六次点击后永久消失；重启和覆盖升级不会恢复，只有全新安装环境会重新出现。
- 二维码改为主窗口内固定居中的浮层，不再跟随标题栏或铜钱位置漂移。
- 避免快速点击穿透到标题栏触发窗口缩放与潜在崩溃。

## 系统要求

- Apple Silicon Mac（arm64）
- macOS 14.0 或更高版本
- 本地 AI 自然语言搜索需要 macOS 26.2 或更高版本

macOS 14.0–26.1 仍可使用全部非 AI 功能。正式 App 已内置本地 AI 运行时与模型，无需安装 Python、Homebrew、Xcode 或额外模型。

## 安装

1. 下载 `Shixiang-1.0.0-macOS-arm64-Build111.dmg`。
2. 打开 DMG，将“拾响.app”拖入“Applications”。
3. 从“应用程序”打开拾响。

当前版本使用本地稳定签名，尚未经过 Apple Developer ID 公证。若 macOS 首次打开时拦截，请按住 Control 点击 App 并选择“打开”，或前往“系统设置 → 隐私与安全性 → 仍要打开”。

## 完整性校验

```text
SHA-256  17818ce885ea5fe3e52e7c99340c01a5a0f21405e5b79e70c2d9276f7551ccbb
```

## 验证

- 自动测试：144 项（143 通过、1 项按系统能力正常跳过），0 失败
- 架构：arm64
- 最低系统：macOS 14.0
- App 深层严格签名验证：通过
- DMG 文件系统验证：通过
- 内置 AI 运行时、Qwen 模型、官网链接与赞助二维码资源：通过

完整教程：[shixiang.jack-sun.com/guide](https://shixiang.jack-sun.com/guide/)

完整变更：[RELEASE_NOTES.md](https://github.com/sunqinji666-dotcom/Shixiang/blob/main/RELEASE_NOTES.md)
