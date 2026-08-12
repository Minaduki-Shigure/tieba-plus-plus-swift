import CoreGraphics
import SwiftUI

struct AppAccentColorSettingsView: View {
  private struct CustomEditorPresentation: Identifiable {
    let id = UUID()
    let seed: AppAccentColorSeed
  }

  @Binding var selection: AppAccentColorSelection
  @Binding var savedCustomSeed: AppAccentColorSeed?
  @State private var customEditorPresentation: CustomEditorPresentation?

  var body: some View {
    List {
      ForEach(AppAccentColor.allCases) { accentColor in
        presetRow(accentColor)
      }

      Button {
        customEditorPresentation = CustomEditorPresentation(seed: customEditorSeed)
      } label: {
        accentRow(
          title: "自定义",
          color: customPreviewSelection.style.color,
          isSelected: selection.customSeed != nil
        )
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("自定义")
      .accessibilityValue(selection.customSeed != nil ? "当前使用" : "")
      .accessibilityAddTraits(selection.customSeed != nil ? .isSelected : [])
      .accessibilityIdentifier("accent-color-option-custom")
    }
    .navigationTitle("强调色")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $customEditorPresentation) { presentation in
      CustomAccentColorEditor(
        baseline: presentation.seed,
        apply: applyCustomSeed
      )
    }
  }

  private func presetRow(_ accentColor: AppAccentColor) -> some View {
    let presetSelection = AppAccentColorSelection.preset(accentColor)
    let isSelected = selection == presetSelection
    return Button {
      selection = presetSelection
    } label: {
      accentRow(
        title: accentColor.title,
        color: presetSelection.style.color,
        isSelected: isSelected
      )
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accentColor.title)
    .accessibilityValue(isSelected ? "当前使用" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("accent-color-option-\(accentColor.rawValue)")
  }

  private func accentRow(
    title: String,
    color: Color,
    isSelected: Bool
  ) -> some View {
    HStack(spacing: 12) {
      Circle()
        .fill(color)
        .frame(width: 28, height: 28)
        .overlay {
          Circle()
            .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
        .accessibilityHidden(true)

      Text(title)
        .foregroundStyle(.primary)

      Spacer(minLength: 12)

      Image(systemName: "checkmark")
        .font(.body.weight(.semibold))
        .foregroundStyle(.tint)
        .frame(width: 24, height: 24)
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var customEditorSeed: AppAccentColorSeed {
    AppAccentColorEditorPolicy.initialSeed(
      selection: selection,
      savedCustomSeed: savedCustomSeed
    )
  }

  private var customPreviewSelection: AppAccentColorSelection {
    .custom(customEditorSeed)
  }

  private func applyCustomSeed(_ seed: AppAccentColorSeed) {
    AppAccentColorEditorPolicy.apply(
      seed,
      setSelection: { selection = $0 },
      setSavedCustomSeed: { savedCustomSeed = $0 }
    )
    customEditorPresentation = nil
  }
}

private struct CustomAccentColorEditor: View {
  let baseline: AppAccentColorSeed
  let apply: (AppAccentColorSeed) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draftColor: CGColor

  init(
    baseline: AppAccentColorSeed,
    apply: @escaping (AppAccentColorSeed) -> Void
  ) {
    self.baseline = baseline
    self.apply = apply
    _draftColor = State(initialValue: baseline.cgColor)
  }

  var body: some View {
    NavigationStack {
      Form {
        ColorPicker(selection: $draftColor, supportsOpacity: false) {
          Text("颜色")
        }
        .accessibilityIdentifier("custom-accent-color-picker")
      }
      .navigationTitle("自定义强调色")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("应用") {
            guard let draftSeed else { return }
            apply(draftSeed)
          }
          .disabled(draftSeed == nil)
          .accessibilityIdentifier("custom-accent-color-apply")
        }

        ToolbarItem(placement: .bottomBar) {
          Button {
            draftColor = baseline.cgColor
          } label: {
            Image(systemName: "arrow.uturn.backward")
          }
          .disabled(draftSeed == baseline)
          .accessibilityLabel("恢复打开时的颜色")
          .help("恢复打开时的颜色")
          .accessibilityIdentifier("custom-accent-color-restore")
        }
      }
      .tint(AppAccentColor.defaultValue.color)
    }
  }

  private var draftSeed: AppAccentColorSeed? {
    AppAccentColorSeed(cgColor: draftColor)
  }
}
