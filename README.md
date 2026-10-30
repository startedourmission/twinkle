<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Twinkle 아이콘">
</p>

<h1 align="center">Twinkle</h1>

<p align="center">바탕화면에 붙여 두는 마크다운 메모. 할 일에 <code>@claude</code>를 달면 에이전트가 알아서 처리합니다.</p>

---

Twinkle은 macOS용 메모 앱입니다. 메모 하나하나가 바탕화면에 붙는 작은 창이고, 내용은 평범한 마크다운 파일로 저장됩니다.

할 일(`- [ ]`)에 `@claude`, `@codex`, `@grok` 태그를 달면, 컴퓨터가 켜져 있는 동안 그 에이전트 CLI(Claude Code, Codex, Grok Build)가 할 일을 가져가 실행합니다. 일하는 에이전트의 로고가 화면에 떠다니다가 맡은 할 일로 날아가고, 결과와 질문은 할 일 아래에 댓글로 남습니다.

## 기능

- **바탕화면 메모**: 메모마다 창 하나. 위치, 색, 접힘 상태를 기억하고 미션 컨트롤에서도 고를 수 있습니다.
- **마크다운 편집기**: 제목 접기, 체크박스, 목록 들여쓰기(Tab / Shift+Tab), 코드 블록, 링크, 경로·URL 칩을 그 자리에서 보기 좋게 그립니다. 커서를 올리면 원문이 드러납니다.
- **에이전트 자동 실행**: 태그 붙은 할 일을 에이전트가 가져가 일하고, 상태를 체크박스로 표시합니다. 엔터를 쳐서 줄을 끝내기 전까지는 가져가지 않습니다.
- **댓글로 대화**: 에이전트의 결과·질문에 답글을 달면 같은 세션을 이어서 진행합니다. 권한이 필요하다고 하면 버튼으로 허용할 수 있습니다.
- **에이전트 로고**: 로고를 누르면 지금 하는 일, 작업 기록, 사용량을 보고 이어서 지시하거나 멈출 수 있습니다.
- **할 일 목록 블록**: ```` ```todo ```` 블록 자리에 여러 메모의 할 일을 모아 보여 줍니다.
- **달력 블록**: ```` ```cal ```` 블록 자리에 기한 있는 할 일을 날짜에 점으로 찍은 달력을 그립니다.
- **날짜 칩**: `2026.10.30`처럼 쓰면 칩이 되고, 누르면 달력에서 날짜를 바꿀 수 있습니다.
- **메모 링크**: `[[메모 이름]]`으로 다른 메모를 잇습니다. `[[`를 치면 자동완성이 뜹니다.
- **메뉴 막대**: 별 아이콘을 누르면 모든 메모를 카드 격자로 봅니다. Main이 맨 앞, 그다음 고정한 메모입니다.
- **macOS 위젯**: 바탕화면·알림 센터에 할 일 목록과 달력 위젯을 둘 수 있습니다. 누르면 그 메모가 열립니다.

## 요구 사항

- macOS 14 이상
- Swift 6 도구 모음 (Xcode 16 이상 또는 Command Line Tools)
- 에이전트를 쓰려면 쓰려는 CLI를 설치하고 로그인해 두세요. 하나만 있어도 됩니다.
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
  - [Codex CLI](https://github.com/openai/codex) (`codex`)
  - Grok Build (`grok`)

## 빌드와 실행

```sh
git clone https://github.com/startedourmission/twinkle.git
cd twinkle
./make-app.sh          # release 빌드 후 build/Twinkle.app 생성
open build/Twinkle.app
```

Dock에는 나타나지 않고 메뉴 막대에 별 아이콘이 생깁니다. 처음 실행하면 `~/Documents/Twinkle`에 메인 메모를 만듭니다. 메모 폴더는 설정(⌘,)에서 바꿀 수 있습니다.

앱은 임시 서명(ad-hoc)만 합니다. 다시 빌드해도 macOS 권한을 같은 앱으로 알아보도록 식별자 기준으로 서명합니다.

## 쓰는 법

### 할 일과 에이전트

```markdown
- [ ] @claude ~/dev/my-app 에서 README 오타 고쳐줘
- [ ] @codex 테스트가 왜 깨지는지 찾아줘
- [ ] 장보기 2026.10.30
```

- 에이전트는 할 일 줄이나 그 위 제목에 적힌 경로를 작업 폴더로 씁니다. 경로가 없으면 메모 폴더에서 일합니다.
- 자주 쓰는 작업 폴더는 메모 머리의 📁 버튼에 등록하고 메모로 끌어다 놓을 수 있습니다.
- 체크박스 상태: `[ ]` 할 일, `[/]` 하는 중, `[x]` 끝남, `[?]` 답을 기다림, `[!]` 실패
- 자동 실행은 메뉴 막대 → "에이전트 자동 실행"으로 켜고 끕니다.

> **권한 주의**: 기본 설정에서 에이전트는 확인 없이 실행합니다(Claude·Grok은 bypass, Codex는 danger-full-access). 설정 → 에이전트에서 에이전트마다 권한 단계를 낮출 수 있습니다.

### 할 일 목록 블록

````markdown
```todo
not done
agent is claude
group by filename
sort by due
```
````

한 줄에 조건 하나이고, 여러 줄이면 모두 만족하는 것만 보여 줍니다. 비워 두면 안 끝난 할 일 전부입니다. 블록 위 버튼으로도 조건을 바꿀 수 있습니다.

| 조건 | 예 |
| --- | --- |
| 상태 | `done`, `not done`, `all`, `status.type is DONE` |
| 기한 | `has due date`, `no due date`, `due before 2026-11-01`, `due on today` |
| 에이전트 | `has agent`, `no agent`, `agent is codex` |
| 글자 포함 | `path includes 원고`, `description does not include 회의`, `heading includes 이번 주` |
| 정렬·묶기 | `sort by due`, `sort by status reverse`, `group by heading`, `group by agent` |
| 개수 | `limit 10` |

### 달력 블록

````markdown
```cal
```
````

기한(`📅 2026-10-30` 또는 날짜 칩 `2026.10.30`)이 있는 할 일이 날짜 아래 점으로 찍힙니다. 안 끝난 일이 있는 날은 주황 점, 다 끝난 날은 회색 점입니다. 날짜를 누르면 그날 할 일이 아래에 나옵니다. 블록 안에 할 일 목록 블록과 같은 조건을 쓸 수 있습니다(예: `agent is claude`).

### 스킬·커넥터·플러그인

설정 → 확장에서 Twinkle이 시킬 때만 쓸 스킬, MCP 커넥터, Claude Code 플러그인을 등록할 수 있습니다. 스킬은 SKILL.md가 든 폴더 하나, 스킬이 여러 개 든 폴더나 플러그인, `.zip`·`.skill` 파일 모두 가져올 수 있습니다. 각 CLI의 전역 설정은 건드리지 않고 실행할 때 인자로만 넘깁니다(Claude Code: `--plugin-dir`·`--mcp-config`, Codex: `-c mcp_servers.…`). 전역에 설치해 둔 것은 그대로 같이 쓰고, 설정 화면에 목록으로 보입니다.

| | 스킬 | 커넥터 | 플러그인 |
| --- | --- | --- | --- |
| Claude Code | ✓ | ✓ | ✓ |
| Codex | 전역만 | ✓ | 전역만 |
| Grok Build | 전역만 | 전역만 | 전역만 |

커넥터 칸 맨 위에는 Claude Code의 MCP 목록(`/mcp`와 같음)이 연결 상태와 함께 보입니다. "연결…"을 누르면 브라우저에서 claude.ai 커넥터 설정이 열리고, 거기서 Gmail·Google Drive 같은 걸 연결하면 이 목록에 나타나 Twinkle이 시키는 Claude Code에서 바로 씁니다.

### 위젯

바탕화면에서 우클릭 → "위젯 편집…"을 열고 Twinkle을 찾아 "할 일" 또는 "달력"을 끌어다 놓으세요. Twinkle이 켜져 있어야 내용이 갱신됩니다(앱이 할 일 목록을 `widget.json`으로 써 주고, 샌드박스 안의 위젯은 그 파일만 읽습니다).

## 데이터 위치

| 무엇 | 어디 |
| --- | --- |
| 메모 | 설정한 메모 폴더 (기본 `~/Documents/Twinkle`), 평범한 `.md` 파일 |
| 창 배치 | `~/Library/Application Support/Twinkle/windows.json` |
| Twinkle 전용 스킬·커넥터·플러그인 | `~/Library/Application Support/Twinkle/extensions/` |
| 위젯용 할 일 목록 | `~/Library/Application Support/Twinkle/widget.json` |
| 에이전트 실행 기록 | `~/Library/Application Support/Twinkle/logs/` |
| 로고 바꾸기 | `~/Library/Application Support/Twinkle/logos/<claude\|codex\|grok>.png` |

## 참고

- 에이전트 로고는 [LobeHub Icons](https://github.com/lobehub/lobe-icons)에서 가져왔고, 각 로고의 상표권은 해당 회사에 있습니다.
