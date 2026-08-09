import SwiftUI

enum ExploreSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case personalized
  case hot

  var id: Self { self }

  var title: String {
    switch self {
    case .personalized:
      "推荐"
    case .hot:
      "热门"
    }
  }
}

struct ExploreView: View {
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @State private var selectedSection: ExploreSection

  init(
    initialSection: ExploreSection = .personalized,
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _selectedSection = State(initialValue: initialSection)
  }

  var body: some View {
    TabView(selection: $selectedSection) {
      PersonalizedFeedView(
        service: service,
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
    .navigationTitle("发现")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      Picker("发现频道", selection: $selectedSection) {
        ForEach(ExploreSection.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }
}
