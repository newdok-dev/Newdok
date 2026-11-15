//
//  SubscriptionsView.swift
//  Newdok
//
//  Created by 권민재 on 3/3/25.
//
import SwiftUI
import DesignSystem
import SubscribeDomain
import PopupView
import Shared
import ComposableArchitecture

public struct SubscriptionsView: View {
    private let store: StoreOf<SubscriptionsFeature>

    private let onSearch: (() -> Void)?
    private let onLogin: () -> Void
    private let onBrandTap: (String, AnalyticsListContext) -> Void

    public init(
        store: StoreOf<SubscriptionsFeature>,
        onSearch: (() -> Void)?,
        onLogin: @escaping () -> Void,
        onBrandTap: @escaping (String, AnalyticsListContext) -> Void
    ) {
        self.store = store
        self.onSearch = onSearch
        self.onLogin = onLogin
        self.onBrandTap = onBrandTap
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView

            CustomSegmentedSlider(selectedIndex: Binding(
                get: { store.selectedTab.rawValue },
                set: { if let tab = SubscriptionsFeature.Tab(rawValue: $0) { store.send(.tabSelected(tab)) } }
            ), titles: ["구독 중", "구독 중지"])
                .padding(.top, 8)
                .padding(.bottom, 18)
                .padding(.horizontal, 20)

            contentSection
                .background(Color.bgSystem)
        }
        .analyticsScreen(.subscriptions, from: .subscriptions)
        .analyticsContentState(store.analyticsState, list: store.analyticsStateList)
        .task(id: AppState.shared.authState) {
            await store.send(.task(isGuest: AppState.shared.authState == .guest)).finish()
        }
        .onDisappear { store.send(.disappeared) }
        .popup(item: Binding(
            get: { store.confirmation },
            set: { if $0 == nil { store.send(.confirmationDismissed) } }
        )) { selected in
            UnsubscribePopupView(
                brandName: selected.brandName,
                onCancel: { store.send(.confirmationDismissed) },
                onConfirm: { store.send(.pauseConfirmed) }
            )
        } customize: {
            $0.type(.default)
                .position(.center)
                .animation(.easeInOut)
                .backgroundColor(Color.black.opacity(0.3))
                .closeOnTap(false)
                .closeOnTapOutside(false)
                .allowTapThroughBG(false)
        }
        .popup(item: Binding(
            get: { store.toast },
            set: { if $0 == nil { store.send(.toastDismissed) } }
        )) { change in
            ToastView(message: change.message).padding(.bottom, 106)
        } customize: {
            $0.type(.toast).position(.bottom).animation(.easeInOut).closeOnTapOutside(false)
        }
        .serverErrorPopup(
            error: Binding(get: { store.currentError }, set: { if $0 == nil { store.send(.errorDismissed) } }),
            onRetry: { store.send(.retryTapped) }
        )
    }

    // MARK: - Content
    private var contentSection: some View {
        PullToRefreshView(
            content: {
                contentView
            },
            animationView: {
                LoadingView()
            },
            onRefresh: {
                await store.send(.refreshRequested).finish()
            }
        )
        .background(Color.bgSystem)
    }

    @ViewBuilder
    private var contentView: some View {
        if store.isGuest {
            EmptySubscriptionsView(isSubscribedTab: store.selectedTab == .active, isGuest: true, onLogin: { onLogin() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isInitialLoading {
            EmptyView()
        } else if store.newsletters.isEmpty {
            EmptySubscriptionsView(isSubscribedTab: store.selectedTab == .active, isGuest: false, onLogin: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            subscriptionListView
        }
    }

    private var subscriptionListView: some View {
        let subscriptions = store.newsletters
        return LazyVStack(alignment: .leading, spacing: 0) {
            listHeaderView()
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

            ForEach(Array(subscriptions.enumerated()), id: \.element.id) { index, newsletter in
                SubscriptionRow(
                    newsletter: newsletter,
                    isSubscribed: store.selectedTab == .active,
                    isPerformingAction: newsletter.id.map { store.pendingChanges[$0] != nil } ?? false,
                    onNavigate: {
                        guard let id = newsletter.id, id > 0 else { return }
                        let list = store.analyticsList
                        store.send(.newsletterSelected(newsletter))
                        onBrandTap(String(id), list)
                    }
                ) {
                    if store.selectedTab == .active {
                        store.send(.pauseTapped(newsletter))
                    } else {
                        store.send(.resumeTapped(newsletter))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, index == subscriptions.count - 1 ? 28 : 12)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.3), value: subscriptions.count)
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Text("내 구독")
                .font(.hanSansNeo(18, .bold))
                .foregroundStyle(Color.captionHeavy)
            Spacer()
            if let onSearch {
                Button {
                    onSearch()
                } label: {
                    Image(asset: DesignSystemAsset.lineSearch)
                        .padding(.trailing, 12)
                }
                .accessibilityLabel("검색")
                .accessibilityIdentifier("subscribe_search_button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .background(Color.white)
    }

    private func listHeaderView() -> some View {
        let count = store.newsletters.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(store.selectedTab == .active
                 ? "총 \(count)개의 뉴스레터를 구독중이에요."
                 : "\(count)개의 뉴스레터를 구독 중지했어요.")
                .font(.hanSansNeo(16, .bold))
                .padding(.top, 30)
            Text(store.selectedTab == .active
                 ? "구독신청 후 첫 아티클을 수신받으면 내 구독에 추가돼요."
                 : "구독을 재개하면 다시 아티클을 받아볼 수 있어요")
                .font(.hanSansNeo(14, .medium))
                .foregroundStyle(Color.captionNeutral)
        }
    }
}
