//
//  HomeViewModel.swift
//  Home
//
//  Created by 권민재 on 4/16/25.
//  Copyright © 2025 Newdok. All rights reserved.
//

import SwiftUI
import HomeDomain
import Shared
import FoundationKit
import Foundation
import Observation

// MARK: - Calendar State
public struct CalendarState {
    public var selectedDate: Date
    public var displayedMonth: Date
    public var dataDays: Set<Int> = []
    public var isLoading: Bool = false

    public init(initialDate: Date = Date()) {
        self.selectedDate = initialDate
        self.displayedMonth = initialDate
    }
}

public enum HomeState {
    case idle
    case loading
    case guest
    case noSubscriptions
    case noArticles
    case articles
}

@Observable
@MainActor
public final class HomeViewModel: ErrorHandling {
    public private(set) var analyticsDate = Date()
    private var analyticsDateLoading = false
    private var dataSessionID = UUID()
    public private(set) var analyticsList = AnalyticsListContext(.homeArticles)
    private var failedList: AnalyticsListContext?
    var analyticsStateList: AnalyticsListContext {
        currentError == .serverError ? failedList ?? analyticsList : analyticsList
    }
    public var analyticsState: AnalyticsContentState? {
        if currentError == .serverError { return .failed }
        guard !isTodayLoading, !analyticsDateLoading else { return nil }
        switch homeState {
        case .idle, .loading: return nil
        case .guest: return .guest
        case .noSubscriptions: return .noSubscriptions
        case .noArticles: return .noArticlesOnDate
        case .articles: return .ready
        }
    }
    func trackAction(_ action: AnalyticsHomeAction, state explicitState: AnalyticsContentState? = nil) {
        guard let state = explicitState ?? analyticsState else { return }
        analytics.record(.homeActionSelected(state: state, action: action, date: .init(date: selectedDate)), from: .home)
    }
    public let analytics: AnalyticsClient

    public var currentError: AppError?
    public private(set) var calendarLoadFailed = false
    // MARK: - Dependencies
    private let fetchTodayArticlesUseCase: FetchTodayArticlesUseCase
    private let fetchMonthArticlesUseCase: FetchMonthArticlesUseCase
    private let fetchDayArticlesUseCase: FetchDayArticlesUseCase
    private let fetchNewslettersUseCase: FetchHomeNewslettersUseCase
    private let decorateArticlesUseCase: DecorateArticlesUseCase
    private let refreshArticlesUseCase: RefreshHomeArticlesUseCase
    private let loadReadIdsUseCase: LoadReadArticleIdsUseCase
    private let saveReadIdsUseCase: SaveReadArticleIdsUseCase
    private let extractArticleDaysUseCase: ExtractArticleDaysUseCase
    private let mergeDayArticleSummaryUseCase: MergeDayArticleSummaryUseCase
    private let appState: AppState
    private let userInfoStore: UserInfoStoreProtocol

    // MARK: - Published State
    private var isBatchUpdating = false
    public var calendarState: CalendarState {
        didSet {
            guard !isBatchUpdating else { return }
            let oldMonth = oldValue.displayedMonth
            let newMonth = calendarState.displayedMonth
            guard !Calendar.current.isDate(oldMonth, equalTo: newMonth, toGranularity: .month) else { return }
            applyDataDaysForMonth(newMonth)
        }
    }
    @ObservationIgnored private var monthLoadTask: Task<Void, Never>?
    @ObservationIgnored private var dateSelectionTask: Task<Void, Never>?
    private struct MonthRequest {
        let id: UUID
        let task: Task<[HomeArticles], Error>
    }
    // Shared by calendar loading and prefetching; all tasks are cancelled on exit/reset.
    @ObservationIgnored private var monthRequests: [String: MonthRequest] = [:]
    @ObservationIgnored private var prefetchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observedAuthState: AuthState

    public var homeState: HomeState = .idle
    public var filteredArticles: [HomeArticle] = [] {
        didSet { articlesRevision = UUID() }
    }
    @ObservationIgnored private var articlesRevision = UUID()
    public var subscribedNewsletters: [HomeNewsletter] = []
    public var articlesByMonth: [HomeArticles] = []

    // MARK: - Caches
    private let maxCachedMonths = 4
    @ObservationIgnored private var dataDaysCache: [String: Set<Int>] = [:]
    @ObservationIgnored private var monthlyCache: [String: [HomeArticles]] = [:]
    @ObservationIgnored private var dayArticlesCache: [String: [HomeArticle]] = [:]
    @ObservationIgnored private var cachedMonthOrder: [String] = []
    private var readArticleIds: Set<Int> = []
    private var lastLoadedDate: Date?
    private var lastLoadedUserInfo: UserInfo?
    private var isTodayLoading = false
    private var isLoaded = false
    private var latestMonthRequestID: UUID?
    private var latestDateSelectionID: UUID?

    private var isGuest: Bool { appState.authState == .guest }

    public init(
        fetchTodayArticles: FetchTodayArticlesUseCase,
        fetchMonthArticles: FetchMonthArticlesUseCase,
        fetchDayArticles: FetchDayArticlesUseCase,
        fetchNewsletters: FetchHomeNewslettersUseCase,
        decorateArticles: DecorateArticlesUseCase,
        refreshArticles: RefreshHomeArticlesUseCase,
        loadReadIds: LoadReadArticleIdsUseCase,
        saveReadIds: SaveReadArticleIdsUseCase,
        extractArticleDays: ExtractArticleDaysUseCase,
        mergeDayArticleSummary: MergeDayArticleSummaryUseCase,
        appState: AppState,
        userInfoStore: UserInfoStoreProtocol,
        analytics: AnalyticsClient = .disabled
    ) {
        self.analytics = analytics
        self.fetchTodayArticlesUseCase = fetchTodayArticles
        self.fetchMonthArticlesUseCase = fetchMonthArticles
        self.fetchDayArticlesUseCase = fetchDayArticles
        self.fetchNewslettersUseCase = fetchNewsletters
        self.decorateArticlesUseCase = decorateArticles
        self.refreshArticlesUseCase = refreshArticles
        self.loadReadIdsUseCase = loadReadIds
        self.saveReadIdsUseCase = saveReadIds
        self.extractArticleDaysUseCase = extractArticleDays
        self.mergeDayArticleSummaryUseCase = mergeDayArticleSummary
        self.appState = appState
        self.observedAuthState = appState.authState
        self.userInfoStore = userInfoStore
        self.calendarState = CalendarState()
        self.readArticleIds = loadReadIds.execute()
    }

    // MARK: - Computed Properties
    public var selectedDate: Date {
        get { calendarState.selectedDate }
        set { calendarState.selectedDate = newValue }
    }

    public var displayedMonth: Date {
        get { calendarState.displayedMonth }
        set { calendarState.displayedMonth = newValue }
    }

    private func resolveState() -> HomeState {
        if isGuest { return .guest }
        if subscribedNewsletters.isEmpty && filteredArticles.isEmpty { return .noSubscriptions }
        if filteredArticles.isEmpty { return .noArticles }
        return .articles
    }

    public var formattedDate: String {
        selectedDate.newdokHomeDisplayText
    }

    // MARK: - Intent Handlers

    public func loadForAppearance() async {
        guard !Task.isCancelled else { return }
        if observedAuthState != appState.authState {
            await resetForAuthChange()
        }
        guard !isGuest else {
            homeState = .guest
            return
        }
        if await shouldReloadToday() {
            await loadToday()
        } else {
            let session = dataSessionID
            await refreshHighlights()
            guard session == dataSessionID, !Task.isCancelled else { return }
            // A previous appearance may have ended after the cards became ready.
            await loadMonthDataIfNeeded(for: calendarState.displayedMonth)
        }
    }

    public func cancelPendingWork() {
        if analyticsDateLoading { calendarState.selectedDate = analyticsDate }
        dataSessionID = UUID()
        monthLoadTask?.cancel()
        monthLoadTask = nil
        dateSelectionTask?.cancel()
        dateSelectionTask = nil
        for request in monthRequests.values { request.task.cancel() }
        monthRequests.removeAll()
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        latestMonthRequestID = nil
        latestDateSelectionID = nil
        isTodayLoading = false
        analyticsDateLoading = false
        calendarState.isLoading = false
    }

    public func loadToday() async {
        guard !isGuest else {
            homeState = .guest
            return
        }
        guard !Task.isCancelled, !isTodayLoading else { return }
        cancelPendingWork()
        let context = AnalyticsListContext(.homeArticles)
        let session = dataSessionID
        isTodayLoading = true
        defer { if session == dataSessionID { isTodayLoading = false } }

        analyticsDateLoading = false
        latestDateSelectionID = nil
        let requestedUserInfo = userInfoStore.load()
        if homeState == .idle || lastLoadedUserInfo != requestedUserInfo {
            homeState = .loading
        }

        do {
            async let articlesTask = fetchTodayArticlesUseCase.execute()
            async let newslettersTask = fetchNewslettersUseCase.execute()
            let articles = try await articlesTask
            let newsletters = try await newslettersTask

            let today = strippedDate(Date())
            let month = startOfMonth(today)
            let processedArticles = await decorateArticles(articles)

            try Task.checkCancellation()
            guard requestedUserInfo == userInfoStore.load(), session == dataSessionID else { return }
            subscribedNewsletters = newsletters
            clearMonthlyCache(for: today)
            storeArticles(processedArticles, for: today)
            filteredArticles = processedArticles
            articlesByMonth = []

            batchUpdate {
                calendarState.selectedDate = today
                calendarState.displayedMonth = month
                calendarState.dataDays = []
            }
            applyMonthlyAdjustment(for: today, articles: processedArticles)

            isLoaded = true
            lastLoadedDate = today
            lastLoadedUserInfo = requestedUserInfo
            analyticsList = context
            failedList = nil
            currentError = nil
            analyticsDate = today
            isTodayLoading = false
            homeState = resolveState()
            // Cards and analytics are ready before waiting for calendar summaries.
            await loadMonthInternal(for: today)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), requestedUserInfo == userInfoStore.load(), session == dataSessionID else { return }
            failedList = context
            analytics.record(.operationFailed(.list(context), category: .init(error: error)), from: .home)
            handleError(error, feature: "home", operation: "loadToday")
            isLoaded = true
            calendarState.isLoading = false
            homeState = resolveState()
        }
    }

    public func loadMonthDataIfNeeded(for date: Date) async {
        await loadMonthInternal(for: date)
    }

    public func loadMonthData(for date: Date, forceReload: Bool = false) async {
        await loadMonthInternal(for: date, forceReload: forceReload)
    }

    public func selectDateWithMonthGuarantee(_ date: Date) {
        if isTodayLoading { cancelPendingWork() }
        dateSelectionTask?.cancel()
        if !Calendar.current.isDate(date, inSameDayAs: analyticsDate) { trackAction(.changeDate) }
        let context = Calendar.current.isDate(date, inSameDayAs: analyticsDate) ? analyticsList : AnalyticsListContext(.homeArticles)
        let requestID = UUID()
        let session = dataSessionID
        analyticsDateLoading = true
        calendarState.selectedDate = date
        latestDateSelectionID = requestID
        guard !isGuest else {
            analyticsDateLoading = false
            homeState = .guest
            return
        }
        dateSelectionTask = Task { [weak self] in
            guard let self else { return }
            if !Calendar.current.isDate(date, equalTo: calendarState.displayedMonth, toGranularity: .month) {
                await loadMonthInternal(for: date)
            }
            guard session == dataSessionID, latestDateSelectionID == requestID, !Task.isCancelled else { return }
            await updateFilteredArticles(for: date)
            guard session == dataSessionID, latestDateSelectionID == requestID, !Task.isCancelled else { return }
            analyticsList = context
            analyticsDate = date
            analyticsDateLoading = false
            homeState = resolveState()
        }
    }

    public func refreshCurrentData() async {
        await updateFilteredArticles()
        homeState = resolveState()
    }

    public func refreshToToday() async {
        guard !isGuest else {
            homeState = .guest
            return
        }
        guard !Task.isCancelled, !isTodayLoading else { return }
        cancelPendingWork()
        let session = dataSessionID
        do {
            try await refreshArticlesUseCase.execute()
        } catch {
            guard session == dataSessionID, !Task.isCancelled, !(error is CancellationError) else { return }
            handleError(error, feature: "home", operation: "refresh")
        }
        guard session == dataSessionID, !Task.isCancelled else { return }
        await loadToday()
    }

    public func applyDataDaysForMonth(_ date: Date) {
        calendarState.dataDays = dataDaysCache[monthKey(for: date)] ?? []
        monthLoadTask?.cancel()
        monthLoadTask = Task { [weak self] in
            await self?.loadMonthDataIfNeeded(for: date)
        }
    }

    public func markArticleAsRead(articleId: Int) async {
        readArticleIds.insert(articleId)
        saveReadIdsUseCase.execute(readArticleIds)

        let targetDate = calendarState.selectedDate
        let session = dataSessionID
        let selectionID = latestDateSelectionID
        if var cached = cachedArticles(for: targetDate) {
            cached = await decorateArticles(cached, refreshHighlightCounts: false)
            guard session == dataSessionID, selectionID == latestDateSelectionID,
                  dayKey(for: targetDate) == dayKey(for: selectedDate),
                  !Task.isCancelled else { return }
            storeArticles(cached, for: targetDate)
            withAnimation(.easeInOut(duration: 0.25)) {
                filteredArticles = cached
            }
            applyMonthlyAdjustment(for: targetDate, articles: cached)
        } else {
            await updateFilteredArticles(for: targetDate)
        }
        homeState = resolveState()
    }

    public func resetForAuthChange() async {
        cancelPendingWork()
        observedAuthState = appState.authState
        failedList = nil
        currentError = nil
        calendarLoadFailed = false
        analyticsDateLoading = false
        analyticsList = .init(.homeArticles)
        homeState = .loading
        dataDaysCache.removeAll()
        monthlyCache.removeAll()
        dayArticlesCache.removeAll()
        cachedMonthOrder.removeAll()
        readArticleIds.removeAll()
        lastLoadedDate = nil
        lastLoadedUserInfo = nil
        isTodayLoading = false
        isLoaded = false
        latestMonthRequestID = nil
        latestDateSelectionID = nil

        let today = Date()
        batchUpdate {
            calendarState.selectedDate = today
            calendarState.displayedMonth = startOfMonth(today)
            calendarState.dataDays = []
            calendarState.isLoading = false
        }
        filteredArticles = []
        subscribedNewsletters = []
        articlesByMonth = []

        if isGuest {
            homeState = .guest
        }
    }

    public func shouldReloadToday(currentDate: Date = Date()) async -> Bool {
        if !isLoaded { return true }
        if lastLoadedUserInfo != userInfoStore.load() { return true }
        guard let lastLoadedDate else { return true }
        return !Calendar.current.isDate(lastLoadedDate, inSameDayAs: currentDate)
    }

    public func refreshHighlights() async {
        let targetDate = calendarState.selectedDate
        let session = dataSessionID
        let selectionID = latestDateSelectionID
        let revision = articlesRevision
        let readIDs = readArticleIds
        let original = filteredArticles
        let updated = await decorateArticlesUseCase.execute(articles: original, readIds: readIDs)
        guard session == dataSessionID, selectionID == latestDateSelectionID,
              dayKey(for: targetDate) == dayKey(for: selectedDate),
              articlesRevision == revision, readArticleIds == readIDs, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            filteredArticles = updated
        }
        storeArticles(updated, for: targetDate)
    }

    public func calendarDataDays(for date: Date) async -> Set<Int> {
        guard !isGuest else { return [] }

        let key = monthKey(for: date)
        if let cached = dataDaysCache[key] {
            return cached
        }

        if let monthly = monthlyCache[key] {
            let days = extractArticleDaysUseCase.execute(from: monthly)
            storeDataDays(days, for: date)
            return days
        }

        return await fetchDataDays(for: date)
    }

    // MARK: - Private: Month Loading

    private func loadMonthInternal(for date: Date, forceReload: Bool = false) async {
        guard !isGuest else {
            calendarState.isLoading = false
            homeState = .guest
            return
        }
        guard !Task.isCancelled else { return }
        let session = dataSessionID
        let key = monthKey(for: date)
        let month = startOfMonth(date)
        let requestID = UUID()
        latestMonthRequestID = requestID
        calendarLoadFailed = false
        calendarState.isLoading = true
        batchUpdate {
            calendarState.displayedMonth = month
            calendarState.dataDays = dataDaysCache[key] ?? []
        }
        defer {
            if session == dataSessionID, latestMonthRequestID == requestID {
                calendarState.isLoading = false
            }
        }

        do {
            let monthly = try await fetchMonthlyArticles(for: date, forceReload: forceReload)
            guard session == dataSessionID, latestMonthRequestID == requestID,
                  monthKey(for: displayedMonth) == key, !Task.isCancelled else { return }
            articlesByMonth = monthly
            calendarState.dataDays = dataDaysCache[key] ?? []
            prefetchAdjacent(from: month)
        } catch {
            guard session == dataSessionID, latestMonthRequestID == requestID,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            calendarLoadFailed = true
            ErrorLoggerRegistry.shared?.logError(.init(underlyingError: error, feature: "home", operation: "loadMonthData"))
        }
    }

    private func fetchMonthlyArticles(for date: Date, forceReload: Bool = false) async throws -> [HomeArticles] {
        try Task.checkCancellation()
        let key = monthKey(for: date)
        let session = dataSessionID
        if forceReload {
            monthRequests.removeValue(forKey: key)?.task.cancel()
            monthlyCache.removeValue(forKey: key)
        } else if let cached = monthlyCache[key] {
            touchMonthCache(key)
            return cached
        }

        let request: MonthRequest
        if let existing = monthRequests[key] {
            request = existing
        } else {
            let id = UUID()
            let year = formatYear(date)
            let month = formatMonth(date)
            let task = Task { [weak self, fetchMonthArticlesUseCase] in
                var monthly = try await fetchMonthArticlesUseCase.execute(year: year, publicationMonth: month)
                try Task.checkCancellation()
                guard let self, session == self.dataSessionID,
                      self.monthRequests[key]?.id == id else { throw CancellationError() }
                // Preserve the fresh day response/read status when the server's summary arrives later.
                if self.monthKey(for: self.selectedDate) == key,
                   let articles = self.cachedArticles(for: self.selectedDate) {
                    monthly = self.mergeDayArticleSummaryUseCase.execute(
                        day: Calendar.current.component(.day, from: self.selectedDate),
                        dayArticles: articles, into: monthly
                    )
                }
                self.monthlyCache[key] = monthly
                self.storeDataDays(self.extractArticleDaysUseCase.execute(from: monthly), for: date)
                return monthly
            }
            request = MonthRequest(id: id, task: task)
            monthRequests[key] = request
        }
        defer {
            if monthRequests[key]?.id == request.id { monthRequests.removeValue(forKey: key) }
        }
        // Cancellation of one calendar consumer must not cancel another consumer's shared request.
        // cancelPendingWork owns cancellation of the screen's requests and prefetch tasks.
        let monthly = try await request.task.value
        try Task.checkCancellation()
        guard session == dataSessionID else { throw CancellationError() }
        return monthly
    }

    // MARK: - Private: Article Loading & Decoration

    private func updateFilteredArticles(for date: Date? = nil) async {
        let target = date ?? calendarState.selectedDate
        let session = dataSessionID
        let selectionID = latestDateSelectionID
        let articles = await loadArticles(for: target)
        guard session == dataSessionID, selectionID == latestDateSelectionID,
              !Task.isCancelled, dayKey(for: target) == dayKey(for: selectedDate) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            filteredArticles = articles
        }
        applyMonthlyAdjustment(for: target, articles: articles)
    }

    private func loadArticles(for date: Date) async -> [HomeArticle] {
        let session = dataSessionID
        let selectionID = latestDateSelectionID
        if let cached = cachedArticles(for: date) {
            return cached
        }

        do {
            let fetched = try await fetchDayArticlesUseCase.execute(
                year: formatYear(date),
                publicationMonth: formatMonth(date),
                publicationDate: formatDay(date)
            )
            let decorated = await decorateArticles(fetched)
            guard session == dataSessionID, selectionID == latestDateSelectionID,
                  !Task.isCancelled else { return [] }
            storeArticles(decorated, for: date)
            return decorated
        } catch {
            guard session == dataSessionID, selectionID == latestDateSelectionID,
                  !Task.isCancelled, !(error is CancellationError) else { return [] }
            handleError(error, feature: "home", operation: "loadArticles")
            return []
        }
    }

    private func decorateArticles(_ articles: [HomeArticle], refreshHighlightCounts: Bool = true) async -> [HomeArticle] {
        await decorateArticlesUseCase.execute(articles: articles, readIds: readArticleIds, refreshHighlightCounts: refreshHighlightCounts)
    }

    // MARK: - Private: Cache Management

    private func storeArticles(_ articles: [HomeArticle], for date: Date) {
        dayArticlesCache[dayKey(for: date)] = articles
    }

    private func cachedArticles(for date: Date) -> [HomeArticle]? {
        dayArticlesCache[dayKey(for: date)]
    }

    private func storeDataDays(_ days: Set<Int>, for date: Date) {
        let key = monthKey(for: date)
        dataDaysCache[key] = days
        touchMonthCache(key)
    }

    private func touchMonthCache(_ key: String) {
        cachedMonthOrder.removeAll { $0 == key }
        cachedMonthOrder.append(key)

        let displayedKey = monthKey(for: calendarState.displayedMonth)
        while cachedMonthOrder.count > maxCachedMonths,
              let oldest = cachedMonthOrder.first(where: { $0 != displayedKey }) {
            cachedMonthOrder.removeAll { $0 == oldest }
            evictMonth(oldest)
        }
    }

    private func evictMonth(_ key: String) {
        monthlyCache.removeValue(forKey: key)
        dataDaysCache.removeValue(forKey: key)
        let prefix = "\(key)-"
        dayArticlesCache = dayArticlesCache.filter { !$0.key.hasPrefix(prefix) }
    }

    private func applyMonthlyAdjustment(for date: Date, articles: [HomeArticle]) {
        let day = Calendar.current.component(.day, from: date)
        let key = monthKey(for: date)
        if key == monthKey(for: displayedMonth) {
            articlesByMonth = mergeDayArticleSummaryUseCase.execute(day: day, dayArticles: articles, into: articlesByMonth)
        }
        if var cache = monthlyCache[key] {
            cache = mergeDayArticleSummaryUseCase.execute(day: day, dayArticles: articles, into: cache)
            monthlyCache[key] = cache
            let days = extractArticleDaysUseCase.execute(from: cache)
            storeDataDays(days, for: date)
            if key == monthKey(for: calendarState.displayedMonth) {
                calendarState.dataDays = days
            }
        } else if key == monthKey(for: calendarState.displayedMonth) {
            let days = extractArticleDaysUseCase.execute(from: articlesByMonth)
            storeDataDays(days, for: date)
            calendarState.dataDays = days
        }
    }

    private func clearMonthlyCache(for date: Date) {
        let key = monthKey(for: date)
        cachedMonthOrder.removeAll { $0 == key }
        evictMonth(key)
    }

    // MARK: - Private: Prefetching

    private func prefetchAdjacent(from date: Date) {
        let calendar = Calendar.current
        for offset in [-1, 1] {
            guard let target = calendar.date(byAdding: .month, value: offset, to: date) else { continue }
            let key = monthKey(for: target)
            if monthlyCache[key] != nil || monthRequests[key] != nil || prefetchTasks[key] != nil { continue }
            let session = dataSessionID
            prefetchTasks[key] = Task { [weak self] in
                await self?.fetchDataDays(for: target)
                if self?.dataSessionID == session { self?.prefetchTasks.removeValue(forKey: key) }
            }
        }
    }

    @discardableResult
    private func fetchDataDays(for date: Date) async -> Set<Int> {
        let session = dataSessionID
        do {
            let monthly = try await fetchMonthlyArticles(for: date)
            guard session == dataSessionID, !Task.isCancelled else { return [] }
            return extractArticleDaysUseCase.execute(from: monthly)
        } catch {
            guard session == dataSessionID, !Task.isCancelled, !(error is CancellationError) else { return [] }
            ErrorLoggerRegistry.shared?.logError(.init(underlyingError: error, feature: "home", operation: "fetchDataDays"))
            return []
        }
    }

    // MARK: - Private: Batch Update Helper

    private func batchUpdate(_ block: () -> Void) {
        isBatchUpdating = true
        defer { isBatchUpdating = false }
        block()
    }

    // MARK: - Private: Date Helpers

    private func formatYear(_ date: Date) -> String { date.newdokYearString }
    private func formatMonth(_ date: Date) -> String { date.newdokMonthString }
    private func formatDay(_ date: Date) -> String { date.newdokDayString }

    private func strippedDate(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func startOfMonth(_ date: Date) -> Date {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? date
    }

    private func monthKey(for date: Date) -> String { date.newdokMonthKey }
    private func dayKey(for date: Date) -> String { date.newdokDayKey }
}
