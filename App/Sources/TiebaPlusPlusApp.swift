import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  @AppStorage(AppPreferenceKey.appearance)
  private var appearance = AppAppearance.system.rawValue
  @AppStorage(AppPreferenceKey.contentMediaLoadPolicy)
  private var contentMediaLoadPolicy = ContentMediaLoadPolicy.automatic.rawValue
  private let service:
    any BrowseService & SearchService & ForumPostSearchService & HotTopicService & HotThreadService
      & UserProfileService & ForumInformationService & SearchSuggestionService
  private let contentFilterRepository: any ContentFilterRepository
  private let historyRepository: any BrowsingHistoryRepository = FileBrowsingHistoryStore.live()
  private let favoritesRepository: any LocalFavoritesRepository = FileLocalFavoritesStore.live()
  private let searchHistoryRepository: any ForumSearchHistoryRepository =
    FileForumSearchHistoryStore.live()
  private let globalSearchHistoryRepository: any GlobalSearchHistoryRepository =
    FileGlobalSearchHistoryStore.live()
  private let accountVault: any AccountVault = KeychainAccountVault()
  private let accountService: any AccountService = TiebaCoreAccountService()

  init() {
    let contentFilterRepository = FileContentFilterStore.live()
    self.contentFilterRepository = contentFilterRepository
    self.service = TiebaCoreBrowseService(
      contentFilterRepository: contentFilterRepository
    )
  }

  var body: some Scene {
    WindowGroup {
      RootView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        globalSearchHistoryRepository: globalSearchHistoryRepository,
        accountVault: accountVault,
        accountService: accountService
      )
      .environment(\.contentFilterRepository, contentFilterRepository)
      .environment(
        \.contentMediaLoadPolicy,
        ContentMediaLoadPolicy.resolved(contentMediaLoadPolicy)
      )
      .preferredColorScheme(AppAppearance.resolved(appearance).colorScheme)
    }
  }
}
