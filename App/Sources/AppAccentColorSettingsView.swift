import SwiftUI

struct AppAccentColorSettingsView: View {
  @Binding var selection: AppAccentColor

  var body: some View {
    List(AppAccentColor.allCases) { accentColor in
      let isSelected = selection == accentColor
      Button {
        selection = accentColor
      } label: {
        HStack(spacing: 12) {
          Circle()
            .fill(accentColor.color)
            .frame(width: 28, height: 28)
            .overlay {
              Circle()
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
            }
            .accessibilityHidden(true)

          Text(accentColor.title)
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
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accentColor.title)
      .accessibilityValue(isSelected ? "当前使用" : "")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("accent-color-option-\(accentColor.rawValue)")
    }
    .navigationTitle("强调色")
    .navigationBarTitleDisplayMode(.inline)
  }
}
