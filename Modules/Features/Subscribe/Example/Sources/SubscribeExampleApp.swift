import SwiftUI
import Shared
import DesignSystem
import Subscribe
import SubscribeDomain
import SubscribeTesting
import ComposableArchitecture

@main
struct SubscribeExampleApp: App {
    private let store: StoreOf<SubscriptionsFeature>

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SubscriptionsView(
                    store: store,
                    onSearch: {},
                    onLogin: {},
                    onBrandTap: { _, _ in }
                )
            }
            .environment(AppState.shared)
            .environment(ToastCenter.shared)
        }
    }

    init() {
        let active = MockFetchActiveSubscriptionUseCase()
        active.result = .success(SampleSubscriptions.mixed)

        let paused = MockFetchPausedSubscriptionUseCase()
        paused.result = .success(SampleSubscriptions.paused)

        let pause = MockPauseSubscriptionUseCase()
        let resume = MockResumeSubscriptionUseCase()

        store = Store(initialState: SubscriptionsFeature.State()) {
            SubscriptionsFeature()
        } withDependencies: {
            $0.subscriptionsClient = SubscriptionsClient(
                fetchActive: { try await active.execute() },
                fetchPaused: { try await paused.execute() },
                pause: { try await pause.execute(newsletterId: $0) },
                resume: { try await resume.execute(newsletterId: $0) }
            )
            $0.subscriptionsAnalytics = .disabled
        }
    }
}
