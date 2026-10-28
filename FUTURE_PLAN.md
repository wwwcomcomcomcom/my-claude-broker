# Future plan

## 1. tmux 를 쓰기 어려운 환경 (Windows)

### 1.1 tmux 가 맡고 있는 역할
현재 구현에서 tmux 를 대체하려면 아래 다섯 가지를 각각 대신할 수단이 필요하다.

| 역할 | 현재 구현 | 사용 위치 |
|---|---|---|
| 호스팅 | `tmux new-session -d` — 부모(메인/훅)가 끝나도 세션 유지 | spawn, revive, start_main |
| 이름 기반 조회 | `tmux has-session -t =<name>`, `tmux ls` | 모든 생존 판정, gc |
| 입력 주입 | `tmux send-keys` (idle 대상에게만) | wake-main(메인 idle), send.sh(워커 idle) |
| 화면 확인 | `tmux capture-pane` | peek.sh, 신뢰 확인 창 감지 |
| 종료 | `tmux kill-session` | stop, finalize, gc |

이 외에 Windows 에서 따로 확인해야 하는 것: bash 스크립트 실행 환경, 훅에서 백그라운드 프로세스 분리(`nohup ... &`), `uuidgen`/`find -mmin` 등 유틸리티, 경로(드라이브 문자·공백·역슬래시).

### 1.2 선택지

**A. WSL2 에서 그대로 실행 (단기 권장)**
- WSL2 Ubuntu 에 Claude Code · tmux · git 설치 후 현재 skill 을 수정 없이 사용.
- Claude Code 는 WSL2 를 지원하고, cross-session messaging 도 WSL2 에서 동작한다.
- 주의
  - 레포는 Linux 파일시스템(`~/...`)에 둘 것. `/mnt/c` 는 git/파일 I/O 가 느리다.
  - WSL VM 이 idle 로 종료되면 워커도 죽는다 → `.wslconfig` 의 `vmIdleTimeout` 조정 또는 상시 실행 유지.
  - Windows 전용 툴체인(MSBuild, Windows SDK 등)이 필요한 프로젝트에는 맞지 않는다 → B 필요.

**B. `claude --bg` 백그라운드 세션으로 tmux 대체 (네이티브 Windows, 중기)**
Claude Code 자체 기능으로 tmux 의 역할 대부분을 대신할 수 있다. macOS 에서 `claude --bg --remote-control <name> -n <name> "<prompt>"` 로 백그라운드 + Remote Control + 초기 프롬프트가 함께 동작하는 것은 확인했다.

| 역할 | 대체 수단 | 검증 필요 |
|---|---|---|
| 호스팅 | `claude --bg ...` (백그라운드 서비스가 세션 유지) | Windows 에서 `--bg` + `--remote-control` 조합 |
| 조회 | `claude agents --json` (name, sessionId, status busy/idle, state) | status 가 활동 마커를 대체할 만큼 정확한지 |
| 입력 주입 | ① `claude --bg --resume <id> "<msg>"` (같은 ID 로 백그라운드 재개) ② cross-session messaging (`SendMessage`, Windows 는 v2.1.234+, named pipe) | ① 실행 중(idle) 세션에 쓸 수 있는지, 아니면 "사본 시작"이 되는지 ② 스크립트에서 메시지 보내는 방법(문서화 안 됨) |
| 화면 확인 | `claude logs <id>` | 출력 형식(ANSI 포함) 정리 필요 |
| 종료 | `claude stop <id>` / `claude rm <id>` | — |

- 신뢰 확인 창 감지는 `claude logs` 출력에서 같은 문구를 찾는 방식으로 옮긴다.
- 장점: tmux 의존이 사라지고 macOS/Linux 에서도 같은 백엔드를 쓸 수 있다. `claude agents --json` 이 상태를 주므로 직접 관리하는 활동 마커를 줄일 수 있다.
- 단점: 터미널에서 바로 붙어 보는 경험(`tmux attach`)은 `claude attach` 로 바뀐다. 입력 주입 방식이 검증되기 전까지는 "메일박스 + Stop 훅" 전달에만 의존해야 한다 (idle 대상에게 즉시 전달 불가 → 메인 idle 시 새 메인을 띄우는 방식으로 우회 가능).

**C. 네이티브 터미널 멀티플렉서 대체 (보류)**
Windows Terminal 탭, ConPTY 기반 도구 등은 `send-keys`/`capture-pane` 에 해당하는 스크립트 인터페이스가 약하다. B 가 막힐 때만 검토한다.

### 1.3 구현 계획
1. **러너 추상화** — `lib.sh` 에 tmux 호출을 모아 함수로 분리하고 `config.env` 에 `RUNNER=tmux|bg` 추가.
   ```
   runner_start <name> <cwd> <launcher>   runner_alive <name>   runner_list
   runner_type <name> <text>              runner_peek <name> [N]  runner_kill <name>
   ```
   현재 스크립트의 `tmux ...` 직접 호출(spawn, revive, start_main, wake-main, send, peek, stop, finalize, gc, list)을 이 함수들로 교체한다. 동작 변화 없는 리팩터링이므로 macOS 에서 기존 E2E 로 회귀 확인.
2. **bg 러너** — 위 표의 검증 항목을 macOS 에서 먼저 확인한 뒤 `RUNNER=bg` 구현. `runner_type` 이 불가능하면 "idle 메인 → 종료 후 새 메인 기동", "idle 워커 → `--bg --resume <id> <msg>`" 로 대체.
3. **Windows 실행 환경**
   - Claude Code 네이티브 Windows 는 Git for Windows(Git Bash)를 사용하므로 스크립트는 Git Bash 에서 실행하는 것을 1차 목표로 한다. 훅 command 가 Windows 에서 어떤 셸로 실행되는지 확인하고, 필요하면 `bash '<path>/hook.sh' ...` 형태로 명시한다.
   - 대체 필요 항목: `nohup ... &` → Git Bash 의 백그라운드 실행 또는 `powershell Start-Process`, `uuidgen` → `python3`/PowerShell `[guid]::NewGuid()` (lib.sh 에 이미 python3 fallback 있음), 경로 처리(`cygpath`).
4. **장기 옵션** — 스크립트가 커지면 bash 대신 단일 크로스플랫폼 CLI(Node/TS 또는 Python)로 이식. 스크립트 이름과 인자를 그대로 하위 명령으로 유지해 SKILL.md 변경을 최소화한다.

## 2. 기타 후보
- 설치/배포: 레포 clone + symlink, 또는 Claude Code plugin 으로 패키징
- 요청(request) 단위 추적: journal 의 `request:` 기록 대신 `requests/<id>.md` 로 태스크 묶음과 진행률 관리
- 메인 컨텍스트 관리: 처리한 이벤트 수가 일정 이상이면 메인이 스스로 정리 후 재기동하는 정책
- 알림: 완료/blocked/permission 이벤트를 ntfy·Telegram 등 외부 채널로 전달
- GitHub PR 머지 전략 (`MERGE_STRATEGY=pr`)
- 여러 인스턴스 현황을 한곳에서 보기 (각 인스턴스의 `board.md` 수집)
