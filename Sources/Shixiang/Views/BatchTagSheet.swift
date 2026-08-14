import SwiftUI

struct BatchTagSheet: View {
    let selectionCount: Int
    let save: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tagText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                ShixiangIconBadge(systemImage: "tag.fill", size: 34, tint: ShixiangTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量添加标签")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ShixiangTheme.primaryText)
                    Text("将添加到已选择的 \(selectionCount.formatted(.number)) 个声音，不会覆盖已有标签")
                        .font(.system(size: 10))
                        .foregroundStyle(ShixiangTheme.tertiaryText)
                }
            }

            TextField("例如：雨声，室内，安静", text: $tagText)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { submit() }

            Text("使用逗号、顿号或换行分隔多个标签。标签只写入拾响索引。")
                .font(.system(size: 9))
                .foregroundStyle(ShixiangTheme.tertiaryText)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(ShixiangCommandButtonStyle())
                Button("添加标签", action: submit)
                    .buttonStyle(ShixiangCommandButtonStyle(isPrimary: true))
                    .disabled(parsedTags.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(ShixiangTheme.workspaceGradient)
        .task { isFocused = true }
    }

    private var parsedTags: [String] {
        SoundItem.normalizedTags(
            tagText.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
        )
    }

    private func submit() {
        let tags = parsedTags
        guard !tags.isEmpty else { return }
        save(tags)
        dismiss()
    }
}
