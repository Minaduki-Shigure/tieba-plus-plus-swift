import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  private let service: any BrowseService & SearchService = TiebaCoreBrowseService()

  var body: some Scene {
    WindowGroup {
      RootView(service: service)
    }
  }
}
