import SwiftUI

struct RootView: View {
  let service: any BrowseService

  @AppStorage("recentForums") private var recentForumsStorage = ""
  @State private var query = ""
  @State private var path: [String] = []

  private var recentForums: [String] {
    recentForumsStorage
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.secondary)
            TextField("输入吧名", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.go)
              .onSubmit(openForum)
            Button(action: openForum) {
              Image(systemName: "arrow.right.circle.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("打开贴吧")
          }
        }

        if !recentForums.isEmpty {
          Section("最近访问") {
            ForEach(recentForums, id: \.self) { forum in
              Button {
                rememberAndOpen(forum)
              } label: {
                Label(forum, systemImage: "text.bubble")
              }
              .buttonStyle(.plain)
            }
            .onDelete(perform: removeRecentForums)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("贴吧++")
      .navigationDestination(for: String.self) { forumName in
        ForumView(forumName: forumName, service: service)
      }
    }
  }

  private func openForum() {
    rememberAndOpen(query)
  }

  private func rememberAndOpen(_ rawName: String) {
    let forumName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else { return }
    var updated = recentForums.filter { $0.caseInsensitiveCompare(forumName) != .orderedSame }
    updated.insert(forumName, at: 0)
    recentForumsStorage = updated.prefix(12).joined(separator: "\n")
    query = ""
    path.append(forumName)
  }

  private func removeRecentForums(at offsets: IndexSet) {
    var updated = recentForums
    updated.remove(atOffsets: offsets)
    recentForumsStorage = updated.joined(separator: "\n")
  }
}
