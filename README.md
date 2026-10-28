# my-claude-broker

Claude Code 메인 에이전트가 서브에이전트 대신 **독립 워커 세션**(tmux 안의 `claude --remote-control`)에 작업을 분배하고, 워커가 턴을 끝낼 때마다 메인을 자동으로 깨워(없으면 새로 띄워) 리뷰 · 로컬 머지 · 결과 문서화까지 이어가게 하는 skill.

- 워커는 메인과 무관하게 계속 실행됨 → 메인은 언제든 재시작 가능
- 모든 워커가 Claude 앱 최근 항목에 `broker/<project>/<worker>` 로 노출 → 진행 과정을 보고 직접 개입 가능
- 모든 상태는 레포 안 `.broker/` 문서에 있음 → 새 메인은 `context.sh` 로 맥락 복구

설계 배경과 결정은 [PLAN.md](PLAN.md), 향후 계획(Windows 등)은 [FUTURE_PLAN.md](FUTURE_PLAN.md).

## 요구 사항
- Claude Code (구독 로그인, Remote Control 사용 가능 계정), tmux, git 2.31+, bash (macOS 기본 3.2 OK)
- `jq` 또는 `python3` (없으면 inbox 이벤트에 워커 마지막 메시지가 빠질 뿐 동작은 함)
- 대상 프로젝트 폴더가 Claude Code 에서 **신뢰(trust) 승인된 상태**여야 함. 워커 worktree 는 메인 레포의 신뢰를 이어받음

## 설치

### 1. 의존성 설치
```bash
# macOS (Homebrew)
brew install tmux jq git
# Ubuntu / Debian / WSL2
sudo apt install tmux jq git
```
Claude Code 가 없다면 [공식 문서](https://docs.claude.com/en/docs/claude-code/setup)대로 설치 후 `claude` 로 한 번 로그인한다.

### 2. 레포 클론
```bash
git clone https://github.com/wwwcomcomcomcom/my-claude-broker.git ~/my-claude-broker
```
클론 위치는 자유지만, 설치 후에는 옮기지 않는다 (실행 중인 세션의 훅이 이 경로를 가리킨다).

### 3. skill 연결
심볼릭 링크로 연결하면 `git pull` 만으로 업데이트된다.
```bash
# 전역 (모든 프로젝트에서 /broker 사용)
mkdir -p ~/.claude/skills
ln -s ~/my-claude-broker/skill/broker ~/.claude/skills/broker

# 또는 특정 프로젝트에서만
mkdir -p <project>/.claude/skills
ln -s ~/my-claude-broker/skill/broker <project>/.claude/skills/broker
```
확인: `ls ~/.claude/skills/broker/SKILL.md` 가 보이고, Claude Code 에서 `/broker` 가 자동완성되면 성공.

편의를 위해 스크립트 경로를 변수로 잡아두면 좋다 (`~/.zshrc` 등):
```bash
export BROKER="$HOME/.claude/skills/broker/scripts"
```

### 4. 프로젝트 준비
```bash
cd <project>                 # git 레포여야 함 (커밋 1개 이상)
claude                       # 처음이면 한 번 실행해 폴더 신뢰(trust) 승인 후 종료
"$BROKER/init.sh"            # .broker/ 생성 (--prefix, --base-branch 옵션)
"$BROKER/main.sh"            # 메인 세션을 tmux 에 띄움
```
Claude 앱(또는 claude.ai/code)의 최근 세션에서 `broker/<project>/main` 을 열면 된다. 터미널에서는 `tmux attach -t '=broker/<project>/main'`.

### 업데이트
```bash
git -C ~/my-claude-broker pull
```
이미 떠 있는 세션도 다음 훅 호출부터 새 스크립트를 쓴다. `SKILL.md` 변경은 새로 띄운 메인부터 반영된다.

### 제거
```bash
cd <project>
# 실행 중 워커 종료 + worktree·브랜치 삭제 (머지 안 된 작업은 버려짐)
for w in $(ls .broker/running); do "$BROKER/finalize.sh" "$w" --abandon; done
"$BROKER/stop.sh" main
rm -rf .broker               # 레지스트리 삭제 (결과 문서도 사라짐)
sed -i '' '/^\/\.broker\/$/d' .git/info/exclude   # Linux 는 sed -i
rm ~/.claude/skills/broker   # skill 링크 제거
```

## 사용법
메인 세션(앱)에서:
- `/broker add <요청>` — 태스크 분해 → 큐 등록 → 워커 기동
- `/broker status` — 브리핑 (워커 문서 기반)
- `/broker inbox` — 워커 이벤트 처리 (보통 자동으로 호출됨)
- `/broker gc` — 멈춘/실패/고아 세션 점검
- `/broker resume` — 맥락 복구

메인을 미리 띄워두지 않아도 됨: 워커가 턴을 끝내면 `broker/<project>/main` 이 자동으로 생성되어 inbox 를 처리한다.

## 동작 요약
```
메인: new-task.sh → task.md 작성 → dispatch.sh
        └─ spawn.sh: git worktree + tmux + claude --remote-control (워커 전용 훅 주입)
워커: task.md 수행, status.md 갱신, 완료 시 report.md + state: done → 턴 종료
        └─ Stop 훅 (조건 없음): inbox/ 에 이벤트 기록 → wake-main.sh
wake-main: 메인 없음 → 새 메인 "/broker inbox"
           메인 idle → tmux 로 "[broker] inbox ..." 입력
           메인 busy → 아무것도 안 함 (메인 Stop 훅이 새 이벤트를 이어서 전달)
메인: inbox.sh → done: 리뷰 → merge.sh → results/<date>-<w>.md → finalize.sh → dispatch.sh
                 blocked: journal/task 로 답하거나 사용자에게 질문 → send.sh
send.sh: 워커 idle → 즉시 입력 / busy → 메일박스, 다음 도구 호출 직후 PostToolUse 훅이 턴 중간에 전달
         (도구 호출 없이 턴이 끝나면 Stop 훅이 턴을 이어가며 전달)
```

## `.broker/` 문서
| 경로 | 내용 |
|---|---|
| `config.env` | `PREFIX`(기본 `broker`), `BASE_BRANCH`, `MAX_WORKERS`, 권한 모드, 머지 정책 |
| `journal.md` | 생명주기 이벤트 + 메인 결정 기록 |
| `board.md` | 현황판 (`list.sh` 실행 시 갱신) |
| `queue/<w>/` | 대기 태스크 |
| `running/<w>/` | 실행 중 태스크 (`task.md`, `status.md`, `report.md`, `meta.env`, `mail/`, `launch.sh`) |
| `results/<date>-<w>.md` | 태스크 결과 문서 |
| `archive/<date>-<w>/` | 끝난 태스크 원본 |
| `inbox/` | 워커 → 메인 이벤트 (`done/` 처리 완료) |
| `worktrees/<w>/` | 워커 git worktree |
| `logs/` | `hook.log`, `wake.log` |

`.broker/` 는 프로젝트 `.gitignore` 대신 `.git/info/exclude` 에 등록된다.

## Prefix
tmux 세션, Claude 세션 이름, 워커 브랜치에 항상 prefix 가 붙는다 (`<prefix>/<project>/<worker>`, 브랜치 `<prefix>/<worker>`). 기본 `broker`, `config.env` 의 `PREFIX` 또는 환경변수 `BROKER_PREFIX` 로 변경. `gc.sh` 는 이 prefix 로 고아/죽은/멈춘 세션을 찾는다.
