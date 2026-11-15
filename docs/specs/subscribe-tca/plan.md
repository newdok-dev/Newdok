# Plan: 구독 관리 TCA 전환

## 영향 모듈

- `Subscribe`: ViewModel을 `SubscriptionsFeature`로 대체하고 View·Row·Builder·DI·Tests·Example을 함께 전환한다.
- `SubscribeDomain`, `SubscribeData`: 기존 모델과 UseCase/Repository를 재사용한다. State 비교에 필요한 모델의 합성 Equatable 적합성만 필요 시 추가한다.
- `Tuist/Package.swift`, `Modules/Features/Subscribe/Project.swift`: TCA와 필요한 테스트/Example 의존성을 선언한다.
- `AGENTS.md`: 구현 시 승인된 TCA Feature의 상태 소유 규칙을 기록한다. 미전환 화면의 기존 규칙은 유지한다.
- 기존 `SubscribeBuildable`과 App의 탐색 콜백은 유지한다. 새 Feature/Core 타깃은 만들지 않는다.

## 일관된 작성 규칙

| 책임 | 규칙 |
|---|---|
| 화면 상태 | `@Reducer SubscriptionsFeature` 안에 `@ObservableState State` 정의 |
| 입력 | 사용자 행동과 비동기 결과를 `Action`으로 표현 |
| 상태 변경 | Reducer에서 처리. View는 Store를 관찰하고 Action 전달 |
| 비동기 작업 | `.run`과 TCA 취소 기능 사용. View에서 업무 Task를 연쇄 실행하지 않음 |
| 의존성 | Builder에서 기존 UseCase를 조립하고 TCA DependencyValues에 주입. Client는 네 가지 비동기 호출을 연결하는 값이며 자체 상태·업무 로직·Repository 조립을 갖지 않음 |
| 테스트 | Swift Testing + TestStore. 응답 순서는 continuation, 시간은 TestClock으로 제어 |
| 표현 상태 | 스크롤·포커스·애니메이션 등 일시적 UI 상태는 View에 둘 수 있음 |

화면마다 State/Action/Reducer/Effect를 정의하는 규칙을 공유한다. 기능마다 같은 모양의 추상 클래스나 공용 상태 머신을 강제하지 않는다.

## 상태와 이벤트

- 탭은 `.active`, `.paused` enum으로 표현한다. 선택 탭, 각 목록과 조회 상태, 실패한 작업, 변경 중인 구독을 Feature State가 소유한다.
- 주요 입력은 화면 진입/종료, 인증 변경, 탭 선택, 새로고침, 중지 확인, 재개, 재시도다.
- 조회·변경 응답은 의미 있는 결과 Action으로 받아 현재 상태와 함께 판단한다.
- 중지 확인 대상과 성공 알림을 Feature가 관리한다. 기존 PopupView/DesignSystem 표현을 재사용한다.
- 분석용 목록 문맥은 실제 채택한 목록과 함께 갱신한다. 화면/목록 관찰 modifier와 AnalyticsClient는 기존 것을 재사용한다.

## 요청 처리 정책

1. 두 탭 조회는 탭별 취소 키로 관리한다. 하나의 전역 갱신 플래그로 다른 탭 요청을 버리지 않는다.
2. 초기 로드와 탭별 재조회는 동일한 조회 처리 함수를 사용하고, 초기 로드 완료 여부가 재시도를 차단하지 않는다.
3. 중지·재개 성공은 Reducer에서 해당 항목의 목록 상태를 일관되게 반영하고, 변경 이전에 시작한 조회를 정리한 뒤 필요한 재조회를 수행한다.
4. 변경 중/변경 직후의 이전 응답 처리 정책을 회귀 테스트로 고정한다. `.cancellable`만 추가하면 모든 늦은 응답이 안전해진다고 가정하지 않는다. 단순한 작업 순서와 취소 검사를 우선하며 별도 응답 식별 체계는 검증상 필요할 때만 도입한다.
5. 실패 작업은 명시적 enum으로 보관한다. 중지 성공 후 조회 실패와 중지 자체의 실패를 구분하여 재시도한다.
6. View의 `.task`를 Store 작업 수명에 연결한다. 인증 변경·이탈 시 조회와 변경 Effect를 정리하고 이전 상태 반영을 차단한다.

## 의존성 / 도구 검토

2026-11-14 확인 기준 공식 최신 릴리스는 TCA 1.26.2다. 해당 태그의 기본 manifest는 Swift tools 6.4, iOS 16 이상, 라이브러리 Swift 6 모드를 사용하며 버전별 manifest도 제공한다. 로컬은 Xcode 27.2 / Swift 6.4.2이며 앱 최소 버전은 iOS 18이다. 아래 호환 설정을 반영한 뒤 Tuist 매크로·링크와 SubscribeExample의 실제 빌드를 검증했다.

- 첫 도입 후보를 1.26.2로 고정하여 검증하고 resolved 파일에 재현 가능한 의존성을 남긴다.
- 설치 후 확인한 swift-collections 1.7.6의 `strictMemorySafety` manifest 설정을 Tuist 4.143.0이 해석하지 못한다. 해당 설정 이전의 호환 릴리스 1.7.1로 collections를 제한하고 도구 버전과 자체 코드 안전성 설정은 유지한다.
- TCA의 외부 의존성은 iOS 16, 매크로/SwiftSyntax 호스트 타깃은 macOS 13으로 설정한다. Perception은 iOS 17에서 obsoleted 된 백포트를 포함해 패키지 전체를 iOS 18로 올릴 수 없다. 자체 타깃의 iOS 18 기준은 유지하며, 최신 Xcode가 지원하지 않는 패키지의 과거 deployment target만 manifest의 targetSettings에서 조정한다.
- Tuist 4.143.0은 default trait를 컴파일 조건에는 확장하지만 의존성 연결 시에는 확장하지 않는다. Dependencies·Navigation·Sharing의 기본 trait를 루트 manifest에 명시해 필요한 모듈의 빌드 순서를 보장한다. trait 선언을 위해 패키지 manifest의 tools 버전만 6.1로 올리며 자체 타깃의 Swift 언어 모드는 6.0을 유지한다.
- TCA 의존성은 필요한 Feature/Tests/Example 타깃에만 선언한다. Domain에 TCA를 유입하지 않는다.
- Tuist의 기존 외부 의존성 선언 방식을 사용하고 중복 정적 링크 여부를 검증한다. 패키지 매크로를 포함한 실제 생성·빌드 결과로 제품 타입을 결정한다.
- 자체 타깃의 Swift 6 및 strict concurrency 설정을 낮추지 않는다.
- ErrorHandling은 클래스/메인 액터 기반이므로 Reducer에 강제 적용하지 않는다. 기존 오류 변환·로깅 API를 재사용하고 UI 분석 기록의 MainActor 경계를 명시한다.
- 공식 근거: [1.26.2 릴리스](https://github.com/pointfreeco/swift-composable-architecture/releases/tag/1.26.2), [태그 manifest](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/Package.swift), [State/Action/Reducer/Store 및 TestStore 설명](https://github.com/pointfreeco/swift-composable-architecture/blob/1.26.2/README.md).

## 승인된 이름 / 의존성 정리

- `Sources/SubscriptionsFeature.swift`, `SubscriptionsView.swift`로 화면 파일을 평탄화한다. 내부 타입도 파일 이름과 일치시킨다.
- 행·빈 화면·탭 컴포넌트는 `Sources/Components/`로 모은다. 모듈 이름과 App 연결용 `SubscribeBuildable`은 유지한다.
- `Dependencies/SubscriptionsClient.swift`는 `@DependencyClient`와 `TestDependencyKey`로 조회·중지·재개 호출을 정의한다. live 구현은 전역 네트워크를 생성하지 않고 Builder가 기존 UseCase에서 연결한다. AnalyticsClient도 Feature 내부 DependencyValues에 등록하며 Shared의 타입은 변경하지 않는다.
- `Integration/SubscribeBuilder.swift`가 Repository 하나와 기존 UseCase, Store를 조립한다. 별도 SubscribeDIContainer를 제거한다. 파일 내부의 진입 View가 `@State`로 Store를 소유해 화면 identity가 유지되는 동안 재사용하고 계정 변경 시 새로 생성한다. AppContainer가 앱 수명 동안 유지되는 구조이므로 Builder 자체에 Store를 캐시하지 않는다.
- View는 `let StoreOf<SubscriptionsFeature>`를 관찰한다. Example은 진입 App에서 Store를 한 번 생성한다. 테스트는 `withDependencies`에서 호출을 교체한다.
- 기존 상태 전이·취소 정책·UI 문구·탐색 동작은 유지한다.

## 위험 / 트레이드오프

- 패키지와 매크로 의존성이 추가되어 초기 빌드 비용과 라이브러리 업데이트 관리가 생긴다.
- TCA 도입만으로 조회 정책·동시성 오류·렌더링 비용이 해결되지는 않는다. 수용 조건 테스트와 기존 동작 보존으로 평가한다.
- 한 화면 안의 상태 소유권은 전환 시 완결한다. 다른 화면으로의 확장은 구독 전환 검증 후 별도 변경으로 진행한다.
