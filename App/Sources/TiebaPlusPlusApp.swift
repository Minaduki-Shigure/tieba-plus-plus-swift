import Foundation
import SwiftUI
import TiebaCore

@main
@MainActor
struct TiebaPlusPlusApp: App {
  @StateObject private var externalWebPresentation = ExternalWebPresentationModel()
  @StateObject private var contentMediaNetworkMonitor = ContentMediaNetworkMonitor()
  @StateObject private var mediaPlaybackCoordinator: MediaPlaybackCoordinator
  @StateObject private var voicePlaybackController: VoicePlaybackController
  @StateObject private var videoPlaybackController: VideoPlaybackController
  @StateObject private var followedForumsViewModel: FollowedForumsViewModel
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
  @AppStorage(AppPreferenceKey.hidesReplyEntryPoints)
  private var hidesReplyEntryPoints = AppPreferenceDefaults.hidesReplyEntryPoints
  @AppStorage(AppPreferenceKey.darkensContentThumbnailsInDarkMode)
  private var darkensContentThumbnailsInDarkMode = true
  @AppStorage(AppPreferenceKey.showsBothUsernameAndNickname)
  private var showsBothUsernameAndNickname = false
  @AppStorage(AppPreferenceKey.externalWebOpenMode)
  private var externalWebOpenMode = ExternalWebOpenMode.defaultValue.rawValue
  private let service:
    any BrowseService & SearchService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
      & SearchSuggestionService
  private let contentFilterRepository: any ContentFilterRepository
  private let historyRepository: any BrowsingHistoryRepository = FileBrowsingHistoryStore.live()
  private let favoritesRepository: any LocalFavoritesRepository = FileLocalFavoritesStore.live()
  private let searchHistoryRepository: any ForumSearchHistoryRepository =
    FileForumSearchHistoryStore.live()
  private let globalSearchHistoryRepository: any GlobalSearchHistoryRepository =
    FileGlobalSearchHistoryStore.live()
  private let accountVault: any AccountVault
  private let accountService: any AccountService
  private let contentAgreementStore: ContentAgreementStore
  private let threadCloudFavoriteStore: ThreadCloudFavoriteStore
  private let textReplySubmissionStore: TextReplySubmissionStore
  private let startDestination: AppStartDestination

  init() {
    let contentFilterRepository = FileContentFilterStore.live()
    let clientConfiguration = TiebaClientConfiguration(
      personalizedCUID: PersonalizedRecommendationIdentity.current()
    )
    let accountVault: any AccountVault = KeychainAccountVault()
    let accountService: any AccountService = TiebaCoreAccountService(
      client: TiebaAuthenticatedClient(configuration: clientConfiguration),
      contentFilterRepository: contentFilterRepository
    )
    self.accountVault = accountVault
    self.accountService = accountService
    _followedForumsViewModel = StateObject(
      wrappedValue: FollowedForumsViewModel(service: accountService, vault: accountVault)
    )
    let accountAccess = AccountAccess(vault: accountVault, service: accountService)
    self.contentAgreementStore = ContentAgreementStore(access: accountAccess)
    self.threadCloudFavoriteStore = ThreadCloudFavoriteStore(access: accountAccess)
    self.textReplySubmissionStore = TextReplySubmissionStore(access: accountAccess)
    let mediaPlaybackCoordinator = MediaPlaybackCoordinator()
    _mediaPlaybackCoordinator = StateObject(wrappedValue: mediaPlaybackCoordinator)
    _voicePlaybackController = StateObject(
      wrappedValue: VoicePlaybackController(coordinator: mediaPlaybackCoordinator)
    )
    _videoPlaybackController = StateObject(
      wrappedValue: VideoPlaybackController(coordinator: mediaPlaybackCoordinator)
    )
    startDestination = AppStartDestination.resolved(
      UserDefaults.standard.string(forKey: AppPreferenceKey.homeStartDestination) ?? ""
    )
    self.contentFilterRepository = contentFilterRepository
    let browseClient = TiebaClient(configuration: clientConfiguration)
    self.service = TiebaCoreBrowseService(
      client: browseClient,
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
      .environment(
        \.accountAccess,
        AccountAccess(vault: accountVault, service: accountService)
      )
      .environment(\.contentAgreementStore, contentAgreementStore)
      .environment(\.threadCloudFavoriteStore, threadCloudFavoriteStore)
      .environment(\.textReplySubmissionStore, textReplySubmissionStore)
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
      .environment(\.hidesReplyEntryPoints, hidesReplyEntryPoints)
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
      .environmentObject(mediaPlaybackCoordinator)
      .environmentObject(voicePlaybackController)
      .environmentObject(videoPlaybackController)
      .environmentObject(followedForumsViewModel)
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
