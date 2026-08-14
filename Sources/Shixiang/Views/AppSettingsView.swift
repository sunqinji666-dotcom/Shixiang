import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A compact product-facing settings window. It keeps the local-first promise visible while
/// giving a future paid build one stable home for support, diagnostics and account features.
struct AppSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerController
    @EnvironmentObject private var license: ShixiangLicenseStore
    @EnvironmentObject private var updates: ShixiangUpdateStore
    @State private var isHealthPresented = false
    @State private var isPrivacyPresented = false
    @State private var licenseToken = ""
    @State private var operationMessage: String?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "111"
        return "\(marketing) · Build \(build)"
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("常规", systemImage: "slider.horizontal.3") }
            libraryTab
                .tabItem { Label("本地资料库", systemImage: "waveform.path.ecg") }
            supportTab
                .tabItem { Label("支持与更新", systemImage: "lifepreserver") }
            aboutTab
                .tabItem { Label("关于拾响", systemImage: "sparkles") }
        }
        .frame(width: 620, height: 430)
        .sheet(isPresented: $isHealthPresented) {
            LibraryHealthView()
                .environmentObject(library)
        }
        .alert("拾响", isPresented: Binding(
            get: { operationMessage != nil },
            set: { if !$0 { operationMessage = nil } }
        )) {
            Button("知道了") { operationMessage = nil }
        } message: {
            Text(operationMessage ?? "")
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    Text(version)
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                LabeledContent("工作模式") {
                    Label("本地优先", systemImage: "internaldrive")
                        .foregroundStyle(ShixiangTheme.gold)
                }
            } header: {
                Text("拾响")
            }

            Section {
                Text("拾响不会上传音频、波形或本地索引。在线音效库会在未来作为独立入口开放。")
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("隐私与联网")
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private var libraryTab: some View {
        Form {
            Section {
                LabeledContent("索引位置") {
                    Text(library.databaseDirectoryURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("波形缓存") {
                    Text(WaveformCacheMaintenance.directoryURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(
                    "自动监控已导入文件夹",
                    isOn: Binding(
                        get: { library.isFolderMonitoringEnabled },
                        set: { library.setFolderMonitoringEnabled($0) }
                    )
                )
                Text("素材文件新增、删除或替换后，拾响会等待操作结束，再以低优先级增量刷新。外接硬盘离线时保留索引并显示状态。")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("本机数据")
            }

            Section {
                HStack(spacing: 9) {
                    Button("打开素材库体检") { isHealthPresented = true }
                        .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                    Button("导出资料库备份") {
                        library.exportRecoverySnapshotWithPanel()
                    }
                    .buttonStyle(ShixiangCommandButtonStyle())
                    .disabled(library.isRecoveryTransferInProgress)
                }

                if library.isRecoveryTransferInProgress {
                    Label("正在后台处理资料库备份…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ShixiangTheme.gold)
                }

                HStack(spacing: 9) {
                    Button("清理波形缓存") {
                        _ = WaveformCacheMaintenance.clearInBackground()
                        operationMessage = "波形缓存正在后台清理，不会影响原始音频。"
                    }
                    .buttonStyle(ShixiangCommandButtonStyle())
                    Button("释放预加载声音") {
                        player.clearPreloadedAudio()
                        operationMessage = "预加载声音已释放，下一次试听会按需准备。"
                    }
                    .buttonStyle(ShixiangCommandButtonStyle())
                }
            } header: {
                Text("维护")
            }

            Section {
                Text("删除和清理操作只涉及拾响自己创建的索引、波形缓存与预加载播放器，不会删除、移动或改名硬盘上的原始音频。")
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Spacer()
            ShixiangMark(size: 62)
            Text("拾响")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .tracking(3)
                .foregroundStyle(ShixiangTheme.primaryText)
            Text("by Jacksun")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShixiangTheme.gold)
            Link(destination: ShixiangDistributionLinks.officialWebsiteURL) {
                VStack(spacing: 3) {
                    Label("访问拾响官方网站", systemImage: "globe")
                        .font(.system(size: 11, weight: .semibold))
                    Text("shixiang.jack-sun.com")
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(ShixiangTheme.violet)
            }
            .buttonStyle(.plain)
            .help("打开拾响官方网站")
            .accessibilityLabel("访问拾响官方网站 shixiang.jack-sun.com")
            Text("让散落的声音，回到它该在的位置。")
                .font(.system(size: 12))
                .foregroundStyle(ShixiangTheme.secondaryText)
            Text(version)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ShixiangTheme.tertiaryText)
            Spacer()
            Text("本地优先 · 原始音频只读 · 为创作者而生")
                .font(.system(size: 10))
                .foregroundStyle(ShixiangTheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var supportTab: some View {
        Form {
            Section {
                Text("遇到播放、扫描或拖入 Final Cut Pro 的问题时，可以导出一份匿名诊断包。它只包含版本、系统和数量统计，不会包含音频、文件名或目录路径。")
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    exportDiagnostics()
                } label: {
                    Label("导出匿名诊断包", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
            } header: {
                Text("支持")
            }

            Section {
                LabeledContent("当前版本") {
                    Text(version)
                        .foregroundStyle(ShixiangTheme.secondaryText)
                }
                LabeledContent("在线服务") {
                    Label("本地版未启用联网", systemImage: "lock.shield")
                        .foregroundStyle(ShixiangTheme.gold)
                }
                LabeledContent("自动更新") {
                    Label(updates.result.status.title, systemImage: updates.result.status.systemImage)
                        .foregroundStyle(updates.result.status == .available ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                }
                HStack(spacing: 9) {
                    Button("检查更新") {
                        updates.check()
                    }
                    .buttonStyle(ShixiangCommandButtonStyle())
                    .disabled(updates.result.status == .checking)

                    if updates.result.status == .available {
                        Button("打开下载页") {
                            updates.openDownloadPage()
                        }
                        .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                    }
                }
                Text(updates.result.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("发布边界")
            }

            Section {
                LabeledContent("授权状态") {
                    Label(license.status.title, systemImage: license.status.systemImage)
                        .foregroundStyle(license.status == .active ? ShixiangTheme.gold : ShixiangTheme.secondaryText)
                }
                Text(license.status.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if license.status != .localEdition {
                    TextField("粘贴离线许可证", text: $licenseToken, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)

                    HStack(spacing: 9) {
                        Button("验证并保存许可证") {
                            let accepted = license.install(token: licenseToken)
                            operationMessage = accepted
                                ? "许可证已在本机验证并保存。"
                                : license.status.detail
                        }
                        .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))

                        if license.status == .active {
                            Button("移除许可证") {
                                license.clear()
                                licenseToken = ""
                                operationMessage = "本机许可证已移除；当前资料库不受影响。"
                            }
                            .buttonStyle(ShixiangCommandButtonStyle())
                        }
                    }
                }
            } header: {
                Text("许可证")
            }

            Section {
                Text("隐私政策与正式支持入口会在联网售卖版上线前独立发布。本地版不会因为导出诊断包而上传任何内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(ShixiangTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("查看隐私说明") {
                    isPrivacyPresented = true
                }
                .buttonStyle(ShixiangCommandButtonStyle())
            } header: {
                Text("隐私")
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .sheet(isPresented: $isPrivacyPresented) {
            PrivacyPolicyView()
        }
    }

    private func exportDiagnostics() {
        let report = SupportDiagnosticsReport.make(
            appVersion: marketingVersion,
            build: buildVersion,
            soundPackCount: library.packs.count,
            soundCount: library.soundCount,
            savedCollectionCount: library.savedCollections.count,
            analyzedSoundCount: library.intelligenceByID.count
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "shixiang-diagnostics-build-\(buildVersion).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try report.jsonData.write(to: url, options: .atomic)
            operationMessage = "匿名诊断包已导出。它不包含音频、文件名或目录路径。"
        } catch {
            operationMessage = "诊断包导出失败：\(error.localizedDescription)"
        }
    }

    private var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "111"
    }
}

private struct PrivacyPolicyView: View {
    private let text: String

    init() {
        if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
           let bundledText = try? String(contentsOf: url, encoding: .utf8) {
            text = bundledText
        } else {
            text = "拾响本地版只在本机处理音效索引、波形和播放数据，不会上传原始音频。"
        }
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(ShixiangTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .frame(width: 620, height: 500)
        .background(ShixiangTheme.canvas)
    }
}
