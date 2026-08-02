import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  private let service:
    any BrowseService & SearchService & HotTopicService & UserProfileService
      & ForumInformationService =
      TiebaCoreBrowseService()
  private let historyRepository: any BrowsingHistoryRepository = FileBrowsingHistoryStore.live()
  private let favoritesRepository: any LocalFavoritesRepository = FileLocalFavoritesStore.live()
  private let accountVault: any AccountVault = KeychainAccountVault()
  private let accountService: any AccountService = TiebaCoreAccountService()

  var body: some Scene {
    WindowGroup {
      RootView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        accountVault: accountVault,
        accountService: accountService
      )
    }
  }
}
