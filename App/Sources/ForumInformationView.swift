import Foundation
import SwiftUI

struct ForumInformationView: View {
  let forum: BrowseForum
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: ForumInformationViewModel
  @State private var selection = ForumInformationTab.overview
  @State private var retryToken = UUID()
  @State private var linkedTarget: TiebaLinkTarget?

  init(
    forum: BrowseForum,
    service: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.forum = forum
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: ForumInformationViewModel(forumID: forum.id, service: service)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("本吧信息", selection: $selection) {
        ForEach(ForumInformationTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Divider()
      content
    }
    .navigationTitle("本吧信息")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: LoadIdentity(tab: selection, retryToken: retryToken)) {
      await viewModel.load(selection)
    }
    .navigationDestination(isPresented: linkedTargetPresented) {
      if let linkedTarget {
        TiebaLinkDestination(
          target: linkedTarget,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch selection {
    case .overview:
      overviewContent
    case .rules:
      rulesContent
    case .moderators:
      moderatorsContent
    }
  }

  @ViewBuilder
  private var overviewContent: some View {
    switch viewModel.overview {
    case .idle, .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ErrorStateView(message: message, retry: retry)
    case .loaded(let overview):
      ForumOverviewList(snapshot: forum, overview: overview)
        .refreshable { await viewModel.reload(.overview) }
    }
  }

  @ViewBuilder
  private var rulesContent: some View {
    switch viewModel.rules {
    case .idle, .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ErrorStateView(message: message, retry: retry)
    case .loaded(let rules):
      if rules.rules.isEmpty,
        rules.title.isEmpty,
        rules.preface.isEmpty,
        rules.publishTime.isEmpty,
        rules.author == nil
      {
        EmptyStateView(title: "暂无公开吧规", systemImage: "doc.text")
      } else {
        rulesList(rules)
          .refreshable { await viewModel.reload(.rules) }
      }
    }
  }

  @ViewBuilder
  private var moderatorsContent: some View {
    switch viewModel.moderatorRoles {
    case .idle, .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ErrorStateView(message: message, retry: retry)
    case .loaded(let roles):
      if roles.allSatisfy({ $0.moderators.isEmpty }) {
        EmptyStateView(title: "暂无公开吧务", systemImage: "checkmark.shield")
      } else {
        moderatorList(roles)
          .refreshable { await viewModel.reload(.moderators) }
      }
    }
  }

  private func rulesList(_ rules: BrowseForumRules) -> some View {
    List {
      if !rules.title.isEmpty {
        Text(rules.title)
          .font(.title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
      }

      if let author = rules.author {
        Section("发布信息") {
          moderatorDestination(author) {
            ModeratorRow(moderator: author, detail: rules.publishTime)
          }
        }
      } else if !rules.publishTime.isEmpty {
        Section("发布信息") {
          Label(rules.publishTime, systemImage: "calendar")
        }
      }

      if !rules.preface.isEmpty {
        Section("前言") {
          Text(rules.preface)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      ForEach(rules.rules) { rule in
        Section(rule.title.isEmpty ? "规则" : rule.title) {
          BrowseContentView(contents: rule.contents, onTiebaLink: openTiebaLink)
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  private func moderatorList(_ roles: [BrowseForumModeratorRole]) -> some View {
    List {
      ForEach(roles.filter { !$0.moderators.isEmpty }) { role in
        Section("\(role.name) · \(role.moderators.count)") {
          ForEach(role.moderators) { moderator in
            moderatorDestination(moderator) {
              ModeratorRow(moderator: moderator, detail: nil)
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
  }

  @ViewBuilder
  private func moderatorDestination<Label: View>(
    _ moderator: BrowseForumModerator,
    @ViewBuilder label: () -> Label
  ) -> some View {
    if moderator.id > 0 {
      NavigationLink {
        UserProfileView(
          userID: moderator.id,
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
      } label: {
        label()
      }
    } else {
      label()
    }
  }

  private func retry() {
    retryToken = UUID()
  }

  private var linkedTargetPresented: Binding<Bool> {
    Binding(
      get: { linkedTarget != nil },
      set: { isPresented in
        if !isPresented { linkedTarget = nil }
      }
    )
  }

  private func openTiebaLink(_ target: TiebaLinkTarget) {
    linkedTarget = target
  }
}

private struct LoadIdentity: Hashable {
  let tab: ForumInformationTab
  let retryToken: UUID
}

private struct ForumOverviewList: View {
  let snapshot: BrowseForum
  let overview: BrowseForumOverview

  private var forum: BrowseForum { overview.forum }
  private var name: String { forum.name.isEmpty ? snapshot.name : forum.name }
  private var avatarURL: URL? {
    overview.originalAvatarURL ?? forum.avatarURL ?? snapshot.avatarURL
  }
  private var slogan: String { forum.slogan.isEmpty ? snapshot.slogan : forum.slogan }
  private var memberCount: Int {
    forum.memberCount > 0 ? forum.memberCount : snapshot.memberCount
  }
  private var threadCount: Int {
    forum.threadCount > 0 ? forum.threadCount : snapshot.threadCount
  }
  private var postCount: Int { forum.postCount > 0 ? forum.postCount : snapshot.postCount }
  private var category: String {
    let details = [forum.category, forum.subcategory].filter { !$0.isEmpty }
    let fallback = [snapshot.category, snapshot.subcategory].filter { !$0.isEmpty }
    return (details.isEmpty ? fallback : details).joined(separator: " · ")
  }

  var body: some View {
    List {
      HStack(alignment: .center, spacing: 14) {
        DownsampledRemoteImage(url: avatarURL, maxPixelSize: 384) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFill()
          default:
            Image(systemName: "text.bubble.fill")
              .foregroundStyle(.tint)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(Color(uiColor: .secondarySystemFill))
          }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text("\(name)吧")
            .font(.title3.weight(.semibold))
          if !slogan.isEmpty {
            Text(slogan)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.vertical, 4)

      Section("数据") {
        LabeledContent("关注", value: memberCount.formatted())
        if threadCount > 0 {
          LabeledContent("主题", value: threadCount.formatted())
        }
        if postCount > 0 {
          LabeledContent("帖子", value: postCount.formatted())
        }
        if !category.isEmpty {
          LabeledContent("分类", value: category)
        }
      }

      if !overview.introduction.isEmpty {
        Section("吧简介") {
          Text(overview.introduction)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .listStyle(.insetGrouped)
  }
}

private struct ModeratorRow: View {
  let moderator: BrowseForumModerator
  let detail: String?

  var body: some View {
    HStack(spacing: 12) {
      AvatarView(url: moderator.portraitURL, name: moderator.preferredName, size: 42)
      VStack(alignment: .leading, spacing: 3) {
        Text(moderator.preferredName)
          .foregroundStyle(.primary)
          .lineLimit(2)
        let metadata = [
          moderator.roleName,
          moderator.level > 0 ? "等级 \(moderator.level)" : "",
          detail ?? "",
        ].filter { !$0.isEmpty }
        if !metadata.isEmpty {
          Text(metadata.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
