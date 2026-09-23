# AI Multi-Agent Coding System

Claude Code를 Brain/Orchestrator로, Codex와 Grok을 전문 worker로 활용하는 멀티에이전트 코딩 시스템.

모든 worker 호출은 `delegate.ps1`이라는 단일 gateway를 통과하며, 토큰 사용량·세션·실패를 자동 기록한다.

---

## 목차

1. [전체 구조](#1-전체-구조)
2. [Session 개념 구분](#2-session-개념-구분)
3. [전제 조건](#3-전제-조건)
4. [설치](#4-설치)
5. [파일 구조](#5-파일-구조)
6. [일상 사용법](#6-일상-사용법)
7. [delegate.ps1 레퍼런스](#7-delegateps1-레퍼런스)
8. [Worker 전략](#8-worker-전략)
9. [Trace ID](#9-trace-id)
10. [Profiling](#10-profiling)
11. [Claude 세션 관리](#11-claude-세션-관리)
12. [원격 접속](#12-원격-접속-tailscale--ssh--herdr)
13. [운영 원칙 요약](#13-운영-원칙-요약)

---

## 1. 전체 구조

```
                        PHONE
                          │ SSH
                   Tailscale Network
                          │
                   Windows OpenSSH
                          │
                   HERDR NAMED SESSIONS
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
    ai-influencer      youtube      social-director
     Claude Brain    Claude Brain   Claude Brain
          │
          ├─── delegate.ps1 ──┬─── Codex Worker
          │                   └─── Grok Worker
          │
          └─── Claude 직접 작업 (Codex quota 소진 시)
                          │
                    Telemetry / Profiling
                  (.ai-swarm/logs/events.jsonl)
```

---

## 2. Session 개념 구분

| 개념 | 수명 | 역할 |
|---|---|---|
| **Herdr Named Session** | 프로젝트 단위 (장기) | 프로젝트 runtime 컨테이너 |
| **Claude Native Session** | 대화/context 단위 | Brain의 LLM context |
| **Worker Session** | 작업 단위 | Codex/Grok context |
| **Trace ID** | 작업 묶음 단위 | 로그 분석용 ID |

**핵심**: Herdr session은 LLM context가 아니다. Claude context가 꽉 차도 Herdr session은 유지한다.

```
Herdr: ai-influencer  ← 몇 주/달 동안 유지
  ├─ Claude Session A  ← context 길어지면 교체
  ├─ Claude Session B
  └─ Claude Session C
```

---

## 3. 전제 조건

### 필수 (확인됨)

| 도구 | 설치 | 확인 |
|---|---|---|
| Node.js 18+ | `winget install -e --id OpenJS.NodeJS.LTS` | `node --version` |
| Git | `winget install -e --id Git.Git` | `git --version` |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | `claude --version` |
| Codex CLI | `npm install -g @openai/codex` | `codex --version` |

### 설치 전 실제 CLI 명령어 확인 필요

| 도구 | 설치 (공식 문서 확인 후 사용) | 확인 |
|---|---|---|
| Grok CLI | xAI 공식 문서 참조 | `grok --version` |
| Herdr | herdr 공식 문서 참조 | `herdr --version` |

> Grok CLI와 Herdr의 정확한 설치 명령 및 지원 flags는 실제 설치 전 공식 문서에서 반드시 확인한다.
> 특히 `--session-id`, `--resume`, `--output-format json` 등의 flags가 실제로 지원되는지 검증 필요.

### 로그인

```powershell
claude          # Claude 계정 로그인 (App 구독 또는 API Key)
codex           # ChatGPT 계정으로 로그인 (Sign in with ChatGPT 선택)
```

---

## 4. 설치

### 새 프로젝트에 설치

```powershell
# 프로젝트 디렉터리로 이동 후
cd C:\workspace\myproject
powershell -File C:\workspace\herdr설치\install.ps1
```

```powershell
# 또는 경로를 명시
powershell -File C:\workspace\herdr설치\install.ps1 -Target C:\workspace\myproject
```

```powershell
# herdr_session 이름을 직접 지정하고 싶은 경우
powershell -File C:\workspace\herdr설치\install.ps1 -Target C:\workspace\myproject -HerdrSession "my-project"
```

`install.ps1` 한 번으로 다음이 모두 완료된다:

```
[OK] .ai-swarm/ 디렉터리 구조 생성 (state, logs, reports, tmp)
[OK] delegate.ps1, profile.ps1, trace.ps1, claude-session-hook.ps1 복사
[OK] .ai-swarm/config.json 생성 (herdr_session 자동 감지)
[OK] .ai-swarm/RULES.md 복사 (공통 규칙, 매번 최신으로 덮어씀)
[OK] CLAUDE.md 생성 (@.ai-swarm/RULES.md 참조, 이미 있으면 참조 줄만 맨 위에 추가)
[OK] .claude/settings.json 에 Claude session hook 등록
[OK] .gitignore 에 ai-swarm 런타임 경로 추가 (logs, state, tmp, reports)
```

### 여러 프로젝트에 배포

```powershell
powershell -File C:\workspace\herdr설치\install.ps1 -Target C:\workspace\youtube
powershell -File C:\workspace\herdr설치\install.ps1 -Target C:\workspace\social_director
```

---

## 5. 파일 구조

### `herdr설치/` (이 폴더 — 설치 패키지)

```
herdr설치/
├── README.md                  ← 이 문서
├── install.ps1                ← 프로젝트 설치 진입점
├── RULES.md                   ← 공통 규칙 (원본, 수정은 여기서)
├── CLAUDE.md                  ← 이 저장소용 (@RULES.md 참조)
├── delegate.ps1               ← Worker gateway
├── profile.ps1                ← 사용량 분석
├── trace.ps1                  ← Trace ID 관리
├── claude-session-hook.ps1    ← Claude session 추적 hook
└── config.json                ← config 예시
```

### 설치 후 프로젝트 구조

```
myproject/
├── CLAUDE.md                  ← @.ai-swarm/RULES.md 참조 + 프로젝트별 메모
├── .gitignore                 ← ai-swarm 런타임 경로 추가됨
├── .claude/
│   └── settings.json          ← Claude hook 등록
└── .ai-swarm/
    ├── config.json            ← { "herdr_session": "my-project" }
    ├── delegate.ps1
    ├── profile.ps1
    ├── trace.ps1
    ├── claude-session-hook.ps1
    ├── RULES.md               ← 공통 규칙 (install 때마다 갱신)
    ├── state/
    │   ├── current-trace.json
    │   ├── current-claude.json
    │   └── sticky-workers.json
    ├── logs/
    │   └── events.jsonl       ← 모든 worker 호출 기록
    ├── reports/
    │   └── <trace-id>/
    │       ├── profile.md
    │       └── profile.json
    └── tmp/                   ← worker 원시 출력 임시 파일
```

---

## 6. 일상 사용법

### 기본 흐름

```
1. Herdr session attach (또는 그냥 터미널)
2. Trace ID 설정
3. claude 실행
4. 작업 지시 → Claude가 delegate.ps1로 worker 호출
5. 작업 완료 후 profile.ps1 실행
```

### 매일 쓰는 명령

```powershell
# 프로젝트 진입 (Herdr 사용 시)
herdr session attach ai-influencer

# Trace ID 설정 (작업 시작 전)
.\.ai-swarm\trace.ps1 -Set "20260921-post1-refactor"

# Claude 시작
claude

# 최근 대화 이어서
claude --continue

# 특정 대화로 복귀
claude --resume <SESSION_ID>

# 작업 후 분석
.\.ai-swarm\profile.ps1
```

---

## 7. delegate.ps1 레퍼런스

Claude가 worker를 호출할 때 반드시 이 스크립트를 통한다.

### 파라미터

| 파라미터 | 필수 | 기본값 | 설명 |
|---|---|---|---|
| `-Agent` | ✓ | — | `codex` 또는 `grok` |
| `-Prompt` | ✓ | — | 작업 내용 |
| `-Role` | | `general` | 아래 역할 목록 참조 |
| `-TaskName` | | `""` | 로그용 짧은 레이블 |
| `-Mode` | | `read` | `read` 또는 `write` |
| `-SessionMode` | | `fresh` | `fresh` 또는 `sticky` |
| `-WorkerKey` | | `"$Agent-$Role"` | sticky 세션 식별 키 |
| `-NoFallback` | | off | Codex quota 실패 시 fallback 비활성화 |

### 역할(Role) 목록

| Role | 적합한 Worker |
|---|---|
| `implementation` | Codex |
| `debugging` | Codex |
| `review` | Codex / Grok |
| `testing` | Codex |
| `exploration` | Grok |
| `research` | Grok |
| `alternatives` | Grok |
| `edge-cases` | Grok |
| `brainstorm` | Grok |
| `summary` | Grok |

### Exit code

| Code | 의미 | 처리 |
|---|---|---|
| `0` | 성공 | stdout에 worker 결과 |
| `20` | Codex quota/rate-limit | stdout 첫 줄: `AI_SWARM_FALLBACK_TO_BRAIN` → Claude가 직접 처리 |
| 기타 | worker 오류 | stdout 첫 줄: `AI_SWARM_WORKER_ERROR ...` |

### 호출 예시

```powershell
# Codex — 구현 (read-only 모드)
.\.ai-swarm\delegate.ps1 `
    -Agent codex `
    -Prompt "Fix the off-by-one error in src/parser.py line 42. The loop should use < not <=" `
    -Role implementation `
    -TaskName "fix-parser-offbyone"

# Codex — 파일 수정 허용
.\.ai-swarm\delegate.ps1 `
    -Agent codex `
    -Prompt "Refactor the upload function to use async/await" `
    -Role implementation `
    -TaskName "refactor-upload" `
    -Mode write

# Grok — repository 탐색
.\.ai-swarm\delegate.ps1 `
    -Agent grok `
    -Prompt "Explore the entire repository and give a summary of the architecture" `
    -Role exploration `
    -TaskName "explore-repo"

# Codex — sticky 세션 (첫 번째 호출)
.\.ai-swarm\delegate.ps1 `
    -Agent codex `
    -Prompt "Test is failing: TypeError: cannot read property 'id' of undefined at line 87" `
    -Role debugging `
    -TaskName "fix-test-1" `
    -SessionMode sticky `
    -WorkerKey "fix-failing-test"

# Codex — sticky 세션 (같은 작업, 두 번째 호출 — 같은 WorkerKey)
.\.ai-swarm\delegate.ps1 `
    -Agent codex `
    -Prompt "Still failing. New error: ..." `
    -Role debugging `
    -TaskName "fix-test-2" `
    -SessionMode sticky `
    -WorkerKey "fix-failing-test"
```

### Fallback 처리 패턴

```powershell
$result = .\.ai-swarm\delegate.ps1 -Agent codex -Prompt "..." -Role implementation -TaskName "task"

if ($LASTEXITCODE -eq 20) {
    # Codex quota 소진 → Claude가 직접 처리
    # (CLAUDE.md 지시에 따라 Claude Brain이 자동으로 이어받음)
} elseif ($LASTEXITCODE -ne 0) {
    # 일반 오류
    Write-Error "Worker failed: $result"
}
```

---

## 8. Worker 전략

### Codex (희소 자원)

quota가 제한적이므로 고가치 작업에만 사용한다.

- 집중 구현 (implementation)
- 어려운 디버깅 (hard debugging)
- 정밀 코드 리뷰 (precise code review)
- 테스트 설계 (focused test)
- 최종 diff 리뷰 (final diff review)

### Grok (대량 사용 가능)

탐색, 조사, 의견 수렴에 적극 활용한다.

- repository 탐색 (exploration)
- 대안 조사 (alternatives)
- 엣지 케이스 발굴 (edge-cases)
- 리서치 (research)
- 광범위 리뷰 (broad review)
- 독립적인 second opinion

### 병렬 호출

```
Claude
  ├── Codex  (correctness 검증)
  ├── Grok A (edge cases)
  └── Grok B (alternative approach)
       ↓
   Claude 판단 및 통합
```

단, **동일 파일에 여러 worker가 동시에 write하는 것은 금지**한다.

---

## 9. Trace ID

작업 묶음을 식별하는 단위. Claude session을 `/clear`해도 같은 Trace ID를 유지할 수 있다.

```powershell
# 새 trace 시작
.\.ai-swarm\trace.ps1 -Set "20260921-post1-refactor"

# 현재 trace 확인
.\.ai-swarm\trace.ps1

# trace 초기화
.\.ai-swarm\trace.ps1 -Clear
```

명명 규칙 예시:

```
20260921-post1-pipeline
20260921-auth-refactor
20260922-test-fix
```

---

## 10. Profiling

`events.jsonl`에 쌓인 모든 worker 호출을 분석한다.

```powershell
# 전체 이벤트 분석
.\.ai-swarm\profile.ps1

# 특정 trace만
.\.ai-swarm\profile.ps1 -TraceId "20260921-post1-refactor"

# 특정 Claude session만
.\.ai-swarm\profile.ps1 -ClaudeSessionId "abc123..."

# 모든 trace 합산
.\.ai-swarm\profile.ps1 -All
```

결과 파일:

```
.ai-swarm/reports/<trace-id>/profile.md    ← 사람이 읽는 리포트
.ai-swarm/reports/<trace-id>/profile.json  ← 프로그래밍용
```

리포트 항목:

- Worker별 호출 수, 성공/실패, 토큰 사용량, 소요 시간
- Role별 분배 현황
- Claude session별 worker 사용량
- Sticky session 연속성 확인
- 낭비 탐지 (중복 프롬프트, Codex를 탐색에 낭비 등)

---

## 11. Claude 세션 관리

### Context 전략

```
context 적당함      → 그대로 사용
context 길어짐      → /compact 또는 새 session
fresh가 더 나음     → 새 session 시작
```

Claude session을 바꿔도 **Herdr session은 그대로 유지**한다.

```powershell
claude --continue            # 가장 최근 conversation 이어서
claude --resume <SESSION_ID> # 특정 conversation 복귀
```

### Claude session hook

`install.ps1`이 `.claude/settings.json`에 자동 등록한다.
Claude가 실행되면 현재 session ID가 `.ai-swarm/state/current-claude.json`에 저장되고, 모든 worker 호출 로그에 `parent_claude_session_id`로 기록된다.

---

## 12. 원격 접속 (Tailscale + SSH + Herdr)

### 구성

```
PHONE
  │ SSH Client
  ▼
Tailscale (private network)
  │
  ▼
Windows OpenSSH Server (집 PC)
  │
  ▼
Herdr session → Claude Brain
```

> **주의**: Tailscale의 자체 SSH 기능이 아니라, Tailscale private network 위에 Windows OpenSSH를 올리는 방식이다.
> Tailscale SSH server는 현재 Windows host를 지원하지 않는다.

### Windows OpenSSH 설정 (관리자 PowerShell)

```powershell
# 설치
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# 시작 및 자동 실행 등록
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# 상태 확인
Get-Service sshd
```

### Tailscale 설정

집 PC와 휴대폰 모두 Tailscale을 설치하고 같은 계정으로 로그인한다.
집 PC의 Tailscale IP (예: `100.x.x.x`)로 SSH 접속:

```
ssh WINDOWS_USERNAME@100.x.x.x
```

### Herdr로 프로젝트 접속

```powershell
herdr session attach ai-influencer
herdr session attach youtube
herdr session list
```

### Detach (session 유지하며 나가기)

```
Ctrl+B, D
```

SSH를 종료해도 Herdr server와 프로세스는 계속 실행된다.

### 외부에서 작업 지시 후 나오기

```
1. SSH 접속
2. herdr session attach <project>
3. Claude에게 작업 지시
4. Ctrl+B, D  (detach)
5. SSH 종료
6. 나중에 다시 접속해서 결과 확인
```

---

## 13. 운영 원칙 요약

```
프로젝트 바꿈
  → Herdr Session 바꿈

같은 프로젝트에서 Claude context만 길어짐
  → Claude Session만 바꿈 (Herdr session 유지)

독립적인 worker 작업
  → SessionMode = fresh (기본값)

동일 문제를 계속 해결
  → SessionMode = sticky, 같은 WorkerKey

Codex quota 부족
  → Claude fallback (자동, 사용자 개입 없음)

단순 탐색 / 대량 조사
  → Grok

중요 코딩 / 최종 리뷰
  → Codex

밖에서 사용
  → SSH → Herdr

작업 지시 후 폰 종료
  → Herdr에서 계속 실행
```

---

## 파일 레퍼런스 요약

| 파일 | 역할 | 직접 실행 |
|---|---|---|
| `install.ps1` | 프로젝트에 swarm 설치 | `powershell -File install.ps1 [-Target path]` |
| `delegate.ps1` | Worker 호출 gateway | Claude가 호출 (직접 실행 가능) |
| `profile.ps1` | 사용량 분석 리포트 | `.\.ai-swarm\profile.ps1` |
| `trace.ps1` | Trace ID 관리 | `.\.ai-swarm\trace.ps1 -Set "..."` |
| `claude-session-hook.ps1` | Claude session ID 캡처 | Claude Code hook으로 자동 실행 |
| `RULES.md` | 공통 규칙 (타겟의 `.ai-swarm/RULES.md`로 복사) | — |
| `CLAUDE.md` | 이 저장소용 지시 (`@RULES.md` 참조) | — |
| `config.json` | herdr_session 설정 | — |
