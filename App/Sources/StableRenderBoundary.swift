import SwiftUI

struct StableRenderBoundary<Key: Equatable, Content: View>: View, Equatable {
  let key: Key
  private let content: () -> Content

  init(key: Key, @ViewBuilder content: @escaping () -> Content) {
    self.key = key
    self.content = content
  }

  static func == (
    lhs: StableRenderBoundary<Key, Content>,
    rhs: StableRenderBoundary<Key, Content>
  ) -> Bool {
    lhs.key == rhs.key
  }

  var body: some View {
    content()
  }
}
