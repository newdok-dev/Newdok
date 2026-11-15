import Shared
import SwiftUI
import NetworkKit
import SubscribeInterface
import SubscribeData
import ComposableArchitecture

public struct SubscribeBuilder: SubscribeBuildable {
    private let subscriptions: SubscriptionsClient
    private let analytics: AnalyticsClient

    public init(networkProvider: NetworkProviding, analytics: AnalyticsClient) {
        let repository = SubscribeNewsletterRepositoryImpl(network: networkProvider.makeService())
        let active = FetchActiveSubscriptionUseCaseImpl(repository: repository)
        let paused = FetchPausedSubscriptionUseCaseImpl(repository: repository)
        let pause = PauseSubscriptionUseCaseImpl(repository: repository)
        let resume = ResumeSubscriptionUseCaseImpl(repository: repository)

        self.subscriptions = SubscriptionsClient(
            fetchActive: { try await active.execute() },
            fetchPaused: { try await paused.execute() },
            pause: { try await pause.execute(newsletterId: $0) },
            resume: { try await resume.execute(newsletterId: $0) }
        )
        self.analytics = analytics
    }

    public func makeSubscribeView(
        onSearch: (() -> Void)?,
        onLogin: @escaping () -> Void,
        onBrandTap: @escaping (String, AnalyticsListContext) -> Void
    ) -> AnyView {
        let store = Store(initialState: SubscriptionsFeature.State(isGuest: AppState.shared.authState == .guest)) {
            SubscriptionsFeature()
        } withDependencies: {
            $0.subscriptionsClient = subscriptions
            $0.subscriptionsAnalytics = analytics
        }
        return AnyView(
            SubscriptionsRootView(
                store: store,
                onSearch: onSearch,
                onLogin: onLogin,
                onBrandTap: onBrandTap
            )
        )
    }
}

// Store lifetime follows the tab's SwiftUI identity, which changes on account changes.
private struct SubscriptionsRootView: View {
    @State var store: StoreOf<SubscriptionsFeature>
    let onSearch: (() -> Void)?
    let onLogin: () -> Void
    let onBrandTap: (String, AnalyticsListContext) -> Void

    var body: some View {
        SubscriptionsView(
            store: store,
            onSearch: onSearch,
            onLogin: onLogin,
            onBrandTap: onBrandTap
        )
    }
}
