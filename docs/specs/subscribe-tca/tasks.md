# Tasks: 구독 관리 TCA 전환

## 후속 구조 정리 — 사용자 승인 “수정 ㄱㄱㄱㄱ”

- [x] Feature/View/컴포넌트/테스트 이름과 폴더를 통일한다.
- [x] @Dependency 주입과 진입 View의 Store 소유를 적용하고 DIContainer를 제거한다.
- [x] 테스트와 Example을 의존성 override 방식으로 갱신한다.
- [x] Tuist 재생성, 구독 테스트·Example 빌드, Release 빌드, CodeGraph와 diff 검사를 수행한다.

## 최초 전환

- [x] View/VM/Builder/Domain/Example 호출 관계와 기존 테스트를 확인한다.
- [x] 현재 코드의 재시도·탭 전환·변경 후 재조회 문제 3개를 임시 테스트로 재현한다.
- [x] 공식 TCA 릴리스의 요구조건과 로컬 Swift/Xcode 버전을 비교한다.
- [x] spec/plan/tasks 초안을 작성한다.
- [x] 스펙 검토를 완료하고 상태를 approved로 갱신한다. 사용자 승인: “브랜치 파서 ㄱㄱ”.
- [x] Tuist에 TCA 의존성을 선언하고 `mise exec -- tuist install`, `mise exec -- tuist generate --no-open`으로 매크로/타깃 구성을 검증한다.
- [x] SubscribeFeature의 State/Action/Reducer와 조회·변경·재시도 Effect를 구현한다.
- [x] View·Row·Builder·DI·Example을 Store 기반으로 함께 전환하고 이전 ViewModel을 제거한다.
- [x] AGENTS.md에 전환된 Feature의 TCA 작성 규칙을 반영한다.
- [x] 기존 테스트의 제품 동작 검증을 보존하고 3개 재현 사례, 중복 변경, 조회 실패 후 재시도, 취소/인증 변경을 TestStore로 검증한다.
- [x] 공통 하네스로 구독 모듈 테스트 및 전체 테스트를 실행한다. 전체 테스트는 `--no-selective-testing`으로 기존 성공 결과에 따른 생략 없이 실행한다.
- [x] SubscribeExample과 `fastlane build`를 검증한다. 배포는 수행하지 않는다.
- [x] 소스 diff를 검토하고 수용 조건과 검증 결과를 기록한다. 생성물과 기존 Home·Detail 변경은 별도 변경으로 보존한다.

## 검증 결과 — 2026-11-14

| 검증 | 결과 | 로컬 기록 |
|---|---|---|
| `scripts/test.sh Subscribe --no-selective-testing` | 최종 구독 테스트 11개 통과. SubscribeExample 컴파일·링크 포함 | `/private/tmp/newdok-tca-subscribe-tests.log` |
| `scripts/test.sh --no-selective-testing` | 테스트 생략 없이 전체 207개 통과 | `/private/tmp/newdok-tca-all-tests.log` |
| `fastlane build` | Release 클린 빌드 성공, 종료 코드 0 | `/private/tmp/newdok-tca-release.log` |
| CodeGraph 갱신 및 `python3 scripts/check-codegraph.py` | 자체 Swift 소스 525개 누락·중복 없음 | `/private/tmp/newdok-tca-codegraph.log` |
| `git diff --check` | 통과 | 소스/스펙 diff 확인 |

- 전체 테스트 이후 팝업을 `item` 바인딩으로 다듬었으며, 해당 최종 코드로 구독 모듈 테스트·Example 빌드와 Release 빌드를 다시 검증했다.
- UI 문구·레이아웃·접근성·탐색 콜백은 소스 비교로 확인했다. 실기기의 수동 시각 검증은 수행하지 않았다.
- 기존 Tuist Config 경로 deprecation, Alamofire 정적 링크, 자체 정적 framework의 umbrella header 경고는 남아 있다. 이 전환에서 추가된 Swift 6 컴파일 오류나 TCA 링크 오류는 없다.
- CodeGraph는 Git에 아직 남아 있는 삭제 대상 ViewModel/이전 테스트 두 경로에 ENOENT를 기록하지만, 현재 자체 소스의 coverage 검사는 통과한다.

## 후속 구조 정리 검증 — 2026-11-14

| 검증 | 결과 | 로컬 기록 |
|---|---|---|
| `scripts/test.sh Subscribe --no-selective-testing` | 이름·주입·Store 소유 변경 후 11개 통과, SubscribeExample 컴파일·링크 성공 | `/private/tmp/newdok-subscriptions-structure-tests.log` |
| `fastlane build` | Tuist install/generate 후 앱 Release 클린 빌드 성공, 종료 코드 0 | `/private/tmp/newdok-subscriptions-structure-release.log` |
| CodeGraph 갱신 및 `python3 scripts/check-codegraph.py` | 자체 Swift 소스 525개 누락·중복 없음 | `/private/tmp/newdok-subscriptions-structure-codegraph.log` |
| `git diff --check` | 통과 | 최종 소스·스펙 diff 확인 |

- AppContainer가 앱 수명 동안 유지되며 NewDokTabView는 계정에 따라 identity가 바뀌는 것을 확인했다. Store는 Builder에 영구 캐시하지 않고 내부 SubscriptionsRootView의 State로 보관한다. 화면의 SubscriptionsView는 let Store를 관찰한다.
- 기존 UseCase/Repository와 업무 상태 전이는 유지했다. DIContainer를 제거하고 Builder에서 단일 Repository와 UseCase를 TCA 의존성으로 조립한다.
- 이번 후속 변경은 Subscribe 내부에 한정되어 모듈 테스트와 앱 빌드를 실행했다. 위 전체 207개 결과는 최초 전환 당시의 기록이다. 실기기 수동 UI 검증은 수행하지 않았다.
- 생성된 프로젝트·scheme diff와 기존 Home·Detail 등 요청 범위 밖의 변경은 그대로 보존했다.

## PR 병합 전 검증 — 2026-11-15

- 최종 구독 구조와 Home·Detail 개선, 계측 직렬화 함수 분리까지 포함하여 `scripts/test.sh --no-selective-testing`으로 전체 207개 테스트가 통과했다. 기록: `/private/tmp/newdok-pr-final-tests.log`.
- `fastlane build`로 Tuist install/generate 및 Release 클린 빌드를 다시 실행했고 종료 코드 0으로 성공했다. 기록: `/private/tmp/newdok-pr-final-release.log`.
- CI와 같은 SwiftLint 0.62.2에서 오류 0개, 경고 156개를 확인했다. 기록: `/private/tmp/newdok-pr-swiftlint.json`.
- CodeGraph 갱신 후 자체 Swift 소스 525개에 누락·중복·제외 경로 유입이 없음을 확인했다.
- 생성된 프로젝트·scheme·xcconfig는 PR에서 제외했다. 실기기 수동 UI 검증은 수행하지 않았다.
