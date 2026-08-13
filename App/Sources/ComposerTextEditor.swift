import SwiftUI
import TiebaCore
import UIKit

struct ComposerTextSelection: Equatable, Sendable {
  let location: Int
  let length: Int

  static let start = ComposerTextSelection(location: 0, length: 0)

  init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  init(_ range: NSRange) {
    self.init(location: range.location, length: range.length)
  }

  var nsRange: NSRange {
    NSRange(location: location, length: length)
  }

  func isValid(for text: String) -> Bool {
    let utf16Count = text.utf16.count
    return location >= 0
      && length >= 0
      && location <= utf16Count
      && length <= utf16Count - location
  }
}

struct ComposerTextInsertionResult: Equatable, Sendable {
  let text: String
  let selection: ComposerTextSelection
}

enum ComposerTextInsertionPolicy {
  static func replacingSelection(
    in text: String,
    selection: ComposerTextSelection,
    with insertion: String
  ) -> ComposerTextInsertionResult? {
    guard
      !insertion.isEmpty,
      selection.isValid(for: text),
      let range = Range(selection.nsRange, in: text)
    else { return nil }

    let updated = text.replacingCharacters(in: range, with: insertion)
    return ComposerTextInsertionResult(
      text: updated,
      selection: ComposerTextSelection(
        location: selection.location + insertion.utf16.count,
        length: 0
      )
    )
  }
}

@MainActor
struct ComposerTextEditor: UIViewRepresentable {
  @Binding var text: String
  @Binding var selection: ComposerTextSelection
  @Binding var isFocused: Bool

  let isEditable: Bool
  let accessibilityLabel: String
  let accessibilityIdentifier: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.backgroundColor = .clear
    textView.font = UIFont.preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    textView.textContainer.lineFragmentPadding = 0
    textView.alwaysBounceVertical = true
    textView.keyboardDismissMode = .interactive
    textView.accessibilityLabel = accessibilityLabel
    textView.accessibilityIdentifier = accessibilityIdentifier
    context.coordinator.apply(parent: self, to: textView)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.apply(parent: self, to: textView)
  }

  static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
    textView.delegate = nil
    if textView.isFirstResponder {
      textView.resignFirstResponder()
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextEditor
    private var isApplyingParentState = false

    init(parent: ComposerTextEditor) {
      self.parent = parent
    }

    func apply(parent: ComposerTextEditor, to textView: UITextView) {
      isApplyingParentState = true
      defer { isApplyingParentState = false }

      if !textView.text.utf8.elementsEqual(parent.text.utf8) {
        textView.text = parent.text
      }
      if parent.selection.isValid(for: parent.text),
        textView.selectedRange != parent.selection.nsRange,
        textView.markedTextRange == nil
      {
        textView.selectedRange = parent.selection.nsRange
      }
      textView.isEditable = parent.isEditable
      textView.isSelectable = true
      textView.accessibilityLabel = parent.accessibilityLabel
      textView.accessibilityIdentifier = parent.accessibilityIdentifier

      if parent.isFocused, parent.isEditable, !textView.isFirstResponder {
        Task { @MainActor [weak self, weak textView] in
          guard
            let self,
            let textView,
            self.parent.isFocused,
            self.parent.isEditable,
            textView.window != nil
          else { return }
          textView.becomeFirstResponder()
        }
      } else if (!parent.isFocused || !parent.isEditable), textView.isFirstResponder {
        textView.resignFirstResponder()
      }
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
      parent.text = textView.text
      publishSelection(textView.selectedRange)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
      publishSelection(textView.selectedRange)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      if !parent.isFocused {
        parent.isFocused = true
      }
      publishSelection(textView.selectedRange)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      publishSelection(textView.selectedRange)
      if parent.isFocused {
        parent.isFocused = false
      }
    }

    private func publishSelection(_ range: NSRange) {
      let value = ComposerTextSelection(range)
      if value != parent.selection, value.isValid(for: parent.text) {
        parent.selection = value
      }
    }
  }
}

struct ClassicEmoticonPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let onSelect: (String) -> Void

  private var columns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible(), spacing: 8, alignment: .top)]
    }
    return [
      GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 8, alignment: .top)
    ]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
          ForEach(Array(TiebaClassicEmoticonCatalog.names.enumerated()), id: \.offset) {
            index, name in
            Button {
              guard let token = TiebaClassicEmoticonCatalog.token(for: name) else { return }
              onSelect(token)
              dismiss()
            } label: {
              Text(name)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("表情 \(name)")
            .accessibilityIdentifier("classic-emoticon-\(index)")
          }
        }
        .padding(12)
      }
      .navigationTitle("经典表情")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("关闭")
          .help("关闭")
        }
      }
    }
  }
}
