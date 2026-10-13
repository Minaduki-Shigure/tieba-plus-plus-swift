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

/// The picker performs a native editing operation on the mounted editor. Draft
/// restoration remains a separate document replacement, never an undoable edit.
@MainActor
final class ComposerTextEditorController: ObservableObject {
  private weak var textView: UITextView?
  private var documentID: UUID?
  private var didEdit: ((UITextView) -> Void)?

  func attach(
    to textView: UITextView,
    documentID: UUID,
    didEdit: @escaping (UITextView) -> Void
  ) {
    self.textView = textView
    self.documentID = documentID
    self.didEdit = didEdit
  }

  func detach(from textView: UITextView) {
    guard self.textView === textView else { return }
    self.textView = nil
    documentID = nil
    didEdit = nil
  }

  /// Invalidate synchronously, before SwiftUI has applied the new document ID.
  /// Even identical source text in another account must not share undo history.
  func invalidateDocument() {
    documentID = nil
    textView?.undoManager?.removeAllActions()
  }

  @discardableResult
  func insert(
    _ insertion: String,
    expectedText: String,
    selection: ComposerTextSelection,
    documentID: UUID
  ) -> Bool {
    guard
      self.documentID == documentID,
      let textView,
      textView.window != nil,
      textView.isEditable,
      textView.markedTextRange == nil,
      textView.text.utf8.elementsEqual(expectedText.utf8),
      textView.selectedRange == selection.nsRange,
      let result = ComposerTextInsertionPolicy.replacingSelection(
        in: expectedText, selection: selection, with: insertion),
      let undoManager = textView.undoManager
    else { return false }

    // insertText also replaces a selected range. Do not assign text or mutate
    // textStorage: only the native editing path registers the matching undo.
    undoManager.beginUndoGrouping()
    textView.insertText(insertion)
    undoManager.endUndoGrouping()
    // A picker sheet may own first responder. Publish synchronously even if
    // UIKit does not emit an editing callback for this programmatic insertion.
    didEdit?(textView)
    return textView.text.utf8.elementsEqual(result.text.utf8)
      && textView.selectedRange == result.selection.nsRange
  }
}

@MainActor
struct ComposerTextEditor: UIViewRepresentable {
  @Environment(\.contentMediaLoadPolicy) private var mediaLoadPolicy
  @Environment(\.contentMediaLoadBehavior) private var mediaLoadBehavior
  @Environment(\.contentImagePreviewNetworkAccess) private var previewNetworkAccess
  @Binding var text: String
  @Binding var selection: ComposerTextSelection
  @Binding var isFocused: Bool

  let controller: ComposerTextEditorController
  let documentID: UUID
  let isEditable: Bool
  let accessibilityLabel: String
  let accessibilityIdentifier: String

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = ComposerEmoticonTextView()
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
    textView.updateEmoticonImages(fetchPolicy: emoticonFetchPolicy)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.apply(parent: self, to: textView)
    (textView as? ComposerEmoticonTextView)?.updateEmoticonImages(fetchPolicy: emoticonFetchPolicy)
  }

  private var emoticonFetchPolicy: DownsampledImageFetchPolicy {
    ContentRemoteImageLoadDecision.fetchPolicy(
      policy: mediaLoadPolicy, behavior: mediaLoadBehavior, lastObservedPolicy: nil,
      request: .init(url: nil, maxPixelSize: ClassicEmoticonThumbnailRequest.maximumPixelSize),
      authorizedRequest: nil, networkAccess: previewNetworkAccess)
  }

  static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
    coordinator.cancelFocusUpdate()
    (textView as? ComposerEmoticonTextView)?.stopLoadingImages()
    coordinator.parent.controller.detach(from: textView)
    textView.delegate = nil
    if textView.isFirstResponder {
      textView.resignFirstResponder()
    }
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextEditor
    private var isApplyingParentState = false
    private var appliedDocumentID: UUID?
    private var focusUpdateTask: Task<Void, Never>?

    init(parent: ComposerTextEditor) {
      self.parent = parent
    }

    func apply(parent: ComposerTextEditor, to textView: UITextView) {
      isApplyingParentState = true
      defer { isApplyingParentState = false }

      let isNewDocument = appliedDocumentID != parent.documentID
      if isNewDocument {
        textView.unmarkText()
      }
      let sourceChanged = !textView.text.utf8.elementsEqual(parent.text.utf8)
      if isNewDocument || (sourceChanged && textView.markedTextRange == nil) {
        textView.undoManager?.removeAllActions()
        if sourceChanged { textView.text = parent.text }
        textView.undoManager?.removeAllActions()
      }
      appliedDocumentID = parent.documentID
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
      parent.controller.attach(to: textView, documentID: parent.documentID) { [weak self] view in
        self?.textViewDidChange(view)
      }

      scheduleFocusUpdate(for: textView)
    }

    func cancelFocusUpdate() {
      focusUpdateTask?.cancel()
      focusUpdateTask = nil
    }

    private func scheduleFocusUpdate(for textView: UITextView) {
      cancelFocusUpdate()
      let documentID = parent.documentID
      // Both gaining and losing first responder can synchronously update the
      // SwiftUI keyboard toolbar. Perform neither inside updateUIView: opening
      // the picker while resigning there can reenter the presentation graph.
      focusUpdateTask = Task { @MainActor [weak self, weak textView] in
        guard
          !Task.isCancelled,
          let self,
          let textView,
          textView.delegate === self,
          self.parent.documentID == documentID,
          self.appliedDocumentID == documentID
        else { return }
        self.focusUpdateTask = nil

        // A newer SwiftUI update, user interaction, or dismantle may have
        // superseded this request. Read the current bindings, not a snapshot.
        if self.parent.isFocused, self.parent.isEditable {
          if !textView.isFirstResponder, textView.window != nil {
            textView.becomeFirstResponder()
          }
        } else if textView.isFirstResponder {
          textView.resignFirstResponder()
        }
      }
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
      parent.text = textView.text
      (textView as? ComposerEmoticonTextView)?.normalizeSelection()
      publishSelection(textView.selectedRange)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
      (textView as? ComposerEmoticonTextView)?.normalizeSelection(
        movingFrom: parent.selection.nsRange)
      publishSelection(textView.selectedRange)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
      if !parent.isFocused {
        parent.isFocused = true
      }
      publishSelection(textView.selectedRange)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      guard !isApplyingParentState else { return }
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
