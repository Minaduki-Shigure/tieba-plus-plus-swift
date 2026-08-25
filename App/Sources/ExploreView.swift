import SwiftUI

enum ExploreSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case concern
  case personalized
  case hot

  var id: Self { self }

  var title: String {
    switch self {
    case .concern:
      "关注"
    case .personalized:
      "推荐"
    case .hot:
      "热门"
    }
  }

  static func available(hasActiveAccount: Bool) -> [Self] {
    hasActiveAccount ? [.concern, .personalized, .hot] : [.personalized, .hot]
  }
}

struct ExploreView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let accountService: any AccountService
  let feedbackService: any PersonalizedFeedbackService
  let accountVault: any AccountVault
  let accountSessionLookup: any AccountSessionLookup

  @State private var selectedSection: ExploreSection
  @StateObject private var channelsViewModel: ExploreChannelsViewModel

  init(
    initialSection: ExploreSection = .personalized,
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    accountService: any AccountService,
    feedbackService: any PersonalizedFeedbackService,
    accountVault: any AccountVault,
    accountSessionLookup: any AccountSessionLookup
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.accountService = accountService
    self.feedbackService = feedbackService
    self.accountVault = accountVault
    self.accountSessionLookup = accountSessionLookup
    _selectedSection = State(initialValue: initialSection)
    _channelsViewModel = StateObject(
      wrappedValue: ExploreChannelsViewModel(vault: accountVault)
    )
  }

  var body: some View {
    TabView(selection: selectedSectionBinding) {
      if channelsViewModel.visibleSections.contains(.concern) {
        ConcernFeedView(
          isActive: selectedSection == .concern,
          browseService: service,
          accountService: accountService,
          vault: accountVault,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository
        )
        .tag(ExploreSection.concern)
      }

      PersonalizedFeedView(
        isActive: selectedSection == .personalized,
        service: service,
        accountService: accountService,
        feedbackService: feedbackService,
        vault: accountVault,
        accountSessionLookup: accountSessionLookup,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
      .tag(ExploreSection.personalized)

      HotThreadListView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        showsNavigationTitle: false
      )
      .tag(ExploreSection.hot)
    }
    .tabViewStyle(.page(indexDisplayMode: .never))
    .appPageSurface(.canvas)
    .navigationTitle("发现")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("发现频道", selection: selectedSectionBinding) {
        ForEach(channelsViewModel.visibleSections) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .appBarMaterialSurface()
    }
    .onAppear(perform: channelsViewModel.reload)
    .onDisappear(perform: channelsViewModel.cancel)
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      channelsViewModel.reload()
    }
    .onChange(of: channelsViewModel.visibleSections) { sections in
      if !sections.contains(selectedSection) {
        selectedSection = .personalized
      }
    }
  }

  private var selectedSectionBinding: Binding<ExploreSection> {
    Binding(
      get: {
        channelsViewModel.visibleSections.contains(selectedSection)
          ? selectedSection
          : .personalized
      },
      set: { section in
        guard channelsViewModel.visibleSections.contains(section) else { return }
        selectedSection = section
      }
    )
  }
}
