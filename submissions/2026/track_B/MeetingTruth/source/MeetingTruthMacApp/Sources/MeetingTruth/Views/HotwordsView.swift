import SwiftUI

struct HotwordsView: View {
    @EnvironmentObject private var store: LabStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "热词库",
                    subtitle: "把机构名、业务术语、人名和缩写分组管理；不同模型会按能力映射为原生热词或提示词偏置。"
                )

                HStack {
                    Button {
                        store.addHotwordSet()
                    } label: {
                        Label("新增热词组", systemImage: "plus")
                    }
                    Spacer()
                    Text("已启用 \(store.hotwordSets.filter(\.isEnabled).count) 组，\(store.enabledHotwords.count) 个热词")
                        .foregroundStyle(.secondary)
                }

                ForEach($store.hotwordSets) { $set in
                    HotwordSetEditor(set: $set)
                }
            }
            .padding(24)
        }
    }
}

private struct HotwordSetEditor: View {
    @EnvironmentObject private var store: LabStore
    @Binding var set: HotwordSet

    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("", isOn: $set.isEnabled)
                        .labelsHidden()
                    TextField("热词组名称", text: $set.name)
                        .font(.headline)
                        .textFieldStyle(.plain)
                    Spacer()
                    Text("权重 \(set.weight, specifier: "%.1f")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $set.weight, in: 0.8...2.0, step: 0.1)

                TextEditor(text: Binding(
                    get: { set.words.joined(separator: "\n") },
                    set: { store.updateHotwords(for: set.id, text: $0) }
                ))
                .font(.body.monospaced())
                .frame(minHeight: 92)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("支持换行、逗号、顿号分隔。普通行作为热词；“误识别 => 正确词”作为术语纠错规则。纠错只在开启“术语后处理”时应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
