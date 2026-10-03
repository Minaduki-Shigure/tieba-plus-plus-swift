import SwiftUI

enum ExploreSection: String, CaseIterable, Hashable, Identifiable, Sendable {
  case concern
  case personalized
  case hot

  var id: Self { self }

  var title: String {
    switch self {
    case .concern:
      "关注"
    case .personalized:
      "推荐"
    case .hot:
      "热门"
    }
  }

  static func available(hasActiveAccount: Bool) -> [Self] {
    hasActiveAccount ? [.concern, .personalized, .hot] : [.personalized, .hot]
  }
}

struct ExploreView: View {
  let isActive: Bool
  let refreshRequestID: UInt64
  let service:
    any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let accountService: any AccountService
  let feedbackService: any PersonalizedFeedbackService
  let accountVault: any AccountVault
  let accountSessionLookup: any AccountSessionLookup

  @State private var selectedSection: ExploreSection
  @State private var isVisible = false
  @State private var channelRefreshRequests: [ExploreSection: UInt64] = [:]
  @StateObject private var channelsViewModel: ExploreChannelsViewModel

  init(
    initialSection: ExploreSection = .personalized,
    isActive: Bool = true,
    refreshRequestID: UInt64 = 0,
    service: any BrowseService & ForumPostSearchService & HotTopicService & HotThreadService
      & PersonalizedFeedService & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    accountService: any AccountService,
    feedbackService: any PersonalizedFeedbackService,
    accountVault: any AccountVault,
    accountSessionLookup: any AccountSessionLookup
  ) {
    self.isActive = isActive
    self.refreshRequestID = refreshRequestID
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.accountService = accountService
    self.feedbackService = feedbackService
    self.accountVault = accountVault
    self.accountSessionLookup = accountSessionLookup
    _selectedSection = State(initialValue: initialSection)
    _channelsViewModel = StateObject(
      wrappedValue: ExploreChannelsViewModel(vault: accountVault)
    )
  }

  var body: some View {
    Group {
      if channelsViewModel.hasResolvedInitialSession {
        TabView(selection: selectedSectionBinding) {
          ForEach(channelsViewModel.visibleSections) { section in
            channel(section).tag(section)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
      } else {
        // Resolve the initial page set before mounting the pager. Inserting an
        // authenticated page ahead of an appearing selection can cancel that
        // page's first load during UIKit's page-controller reconfiguration.
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .appPageSurface(.canvas)
    .navigationTitle("发现")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      if channelsViewModel.hasResolvedInitialSession {
        ExploreChannelSelector(
          sections: channelsViewModel.visibleSections,
          selection: selectedSectionBinding.wrappedValue
        ) { section in
          if section == selectedSectionBinding.wrappedValue {
            refreshCurrentChannel()
          } else {
            selectedSectionBinding.wrappedValue = section
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .appBarMaterialSurface()
      }
    }
    .onAppear {
      isVisible = true
      #if DEBUG
        ExploreRefreshLifecycleDiagnostics.active?.recordExplore(
          selection: selectedSection, sections: channelsViewModel.visibleSections,
          ready: channelsViewModel.hasResolvedInitialSession)
      #endif
      if isActive { channelsViewModel.reload() }
    }
    .onChange(of: refreshRequestID) { _ in refreshCurrentChannel() }
    .onChange(of: isActive) { active in
      if active {
        channelsViewModel.reload()
      } else {
        channelsViewModel.cancel()
      }
    }
    .onDisappear {
      isVisible = false
      channelsViewModel.cancel()
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      if isActive {
        channelsViewModel.reload()
      } else {
        channelsViewModel.cancel()
      }
    }
    .onChange(of: channelsViewModel.visibleSections) { sections in
      if !sections.contains(selectedSection) {
        selectedSection = .personalized
      }
      #if DEBUG
        ExploreRefreshLifecycleDiagnostics.active?.recordExplore(
          selection: selectedSection, sections: sections,
          ready: channelsViewModel.hasResolvedInitialSession)
      #endif
    }
  }

  @ViewBuilder
  private func channel(_ section: ExploreSection) -> some View {
    switch section {
    case .concern:
      ConcernFeedView(
        isActive: isActive && selectedSection == .concern,
        refreshRequestID: channelRefreshRequests[.concern, default: 0],
        browseService: service,
        accountService: accountService,
        vault: accountVault,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .personalized:
      PersonalizedFeedView(
        isActive: isActive && selectedSection == .personalized,
        refreshRequestID: channelRefreshRequests[.personalized, default: 0],
        service: service,
        accountService: accountService,
        feedbackService: feedbackService,
        vault: accountVault,
        accountSessionLookup: accountSessionLookup,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .hot:
      HotThreadListView(
        isActive: isActive && selectedSection == .hot,
        refreshRequestID: channelRefreshRequests[.hot, default: 0],
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        showsNavigationTitle: false
      )
    }
  }

  private func refreshCurrentChannel() {
    guard isVisible, isActive, channelsViewModel.hasResolvedInitialSession,
      channelsViewModel.visibleSections.contains(selectedSection)
    else { return }
    channelRefreshRequests[selectedSection, default: 0] &+= 1
  }

  private var selectedSectionBinding: Binding<ExploreSection> {
    Binding(
      get: {
        channelsViewModel.visibleSections.contains(selectedSection)
          ? selectedSection
          : .personalized
      },
      set: { section in
        guard channelsViewModel.visibleSections.contains(section) else { return }
        selectedSection = section
        #if DEBUG
          ExploreRefreshLifecycleDiagnostics.active?.recordExplore(
            selection: selectedSection, sections: channelsViewModel.visibleSections,
            ready: channelsViewModel.hasResolvedInitialSession)
        #endif
      }
    )
  }
}

/// Selection and reselection are distinct actions. A Picker's selection binding
/// only represents the selected value and cannot express a repeated selection.
private struct ExploreChannelSelector: View {
  let sections: [ExploreSection]
  let selection: ExploreSection
  let onSelect: (ExploreSection) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(sections) { section in
        Button {
          onSelect(section)
        } label: {
          Text(section.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background {
              if section == selection {
                RoundedRectangle(cornerRadius: 6)
                  .fill(Color(uiColor: .secondarySystemGroupedBackground))
                  .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("explore-channel-\(section.rawValue)")
        .accessibilityAddTraits(section == selection ? [.isSelected] : [])
        .accessibilityHint(section == selection ? "再次点击刷新当前频道" : "切换发现频道")
      }
    }
    .padding(2)
    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("发现频道")
  }
}
