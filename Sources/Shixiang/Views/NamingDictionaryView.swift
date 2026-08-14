import SwiftUI

struct NamingDictionaryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: JacksunNamingProfile
    @State private var previewText = "Cinematic Braam Impact 01"

    init(profile: JacksunNamingProfile) {
        _draft = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ShixiangTheme.hairline)
            HSplitView {
                ruleList
                    .frame(minWidth: 430)
                templatePanel
                    .frame(minWidth: 300, maxWidth: 360)
            }
            Divider().overlay(ShixiangTheme.hairline)
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 580, idealHeight: 680)
        .background(ShixiangTheme.workspaceGradient)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ShixiangIconBadge(systemImage: "text.book.closed.fill", size: 34, tint: ShixiangTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Jacksun 命名字典")
                    .font(.system(size: 17, weight: .semibold))
                Text("把常见素材词，变成你自己的创作语言")
                    .font(.system(size: 10))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
            }
            Spacer()
            Text("\(draft.entries.filter(\.isEnabled).count) 条启用")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ShixiangTheme.gold)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(ShixiangRoundButtonStyle(size: 28))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(ShixiangTheme.surface.opacity(0.96))
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("词语替换")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    draft.entries.append(.init(sourceTerm: "", preferredName: ""))
                } label: {
                    Label("新增词条", systemImage: "plus")
                }
                .buttonStyle(ShixiangCommandButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            List {
                ForEach($draft.entries) { $entry in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $entry.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .frame(width: 34)
                        TextField("素材词，例如 braam", text: $entry.sourceTerm)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(ShixiangTheme.tertiaryText)
                        TextField("你的叫法，例如 深沉号角", text: $entry.preferredName)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            draft.entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(ShixiangTheme.canvas.opacity(0.44))
    }

    private var templatePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("命名模板", systemImage: "textformat")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("固定前缀（可留空）", text: $draft.namePrefix)
                        .textFieldStyle(.roundedBorder)
                    TextField("分隔符", text: $draft.separator)
                        .textFieldStyle(.roundedBorder)
                    Toggle("保留原素材编号", isOn: $draft.keepsSourceSequence)
                    Toggle("同名建议自动编号", isOn: $draft.numbersConflicts)
                }
                .font(.system(size: 10))
                .padding(12)
                .background(ShixiangTheme.elevated.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Label("即时预览", systemImage: "eye")
                        .font(.system(size: 12, weight: .semibold))
                    TextField("输入一个原始素材名", text: $previewText)
                        .textFieldStyle(.roundedBorder)
                    Text(draft.personalizedName(baseName: "电影冲击 01", searchableText: previewText))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.gold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(ShixiangTheme.canvas.opacity(0.56))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(12)
                .background(ShixiangTheme.elevated.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("所有规则只影响拾响里的显示别名和标签。原文件名、目录与音频内容始终不变。")
                    .font(.system(size: 9))
                    .foregroundStyle(ShixiangTheme.tertiaryText)
                    .lineSpacing(3)
            }
            .padding(14)
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button("恢复内置词典") { draft = .default }
                .buttonStyle(ShixiangCommandButtonStyle())
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(ShixiangCommandButtonStyle())
            Button("保存 Jacksun 词典") {
                draft.entries = draft.entries.filter {
                    !$0.sourceTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                library.updateNamingProfile(draft)
                dismiss()
            }
            .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(ShixiangTheme.surface.opacity(0.96))
    }
}
