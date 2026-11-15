import Testing
import Foundation
import Synchronization
import Observation
import HomeDomain
import HomeTesting
import Shared

@testable import Home

private final class StubHomeUserInfoStore: UserInfoStoreProtocol {
    private let user = Mutex<UserInfo?>(nil)
    func save(_ value: UserInfo) { user.withLock { $0 = value } }
    func load() -> UserInfo? { user.withLock { $0 } }
    func clear() { user.withLock { $0 = nil } }
    var hasProfile: Bool {
        guard let value = load() else { return false }
        return !value.nickname.isEmpty && value.industryId != nil && !value.interestIds.isEmpty
    }
}

@Suite("HomeViewModel Tests")
@MainActor
struct HomeViewModelTests {
    private let fetchTodayArticles = MockFetchTodayArticlesUseCase()
    private let fetchMonthArticles = MockFetchMonthArticlesUseCase()
    private let fetchDayArticles = MockFetchDayArticlesUseCase()
    private let fetchNewsletters = MockFetchHomeNewslettersUseCase()
    private let decorateArticles = MockDecorateArticlesUseCase()
    private let refreshArticles = MockRefreshHomeArticlesUseCase()
    private let loadReadIds = MockLoadReadArticleIdsUseCase()
    private let saveReadIds = MockSaveReadArticleIdsUseCase()

    private func makeSUT(
        userInfoStore: UserInfoStoreProtocol = StubHomeUserInfoStore(),
        monthFetcher: (any FetchMonthArticlesUseCase)? = nil,
        decorator: (any DecorateArticlesUseCase)? = nil,
        dayFetcher: (any FetchDayArticlesUseCase)? = nil,
        refresher: (any RefreshHomeArticlesUseCase)? = nil
    ) -> HomeViewModel {
        let appState = AppState()
        appState.authState = .authenticated
        return HomeViewModel(
            fetchTodayArticles: fetchTodayArticles,
            fetchMonthArticles: monthFetcher ?? fetchMonthArticles,
            fetchDayArticles: dayFetcher ?? fetchDayArticles,
            fetchNewsletters: fetchNewsletters,
            decorateArticles: decorator ?? decorateArticles,
            refreshArticles: refresher ?? refreshArticles,
            loadReadIds: loadReadIds,
            saveReadIds: saveReadIds,
            extractArticleDays: ExtractArticleDaysUseCaseImpl(),
            mergeDayArticleSummary: MergeDayArticleSummaryUseCaseImpl(),
            appState: appState,
            userInfoStore: userInfoStore
        )
    }

    private static let sampleArticles = [
        HomeArticle(brandName: "B1", imageUrl: "", articleTitle: "T1", articleId: 10, status: .unread),
        HomeArticle(brandName: "B2", imageUrl: "", articleTitle: "T2", articleId: 20, status: .unread)
    ]

    private static let sampleNewsletter = HomeNewsletter(
        id: 1, brandName: "NL1", imageUrl: "", publicationCycle: "daily"
    )

    private func setupSuccessScenario() {
        let today = Calendar.current.component(.day, from: Date())
        fetchTodayArticles.result = .success(Self.sampleArticles)
        fetchDayArticles.result = .success(Self.sampleArticles)
        fetchNewsletters.result = .success([Self.sampleNewsletter])
        fetchMonthArticles.result = .success([
            HomeArticles(publishDate: today, hasArticles: true, totalCount: 2, unreadCount: 2)
        ])
    }

    @Test("loadToday fetches articles and newsletters")
    func loadTodaySuccess() async {
        setupSuccessScenario()

        let sut = makeSUT()
        await sut.loadToday()

        #expect(sut.homeState == .articles)
        #expect(sut.filteredArticles.count == 2)
        #expect(sut.subscribedNewsletters.count == 1)
        #expect(fetchTodayArticles.executeCallCount == 1)
        #expect(fetchNewsletters.executeCallCount == 1)
        #expect(fetchDayArticles.executeCallCount == 0)
        #expect(decorateArticles.executeCallCount == 1)
    }

    @Test("오늘 응답을 보존하며 불필요한 일별 API를 호출하지 않는다")
    func firstLoadKeepsTodayResponse() async {
        setupSuccessScenario()
        fetchDayArticles.result = .failure(HomeAnalyticsServerFailure())
        let sut = makeSUT()
        defer { sut.cancelPendingWork() }

        await sut.loadToday()

        #expect(sut.filteredArticles.map(\.articleId) == [10, 20])
        #expect(fetchDayArticles.executeCallCount == 0)
        #expect(sut.currentError == nil)
        #expect(sut.analyticsState == .ready)
    }

    @Test("월 응답 전에도 오늘 기사와 올바른 목록 계측이 준비된다")
    func cardsAreReadyBeforeMonthResponse() async {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let previousList = sut.analyticsList
        let loading = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(1)

        #expect(sut.homeState == .articles)
        #expect(sut.filteredArticles.map(\.articleId) == [10, 20])
        #expect(sut.analyticsState == .ready)
        #expect(sut.analyticsList != previousList)
        #expect(Calendar.current.isDate(sut.analyticsDate, inSameDayAs: sut.selectedDate))
        #expect(sut.calendarState.isLoading)
        #expect(fetchDayArticles.executeCallCount == 0)
        #expect(decorateArticles.executeCallCount == 1)

        await month.responses.finish(1, with: [])
        await loading.value
        #expect(!sut.calendarState.isLoading)
        let today = Calendar.current.component(.day, from: sut.selectedDate)
        #expect(sut.articlesByMonth.first(where: { $0.publishDate == today })?.totalCount == 2)
        #expect(sut.calendarState.dataDays.contains(today))
    }

    @Test("월 조회 실패는 기사 ready 상태를 유지하고 달력만 재시도한다")
    func monthFailureDoesNotFailArticles() async {
        setupSuccessScenario()
        fetchMonthArticles.result = .failure(HomeAnalyticsServerFailure())
        let sut = makeSUT()
        defer { sut.cancelPendingWork() }
        await sut.loadToday()
        let list = sut.analyticsList

        #expect(sut.homeState == .articles)
        #expect(sut.analyticsState == .ready)
        #expect(sut.currentError == nil)
        #expect(sut.calendarLoadFailed)
        #expect(!sut.calendarState.isLoading)

        fetchMonthArticles.result = .success([])
        await sut.loadMonthDataIfNeeded(for: sut.selectedDate)
        #expect(!sut.calendarLoadFailed)
        #expect(sut.analyticsList == list)
        #expect(fetchTodayArticles.executeCallCount == 1)
        #expect(fetchDayArticles.executeCallCount == 0)
    }

    @Test("첫 진입은 한 번만 가공하고 상세 복귀에서는 하이라이트를 갱신한다")
    func appearanceDecoratesOnceAndRefreshesOnReturn() async {
        setupSuccessScenario()
        let sut = makeSUT()
        defer { sut.cancelPendingWork() }
        await sut.loadForAppearance()
        #expect(decorateArticles.executeCallCount == 1)

        sut.cancelPendingWork()
        decorateArticles.handler = { articles, _ in articles.map { $0.withHighlightCount(3) } }
        await sut.loadForAppearance()
        #expect(decorateArticles.executeCallCount == 2)
        #expect(sut.filteredArticles.allSatisfy { $0.highlightCount == 3 })
        #expect(fetchTodayArticles.executeCallCount == 1)
        #expect(fetchDayArticles.executeCallCount == 0)
    }

    @Test("진입과 달력 열기가 같은 월 요청을 공유한다")
    func calendarSharesInFlightMonth() async {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let loading = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(1)
        var calendar: Task<Void, Never>?
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = sut.calendarState
            } onChange: {
                continuation.resume()
            }
            calendar = Task { await sut.loadMonthDataIfNeeded(for: sut.selectedDate) }
        }
        #expect(await month.responses.callCount == 1)

        await month.responses.finish(1, with: [])
        await loading.value
        await calendar?.value
        #expect(await month.responses.callCount == 1)
        #expect(!sut.calendarState.isLoading)
    }

    @Test("달력을 기다리다 이탈해도 복귀 시 오늘 조회 없이 달력을 재개한다")
    func interruptedCalendarResumesOnAppearance() async {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let first = Task { await sut.loadForAppearance() }
        await month.responses.waitUntilRequested(1)
        first.cancel()
        sut.cancelPendingWork()
        await month.responses.finish(1, with: [])
        await first.value

        let resumed = Task { await sut.loadForAppearance() }
        await month.responses.waitUntilRequested(2)
        #expect(sut.analyticsState == .ready)
        #expect(fetchTodayArticles.executeCallCount == 1)
        await month.responses.finish(2, with: [])
        await resumed.value
        #expect(!sut.calendarState.isLoading)
        #expect(!sut.calendarLoadFailed)
    }

    @Test("인증 초기화 후 도착한 월 응답은 상태와 캐시를 복원하지 않는다")
    func oldMonthCannotRestoreResetState() async {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let loading = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(1)
        await sut.resetForAuthChange()
        let list = sut.analyticsList
        await month.responses.finish(1, with: [HomeArticles(publishDate: 1, hasArticles: true, totalCount: 99, unreadCount: 99)])
        await loading.value

        #expect(sut.filteredArticles.isEmpty)
        #expect(sut.articlesByMonth.isEmpty)
        #expect(sut.calendarState.dataDays.isEmpty)
        #expect(sut.analyticsList == list)
        #expect(sut.analyticsState == nil)
    }

    @Test("새 오늘 조회가 완료된 뒤 도착한 이전 월 응답은 무시한다")
    func oldMonthCannotOverwriteReload() async {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let first = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(1)
        fetchTodayArticles.result = .success([Self.sampleArticles[0]])
        let second = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(2)
        await month.responses.finish(2, with: [])
        await second.value
        let list = sut.analyticsList
        await month.responses.finish(1, with: [HomeArticles(publishDate: 1, hasArticles: true, totalCount: 99, unreadCount: 99)])
        await first.value

        #expect(sut.filteredArticles.map(\.articleId) == [10])
        #expect(sut.analyticsList == list)
        #expect(sut.articlesByMonth.allSatisfy { $0.totalCount == 1 })
        #expect(fetchDayArticles.executeCallCount == 0)
    }

    @Test("오늘 월 응답이 늦어도 사용자가 선택한 다른 월과 기사를 유지한다")
    func oldMonthDoesNotMoveSelectionBack() async throws {
        setupSuccessScenario()
        let month = SuspendedHomeMonth()
        let sut = makeSUT(monthFetcher: month)
        defer { sut.cancelPendingWork() }
        let loading = Task { await sut.loadToday() }
        await month.responses.waitUntilRequested(1)
        let target = try #require(Calendar.current.date(byAdding: .month, value: -2, to: sut.selectedDate))
        fetchDayArticles.result = .success([Self.sampleArticles[1]])
        await selectDateAndWait(target, on: sut)
        let list = sut.analyticsList
        await month.responses.finish(1, with: [])
        await loading.value

        #expect(Calendar.current.isDate(sut.displayedMonth, equalTo: target, toGranularity: .month))
        #expect(Calendar.current.isDate(sut.selectedDate, inSameDayAs: target))
        #expect(sut.filteredArticles.map(\.articleId) == [20])
        #expect(sut.analyticsList == list)
        #expect(sut.analyticsState == .ready)
    }

    @Test("이전 날짜의 하이라이트 결과가 새 날짜 기사나 캐시를 덮어쓰지 않는다")
    func oldHighlightsDoNotOverwriteSelection() async throws {
        setupSuccessScenario()
        let decorator = SuspendedHomeDecorator()
        let sut = makeSUT(decorator: decorator)
        defer { sut.cancelPendingWork() }
        await sut.loadToday()
        decorator.suspendNext = true
        let highlights = Task { await sut.refreshHighlights() }
        await decorator.responses.waitUntilRequested(1)
        let target = try #require(Calendar.current.date(byAdding: .day, value: -1, to: sut.selectedDate))
        fetchDayArticles.result = .success([Self.sampleArticles[1]])
        await selectDateAndWait(target, on: sut)
        await decorator.responses.finish(1, with: [Self.sampleArticles[0].withHighlightCount(9)])
        await highlights.value
        #expect(sut.filteredArticles.map(\.articleId) == [20])
        await sut.refreshCurrentData()
        #expect(sut.filteredArticles.map(\.articleId) == [20])
        #expect(sut.filteredArticles.first?.highlightCount == 0)
    }

    private func selectDateAndWait(_ date: Date, on sut: HomeViewModel) async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = sut.filteredArticles
            } onChange: {
                continuation.resume()
            }
            sut.selectDateWithMonthGuarantee(date)
        }
    }

    @Test("같은 날짜 재선택 후 도착한 이전 일별 응답은 새 캐시를 덮어쓰지 않는다")
    func olderDayResponseCannotPoisonCache() async throws {
        setupSuccessScenario()
        let day = SuspendedHomeDay()
        let sut = makeSUT(dayFetcher: day)
        defer { sut.cancelPendingWork() }
        await sut.loadToday()
        let today = sut.selectedDate
        let target = try #require(Calendar.current.date(byAdding: .day, value: -1, to: today))

        sut.selectedDate = target
        let oldRefresh = Task { await sut.refreshCurrentData() }
        await day.responses.waitUntilRequested(1)
        await selectDateAndWait(today, on: sut)
        sut.selectDateWithMonthGuarantee(target)
        await day.responses.waitUntilRequested(2)
        await withCheckedContinuation { continuation in
            withObservationTracking { _ = sut.filteredArticles } onChange: { continuation.resume() }
            Task { await day.responses.finish(2, with: [Self.sampleArticles[1]]) }
        }
        #expect(sut.filteredArticles.map(\.articleId) == [20])

        await day.responses.finish(1, with: [Self.sampleArticles[0]])
        await oldRefresh.value
        #expect(sut.filteredArticles.map(\.articleId) == [20])
        await sut.refreshCurrentData()
        #expect(sut.filteredArticles.map(\.articleId) == [20])
        #expect(await day.responses.callCount == 2)
    }

    @Test("화면 이탈 후 완료된 새로고침은 오늘 조회를 다시 시작하지 않는다")
    func lateRefreshDoesNotRestartAfterExit() async {
        setupSuccessScenario()
        let refresh = SuspendedHomeRefresh()
        let sut = makeSUT(refresher: refresh)
        defer { sut.cancelPendingWork() }
        await sut.loadToday()
        let list = sut.analyticsList
        let refreshing = Task { await sut.refreshToToday() }
        await refresh.responses.waitUntilRequested(1)
        sut.cancelPendingWork()
        await refresh.responses.finish(1, with: ())
        await refreshing.value

        #expect(fetchTodayArticles.executeCallCount == 1)
        #expect(sut.analyticsList == list)
        #expect(sut.currentError == nil)
    }

    @Test("홈 재조회 실패 후 남아 있는 카드는 이전 표시 ID를 유지한다")
    func failedReloadPreservesDisplayedList() async {
        setupSuccessScenario()
        let vm = makeSUT()
        await vm.loadToday()
        let displayed = vm.analyticsList
        fetchTodayArticles.result = .failure(HomeAnalyticsServerFailure())
        await vm.loadToday()
        #expect(vm.filteredArticles.count == 2)
        #expect(vm.analyticsList == displayed)
        #expect(vm.analyticsState == .failed)
        #expect(vm.analyticsStateList != displayed)
    }

    @Test("loadToday sets guest state for guest user")
    func loadTodayGuest() async {
        let appState = AppState()
        appState.authState = .guest
        let sut = HomeViewModel(
            fetchTodayArticles: fetchTodayArticles,
            fetchMonthArticles: fetchMonthArticles,
            fetchDayArticles: fetchDayArticles,
            fetchNewsletters: fetchNewsletters,
            decorateArticles: decorateArticles,
            refreshArticles: refreshArticles,
            loadReadIds: loadReadIds,
            saveReadIds: saveReadIds,
            extractArticleDays: ExtractArticleDaysUseCaseImpl(),
            mergeDayArticleSummary: MergeDayArticleSummaryUseCaseImpl(),
            appState: appState,
            userInfoStore: StubHomeUserInfoStore()
        )

        await sut.loadToday()

        #expect(sut.homeState == .guest)
        #expect(fetchTodayArticles.executeCallCount == 0)
    }

    @Test("loadToday handles failure gracefully")
    func loadTodayFailure() async {
        fetchTodayArticles.result = .failure(NSError(domain: "test", code: -1))
        fetchNewsletters.result = .success([])

        let sut = makeSUT()
        await sut.loadToday()

        #expect(sut.filteredArticles.isEmpty)
        #expect(sut.homeState == .noSubscriptions)
    }

    @Test("markArticleAsRead updates read status and saves")
    func markArticleAsRead() async {
        setupSuccessScenario()
        decorateArticles.handler = { articles, readIds in
            articles.map { article in
                if readIds.contains(article.articleId) {
                    return HomeArticle(brandName: article.brandName, imageUrl: article.imageUrl, articleTitle: article.articleTitle, articleId: article.articleId, status: .read, publishDate: article.publishDate)
                }
                return article
            }
        }

        let sut = makeSUT()
        await sut.loadToday()
        #expect(sut.filteredArticles.count == 2)

        await sut.markArticleAsRead(articleId: 10)

        #expect(saveReadIds.executeCallCount == 1)
        #expect(saveReadIds.savedIds?.contains(10) == true)
        let readArticle = sut.filteredArticles.first(where: { $0.articleId == 10 })
        #expect(readArticle?.status == .read)
    }

    @Test("resetForAuthChange clears all state")
    func resetForAuthChange() async {
        setupSuccessScenario()

        let sut = makeSUT()
        await sut.loadToday()
        #expect(!sut.filteredArticles.isEmpty)

        await sut.resetForAuthChange()

        #expect(sut.filteredArticles.isEmpty)
        #expect(sut.subscribedNewsletters.isEmpty)
        #expect(sut.articlesByMonth.isEmpty)
    }

    @Test("shouldReloadToday returns true when not loaded")
    func shouldReloadTodayNotLoaded() async {
        let sut = makeSUT()
        let result = await sut.shouldReloadToday()
        #expect(result)
    }

    @Test("프로필 편집 후 같은 날 홈으로 돌아와도 다시 로딩한다")
    func shouldReloadTodayAfterProfileEdit() async {
        setupSuccessScenario()
        let store = StubHomeUserInfoStore()
        var profile = UserInfo(id: 1, nickname: "테스터", birthYear: "2000", gender: "M", createdAt: "2025-01-01", industryId: 1, interestIds: [1])
        store.save(profile)
        let sut = makeSUT(userInfoStore: store)
        await sut.loadToday()
        #expect(await sut.shouldReloadToday() == false)

        profile.interestIds = [2, 3]
        store.save(profile)
        #expect(await sut.shouldReloadToday())
        await sut.loadToday()

        #expect(fetchTodayArticles.executeCallCount == 2)
        #expect(fetchNewsletters.executeCallCount == 2)
        #expect(await sut.shouldReloadToday() == false)
    }

    @Test("프로필 재조회 실패 후에도 다음 홈 복귀에서 다시 시도한다")
    func profileReloadFailure_keepsReloadNeeded() async {
        setupSuccessScenario()
        let store = StubHomeUserInfoStore()
        var profile = UserInfo(id: 1, nickname: "테스터", birthYear: "2000", gender: "M", createdAt: "2025-01-01", industryId: 1, interestIds: [1])
        store.save(profile)
        let sut = makeSUT(userInfoStore: store)
        await sut.loadToday()

        profile.industryId = 2
        store.save(profile)
        fetchTodayArticles.result = .failure(NSError(domain: "test", code: -1))
        await sut.loadToday()

        #expect(await sut.shouldReloadToday())
    }

    @Test("refreshHighlights updates highlight counts")
    func refreshHighlights() async {
        setupSuccessScenario()

        let sut = makeSUT()
        await sut.loadToday()
        #expect(!sut.filteredArticles.isEmpty)

        decorateArticles.handler = { articles, _ in
            articles.map { $0.withHighlightCount($0.articleId == 10 ? 5 : 3) }
        }
        await sut.refreshHighlights()

        let article10 = sut.filteredArticles.first(where: { $0.articleId == 10 })
        let article20 = sut.filteredArticles.first(where: { $0.articleId == 20 })
        #expect(article10?.highlightCount == 5)
        #expect(article20?.highlightCount == 3)
    }

    @Test("noSubscriptions state when no newsletters and no articles")
    func noSubscriptionsState() async {
        fetchTodayArticles.result = .success([])
        fetchDayArticles.result = .success([])
        fetchNewsletters.result = .success([])
        fetchMonthArticles.result = .success([])

        let sut = makeSUT()
        await sut.loadToday()

        #expect(sut.homeState == .noSubscriptions)
    }
}

private struct HomeAnalyticsServerFailure: Error, AppErrorConvertible {
    func toAppError() -> AppError { .serverError }
}

@MainActor
private final class SuspendedHomeMonth: FetchMonthArticlesUseCase {
    let responses = HomeResponses<[HomeArticles]>()
    private let year = Calendar.current.component(.year, from: Date())
    private let month = Calendar.current.component(.month, from: Date())

    func execute(year: String, publicationMonth: String) async throws -> [HomeArticles] {
        guard Int(year) == self.year, Int(publicationMonth) == month else { return [] }
        // Deliberately ignores cancellation to exercise late-response guards.
        return await responses.start()
    }
}

@MainActor
private final class SuspendedHomeDecorator: DecorateArticlesUseCase {
    let responses = HomeResponses<[HomeArticle]>()
    var suspendNext = false

    func execute(articles: [HomeArticle], readIds: Set<Int>, refreshHighlightCounts: Bool) async -> [HomeArticle] {
        guard suspendNext else { return articles }
        suspendNext = false
        return await responses.start()
    }
}

@MainActor
private final class SuspendedHomeDay: FetchDayArticlesUseCase {
    let responses = HomeResponses<[HomeArticle]>()

    func execute(year: String, publicationMonth: String, publicationDate: String) async throws -> [HomeArticle] {
        await responses.start()
    }
}

@MainActor
private final class SuspendedHomeRefresh: RefreshHomeArticlesUseCase {
    let responses = HomeResponses<Void>()

    func execute() async throws {
        await responses.start()
    }
}

private actor HomeResponses<Value: Sendable> {
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<Value, Never>] = [:]
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func start() async -> Value {
        callCount += 1
        let id = callCount
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            waiters.removeValue(forKey: id)?.resume()
        }
    }

    func waitUntilRequested(_ id: Int) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }

    func finish(_ id: Int, with value: Value) {
        pending.removeValue(forKey: id)?.resume(returning: value)
    }
}
