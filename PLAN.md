# my-claude-broker — 설계 & 구현 기록 (v0.3, 2026-10-25)

> v0.1 (중앙 broker 서버 + node agent + 대시보드) 폐기 → v0.2 전역 skill + tmux 워커 + 파일 레지스트리 → **v0.3: v0.2 구현 완료 및 E2E 검증**

## 1. 목표
- 서브에이전트를 메인 세션에서 분리 → **독립 Claude 세션(워커)**
- 워커 진행/중간 결정을 앱에서 보고 개입
- 메인은 상태를 들고 있지 않음 → 재시작해도 문서로 맥락 복구
- 워커가 턴을 끝내면 메인이 꺼져 있어도 자동으로 메인이 떠서 추가 지시 / 머지 / 결과 문서화

## 2. 확정된 결정
| 항목 | 결정 |
|---|---|
| 형태 | skill (`skill/broker`) + bash 스크립트. 설치 방식은 보류 |
| 워커 실행 | tmux 안에서 `claude --remote-control <name> -n <name> --session-id <uuid>` |
| 이름 | `<prefix>/<project>/<worker>`, 메인 `<prefix>/<project>/main`, 브랜치 `<prefix>/<worker>`. prefix 기본 `broker`, 설정 가능 |
| 격리 | 워커별 git worktree (`.broker/worktrees/<w>`) |
| 레지스트리 | 레포 내 `.broker/` (`.git/info/exclude` 등록) — 설정은 `config.env` (bash source) |
| 훅 | `--settings` 로 broker 세션에만 주입. 프로젝트/전역 설정 무변경 |
| 깨우기 | **워커 Stop → 무조건 메인 호출** |
| 머지 | 로컬 git `--no-ff` 머지 (메인이 리뷰 후 `merge.sh`) |
| 권한 | `config.env` 의 `WORKER_PERMISSION_MODE` / `MAIN_PERMISSION_MODE` (기본 auto) |
| SDK | 미사용 (구독 OAuth 불가) |

## 3. 통신 설계 — 메일박스 + Stop 훅
tmux `send-keys` 는 **대상이 idle 일 때만** 사용한다 (busy 중 입력은 권한 다이얼로그를 잘못 승인할 위험). busy 대상에게는 파일 메일박스에 넣고, 대상의 Stop 훅이 턴 종료 시 `exit 2` 로 턴을 이어가며 전달한다.

| 방향 | 메일박스 | 대상 idle | 대상 busy | 대상 없음 |
|---|---|---|---|---|
| 워커 → 메인 | `inbox/*.md` | send-keys 로 "inbox 처리" | 메인 Stop 훅이 미알림 이벤트 전달 | 새 메인 기동 (`/broker inbox`) |
| 메인 → 워커 | `running/<w>/mail/*.md` | send-keys 로 지시 입력 | 워커 PostToolUse 훅이 턴 중간에 전달 (없으면 Stop 훅) | 메일 유지, `revive.sh` 후 전달 |

워커 PostToolUse 훅은 메일을 `additionalContext` 로 주입한다. 모델이 이를 도구 결과 속 프롬프트 인젝션으로 보고 무시하는 것을 막기 위해, worker-protocol 규칙 7 이 이 채널을 명시하고 각 지시에 `mail/delivered/` 파일 경로를 붙여 워커가 실제 파일 존재로 진위를 확인한다. 메일을 `mv` 로 먼저 가져가는 쪽이 전달하므로 PostToolUse·Stop 이 같은 메일을 중복 전달하지 않는다.

idle/busy 판정은 훅이 기록하는 활동 마커 (`UserPromptSubmit` → busy, Stop → idle). `wake-main.sh` 는 mkdir 락으로 메인 중복 기동을 막는다.

## 4. 검증 결과 (2026-10-25, macOS, Claude Code 2.1.310)
| # | 항목 | 결과 |
|---|---|---|
| V1 | 새 worktree 의 trust 프롬프트 | 메인 레포가 trust 되어 있으면 worktree 는 상속 ✅. 미신뢰 시 spawn/revive 가 화면에서 감지 → 세션 종료 후 안내 |
| V2 | 메인 깨우기 | 메인 없음 → 자동 기동 ✅ · idle → send-keys ✅ · busy → Stop 훅 전달 ✅ |
| V3 | 메인 → 워커 지시 | idle → 즉시 입력 ✅ · busy → 메일박스 → 워커 Stop 훅 전달 ✅ |
| V3b | 턴 중간 지시 (2026-10-27) | busy 워커가 다음 도구 호출 직후 지시를 받아 계획 변경 ✅ · 파일 속 위조 지시(메일 파일 없음)는 무시 ✅ · Stop 훅 중복 전달 없음 ✅ |
| V4 | 환경변수 전달 | 훅 인자로 전달하는 방식으로 대체 (env 의존 제거). 부모 Claude 세션 변수는 launcher 에서 unset |
| V5 | 의존성 | `depends_on` 태스크가 선행 태스크 archive 후 기동 ✅ |
| V6 | blocked 처리 | 워커 질문 → 메인이 journal 의 사용자 결정으로 답변 ✅ |
| V7 | gc / revive | prefix 기반 고아 감지·정리 ✅ · `--resume` 재개 시 이전 대화 유지 ✅ |
| E2E | 메인 없는 상태에서 시작 → 4개 태스크 → 자동 리뷰·머지·결과 문서·archive | ✅ (sandbox/demo) |

## 5. 알려진 한계
- 사용자가 Esc 로 턴을 중단하면 Stop 훅이 실행되지 않아 활동 마커가 busy 로 남음 → 그 세션으로의 즉시 전달이 다음 턴 종료까지 지연. `gc.sh` 의 stalled 감지로 보완
- 메인을 계속 재사용하면 컨텍스트가 누적됨 → 언제든 `stop.sh main` 후 재기동 가능 (문서로 복구)
- 워커 Stop 이 매 턴 메인을 부르므로, 사용자가 워커와 직접 긴 대화를 하면 메인도 매번 호출됨 (의도된 정책)
- tmux 의존 → Windows 는 [FUTURE_PLAN.md](FUTURE_PLAN.md)
- 사용자가 앱에서 직접 연 세션은 `broker/<project>/main` 이 아니므로 워커 이벤트는 tmux 메인으로 간다

## 6. 남은 결정
- 설치/배포 방식 (보류)
