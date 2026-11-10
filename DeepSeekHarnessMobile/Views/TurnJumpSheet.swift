import SwiftUI

/// 「跳转到轮次」面板：列出 host turnOutline 投影的全部轮次，
/// 点按跳到该轮第一条消息（对齐 fish-pocket 的同款面板）。
struct TurnJumpSheet: View {
    let outline: [TurnOutlineEntry]
    let onJump: (TurnOutlineEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(outline) { entry in
                        Button {
                            dismiss()
                            onJump(entry)
                        } label: {
                            card(entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(String(localized: "跳转到轮次"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").appFont(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel(String(localized: "关闭"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func card(_ entry: TurnOutlineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "第 \(entry.turn) 轮"))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(entry.prompt?.isEmpty == false ? entry.prompt! : String(localized: "（无文字输入）"))
                .appFont(.headline)
                .lineLimit(2)
            if let response = entry.response, !response.isEmpty {
                Text(response)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}
