import ComposableArchitecture
import Foundation
import Shared
import SubscribeDomain

@Reducer
public struct SubscriptionsFeature {
    public enum Tab: Int, CaseIterable, Sendable {
        case active, paused

        var analyticsID: AnalyticsListID {
            self == .active ? .subscribedNewsletters : .pausedNewsletters
        }
    }

    public enum Change: Equatable, Sendable {
        case pause, resume

        var message: String {
            self == .pause ? "구독이 중지되었습니다." : "구독이 재개되었습니다."
        }
    }

    public struct ListState: Equatable, Sendable {
        var newsletters: [SubscribeNewsletter] = []
        var hasLoaded = false
        var isLoading = false
        var error: AppError?
        var context: AnalyticsListContext
        var request: AnalyticsListContext?
        var failedContext: AnalyticsListContext?

        init(tab: Tab) {
            context = .init(tab.analyticsID)
        }
    }

    public enum Operation: Equatable, Sendable {
        case load(Tab)
        case change(Change, SubscribeNewsletter)
    }

    @ObservableState
    public struct State: Equatable {
        var selectedTab: Tab = .active
        var active = ListState(tab: .active)
        var paused = ListState(tab: .paused)
        var isGuest = true
        var isVisible = false
        var pendingChanges: [Int: Change] = [:]
        var confirmation: SubscribeNewsletter?
        var toast: Change?
        var currentError: AppError?
        var failedOperation: Operation?
        var lastRefreshTime: Date?

        public init(isGuest: Bool = true) {
            self.isGuest = isGuest
        }

        subscript(tab: Tab) -> ListState {
            get { tab == .active ? active : paused }
            set {
                if tab == .active { active = newValue }
                else { paused = newValue }
            }
        }

        var newsletters: [SubscribeNewsletter] { self[selectedTab].newsletters }
        var isInitialLoading: Bool { !isGuest && !self[selectedTab].hasLoaded }
        var analyticsList: AnalyticsListContext { self[selectedTab].context }
        var analyticsStateList: AnalyticsListContext {
            let list = self[selectedTab]
            return list.error == .serverError ? list.failedContext ?? list.context : list.context
        }
        var analyticsState: AnalyticsContentState? {
            if isGuest { return .guest }
            let list = self[selectedTab]
            if list.error == .serverError { return .failed }
            guard list.hasLoaded, !list.isLoading else { return nil }
            if !list.newsletters.isEmpty { return .ready }
            return selectedTab == .active ? .noSubscriptions : .noResults
        }
    }

    public enum Action: Sendable {
        case task(isGuest: Bool)
        case disappeared
        case tabSelected(Tab)
        case refreshRequested
        case retryTapped
        case errorDismissed
        case pauseTapped(SubscribeNewsletter)
        case pauseConfirmed
        case confirmationDismissed
        case resumeTapped(SubscribeNewsletter)
        case toastDismissed
        case newsletterSelected(SubscribeNewsletter)
        case listResponse(Tab, AnalyticsListContext, Result<[SubscribeNewsletter], AppError>)
        case listCancelled(Tab, AnalyticsListContext)
        case changeResponse(Change, SubscribeNewsletter, Result<Void, AppError>)
        case changeCancelled(Int)
    }

    private enum CancelID: Hashable {
        case list(Tab)
        case change(Int)
        case toast
    }

    @Dependency(\.subscriptionsClient) private var subscriptions
    @Dependency(\.subscriptionsAnalytics) private var analytics
    @Dependency(\.uuid) private var uuid
    @Dependency(\.date.now) private var now
    @Dependency(\.continuousClock) private var clock

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .task(isGuest):
                let cancellation = cancelWork(state)
                state.isGuest = isGuest
                state.isVisible = true
                state.pendingChanges = [:]
                state.confirmation = nil
                state.toast = nil
                state.currentError = nil
                state.failedOperation = nil
                state.lastRefreshTime = nil
                for tab in Tab.allCases {
                    state[tab].newsletters = []
                    state[tab].hasLoaded = false
                    state[tab].isLoading = false
                    state[tab].error = nil
                    state[tab].request = nil
                    state[tab].failedContext = nil
                    state[tab].context = .init(tab.analyticsID, id: uuid())
                }
                guard !isGuest else { return cancellation }
                return .concatenate(cancellation, .merge(load(&state, tab: .active), load(&state, tab: .paused)))

            case .disappeared:
                let cancellation = cancelWork(state)
                state.isVisible = false
                state.pendingChanges = [:]
                state.confirmation = nil
                state.toast = nil
                for tab in Tab.allCases {
                    state[tab].isLoading = false
                    state[tab].request = nil
                }
                return cancellation

            case let .tabSelected(tab):
                guard state.selectedTab != tab else { return .none }
                state.selectedTab = tab
                return load(&state, tab: tab)

            case .refreshRequested:
                guard state.lastRefreshTime.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return .none }
                state.lastRefreshTime = now
                return load(&state, tab: state.selectedTab)

            case .retryTapped:
                let operation = state.failedOperation ?? .load(state.selectedTab)
                state.currentError = nil
                state.failedOperation = nil
                switch operation {
                case let .load(tab): return load(&state, tab: tab)
                case let .change(change, newsletter): return changeSubscription(&state, change: change, newsletter: newsletter)
                }

            case .errorDismissed:
                // The popup dismisses before invoking retry; retain the failed operation.
                state.currentError = nil
                return .none

            case let .pauseTapped(newsletter):
                guard state.isVisible, !state.isGuest, let id = newsletter.id, id > 0,
                      state.pendingChanges[id] == nil else { return .none }
                state.confirmation = newsletter
                return .none

            case .pauseConfirmed:
                guard let newsletter = state.confirmation else { return .none }
                state.confirmation = nil
                return changeSubscription(&state, change: .pause, newsletter: newsletter)

            case .confirmationDismissed:
                state.confirmation = nil
                return .none

            case let .resumeTapped(newsletter):
                return changeSubscription(&state, change: .resume, newsletter: newsletter)

            case .toastDismissed:
                state.toast = nil
                return .cancel(id: CancelID.toast)

            case let .newsletterSelected(newsletter):
                guard let id = newsletter.id, id > 0 else { return .none }
                let list = state.analyticsList
                return .run { [analytics] _ in
                    await analytics.record(.contentSelected(.newsletter(.init(id: String(id), name: newsletter.brandName)), list: list), from: .subscriptions)
                }

            case let .listResponse(tab, context, result):
                // Reuse the existing analytics request context; no separate response IDs.
                guard state.isVisible, !state.isGuest, state[tab].request == context else { return .none }
                state[tab].isLoading = false
                state[tab].request = nil
                switch result {
                case let .success(newsletters):
                    state[tab].newsletters = newsletters
                    state[tab].hasLoaded = true
                    state[tab].context = context
                    state[tab].failedContext = nil
                    state[tab].error = nil
                    if state.failedOperation == .load(tab) {
                        state.failedOperation = nil
                        state.currentError = nil
                    }
                case let .failure(error):
                    state[tab].error = error
                    state[tab].failedContext = context
                    if error != .silent {
                        state.currentError = error
                        state.failedOperation = .load(tab)
                    }
                }
                return .none

            case let .listCancelled(tab, context):
                guard state[tab].request == context else { return .none }
                state[tab].isLoading = false
                state[tab].request = nil
                return .none

            case let .changeResponse(change, newsletter, result):
                guard state.isVisible, !state.isGuest, let id = newsletter.id,
                      state.pendingChanges[id] == change else { return .none }
                state.pendingChanges[id] = nil
                switch result {
                case .success:
                    state.active.newsletters.removeAll { $0.id == id }
                    state.paused.newsletters.removeAll { $0.id == id }
                    state[change == .pause ? .paused : .active].newsletters.insert(newsletter, at: 0)
                    state.toast = change
                    if state.failedOperation == .change(change, newsletter) {
                        state.failedOperation = nil
                        state.currentError = nil
                    }
                    return .merge(
                        load(&state, tab: .active), load(&state, tab: .paused),
                        .run { [clock] send in
                            try await clock.sleep(for: .seconds(1))
                            await send(.toastDismissed)
                        }.cancellable(id: CancelID.toast, cancelInFlight: true)
                    )
                case let .failure(error):
                    if error != .silent {
                        state.currentError = error
                        state.failedOperation = .change(change, newsletter)
                    }
                    return .none
                }

            case let .changeCancelled(id):
                state.pendingChanges[id] = nil
                return .none
            }
        }
    }

    private func load(_ state: inout State, tab: Tab) -> Effect<Action> {
        guard state.isVisible, !state.isGuest else { return .none }
        let context = AnalyticsListContext(tab.analyticsID, id: uuid())
        state[tab].request = context
        state[tab].isLoading = true
        state[tab].error = nil
        return .run { [subscriptions, analytics] send in
            do {
                let newsletters = try await (tab == .active ? subscriptions.fetchActive() : subscriptions.fetchPaused())
                try Task.checkCancellation()
                await send(.listResponse(tab, context, .success(newsletters)))
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isCancellation(error) {
                    await send(.listCancelled(tab, context))
                    return
                }
                let failure = Self.mapError(error, operation: "loadSubscriptions")
                await analytics.record(.operationFailed(.list(context), category: .init(error: error)), from: .subscriptions)
                await send(.listResponse(tab, context, .failure(failure)))
            }
        }.cancellable(id: CancelID.list(tab), cancelInFlight: true)
    }

    private func changeSubscription(_ state: inout State, change: Change, newsletter: SubscribeNewsletter) -> Effect<Action> {
        guard state.isVisible, !state.isGuest, let id = newsletter.id, id > 0,
              state.pendingChanges[id] == nil else { return .none }
        state.pendingChanges[id] = change
        return .run { [subscriptions] send in
            do {
                if change == .pause { try await subscriptions.pause(String(id)) }
                else { try await subscriptions.resume(String(id)) }
                try Task.checkCancellation()
                await send(.changeResponse(change, newsletter, .success(())))
            } catch {
                guard !Task.isCancelled else { return }
                if Self.isCancellation(error) {
                    await send(.changeCancelled(id))
                    return
                }
                await send(.changeResponse(change, newsletter, .failure(Self.mapError(error, operation: change == .pause ? "pause" : "resume"))))
            }
        }.cancellable(id: CancelID.change(id), cancelInFlight: true)
    }

    private func cancelWork(_ state: State) -> Effect<Action> {
        .merge(
            [.cancel(id: CancelID.list(.active)), .cancel(id: CancelID.list(.paused)), .cancel(id: CancelID.toast)]
            + state.pendingChanges.keys.map { .cancel(id: CancelID.change($0)) }
        )
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func mapError(_ error: any Error, operation: String) -> AppError {
        let mapped: AppError
        if let error = error as? AppError { mapped = error }
        else if let error = error as? SubscribeError { mapped = .userMessage(error.localizedDescription) }
        else if let error = error as? any AppErrorConvertible { mapped = error.toAppError() }
        else { mapped = AppErrorMapperRegistry.map(error) ?? .userMessage("일시적인 오류가 발생했습니다") }
        if mapped != .silent {
            ErrorLoggerRegistry.shared?.logError(.init(underlyingError: error, feature: "subscribe", operation: operation))
        }
        return mapped
    }
}
