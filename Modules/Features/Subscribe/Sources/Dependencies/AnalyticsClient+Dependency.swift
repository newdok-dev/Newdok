import ComposableArchitecture
import Shared

private enum SubscriptionsAnalyticsKey: TestDependencyKey {
    static let testValue: AnalyticsClient = .disabled
}

public extension DependencyValues {
    var subscriptionsAnalytics: AnalyticsClient {
        get { self[SubscriptionsAnalyticsKey.self] }
        set { self[SubscriptionsAnalyticsKey.self] = newValue }
    }
}
