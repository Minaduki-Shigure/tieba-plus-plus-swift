import Foundation
import SwiftUI
import TiebaCore

@main
@MainActor
struct TiebaPlusPlusApp: App {
  @StateObject private var externalWebPresentation: ExternalWebPresentationModel
  @StateObject private var contentReportCoordinator: ContentReportCoordinator
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
  private let accountSessionLookup: any AccountSessionLookup
  private let accountService: any AccountService
  private let personalizedFeedbackService: any PersonalizedFeedbackService
  private let contentAgreementStore: ContentAgreementStore
  private let threadCloudFavoriteStore: ThreadCloudFavoriteStore
  private let textReplySubmissionStore: TextReplySubmissionStore
  private let newThreadSubmissionStore: NewThreadSubmissionStore
  private let composerImageAttachmentStore: ComposerImageAttachmentStore
  private let startDestination: AppStartDestination

  init() {
    let contentFilterRepository = FileContentFilterStore.live()
    let clientConfiguration = TiebaClientConfiguration(
      personalizedCUID: PersonalizedRecommendationIdentity.current()
    )
    let accountVault = KeychainAccountVault()
    let authenticatedClient = TiebaAuthenticatedClient(configuration: clientConfiguration)
    let accountService: any AccountService = TiebaCoreAccountService(
      client: authenticatedClient,
      contentFilterRepository: contentFilterRepository
    )
    self.accountVault = accountVault
    self.accountSessionLookup = accountVault
    self.accountService = accountService
    self.personalizedFeedbackService = TiebaCorePersonalizedFeedbackService(
      client: authenticatedClient
    )
    _followedForumsViewModel = StateObject(
      wrappedValue: FollowedForumsViewModel(
        service: accountService,
        vault: accountVault,
        pinRepository: FileFollowedForumPinsStore.live()
      )
    )
    let accountAccess = AccountAccess(vault: accountVault, service: accountService)
    let composerImageAttachmentStore = ComposerImageAttachmentStore.live()
    let textReplyDraftStore = FileTextReplyDraftStore.live()
    let newThreadDraftStore = FileNewThreadDraftStore.live()
    let composerImageUploadLedger = ComposerImageUploadLedger.live()
    let composerImageDeletionCoordinator = ComposerImageAttachmentDeletionCoordinator.live(
      newThreadDrafts: newThreadDraftStore,
      replyDrafts: textReplyDraftStore,
      ledger: composerImageUploadLedger
    )
    let composerImageSubmissionPipeline = ComposerImageSubmissionPipeline(
      access: accountAccess,
      attachmentStore: composerImageAttachmentStore,
      ledger: composerImageUploadLedger,
      attachmentDeletionScheduler: composerImageDeletionCoordinator
    )
    Task.detached(priority: .utility) {
      _ = try? await composerImageDeletionCoordinator.performMaintenance()
      _ = ComposerImageTemporaryDirectoryCleaner().cleanup()
    }
    self.composerImageAttachmentStore = composerImageAttachmentStore
    self.contentAgreementStore = ContentAgreementStore(access: accountAccess)
    self.threadCloudFavoriteStore = ThreadCloudFavoriteStore(access: accountAccess)
    self.textReplySubmissionStore = TextReplySubmissionStore(
      access: accountAccess,
      drafts: textReplyDraftStore,
      imagePipeline: composerImageSubmissionPipeline,
      attachmentStore: composerImageAttachmentStore,
      attachmentDeletionScheduler: composerImageDeletionCoordinator
    )
    self.newThreadSubmissionStore = NewThreadSubmissionStore(
      access: accountAccess,
      drafts: newThreadDraftStore,
      imagePipeline: composerImageSubmissionPipeline,
      attachmentStore: composerImageAttachmentStore,
      attachmentDeletionScheduler: composerImageDeletionCoordinator
    )
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
    let browseService = TiebaCoreBrowseService(
      client: browseClient,
      authenticatedClient: authenticatedClient,
      contentFilterRepository: contentFilterRepository
    )
    self.service = browseService
    let externalWebPresentation = ExternalWebPresentationModel()
    _externalWebPresentation = StateObject(wrappedValue: externalWebPresentation)
    _contentReportCoordinator = StateObject(
      wrappedValue: ContentReportCoordinator(
        vault: accountVault,
        service: browseService,
        presentation: externalWebPresentation
      )
    )
  }

  var body: some Scene {
    let resolvedAccentColor = AppAccentColorSelection.resolved(accentColor).style
    let resolvedContentMediaLoadPolicy = ContentMediaLoadPolicy.resolved(contentMediaLoadPolicy)
    let contentMediaLoadBehavior = ContentMediaLoadBehavior.resolved(
      policy: resolvedContentMediaLoadPolicy,
      networkSnapshot: contentMediaNetworkMonitor.snapshot
    )

    WindowGroup {
      #if PERFORMANCE_HARNESS
        Group {
          if let scenario = ThreadScrollPerformanceScenario.requested {
            ThreadScrollPerformanceRootView(scenario: scenario)
          } else {
            standardRootView
          }
        }
        .environment(
          \.accountAccess,
          AccountAccess(vault: accountVault, service: accountService)
        )
        .environment(\.contentAgreementStore, contentAgreementStore)
        .environment(\.threadCloudFavoriteStore, threadCloudFavoriteStore)
        .environment(\.textReplySubmissionStore, textReplySubmissionStore)
        .environment(\.newThreadSubmissionStore, newThreadSubmissionStore)
        .environment(\.composerImageAttachmentStore, composerImageAttachmentStore)
        .environment(\.contentReportCoordinator, contentReportCoordinator)
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
        .contentReportPresentation(contentReportCoordinator)
        .tint(resolvedAccentColor.color)
        .preferredColorScheme(AppAppearance.resolved(appearance).colorScheme)
      #else
        RootView(
          service: service,
          historyRepository: historyRepository,
          favoritesRepository: favoritesRepository,
          searchHistoryRepository: searchHistoryRepository,
          globalSearchHistoryRepository: globalSearchHistoryRepository,
          accountVault: accountVault,
          accountSessionLookup: accountSessionLookup,
          accountService: accountService,
          personalizedFeedbackService: personalizedFeedbackService,
          startDestination: startDestination
        )
        .environment(
          \.accountAccess,
          AccountAccess(vault: accountVault, service: accountService)
        )
        .environment(\.contentAgreementStore, contentAgreementStore)
        .environment(\.threadCloudFavoriteStore, threadCloudFavoriteStore)
        .environment(\.textReplySubmissionStore, textReplySubmissionStore)
        .environment(\.newThreadSubmissionStore, newThreadSubmissionStore)
        .environment(\.composerImageAttachmentStore, composerImageAttachmentStore)
        .environment(\.contentReportCoordinator, contentReportCoordinator)
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
        .contentReportPresentation(contentReportCoordinator)
        .tint(resolvedAccentColor.color)
        .preferredColorScheme(AppAppearance.resolved(appearance).colorScheme)
      #endif
    }
  }

  #if PERFORMANCE_HARNESS
    private var standardRootView: some View {
      RootView(
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        globalSearchHistoryRepository: globalSearchHistoryRepository,
        accountVault: accountVault,
        accountSessionLookup: accountSessionLookup,
        accountService: accountService,
        personalizedFeedbackService: personalizedFeedbackService,
        startDestination: startDestination
      )
    }
  #endif
}
