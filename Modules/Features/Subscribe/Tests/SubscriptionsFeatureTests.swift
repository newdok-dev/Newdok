import ComposableArchitecture
import Foundation
import Testing
import Shared
import SubscribeDomain
@testable import Subscribe
@testable import SubscribeTesting

@Suite("SubscriptionsFeature")
@MainActor
struct SubscriptionsFeatureTests {
    private typealias Feature = SubscriptionsFeature
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func newsletter(_ id: Int = 1) -> SubscribeNewsletter {
        .init(id: id, brandName: "Newsletter \(id)", imageUrl: "", publicationCycle: "매일")
    }

    private func context(_ tab: Feature.Tab, _ id: Int) -> AnalyticsListContext {
        .init(tab.analyticsID, id: UUID(id))
    }

    private func readyState() -> Feature.State {
        var state = Feature.State()
        state.isGuest = false
        state.isVisible = true
        state.active.hasLoaded = true
        state.paused.hasLoaded = true
        return state
    }

    private func makeStore(
        state: Feature.State? = nil,
        active: any FetchActiveSubscriptionUseCase = MockFetchActiveSubscriptionUseCase(),
        paused: any FetchPausedSubscriptionUseCase = MockFetchPausedSubscriptionUseCase(),
        pause: any PauseSubscriptionUseCase = MockPauseSubscriptionUseCase(),
        resume: any ResumeSubscriptionUseCase = MockResumeSubscriptionUseCase(),
        clock: TestClock<Duration> = TestClock()
    ) -> TestStore<Feature.State, Feature.Action> {
        TestStore(initialState: state ?? readyState()) {
            Feature()
        } withDependencies: {
            $0.subscriptionsClient = SubscriptionsClient(
                fetchActive: { try await active.execute() },
                fetchPaused: { try await paused.execute() },
                pause: { try await pause.execute(newsletterId: $0) },
                resume: { try await resume.execute(newsletterId: $0) }
            )
            $0.uuid = .incrementing
            $0.date.now = referenceDate
            $0.continuousClock = clock
        }
    }

    @Test("초기 조회는 두 목록을 병렬로 읽고 준비된 탭부터 표시한다")
    func initialLoad() async {
        let active = ControlledSubscriptions()
        let paused = ControlledSubscriptions()
        let store = makeStore(state: Feature.State(), active: active, paused: paused)
        await store.send(.task(isGuest: false)) {
            $0.isGuest = false
            $0.isVisible = true
            $0.active.context = context(.active, 0)
            $0.paused.context = context(.paused, 1)
            $0.active.request = context(.active, 2)
            $0.paused.request = context(.paused, 3)
            $0.active.isLoading = true
            $0.paused.isLoading = true
        }
        await active.gate.waitForRequests(1)
        await paused.gate.waitForRequests(1)
        await active.gate.finish(0, with: .success([newsletter()]))
        await store.receive(\.listResponse) {
            $0.active.newsletters = [newsletter()]
            $0.active.context = context(.active, 2)
            $0.active.request = nil
            $0.active.isLoading = false
            $0.active.hasLoaded = true
        }
        #expect(store.state.analyticsState == .ready)
        #expect(!store.state.isInitialLoading)
        await paused.gate.finish(0, with: .success([]))
        await store.receive(\.listResponse) {
            $0.paused.context = context(.paused, 3)
            $0.paused.request = nil
            $0.paused.isLoading = false
            $0.paused.hasLoaded = true
        }
        await store.finish()
    }

    @Test("초기 로드 이후 새로고침 실패도 팝업 재시도로 복구한다")
    func retryAfterRefreshFailure() async {
        let active = MockFetchActiveSubscriptionUseCase()
        active.result = .failure(AppError.serverError)
        var state = readyState()
        state.active.newsletters = [newsletter()]
        let displayed = state.active.context
        let store = makeStore(state: state, active: active)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await store.receive(\.listResponse) {
            $0.active.isLoading = false
            $0.active.request = nil
            $0.active.error = .serverError
            $0.active.failedContext = context(.active, 0)
            $0.currentError = .serverError
            $0.failedOperation = .load(.active)
        }
        #expect(store.state.analyticsList == displayed)
        #expect(store.state.analyticsStateList == context(.active, 0))
        #expect(store.state.active.newsletters == [newsletter()])
        active.result = .success([newsletter(2)])
        // ServerErrorPopup dismisses its error binding before sending retry.
        await store.send(.errorDismissed) { $0.currentError = nil }
        await store.send(.retryTapped) {
            $0.failedOperation = nil
            $0.active.error = nil
            $0.active.isLoading = true
            $0.active.request = context(.active, 1)
        }
        await store.receive(\.listResponse) {
            $0.active.newsletters = [newsletter(2)]
            $0.active.context = context(.active, 1)
            $0.active.failedContext = nil
            $0.active.request = nil
            $0.active.isLoading = false
        }
        #expect(active.executeCallCount == 2)
        await store.finish()
    }

    @Test("초기 한 탭 조회가 실패해도 성공한 목록을 유지하고 실패한 탭만 재시도한다")
    func retryInitialFailure() async {
        let active = ControlledSubscriptions()
        let paused = ControlledSubscriptions()
        let store = makeStore(state: Feature.State(), active: active, paused: paused)
        await store.send(.task(isGuest: false)) {
            $0.isGuest = false
            $0.isVisible = true
            $0.active.context = context(.active, 0)
            $0.paused.context = context(.paused, 1)
            $0.active.request = context(.active, 2)
            $0.paused.request = context(.paused, 3)
            $0.active.isLoading = true
            $0.paused.isLoading = true
        }
        await active.gate.waitForRequests(1)
        await paused.gate.waitForRequests(1)
        await paused.gate.finish(0, with: .success([newsletter(2)]))
        await store.receive(\.listResponse) {
            $0.paused.newsletters = [newsletter(2)]
            $0.paused.context = context(.paused, 3)
            $0.paused.request = nil
            $0.paused.isLoading = false
            $0.paused.hasLoaded = true
        }
        await active.gate.finish(0, with: .failure(AppError.serverError))
        await store.receive(\.listResponse) {
            $0.active.request = nil
            $0.active.isLoading = false
            $0.active.error = .serverError
            $0.active.failedContext = context(.active, 2)
            $0.currentError = .serverError
            $0.failedOperation = .load(.active)
        }
        #expect(!store.state.active.hasLoaded)
        await store.send(.retryTapped) {
            $0.currentError = nil
            $0.failedOperation = nil
            $0.active.error = nil
            $0.active.isLoading = true
            $0.active.request = context(.active, 4)
        }
        await active.gate.waitForRequests(2)
        await active.gate.finish(1, with: .success([newsletter()]))
        await store.receive(\.listResponse) {
            $0.active.newsletters = [newsletter()]
            $0.active.context = context(.active, 4)
            $0.active.failedContext = nil
            $0.active.request = nil
            $0.active.isLoading = false
            $0.active.hasLoaded = true
        }
        #expect(!store.state.isInitialLoading)
        #expect(store.state.paused.newsletters == [newsletter(2)])
        await store.finish()
    }

    @Test("다른 탭의 조회 중에도 새로 선택한 탭을 조회한다")
    func switchingTabsDuringRefresh() async {
        let active = ControlledSubscriptions()
        let paused = ControlledSubscriptions()
        let store = makeStore(active: active, paused: paused)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await active.gate.waitForRequests(1)
        await store.send(.tabSelected(.paused)) {
            $0.selectedTab = .paused
            $0.paused.isLoading = true
            $0.paused.request = context(.paused, 1)
        }
        await paused.gate.waitForRequests(1)
        await paused.gate.finish(0, with: .success([newsletter(2)]))
        await store.receive(\.listResponse) {
            $0.paused.newsletters = [newsletter(2)]
            $0.paused.context = context(.paused, 1)
            $0.paused.request = nil
            $0.paused.isLoading = false
        }
        #expect(store.state.analyticsState == .ready)
        await active.gate.finish(0, with: .success([]))
        await store.receive(\.listResponse) {
            $0.active.context = context(.active, 0)
            $0.active.request = nil
            $0.active.isLoading = false
        }
        await store.finish()
    }

    @Test("중지 전 시작된 조회가 늦게 끝나도 최신 목록을 되돌리지 않는다")
    func pauseDuringRefresh() async {
        let active = ControlledSubscriptions()
        let paused = ControlledSubscriptions()
        let clock = TestClock()
        var state = readyState()
        state.active.newsletters = [newsletter()]
        let store = makeStore(state: state, active: active, paused: paused, clock: clock)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await active.gate.waitForRequests(1)
        await store.send(.pauseTapped(newsletter())) { $0.confirmation = newsletter() }
        await store.send(.pauseConfirmed) {
            $0.confirmation = nil
            $0.pendingChanges[1] = .pause
        }
        await store.receive(\.changeResponse) {
            $0.pendingChanges = [:]
            $0.active.newsletters = []
            $0.paused.newsletters = [newsletter()]
            $0.toast = .pause
            $0.active.request = context(.active, 1)
            $0.paused.request = context(.paused, 2)
            $0.paused.isLoading = true
        }
        await active.gate.waitForRequests(2)
        await paused.gate.waitForRequests(1)
        // The first dependency deliberately ignores cancellation and returns obsolete data.
        await active.gate.finish(0, with: .success([newsletter()]))
        await active.gate.finish(1, with: .success([]))
        await store.receive(\.listResponse) {
            $0.active.context = context(.active, 1)
            $0.active.request = nil
            $0.active.isLoading = false
        }
        await paused.gate.finish(0, with: .success([newsletter()]))
        await store.receive(\.listResponse) {
            $0.paused.context = context(.paused, 2)
            $0.paused.request = nil
            $0.paused.isLoading = false
        }
        await clock.advance(by: .seconds(1))
        await store.receive(\.toastDismissed) { $0.toast = nil }
        #expect(store.state.active.newsletters.isEmpty)
        await store.finish()
    }

    @Test("중복 재개를 막고 변경 실패를 재시도하며 후속 조회 실패는 조회만 재시도한다")
    func resumeRetryAndRefreshFailure() async {
        let change = ControlledChange()
        let active = ControlledSubscriptions()
        let paused = ControlledSubscriptions()
        let clock = TestClock()
        var state = readyState()
        state.selectedTab = .paused
        state.paused.newsletters = [newsletter()]
        let store = makeStore(state: state, active: active, paused: paused, resume: change, clock: clock)
        await store.send(.resumeTapped(newsletter())) { $0.pendingChanges[1] = .resume }
        await change.gate.waitForRequests(1)
        await store.send(.resumeTapped(newsletter()))
        #expect(change.ids == ["1"])
        await change.gate.finish(0, with: .failure(AppError.serverError))
        await store.receive(\.changeResponse) {
            $0.pendingChanges = [:]
            $0.currentError = .serverError
            $0.failedOperation = .change(.resume, newsletter())
        }
        await store.send(.retryTapped) {
            $0.pendingChanges[1] = .resume
            $0.currentError = nil
            $0.failedOperation = nil
        }
        await change.gate.waitForRequests(2)
        await change.gate.finish(1, with: .success(()))
        await store.receive(\.changeResponse) {
            $0.pendingChanges = [:]
            $0.active.newsletters = [newsletter()]
            $0.paused.newsletters = []
            $0.toast = .resume
            $0.active.isLoading = true
            $0.paused.isLoading = true
            $0.active.request = context(.active, 0)
            $0.paused.request = context(.paused, 1)
        }
        await active.gate.waitForRequests(1)
        await paused.gate.waitForRequests(1)
        await active.gate.finish(0, with: .failure(AppError.serverError))
        await store.receive(\.listResponse) {
            $0.active.isLoading = false
            $0.active.request = nil
            $0.active.error = .serverError
            $0.active.failedContext = context(.active, 0)
            $0.currentError = .serverError
            $0.failedOperation = .load(.active)
        }
        await paused.gate.finish(0, with: .success([]))
        await store.receive(\.listResponse) {
            $0.paused.context = context(.paused, 1)
            $0.paused.request = nil
            $0.paused.isLoading = false
        }
        #expect(store.state.currentError == .serverError)
        await store.send(.retryTapped) {
            $0.currentError = nil
            $0.failedOperation = nil
            $0.active.error = nil
            $0.active.isLoading = true
            $0.active.request = context(.active, 2)
        }
        await active.gate.waitForRequests(2)
        await active.gate.finish(1, with: .success([newsletter()]))
        await store.receive(\.listResponse) {
            $0.active.context = context(.active, 2)
            $0.active.failedContext = nil
            $0.active.isLoading = false
            $0.active.request = nil
        }
        #expect(change.ids == ["1", "1"])
        await clock.advance(by: .seconds(1))
        await store.receive(\.toastDismissed) { $0.toast = nil }
        await store.finish()
    }

    @Test("화면 이탈은 조회와 구독 변경을 취소하고 늦은 결과를 반영하지 않는다")
    func disappearanceCancelsWork() async {
        let active = ControlledSubscriptions()
        let change = ControlledChange()
        let store = makeStore(active: active, resume: change)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await store.send(.resumeTapped(newsletter())) { $0.pendingChanges[1] = .resume }
        await active.gate.waitForRequests(1)
        await change.gate.waitForRequests(1)
        await store.send(.disappeared) {
            $0.isVisible = false
            $0.active.isLoading = false
            $0.active.request = nil
            $0.pendingChanges = [:]
        }
        await active.gate.finish(0, with: .success([newsletter()]))
        await change.gate.finish(0, with: .success(()))
        await store.finish()
        #expect(store.state.active.newsletters.isEmpty)
        #expect(store.state.toast == nil)
        #expect(store.state.currentError == nil)
    }

    @Test("로그아웃 시 이전 요청을 취소하고 게스트 상태를 유지한다")
    func logoutCancelsWork() async {
        let active = ControlledSubscriptions()
        var state = readyState()
        state.active.newsletters = [newsletter()]
        let store = makeStore(state: state, active: active)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await active.gate.waitForRequests(1)
        await store.send(.task(isGuest: true)) {
            $0.isGuest = true
            $0.lastRefreshTime = nil
            $0.active.newsletters = []
            $0.active.hasLoaded = false
            $0.paused.hasLoaded = false
            $0.active.isLoading = false
            $0.active.request = nil
            $0.active.context = context(.active, 1)
            $0.paused.context = context(.paused, 2)
        }
        await active.gate.finish(0, with: .failure(AppError.serverError))
        await store.finish()
        #expect(store.state.analyticsState == .guest)
        #expect(store.state.currentError == nil)
    }

    @Test("의존성의 취소 오류는 로딩만 끝내고 사용자 오류로 표시하지 않는다")
    func cancellationIsSilent() async {
        let active = MockFetchActiveSubscriptionUseCase()
        active.result = .failure(CancellationError())
        let resume = MockResumeSubscriptionUseCase()
        resume.result = .failure(URLError(.cancelled))
        var state = readyState()
        state.active.hasLoaded = false
        let store = makeStore(state: state, active: active, resume: resume)
        await store.send(.refreshRequested) {
            $0.lastRefreshTime = referenceDate
            $0.active.isLoading = true
            $0.active.request = context(.active, 0)
        }
        await store.receive(\.listCancelled) {
            $0.active.isLoading = false
            $0.active.request = nil
        }
        #expect(store.state.currentError == nil)
        #expect(!store.state.active.hasLoaded)
        await store.send(.resumeTapped(newsletter())) { $0.pendingChanges[1] = .resume }
        await store.receive(\.changeCancelled) { $0.pendingChanges = [:] }
        #expect(store.state.currentError == nil)
        await store.finish()
    }

    @Test("빈 구독과 빈 중지 목록의 표시 및 분석 의미를 구분한다")
    func emptyListSemantics() async {
        let store = makeStore()
        #expect(store.state.analyticsState == .noSubscriptions)
        await store.send(.tabSelected(.paused)) {
            $0.selectedTab = .paused
            $0.paused.isLoading = true
            $0.paused.request = context(.paused, 0)
        }
        await store.receive(\.listResponse) {
            $0.paused.context = context(.paused, 0)
            $0.paused.request = nil
            $0.paused.isLoading = false
        }
        #expect(store.state.analyticsState == .noResults)
        await store.finish()
    }

    @Test("잘못된 구독 ID와 게스트의 변경 요청은 실행하지 않는다")
    func invalidMutationIsIgnored() async {
        let change = MockResumeSubscriptionUseCase()
        let store = makeStore(resume: change)
        await store.send(.resumeTapped(newsletter(0)))
        await store.send(.pauseTapped(newsletter(-1)))
        #expect(change.executedNewsletterId == nil)
        await store.finish()
        let guest = makeStore(state: Feature.State(), resume: change)
        await guest.send(.resumeTapped(newsletter()))
        #expect(change.executedNewsletterId == nil)
        await guest.finish()
    }
}

@MainActor
private final class ControlledSubscriptions: FetchActiveSubscriptionUseCase, FetchPausedSubscriptionUseCase {
    let gate = SubscriptionGate<[SubscribeNewsletter]>()
    func execute() async throws -> [SubscribeNewsletter] { try await gate.value() }
}

@MainActor
private final class ControlledChange: PauseSubscriptionUseCase, ResumeSubscriptionUseCase {
    let gate = SubscriptionGate<Void>()
    private(set) var ids: [String] = []
    func execute(newsletterId: String) async throws {
        ids.append(newsletterId)
        try await gate.value()
    }
}

// Explicit response ordering, including dependencies that finish after cancellation.
private actor SubscriptionGate<Value: Sendable> {
    private var count = 0
    private var requests: [Int: CheckedContinuation<Value, any Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func value() async throws -> Value {
        let id = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            requests[id] = continuation
            let ready = observers.filter { $0.0 <= count }
            observers.removeAll { $0.0 <= count }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func waitForRequests(_ expected: Int) async {
        guard count < expected else { return }
        await withCheckedContinuation { observers.append((expected, $0)) }
    }

    func finish(_ id: Int, with result: Result<Value, any Error>) {
        requests.removeValue(forKey: id)?.resume(with: result)
    }
}
