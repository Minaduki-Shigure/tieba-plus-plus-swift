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
    range(in: text) != nil
  }

  func range(in text: String) -> Range<String.Index>? {
    let utf16Count = text.utf16.count
    guard
      location >= 0
      && length >= 0
      && location <= utf16Count
      && length <= utf16Count - location
    else { return nil }

    let lowerOffset = location
    let upperOffset = location + length
    var lowerBound: String.Index?
    var upperBound: String.Index?
    var index = text.startIndex
    var offset = 0

    // Foundation may clamp malformed NSRanges, so enumerate exact Character boundaries.
    while true {
      if offset == lowerOffset { lowerBound = index }
      if offset == upperOffset { upperBound = index }
      if let lowerBound, let upperBound {
        return lowerBound..<upperBound
      }
      guard index != text.endIndex else { return nil }

      let nextIndex = text.index(after: index)
      offset += text[index..<nextIndex].utf16.count
      index = nextIndex
    }
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
      let range = selection.range(in: text)
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
  @State private var searchText = ""

  let onSelect: (String) -> Void

  private var columns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible(), spacing: 8, alignment: .top)]
    }
    return [
      GridItem(.adaptive(minimum: 80, maximum: 112), spacing: 8, alignment: .top)
    ]
  }

  var body: some View {
    let entries = TiebaClassicEmoticonCatalog.entries(matching: searchText)
    NavigationStack {
      ScrollView {
        if entries.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
              .font(.largeTitle)
              .accessibilityHidden(true)
            Text("没有找到匹配的表情")
              .font(.headline)
            Text("试试其他名称，或清空搜索查看全部表情。")
              .font(.callout)
          }
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(24)
          .accessibilityIdentifier("classic-emoticon-no-results")
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
              ClassicEmoticonPickerCell(entry: entry) {
                guard let token = TiebaClassicEmoticonCatalog.token(for: entry.name) else { return }
                onSelect(token)
                dismiss()
              }
            }
          }
          .padding(12)
        }
      }
      .appPageSurface()
      .navigationTitle("经典表情")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "搜索表情名称"
      )
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
    .appNavigationSurface()
  }
}

struct ClassicEmoticonThumbnailRequest: Equatable, Sendable {
  static let maximumPixelSize = 120

  let url: URL?
  let fetchPolicy: DownsampledImageFetchPolicy

  init(
    entry: TiebaClassicEmoticonCatalog.Entry,
    policy: ContentMediaLoadPolicy,
    behavior: ContentMediaLoadBehavior,
    networkAccess: RemoteImageNetworkAccess
  ) {
    url = entry.thumbnailURL
    // Selecting an emoticon inserts its token; it never grants permission to
    // download an otherwise blocked thumbnail or introduces a nested button.
    fetchPolicy = ContentRemoteImageLoadDecision.fetchPolicy(
      policy: policy,
      behavior: behavior,
      lastObservedPolicy: nil,
      request: ContentRemoteImageRequestIdentity(
        url: entry.thumbnailURL,
        maxPixelSize: Self.maximumPixelSize
      ),
      authorizedRequest: nil,
      networkAccess: networkAccess
    )
  }
}

struct ClassicEmoticonPickerCell: View {
  let entry: TiebaClassicEmoticonCatalog.Entry
  let onSelect: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.contentMediaLoadPolicy) private var mediaLoadPolicy
  @Environment(\.contentMediaLoadBehavior) private var mediaLoadBehavior
  @Environment(\.contentImagePreviewNetworkAccess) private var previewNetworkAccess

  var body: some View {
    let request = ClassicEmoticonThumbnailRequest(
      entry: entry,
      policy: mediaLoadPolicy,
      behavior: mediaLoadBehavior,
      networkAccess: previewNetworkAccess
    )
    Button(action: onSelect) {
      VStack(spacing: 6) {
        DownsampledRemoteImage(
          url: request.url,
          maxPixelSize: ClassicEmoticonThumbnailRequest.maximumPixelSize,
          fetchPolicy: request.fetchPolicy,
          urlPolicy: .classicEmoticon
        ) { phase in
          switch phase {
          case .success(let asset, _):
            RemoteImageAssetView(
              asset: asset,
              contentMode: .fit,
              animationPlaybackEnabled: false
            )
          case .empty, .failure:
            Image(systemName: "face.smiling")
              .font(.title2)
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: 40, height: 40)
        .clipped()
        .accessibilityHidden(true)

        Text(entry.name)
          .font(.caption)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(8)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("表情 \(entry.name)")
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var accessibilityIdentifier: String {
    // Keep identifiers stable when the search hides preceding entries.
    let suffix =
      TiebaClassicEmoticonCatalog.names.firstIndex(of: entry.name)
      .map(String.init) ?? entry.name
    return "classic-emoticon-\(suffix)"
  }
}
