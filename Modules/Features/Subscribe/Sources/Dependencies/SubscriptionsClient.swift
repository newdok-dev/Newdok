import ComposableArchitecture
import SubscribeDomain

@DependencyClient
public struct SubscriptionsClient: Sendable {
    public var fetchActive: @Sendable () async throws -> [SubscribeNewsletter]
    public var fetchPaused: @Sendable () async throws -> [SubscribeNewsletter]
    public var pause: @Sendable (_ newsletterID: String) async throws -> Void
    public var resume: @Sendable (_ newsletterID: String) async throws -> Void
}

extension SubscriptionsClient: TestDependencyKey {
    // The Builder supplies live UseCases; a missing test override reports an issue.
    public static let testValue = Self()
}

public extension DependencyValues {
    var subscriptionsClient: SubscriptionsClient {
        get { self[SubscriptionsClient.self] }
        set { self[SubscriptionsClient.self] = newValue }
    }
}
