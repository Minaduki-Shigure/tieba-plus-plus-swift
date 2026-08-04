import Foundation
import SwiftUI

@main
struct TiebaPlusPlusApp: App {
  @StateObject private var externalWebPresentation = ExternalWebPresentationModel()
  @StateObject private var contentMediaNetworkMonitor = ContentMediaNetworkMonitor()
  @AppStorage(AppPreferenceKey.appearance)
  private var appearance = AppAppearance.system.rawValue
  @AppStorage(AppPreferenceKey.accentColor)
  private var accentColor = AppAccentColor.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.textSizeAdjustment)
  private var textSizeAdjustment = AppTextSizeAdjustment.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.contentMediaLoadPolicy)
  private var contentMediaLoadPolicy = ContentMediaLoadPolicy.automatic.rawValue
  @AppStorage(AppPreferenceKey.contentImagePreviewQuality)
  private var contentImagePreviewQuality = ContentImagePreviewQuality.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.hidesThreadListMedia)
  private var hidesThreadListMedia = false
  @AppStorage(AppPreferenceKey.darkensContentThumbnailsInDarkMode)
  private var darkensContentThumbnailsInDarkMode = true
  @AppStorage(AppPreferenceKey.showsBothUsernameAndNickname)
  private var showsBothUsernameAndNickname = false
  @AppStorage(AppPreferenceKey.externalWebOpenMode)
  private var externalWebOpenMode = ExternalWebOpenMode.defaultValue.rawValue
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
  private let startDestination: AppStartDestination

  init() {
    startDestination = AppStartDestination.resolved(
      UserDefaults.standard.string(forKey: AppPreferenceKey.homeStartDestination) ?? ""
    )
    let contentFilterRepository = FileContentFilterStore.live()
    self.contentFilterRepository = contentFilterRepository
    self.service = TiebaCoreBrowseService(
      contentFilterRepository: contentFilterRepository
    )
  }

  var body: some Scene {
    let resolvedAccentColor = AppAccentColor.resolved(accentColor)
    let resolvedContentMediaLoadPolicy = ContentMediaLoadPolicy.resolved(contentMediaLoadPolicy)
    let contentMediaLoadBehavior = ContentMediaLoadBehavior.resolved(
      policy: resolvedContentMediaLoadPolicy,
      networkSnapshot: contentMediaNetworkMonitor.snapshot
    )

    WindowGroup {
      RootView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        globalSearchHistoryRepository: globalSearchHistoryRepository,
        accountVault: accountVault,
        accountService: accountService,
        startDestination: startDestination
      )
      .appTextSizeAdjustment(AppTextSizeAdjustment.resolved(textSizeAdjustment))
      .environment(\.appAccentColor, resolvedAccentColor)
      .environment(\.contentFilterRepository, contentFilterRepository)
      .environment(
        \.contentMediaLoadPolicy,
        resolvedContentMediaLoadPolicy
      )
      .environment(\.contentMediaLoadBehavior, contentMediaLoadBehavior)
      .environment(
        \.contentImagePreviewQuality,
        ContentImagePreviewQuality.resolved(contentImagePreviewQuality)
      )
      .environment(\.hidesThreadListMedia, hidesThreadListMedia)
      .environment(
        \.darkensContentThumbnailsInDarkMode,
        darkensContentThumbnailsInDarkMode
      )
      .environment(
        \.showsBothUsernameAndNickname,
        showsBothUsernameAndNickname
      )
      .environment(
        \.externalWebOpenMode,
        ExternalWebOpenMode.resolved(externalWebOpenMode)
      )
      .environment(
        \.openExternalWeb,
        ExternalWebOpenAction { url in
          externalWebPresentation.requestPresentation(for: url)
        }
      )
      .background {
        ExternalWebBrowserPresenter(page: externalWebPresentation.page) { pageID in
          externalWebPresentation.dismiss(id: pageID)
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .tint(resolvedAccentColor.color)
      .preferredColorScheme(AppAppearance.resolved(appearance).colorScheme)
    }
  }
}
