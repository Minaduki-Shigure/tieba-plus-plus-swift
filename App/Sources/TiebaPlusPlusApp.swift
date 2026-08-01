import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  private let browseService: any BrowseService = TiebaCoreBrowseService()

  var body: some Scene {
    WindowGroup {
      RootView(service: browseService)
    }
  }
}
