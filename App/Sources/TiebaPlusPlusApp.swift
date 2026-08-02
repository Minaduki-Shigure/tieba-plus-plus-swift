import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  private let service:
    any BrowseService & SearchService & UserProfileService & ForumInformationService =
      TiebaCoreBrowseService()
  private let historyRepository: any BrowsingHistoryRepository = FileBrowsingHistoryStore.live()
  private let favoritesRepository: any LocalFavoritesRepository = FileLocalFavoritesStore.live()

  var body: some Scene {
    WindowGroup {
      RootView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository
      )
    }
  }
}
