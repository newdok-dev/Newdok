# 렌더링·화면 준비 시간 점검 — 2026-11-13

후속 진행: 홈 첫 표시·달력 요청·이전 응답 차단은 구현했고, 홈 테스트 32개를 통과했다. [홈 구현·검증 결과](home-first-display-analysis.md)를 참고한다. 아래 표는 구현 전 점검 시점의 기록이다.

원격 갱신 후 `feat/product-analytics`의 `5d975916`을 기준으로 점검했다. 로컬과 `origin/feat/product-analytics`의 차이는 0/0이고, 최신 `origin/develop`인 `364dfee7`도 포함한다. 추가 병합은 필요하지 않다.

CodeGraph로 연결 관계를 찾고 실제 View, ViewModel, UseCase, DI 원문을 대조했다. 아래는 코드에서 확인한 개선 후보다. 실기기 Instruments 측정 전이므로 시간·메모리 개선율이나 실제 프레임 드롭을 확정하지 않는다. 기존 작업 파일은 보존했고 이번 점검에서 추가한 파일은 이 문서뿐이다.

**우선순위 표**

P1은 먼저 수정·비교할 항목, P2는 다음 순서, P3는 계측 결과에 따라 판단할 항목이다. 위험도는 변경 시 기능 회귀 가능성을 뜻한다.

| 우선순위 | 영역 | 코드에서 확인한 문제 | 개선 방향 | 기대 효과·확인할 지표 | 위험도 |
|---|---|---|---|---|---|
| P1 | 홈 첫 표시 | 오늘 데이터를 저장한 직후 같은 월의 일별 캐시를 삭제한다. 월 조회와 다시 하는 일별 조회가 끝나야 기사 상태를 표시한다. | 캐시 무효화를 새 데이터 저장 전에 수행하고, 오늘 기사·구독 정보를 먼저 표시한 뒤 달력을 갱신한다. | 오늘 진입의 불필요한 일별 요청 제거, 기사 표시까지 기다리는 요청 수 감소 | 중간: 달력·오류·계측 상태를 함께 보존 |
| P1 | 공통 GIF | `makeUIView`에서 파일을 동기 읽기하고 MainActor에서 전체 프레임 이미지를 생성·보관한다. 실제 리소스는 500×500, 75프레임이며 표시 크기는 50pt다. | 설치된 Kingfisher의 애니메이션 지원을 검토해 비동기 로딩·제한된 프레임 버퍼를 사용한다. 실제 픽셀 축소는 별도 검증한다. | 첫 로딩 표시의 메인 스레드 작업·최대 메모리 감소 후보 | 중간: 재생 속도·반복·화면 이탈 처리 |
| P1 | 검색·북마크·브랜드 목록 | 검색 결과와 브랜드 기사에 일반 `VStack`을 사용한다. 북마크는 월 단위만 lazy이고 그 안의 기사 전체를 한꺼번에 구성한다. | 많은 항목을 넣어 비교한 후 행 단위 lazy 구조로 변경한다. 북마크는 월 헤더와 행이 바깥 lazy 컨테이너에 직접 참여하도록 구성한다. | 첫 화면에서 구성하는 행 수, 스크롤 hitch, 메모리 | 낮음~중간: 간격·높이 추정·스크롤 위치 |
| P1 | 홈 비동기 상태 반영 | 월 요청의 최신 여부를 확인하기 전에 내부 함수가 표시 월을 바꾼다. 하이라이트 갱신은 await 뒤의 선택 날짜에 이전 기사 결과를 저장할 수 있다. | 요청 시작 시 날짜·세션·요청 식별자를 고정하고 UI 반영 직전에 검증한다. 화면 작업은 `.task` 계열로 수명을 연결한다. | 늦은 응답으로 화면이 되돌아가는 현상과 중복 작업 방지 | 중간~높음: 빠른 날짜 전환·로그인 전환 회귀 테스트 필요 |
| P2 | 탐색 캐러셀 | 끝에 가까워질 때마다 원본 배열을 `dynamicItems`에 추가하며 상한이 없다. | 제한된 반복 구간을 재사용하고 위치를 재배치한다. | 장시간 넘기기에서 데이터 수·메모리가 계속 증가하는 경로 제거 | 중간: 경계 이동·스크롤 애니메이션 |
| P2 | 추천 정렬·태그 | 정렬 비교의 동점에서 `Bool.random()`을 반환한다. 태그 구성은 View 평가 중 사용자 정보를 디코딩하고 남은 태그를 다시 섞는다. | 새 추천을 만들 때 한 번만 섞고 점수를 미리 계산해 일관된 비교로 정렬한다. 태그 표시 순서도 추천 갱신 시 고정한다. | 비교 규칙 준수, 불필요한 디코딩·계산과 태그 순서 흔들림 방지 | 낮음~중간: 추천 무작위성의 의미 보존 |
| P2 | 약관 WebView | `updateUIView`가 호출될 때마다 같은 URL을 다시 `load`한다. | Coordinator에 마지막 요청 URL을 보관하고 실제 URL 변경 때만 로드한다. | 같은 URL 반복 로드·스크롤 초기화 방지 | 낮음: 리다이렉트 뒤에도 원래 요청 URL 기준으로 비교 |
| P2 | 기사 WebView | 업데이트마다 HTML 전체를 연결한 키를 만들고, 문서를 만들 때마다 번들 JS 두 개를 동기 읽기한다. | 불변 JS를 한 번 로드한다. 문서 입력·변경 시점에 맞는 식별자를 사용해 불필요한 큰 문자열 생성을 줄인다. | 긴 본문에서 업데이트 CPU·할당 및 반복 파일 읽기 감소 후보 | 중간: 같은 기사 ID의 내용 변경과 글꼴·하이라이트 갱신 보존 |
| P3 | 당겨서 새로고침 | 스크롤 위치 전체를 `CGFloat`로 관찰해 값이 바뀔 때마다 콜백을 실행한다. | 실제 필요한 상태(원위치·당기는 중·임계 초과)로 변환한다. cooldown 만료 후 임계 위에 머무는 경우의 기존 동작도 검증한다. | 스크롤 중 콜백 수 감소; 전체 View 재렌더 감소 여부는 별도 계측 | 낮음~중간: 연속 당기기 동작 |

추천 정렬의 동점 무작위 판정은 비교 결과의 일관성을 보장하지 않는다. 표준 라이브러리는 비교 함수에 strict weak ordering을 요구한다. [sorted(by:)](https://developer.apple.com/documentation/swift/array/sorted%28by%3A%29)

**코드 근거**

| 항목 | 파일과 위치 | 확인한 실행 경로 |
|---|---|---|
| 홈 캐시·표시 순서 | [HomeViewModel.swift](../Modules/Features/Home/Sources/Home/HomeViewModel.swift), 195–224, 463–478, 518–523, 545–549행 | `storeArticles → clearMonthlyCache → evictMonth`에서 방금 저장한 날짜가 제거된다. 이후 `loadMonthInternal → updateFilteredArticles → loadArticles`가 일별 API를 다시 호출한다. |
| 홈 중복 장식 | [HomeView.swift](../Modules/Features/Home/Sources/Home/HomeView.swift), 101–120행; [HomeViewModel.swift](../Modules/Features/Home/Sources/Home/HomeViewModel.swift), 202, 361–367행 | 최초 `loadToday`에서 장식한 후 `onAppear` 작업이 `refreshHighlights`를 다시 실행한다. 복귀 시 갱신과 최초 장식을 구분할 수 있다. |
| 홈 오래된 응답 | [HomeViewModel.swift](../Modules/Features/Home/Sources/Home/HomeViewModel.swift), 245–267, 361–367, 389–447행 | `loadMonthInternal`이 상태를 반영한 뒤 호출자가 최신 요청을 검사한다. `refreshHighlights`는 입력 날짜를 await 전에 보관하지 않는다. |
| GIF | [LoadingView.swift](../Modules/DesignSystem/Sources/Component/LoadingView.swift), 45, 59–91행 | MainActor 캐시 미스에서 파일 읽기 및 전체 프레임 생성을 수행한다. [load.gif](../Modules/DesignSystem/Resources/load.gif)의 GIF 블록을 직접 읽어 75프레임·497,265바이트를 확인했다. 이 파일 크기는 런타임 메모리 사용량이 아니다. |
| 검색 목록 | [SearchView.swift](../Modules/Features/Search/Sources/Search/SearchView.swift), 221–240행 | 일반 `VStack` 안에서 검색 결과 전체 `ForEach`를 구성한다. |
| 북마크 목록 | [BookmarkView.swift](../Modules/Features/Bookmark/Sources/Bookmark/BookmarkView.swift), 57–61, 196–213행 | 월은 `LazyVStack`, 각 월의 기사 묶음은 일반 `VStack`이다. |
| 브랜드 기사 목록 | [BrandArticleListSection.swift](../Modules/Features/Detail/Sources/Brand/Component/BrandArticleListSection.swift), 10–30행 | 일반 `VStack` 안에 전체 기사 행이 있다. |
| 캐러셀 | [PagingScrollView.swift](../Modules/Features/Explore/Sources/Explore/Component/PagingScrollView.swift), 23–40, 71–80행 | 처음에는 원본의 3배로 만들고 이동 중 계속 append한다. lazy 표시가 데이터 배열 크기를 제한하지는 않는다. |
| 추천 정렬 | [TransformExploreRecommendationUseCaseImpl.swift](../Modules/Features/Explore/Sources/UseCase/TransformExploreRecommendationUseCaseImpl.swift), 18–28행 | 매 비교에서 관심사 일치 수를 다시 계산하고 동점 순서를 무작위로 판정한다. |
| 태그 계산 | [ExploreRecommendationSection.swift](../Modules/Features/Explore/Sources/Explore/Component/ExploreRecommendationSection.swift), 33–38행; [ExploreViewModel.swift](../Modules/Features/Explore/Sources/Explore/ExploreViewModel.swift), 226–229행; [PrioritizeInterestsUseCaseImpl.swift](../Modules/Features/Explore/Sources/UseCase/PrioritizeInterestsUseCaseImpl.swift), 6–13행 | 행 구성 → `userInfoStore.load()` → 관심사 필터·shuffle. [UserInfoStore.swift](../Modules/Shared/Sources/Store/UserInfoStore.swift), 20–22행에서 매번 PropertyList를 디코딩한다. 추천 목록은 현재 최대 6개이므로 비용을 과장하지 않는다. |
| 약관 WebView | [PolicyWebSheetView.swift](../Modules/Features/Auth/Sources/Signup/Popup/PolicyWebSheetView.swift), 51–61행 | 입력 변경 검사 없이 `updateUIView`에서 `load`한다. |
| 기사 문서 생성 | [ArticleWebView.swift](../Modules/Features/Detail/Sources/Article/Component/ArticleWebView.swift), 92–117행; [ArticleHighlightJS.swift](../Modules/Features/Detail/Sources/Article/ArticleHighlightJS.swift), 4–14행 | 본문 연결 키 생성과 computed `coreScript`의 동기 파일 읽기를 확인했다. |
| 스크롤 관찰 | [PullToRefreshView.swift](../Modules/DesignSystem/Sources/Component/PullToRefreshView.swift), 46–69행 | 연속 offset 변화를 받아 임계값·cooldown을 검사한다. 모든 콜백이 전체 화면 재렌더를 일으킨다는 의미는 아니다. |

**홈의 권장 표시 순서**

1. 오늘 기사와 구독 정보를 병렬로 가져온다.
2. 필요한 기존 캐시를 무효화한 뒤 새 오늘 기사를 저장한다.
3. 오늘 기사와 해당 목록의 계측 상태를 함께 반영한다.
4. 월 달력 데이터를 갱신한다. 달력의 로딩·실패는 이미 표시한 기사와 구분한다.
5. 인접 월 미리 가져오기는 중복 요청을 합치고 현재 요청을 방해하지 않게 수행한다.

렌더링 순서를 임의 지연이나 Task 우선순위로 조절하기보다, 첫 화면에 필요한 데이터가 준비되는 즉시 상태를 확정하는 변경이 먼저다. 현재 215–224행에서는 달력·일별 조회가 기사 표시를 막고 있다.

**현재 개선되어 있는 부분과 보존할 동작**

| 항목 | 확인 결과 |
|---|---|
| 시작 화면 | [AppRootView.swift](../Modules/App/Sources/Root/AppRootView.swift), 29–41행에는 고정 sleep이나 탐색 옵션 API를 기다리는 단계가 없다. 이전 시작 지연 지적을 현재 문제로 중복 집계하지 않는다. |
| Swift 6 | [ProjectHelper.swift](../Tuist/ProjectDescriptionHelpers/ProjectHelper.swift), 12–13행의 공통 설정은 Swift 6.0 / strict concurrency complete다. 이번 작업은 설정·원문 점검이며 새 컴파일 결과를 의미하지 않는다. |
| 사용자 행동 계측 | [AnalyticsClient.swift](../Modules/Shared/Sources/Analytics/AnalyticsClient.swift), 133–172행은 화면 가시성·scenePhase·목록 키로 이벤트를 제어한다. 홈 표시 시점을 앞당길 때 `analyticsList`, 날짜, ready 상태도 맞춰야 한다. |
| 사용자별 화면 수명 | [NewDokTabView.swift](../Modules/App/Sources/Tabs/NewDokTabView.swift), 197행의 사용자별 `.id`는 계정 전환 시 화면 상태를 재생성한다. 단순 렌더 최적화를 이유로 제거하지 않는다. |
| Observation | 내부 캐시와 Task의 관찰 제외는 실제 View 읽기 의존성을 확인한 뒤 판단한다. `@Observable` 속성이라는 이유만으로 모든 변경이 모든 View를 갱신한다고 단정하지 않는다. |

**변경 후 검증 기준**

| 변경 | 기능 검증 | 성능 비교 |
|---|---|---|
| 홈 | 오늘 진입 일별 요청 수, 지연된 월 응답, 빠른 날짜·계정 전환, 하이라이트 복귀, 오류 후 재시도, 목록 이벤트 연결 | 같은 입력·네트워크 조건에서 기사 준비 시점과 달력 준비 시점을 분리해 측정 |
| 목록 | 항목 ID·클릭·접근성·월 간격·스크롤 복귀 유지 | 같은 데이터의 짧은 목록과 긴 목록을 구분해 첫 표시 행 수·hitch 측정 |
| GIF | 첫 프레임, 반복 재생, 이탈·복귀, 접근성 | cold/warm 로드별 메인 스레드 시간과 메모리 최대치 |
| 탐색 | 동점 정렬 비교의 일관성, 새로고침 무작위성, 캐러셀 경계, 태그 표시 유지 | 반복 넘기기 전후 데이터 개수·메모리, body 계산 비용 |
| WebView | 같은 입력 반복 업데이트, URL·기사 내용 변경, 리다이렉트, 글꼴·하이라이트 동작 | navigation 횟수, 긴 HTML 업데이트의 시간·할당 |

프로덕션 코드를 수정할 때는 저장소 규칙에 따라 해당 모듈 테스트를 실행한다. DesignSystem 또는 여러 모듈에 걸친 변경은 `./scripts/test.sh` 전체 테스트, Release 검증은 `fastlane build`를 사용한다. 문서만 추가한 이번 점검에서는 빌드·테스트를 실행하지 않았다.

긴 목록의 lazy 전환 여부는 실기기 프로파일링으로 비교하는 것이 Apple의 권장 방식이다. [Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)

스크롤 관찰 값은 필요한 상태로 변환할 수 있으며, 변환 값이 달라질 때 action이 실행된다. [onScrollGeometryChange](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:))
