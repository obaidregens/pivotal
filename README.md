# pivotal

☀️ **a new universal-workspace model for agent harnesses**
\
[> blog post](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)

_no jargon explanation:_
\
everything you've worked on with claude code, searchable and indexed.

**you can also forget the concept of project and chats, pivotal categorizes everything into topics:**

\> "convert xlx of event attendees into csv"
\
\> "estimate monthly aws bill based on bedrock tokens consumed"
\
\> "read my whatsapp chats and reply to everyone unread with, obaid will speak to you soon"
\
\> "building a claude knowledgebase called pivotal"

are all automatically found, indexed, categorized, and made accessible directly from your terminal `↓ DOWN ARROW`

doesn't interfere with claude code or any default keymapping.

quick install for non-readers:
```sh
curl -fsSL https://pivotal.obaid.wtf/install.sh | bash
```

<img width="800" height="465" alt="Screen Recording 2026-08-02" src="https://github.com/user-attachments/assets/5a01a994-85bf-4600-b738-e5201f817648" />

---

i've worked extremely carefully myself to make the UX as delightful and simple as I always do, and the `install.sh` experience is part of it
 
## Install

everything is handled by `install.sh`, first time it runs it will walk you through the installation, and the next time it will detect your set up and give you configuration options as well as cleanly uninstalling or changing your installation from prod to dev (realtime changes reflected) mode.

<img width="656" height="233" alt="Screenshot 2026-08-02 at 3 41 55 PM" src="https://github.com/user-attachments/assets/806ee214-35e3-4428-94e3-efdf9c7c0595" />


Production (one-off — downloads and sets up the app at `~/.local/share/pivotal`):

```sh
curl -fsSL https://pivotal.obaid.wtf/install.sh | bash
```

Development (clone anywhere; every edit is live immediately):

```sh
git clone https://github.com/obaidregens/pivotal.git && cd pivotal
bash install.sh   # this install.sh auto-detects project directory and offers "Install dev version"
```

## how it works

It directly installs into your terminal, so so just doing `↓ DOWN ARROW` (unmapped key) will let you navigate through your topics like `↑ UP ARROW` does terminal history

select any topic to open a new chat condensing discoveies from the topic across chats, latest steps and reference to original chat sessions used-as-needed.

<img width="800" height="452" alt="Screen Recording 2026-08-02 at 8 10 02 PM" src="https://github.com/user-attachments/assets/787494e6-835c-4051-a2be-83bb5ba93af1" />

the `install.sh` and permanent help badge after should be pretty self-explanatory hand-holding! but if you go off a wrong path or something is not extremely explanatory just dm me on twitter @wtfobaid or text @ +1 940-745-8318 with a link to the repo and what you went through.

but if you still want the full deets i'll hand it off to an LLM to explain further

**why not openclaw?**

the first time I used it, it ate an absurd amount of tokens and then proceeded to accidentally wipe my entire work for the day. i think claude code's context isolation is better, although the lack of fluidity between work is something I've tried to strike a balance with in pivotal. 

feel free to hammer me with all the detailed reasoning for why pivotal is reinventing the openclaw wheel, i might not reply but I will read all of it earnestly and think about it deeply.

## thesis
blog post introducing pivotal [here](https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal.html)


---

---

---

---

---

---

## explained by my LLM

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

### Shell integration (installed by default via ~/.zshrc)

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

### How it stays token-efficient and up to date

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

### Live updates (pivotal plugin)

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
