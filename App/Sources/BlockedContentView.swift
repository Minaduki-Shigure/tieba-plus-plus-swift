import SwiftUI

struct LocallyFilteredContent<Content: View>: View {
  let visibility: LocalContentVisibility
  let placeholder: String
  private let content: () -> Content

  init(
    visibility: LocalContentVisibility,
    placeholder: String,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.visibility = visibility
    self.placeholder = placeholder
    self.content = content
  }

  var body: some View {
    switch visibility {
    case .visible:
      content()
    case .placeholder:
      Label(placeholder, systemImage: "hand.raised.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    case .hidden:
      EmptyView()
    }
  }
}
