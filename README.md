# pivotal

**a new model for agent harnesses: works alongside with claude code, but everything you do is additionally categorized into topics — instead of directories and chat sessions**

---

_thesis: claude code is being used for a lot more than coding now. I do everything from learning and research to connecting mcps and handling my mail._

_and the assumed model of project directories and chat sessions with fresh contexts has become limiting enough for me that I've almost considered breaking claude code to roll my own harness. almost._

_but thus far, I'm choosing to keep and extend it as much as possible until I run into a wall._

---

**`pivotal`** is a new take on the agentic harness model, it views everything you do as a universal workspace, intelligently categorizing it into topics instead of being isolated across workspaces, and empowers claude code to think that way as well.

<img width="1452" height="551" alt="Screenshot 2026-08-02 at 3 37 00 PM" src="https://github.com/user-attachments/assets/1f1dbed0-b4a8-452d-b518-b12acb0e0d76" />

---

**why not openclaw?**

the first time I used it, it ate an absurd amount of tokens and then proceeded to accidentally wipe my entire work for the day. i think claude code's context isolation is better, although the lack of fluidity between work is something I've tried to strike a balance with in pivotal. 

feel free to hammer me with all the detailed reasoning for why pivotal is reinventing the openclaw wheel, i might not reply but I will read all of it earnestly and think about it deeply.

i've worked extremely carefully myself to make the UX as delightful and simple as I always do, but i will hand it off to the LLM now to help you with onboarding
 
## Install

Production (one-off — downloads and sets up the app at `~/.local/share/pivotal`):

```sh
curl -fsSL https://raw.githubusercontent.com/obaidregens/pivotal/main/install.sh | bash
# (repo currently private — until it's public, use:)
gh repo clone obaidregens/pivotal /tmp/pivotal && bash /tmp/pivotal/install.sh
```

Development (clone anywhere; every edit is live immediately):

```sh
git clone https://github.com/obaidregens/pivotal.git && cd pivotal
bash install.sh   # menu offers "Install dev version"
```

`install.sh` is checkout-aware: run from inside a clone it offers dev mode and
uses the clone as the install source; run standalone it bootstrap-clones the
repo and installs production. It also detects dev wiring and offers to unwire
it (never deleting the checkout) before installing production.

Checks deps (bun, fzf, claude), discovers an OpenAI API key (env or dotfiles) or
lets you paste one, and picks the LLM provider:

- **OpenAI key found** → GPT-5.6 Luna ($0.20/$1.20 per 1M tok, ~15× cheaper than
  Sonnet input) — installer prints the exact savings and resolves the model ID
  live from the API.
- **No key** → Claude Sonnet via the `claude` CLI (zero extra setup).

Provider config lives in `~/.claude/cache/pivotal/config.json` (chmod 600; key
stored only if you pasted it — env-discovered keys are referenced, not copied).
OpenAI failures automatically fall back to Claude mid-run.

```
bun ~/Workspace/pivotal/pivotal.ts          # interactive arrow-select menu
bun ~/Workspace/pivotal/pivotal.ts list     # print topics table
bun ~/Workspace/pivotal/pivotal.ts blurb <slug>   # print a topic's context blurb
bun ~/Workspace/pivotal/pivotal.ts rebuild  # drop caches, reclassify everything
```

## Shell integration (installed by default via ~/.zshrc)

`pivotal.zsh` is sourced from `~/.zshrc` and provides:

- **Down-arrow on an empty command line** → fzf topic selector with blurb preview.
  Down-arrow with text in the buffer still does normal history.
  Opt out by setting `PIVOTAL_BIND_UP=0` before the `source` line.
- **Ctrl+T** → same selector, always.
- `cct` alias → `bun ~/Workspace/pivotal/pivotal.ts`.

Enter on a topic runs `cct continue <slug>`: refreshes incrementally, builds or
loads the cached blurb, and starts `claude` in that topic's project directory
with the blurb as the opening prompt. The selector itself is cache-only
(`list-cached` / `preview`) — instant, zero LLM calls.

## How it stays token-efficient and up to date

1. **Local digest stage (no LLM).** Every session `.jsonl` under `~/.claude/projects` is
   parsed locally into a small digest: real user prompts (first + last few, truncated),
   the final assistant reply, project dir, timestamps. Cached by file mtime in
   `~/.claude/cache/pivotal/digests.json` — unchanged sessions are never re-read.
   (~760MB of transcripts → ~1.6MB of digests.)
2. **Incremental topic classification.** Only new/changed digests are sent to
   `claude -p --model haiku`, in chunks, with the existing topic list included so topics
   stay stable. One session can belong to multiple topics. Saved per chunk, so it's
   interruptible and resumes where it left off.
3. **Cached continuation blurbs.** Selecting a topic compresses its most recent session
   digests into a <400-word briefing (haiku, cached by member-session hash — only
   regenerated when the topic has new activity), then launches a fresh `claude` session
   in the topic's main project directory with that briefing as the opening prompt.

Every run refreshes incrementally first, so the menu is always current; a run with no
new sessions costs zero LLM tokens.

## Live updates (pivotal plugin)

The installer registers a Claude Code **Stop hook** via the `pivotal`
plugin (canonical path; falls back to a tagged `settings.json` entry when the
plugin CLI is unavailable). After every Claude reply in any session:

- `touch` — re-digests just that session (local, ~ms, zero tokens) and stamps activity
- a single debounced `settle` process waits for 90s of quiet, then runs one warm:
  classify new sessions + rebuild only the affected briefings

A burst of messages costs one LLM pass, not N. Remove cleanly with:

```sh
bash install.sh --uninstall-hook
```
