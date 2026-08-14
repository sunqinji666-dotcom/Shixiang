# 拾响 0.5 开发契约

## 产品边界

- 每次启动先显示模式选择：本地音效库可进入；在线音效库只显示“尚未开发”。
- 本地界面中不出现在线入口。
- 导入的是整个音效包文件夹。只建立索引，不移动、不改名、不复制原始音频。
- 保留音效包原本的文件夹层级与文件名。
- 首版支持 WAV、AIFF/AIF、MP3、M4A、CAF、FLAC。
- 音效条目可播放、收藏、显示波形，并以文件 URL 拖入 Final Cut Pro。
- 音效条目持有可选的源文件大小、修改时间和快速内容签名；扫描改名或移动时优先保留原路径，仅对唯一指纹继承 Shixiang 元数据。
- 索引和收藏状态保存在用户的 Application Support/Shixiang 中。
- 我的集合、别名标签和音频智能信息都只写入本机 SQLite；恢复快照包含这些 Shixiang-owned 数据。
- 调性识别只在用户主动要求时运行，不对整个素材库后台批量分析。
- 调性识别、变调试听和导出全部在本机完成，不上传音频。
- 所有音频处理都生成新副本，禁止覆盖或修改音效包原文件。
- A/B 拖拽生成的临时片段只保存在拾响自己的临时目录，并定期清理；不得触碰用户原始音频。

## 跨模块接口

Core 模块提供：

- `SoundItem`：`id/packageID/relativePath/fileName/folderPath/fileExtension/duration/sampleRate/channelCount/isFavorite`。
- `SoundPack`：`id/name/rootPath/bookmarkData/importedAt/lastScannedAt/items`。
- `FolderNode`：可递归显示的目录节点，根层从相对路径派生。
- `MusicalKey/KeyAnalysisResult/KeyAnalyzer`：提供 24 调建模、置信度结果、候选调性与按文件指纹缓存的本地分析。
- `@MainActor LibraryStore: ObservableObject`：`packs/selectedPackID/selectedFolderPath/selectedSoundID/query/isIndexing/alertMessage`；提供 `visibleSounds`、`selectedSound`、`selectedPack`、`folderNodes`、`importPackWithPanel()`、`addPack(from:)`、`refreshSelectedPack()`、`removeSelectedPack()`、`toggleFavorite(_:)`、`url(for:)`。

Audio 模块提供：

- `@MainActor AudioPlayerController: ObservableObject`：当前条目、播放状态、时间、总时长、音量；提供播放/暂停、停止、前后跳转和定位。
- `WaveformView(fileURL:accentColor:)`：异步读取音频并绘制静态波形。
- `SoundDragProvider.itemProvider(for:)`：生成可拖到 Final Cut Pro 的文件 URL provider。
- `PitchPreviewController`：提供 `-12...+12` 半音的原音/处理音实时对比试听，保持播放时长。
- `PitchShiftExporter/PitchExportController`：离线渲染 24-bit WAV 副本，提供进度、取消、原子落盘与源文件保护。

UI 模块只通过以上接口连接数据；若实现细节需要轻微调整，以可构建、可操作和保留产品边界为准。

## 视觉语言

- 电影诗意，但不牺牲专业效率：近黑“放映室”底色、克制的暖金高光、紫蓝作为播放状态。
- 系统字体、熟悉的 macOS 侧栏与列表行为；高频操作不做装饰动画。
- 启动页文案使用“让散落的声音，回到它该在的位置。”；品牌署名为 “by Jacksun”。
