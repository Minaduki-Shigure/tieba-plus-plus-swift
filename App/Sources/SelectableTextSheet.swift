import Foundation
import SwiftUI
import UIKit

struct SelectableTextPresentation: Identifiable, Equatable, Sendable {
  let id: UUID
  let text: String

  init?(id: UUID = UUID(), text: String?) {
    guard
      let text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    self.id = id
    self.text = text
  }
}

enum SelectableTextSheetCommand: Equatable, Sendable {
  case close
  case copyAll
}

enum SelectableTextSheetCommandPolicy {
  static func consume(
    _ command: SelectableTextSheetCommand,
    expected: SelectableTextPresentation,
    pending: inout SelectableTextPresentation?
  ) -> String? {
    guard pending == expected else { return nil }
    pending = nil
    return command == .copyAll ? expected.text : nil
  }
}

@MainActor
enum SelectableTextPasteboard {
  static func write(_ text: String) {
    UIPasteboard.general.string = text
  }
}

struct SelectableTextSheet: View {
  let presentation: SelectableTextPresentation
  let onCommand: (SelectableTextSheetCommand, SelectableTextPresentation) -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(verbatim: presentation.text)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 14)
          .accessibilityHint("长按后可选择部分文字")
      }
      .navigationTitle("选择文字")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          Divider()
          Button {
            onCommand(.copyAll, presentation)
          } label: {
            Label("复制全部", systemImage: "doc.on.doc")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.borderedProminent)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
        }
        .background(.bar)
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            onCommand(.close, presentation)
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("关闭")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}
