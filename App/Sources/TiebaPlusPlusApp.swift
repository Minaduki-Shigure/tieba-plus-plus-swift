import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  private let service: any BrowseService & SearchService = TiebaCoreBrowseService()
  private let historyRepository: any BrowsingHistoryRepository = FileBrowsingHistoryStore.live()

  var body: some Scene {
    WindowGroup {
      RootView(service: service, historyRepository: historyRepository)
    }
  }
}
