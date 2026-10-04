import SwiftUI

/// The caller owns section availability and selection reconciliation. Stable
/// section IDs keep page identity independent of server ordering or labels.
struct ForumSectionPager<Selection: Hashable, Content: View>: View {
  let sections: [Selection]
  @Binding private var selection: Selection
  private let content: (Selection) -> Content

  init(
    sections: [Selection],
    selection: Binding<Selection>,
    @ViewBuilder content: @escaping (Selection) -> Content
  ) {
    self.sections = sections
    _selection = selection
    self.content = content
  }

  var body: some View {
    TabView(selection: $selection) {
      ForEach(sections, id: \.self) { section in
        content(section).tag(section)
      }
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
  }
}
