#!/bin/bash
# pivotal installer.
#
#   bash install.sh                  production install (copies app to ~/.local/share/pivotal)
#                                    · dev wiring detected → offers to unwire it first
#                                      (never deletes development files)
#                                    · existing prod install → management menu:
#                                      Add/Change OpenAI key · Install update · Uninstall


#   bash install.sh --uninstall-hook remove only the Stop hook
#
# Scriptable: PIVOTAL_MENU_CHOICE=key|update|uninstall|delete-cache|remove-key bash install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$HOME/.local/share/pivotal"
CACHE_DIR="$HOME/.claude/cache/pivotal"
CONFIG="$CACHE_DIR/config.json"
SETTINGS="$HOME/.claude/settings.json"
REPO_URL="https://github.com/obaidregens/pivotal.git"

# Am I running inside the dev project (a clone), or as a standalone one-off
# (e.g. curl | bash)? Dev mode is only offered from inside a real checkout;
# a one-off bootstrap-clones the repo and installs production from it.
# .pivotal-prod marker: the prod copy ships install.sh (⚙ settings entry) and
# would otherwise look exactly like a checkout — never offer dev mode from it.
IN_CHECKOUT=0
[ -f "$DIR/pivotal.ts" ] && [ -d "$DIR/plugin" ] && [ ! -f "$DIR/.pivotal-prod" ] && IN_CHECKOUT=1

bootstrap_clone() {  # sets DIR to a fresh shallow clone
  command -v git >/dev/null || { echo "git required for bootstrap install"; exit 1; }
  local tmp
  tmp="$(mktemp -d)"
  say "fetching pivotal…"
  git clone -q --depth 1 "$REPO_URL" "$tmp/pivotal" || { echo "clone failed: $REPO_URL"; exit 1; }
  DIR="$tmp/pivotal"
  note "cloned to temporary staging (removed after install)"
}

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
dim()  { printf '  \033[90m%s\033[0m\n' "$*"; }  # light gray — secondary info

# Interactive input that survives `curl | bash`: stdin is the script pipe there,
# so a bare `read` eats script text and the user's typed reply lands in the
# parent shell after exit (typing "yes" then ran yes(1) — infinite y). Always
# read from the terminal; no terminal at all → empty reply (prompts cancel).
ask() {  # ask <read-flags...> <varname>
  if [ -t 0 ]; then read "$@"
  elif [ -e /dev/tty ]; then read "$@" < /dev/tty
  else eval "${!#}=''"; return 1; fi
}

welcome() {  # first-contact banner — nothing installed, no cache yet
  local w line
  w=$(( ${COLUMNS:-$(tput cols 2>/dev/null || echo 100)} - 2 ))
  (( w > 90 )) && w=90
  printf '\n  \033[1;38;5;173mpivotal\033[0m\n\n'
  fold -s -w "$w" <<< "a new model for agent harnesses: works with claude code, but everything you do is categorized into topics — instead of directories and chat sessions." \
    | while IFS= read -r line; do note "$line"; done
  dim "an experiment, so far."
  printf '\n'
}

# ---------- hook management ---------------------------------------------------
settings_hook() {  # $1 = add | remove ; PIVOTAL_HOOK_CMD used on add
  bun -e '
    const fs = require("fs");
    const p = process.env.HOME + "/.claude/settings.json";
    const mode = process.argv[1];
    const cmd = process.env.PIVOTAL_HOOK_CMD;
    let s = {};
    try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
    fs.writeFileSync(p + ".pivotal-backup", JSON.stringify(s, null, 2));
    s.hooks ??= {}; s.hooks.Stop ??= [];
    s.hooks.Stop = s.hooks.Stop.filter(g => !(g.hooks ?? []).some(h => /pivotal\.ts|cc-topics\.ts/.test(h.command ?? "")));
    if (mode === "add") s.hooks.Stop.push({ hooks: [{ type: "command", command: cmd, timeout: 15 }] });
    if (!s.hooks.Stop.length) delete s.hooks.Stop;
    if (!Object.keys(s.hooks).length) delete s.hooks;
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  ' "$1"
}

plugin_hook() {  # $1 = add | remove, $2 = marketplace root (for add)
  command -v claude >/dev/null || return 1
  if [ "$1" = add ]; then
    claude plugin marketplace add "$2" >/dev/null 2>&1 || true
    claude plugin install pivotal@pivotal >/dev/null 2>&1 || return 1
    say "Stop hook installed as plugin: pivotal@pivotal"
  else
    claude plugin uninstall pivotal@pivotal >/dev/null 2>&1 || return 1
  fi
}

install_hook() {  # $1 = app dir (hook target), $2 = marketplace root
  if plugin_hook add "$2"; then :; else
    note "plugin CLI unavailable — writing Stop hook to settings.json"
    PIVOTAL_HOOK_CMD="bun \"$1/pivotal.ts\" touch" settings_hook add
  fi
}

remove_hook() {
  plugin_hook remove || true
  settings_hook remove
  claude plugin marketplace remove pivotal >/dev/null 2>&1 || true
}

# ---------- shell wiring ------------------------------------------------------
wired_zsh_path() {  # echoes the pivotal.zsh path currently sourced from ~/.zshrc
  grep -h "pivotal\.zsh" "$HOME/.zshrc" 2>/dev/null | grep -v '^\s*#' \
    | sed -E 's/^[[:space:]]*source[[:space:]]+//' | head -1
}

wire_shell() {  # $1 = app dir
  if ! grep -q "pivotal.zsh" "$HOME/.zshrc" 2>/dev/null; then
    printf '\n# pivotal: topic selector (down-arrow on empty line, or Ctrl+T)\nsource %s/pivotal.zsh\n' "$1" >> "$HOME/.zshrc"
    say "added source line to ~/.zshrc"
  fi
}

unwire_shell() {
  if grep -qE "pivotal\.zsh|cct\.zsh" "$HOME/.zshrc" 2>/dev/null; then
    # also scrub legacy cc-topics-era lines (pre-rename installs)
    sed -i '' -e '/# pivotal: topic selector/d' -e '/pivotal\.zsh/d' \
              -e '/# cc-topics: topic selector/d' -e '/cct\.zsh/d' "$HOME/.zshrc"
    note "shell integration removed from ~/.zshrc"
  fi
}

# ---------- OpenAI key handling ----------------------------------------------
LUNA_ID="gpt-5.6-luna"

validate_key() {
  local models resolved
  models=$(curl -sf -m 10 https://api.openai.com/v1/models -H "Authorization: Bearer $1" || true)
  [ -n "$models" ] || return 1
  resolved=$(printf '%s' "$models" | grep -oE '"id": *"[^"]*luna[^"]*"' | head -1 | sed -E 's/.*"id": *"([^"]*)".*/\1/' || true)
  [ -n "$resolved" ] && LUNA_ID="$resolved"
  return 0
}

discover_key() {
  if [ -n "${OPENAI_API_KEY:-}" ]; then printf '%s\tenv\n' "$OPENAI_API_KEY"; return; fi
  local f found
  for f in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/openai/key" "$HOME/.openai"; do
    [ -r "$f" ] || continue
    found=$(grep -shoE 'sk-[A-Za-z0-9_-]{20,}' "$f" | head -1 || true)
    if [ -n "$found" ]; then printf '%s\tfile:%s\n' "$found" "$f"; return; fi
  done
}

write_config() {  # $1 = provider, $2 = key, $3 = source
  mkdir -p "$CACHE_DIR"
  if [ "$1" = openai ]; then
    local stored="\"$2\""
    [ "$3" = env ] && stored='"env"'
    printf '{"provider":"openai","openaiModel":"%s","openaiKey":%s,"claudeModel":"sonnet"}\n' "$LUNA_ID" "$stored" > "$CONFIG"
  else
    printf '{"provider":"claude","claudeModel":"sonnet"}\n' > "$CONFIG"
  fi
  chmod 600 "$CONFIG"
}

show_savings() {
  dim "Luna \$0.20/\$1.20 per 1M tokens vs Claude Sonnet \$3/\$15 —"
  dim "≈15× cheaper input, ≈12.5× cheaper output. Full-history index:"
  dim "≈\$0.10 on Luna vs ≈\$1.50 on Sonnet; live background updates: pennies/month."
}

setup_provider() {
  local pair key source
  pair=$(discover_key || true)
  key="${pair%%$'\t'*}"; source="${pair##*$'\t'}"
  if [ -n "$key" ] && validate_key "$key"; then
    say "OpenAI key found (${source}) → using $LUNA_ID"
    show_savings
    write_config openai "$key" "$source"
    return
  fi
  [ -n "$key" ] && note "found a key (${source}) but it failed validation — ignoring it"
  say "No working OpenAI key found."
  show_savings
  printf '  Paste an OpenAI API key to use Luna, or press Enter to skip: '
  ask -rs key || true; echo
  if [ -n "$key" ] && validate_key "$key"; then
    say "key valid → using $LUNA_ID"
    write_config openai "$key" "manual"
  else
    [ -n "$key" ] && note "key failed validation."
    note "Using Claude Sonnet via the claude CLI (no extra setup, works now)."
    write_config claude "" ""
  fi
}

# ---------- install pieces ----------------------------------------------------
install_deps() {
  command -v bun >/dev/null || { echo "bun required: curl -fsSL https://bun.sh/install | bash"; exit 1; }
  command -v claude >/dev/null || note "warning: claude CLI not found — needed for the continue flow"
}

# Bundled fzf: the selector binary ships inside the app dir (bin/fzf), pinned so
# the picker's flags (--footer, --listen, transforms) never break on a system
# fzf that's too old. Deliberately SILENT — from the user's perspective it's
# just part of the package, not a dependency they should have to think about.
FZF_VERSION="0.74.2"

vendor_fzf() {  # $1 = app dir; returns 1 on any failure (caller decides fallback)
  local dest="$1/bin/fzf" os arch asset base tmp sum want
  [ -x "$dest" ] && "$dest" --version 2>/dev/null | grep -q "^$FZF_VERSION " && return 0
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 1 ;; esac
  asset="fzf-$FZF_VERSION-${os}_${arch}.tar.gz"
  base="https://github.com/junegunn/fzf/releases/download/v$FZF_VERSION"
  tmp="$(mktemp -d)"
  curl -fsSL -m 90 -o "$tmp/$asset" "$base/$asset" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  # verify against the release manifest; a failed manifest fetch skips
  # verification (HTTPS is the baseline), a MISMATCH always rejects
  want=$(curl -fsSL -m 30 "$base/fzf_${FZF_VERSION}_checksums.txt" 2>/dev/null | grep " $asset\$" | cut -d' ' -f1 || true)
  if [ -n "$want" ]; then
    sum=$( (shasum -a 256 "$tmp/$asset" 2>/dev/null || sha256sum "$tmp/$asset") | cut -d' ' -f1)
    [ "$sum" = "$want" ] || { rm -rf "$tmp"; return 1; }
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" fzf 2>/dev/null || { rm -rf "$tmp"; return 1; }
  mkdir -p "$1/bin"
  install -m 755 "$tmp/fzf" "$dest"
  rm -rf "$tmp"
}

ensure_fzf() {  # $1 = app dir; bundled preferred, PATH fzf is a silent fallback
  vendor_fzf "$1" && return 0
  command -v fzf >/dev/null && return 0
  echo "install failed: could not fetch required components (network needed) — rerun when online"
  exit 1
}

bundled_fzf() {  # echoes the fzf to use for the installer's own menus
  if [ -x "$PROD_DIR/bin/fzf" ]; then echo "$PROD_DIR/bin/fzf"
  elif [ -x "$DIR/bin/fzf" ]; then echo "$DIR/bin/fzf"
  elif command -v fzf >/dev/null; then echo fzf
  fi
}

deploy_prod_copy() {
  # frozen copy outside the checkout: prod only changes on explicit update,
  # unlike --dev where the live checkout is wired directly
  mkdir -p "$PROD_DIR"
  # install.sh included: the selector's ⚙ settings entry reopens it from PROD_DIR
  cp "$DIR/pivotal.ts" "$DIR/pivotal.zsh" "$DIR/install.sh" "$PROD_DIR/"
  : > "$PROD_DIR/.pivotal-prod"
  rm -rf "$PROD_DIR/plugin" "$PROD_DIR/.claude-plugin"
  cp -R "$DIR/plugin" "$DIR/.claude-plugin" "$PROD_DIR/"
  # point the copy's own references at the copy
  sed -i '' "s|\$HOME/Workspace/pivotal/pivotal.ts|$PROD_DIR/pivotal.ts|g" \
    "$PROD_DIR/pivotal.zsh" "$PROD_DIR/plugin/hooks/hooks.json" 2>/dev/null || true
  sed -i '' "s|\${PIVOTAL_SCRIPT:-[^}]*}|\${PIVOTAL_SCRIPT:-$PROD_DIR/pivotal.ts}|" "$PROD_DIR/pivotal.zsh"
  say "app copied to $PROD_DIR"
}

handoff_shell() {  # make the fresh wiring live in THIS terminal
  # the installer is a child of the user's shell and cannot mutate its parent,
  # so exec an interactive zsh in the installer's place (oh-my-zsh pattern)
  if [ -z "${PIVOTAL_MENU_CHOICE:-}" ] && [ -t 1 ] && [ -e /dev/tty ] && command -v zsh >/dev/null; then
    say "done — pivotal is live in this terminal: down-arrow on an empty line."
    exec zsh -i </dev/tty
  fi
  say "done. Open a new terminal (or: exec zsh), press down-arrow on an empty line."
}

prod_install() {
  say "pivotal install (production)"
  install_deps
  setup_provider
  deploy_prod_copy
  ensure_fzf "$PROD_DIR"
  install_hook "$PROD_DIR" "$PROD_DIR"
  wire_shell "$PROD_DIR"
  handoff_shell
}

dev_install() {
  say "pivotal install (DEVELOPMENT — wired to this checkout: $DIR)"
  install_deps
  setup_provider
  ensure_fzf "$DIR"
  install_hook "$DIR" "$DIR"
  wire_shell "$DIR"
  note "every edit to $DIR is live immediately."
  handoff_shell
}

unwire_any() {  # remove whatever wiring exists (dev or prod); files untouched
  remove_hook
  unwire_shell
}

dev_uninstall() {
  say "uninstalling dev version"
  unwire_any
  note "dev wiring removed — project files untouched (${1:-checkout})"
  say "done."
}

# ---------- management --------------------------------------------------------
menu_pick() {  # header reflects real wiring state, set in MENU_HEADER by entry
  if [ "${PIVOTAL_MENU_CHOICE:-}" = "list" ]; then printf '· %s\n' "$@" >&2; return 1; fi
  if [ -n "${PIVOTAL_MENU_CHOICE:-}" ]; then echo "$PIVOTAL_MENU_CHOICE"; return; fi
  local fzf_bin
  fzf_bin=$(bundled_fzf)
  if [ -n "$fzf_bin" ]; then
    printf '%s\n' "$@" | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$fzf_bin" \
      --height 40% --reverse --no-info \
      --pointer '❯' \
      --color 'bg+:-1,fg+:173,pointer:173,hl:173,hl+:208,gutter:-1' \
      --prompt 'pivotal ▸ ' --header "${MENU_HEADER:-pick an action (Esc quits)}"
  else
    local o; select o in "$@"; do echo "$o"; break; done
  fi
}

update_available() {
  git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$DIR" fetch -q 2>/dev/null || return 1
  local n
  n=$(git -C "$DIR" rev-list HEAD..@{u} --count 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] && { echo "$n"; return 0; }
  return 1
}

change_key() {
  say "Add / change OpenAI key"
  show_savings
  printf '  Paste key (Enter to cancel): '
  local key; ask -rs key || true; echo
  [ -z "$key" ] && { note "cancelled."; return; }
  if validate_key "$key"; then
    write_config openai "$key" "manual"
    say "saved → provider now $LUNA_ID"
  else
    note "key failed validation — config unchanged."
  fi
}

do_update() {
  if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    say "updating checkout…"
    git -C "$DIR" pull --ff-only && note "pulled." || note "pull failed — continuing with local copy."
  fi
  deploy_prod_copy
  ensure_fzf "$PROD_DIR"
  install_hook "$PROD_DIR" "$PROD_DIR"
  wire_shell "$PROD_DIR"
  say "updated."
}

do_uninstall() {
  say "uninstalling pivotal"
  remove_hook
  note "Stop hook / plugin removed"
  unwire_shell
  rm -rf "$PROD_DIR"
  note "removed $PROD_DIR (production copy — the checkout is never touched)"
  note "kept: $CACHE_DIR (topics, briefings, provider config)"
  note "full purge: rm -rf $CACHE_DIR"
  say "uninstalled. Open a new terminal for a clean shell."
}

delete_cache() {
  # analysis data only — provider config (and any pasted key) survives
  say "delete cache"
  note "removes analysis data from $CACHE_DIR:"
  dim "topics, briefings, digests, search index, metrics — rebuilt on next run (costs one LLM pass)"
  dim "provider config + OpenAI key are KEPT (separate menu item removes the key)"
  if [ -z "${PIVOTAL_MENU_CHOICE:-}" ]; then
    printf '  type yes to confirm: '
    local ans; ask -r ans || true
    [ "$ans" = yes ] || { note "cancelled."; return; }
  fi
  find "$CACHE_DIR" -maxdepth 1 -type f ! -name 'config.json' -delete 2>/dev/null
  say "cache deleted (config kept)."
}

remove_key() {
  say "remove OpenAI key"
  note "clears the key from pivotal's config; provider falls back to Claude (claude -p)"
  [ -n "${OPENAI_API_KEY:-}" ] && dim "note: OPENAI_API_KEY in your shell env is yours — not touched"
  if [ -z "${PIVOTAL_MENU_CHOICE:-}" ]; then
    printf '  type yes to confirm: '
    local ans; ask -r ans || true
    [ "$ans" = yes ] || { note "cancelled."; return; }
  fi
  # keep the rest of the config; only drop the key and flip the provider
  bun -e '
    const p = process.argv[1];
    const c = JSON.parse(await Bun.file(p).text());
    delete c.openaiKey;
    c.provider = "claude";
    await Bun.write(p, JSON.stringify(c));
  ' "$CONFIG" 2>/dev/null || printf '{"provider":"claude","claudeModel":"sonnet"}' > "$CONFIG"
  say "key removed — pivotal now uses Claude until a key is re-added."
}

# ---------- entry -------------------------------------------------------------
if [ "${1:-}" = "--uninstall-hook" ]; then
  remove_hook; note "Stop hook removed."; exit 0
fi

WIRED="$(wired_zsh_path || true)"
DEV_WIRED=0; PROD_WIRED=0
if [ -n "$WIRED" ]; then
  if [ "$WIRED" = "$PROD_DIR/pivotal.zsh" ]; then PROD_WIRED=1; else DEV_WIRED=1; fi
fi
HAS_CACHE=0
[ -n "$(ls -A "$CACHE_DIR" 2>/dev/null)" ] && HAS_CACHE=1

# First contact (nothing wired, no cache): welcome banner.
if [ "$DEV_WIRED" = 0 ] && [ "$PROD_WIRED" = 0 ] && [ "$HAS_CACHE" = 0 ]; then
  welcome
fi

# Virgin machine via one-off installer: only one sensible action — no menu.
if [ "$IN_CHECKOUT" = 0 ] && [ "$DEV_WIRED" = 0 ] && [ "$PROD_WIRED" = 0 ] && [ ! -f "$CONFIG" ]; then
  bootstrap_clone
  prod_install
  exit 0
fi

# Otherwise: state-aware menu. Options appear only when they apply:
#  · "Install dev version"    — only when install.sh sits inside the project checkout
#  · "Uninstall dev version"  — only when dev wiring is detected, from anywhere
#  · prod actions             — key / update / uninstall as applicable
opts=()
# key management only makes sense against an installed app (installers set the
# provider themselves; a lone leftover config isn't worth managing)
if { [ "$PROD_WIRED" = 1 ] || [ "$DEV_WIRED" = 1 ]; } && [ -f "$CONFIG" ]; then
  stored=$(grep -oE '"openaiKey": *"[^"]*"' "$CONFIG" | sed -E 's/.*: *"([^"]*)"/\1/' || true)
  [ "$stored" = env ] && stored="${OPENAI_API_KEY:-}"
  if [ -n "$stored" ]; then
    opts+=("Change OpenAI key (sk-…${stored: -4})")
    opts+=("Remove OpenAI key (fall back to Claude)")
  else
    opts+=("Add OpenAI key")
  fi
fi
if [ "$PROD_WIRED" = 1 ]; then
  if [ "$IN_CHECKOUT" = 1 ] && n=$(update_available); then opts+=("Install update ($n new commits)");
  elif [ "$IN_CHECKOUT" = 1 ]; then opts+=("Refresh production from this checkout");
  else opts+=("Update production (fetch latest)"); fi
  opts+=("Uninstall")
else
  opts+=("Install production")
fi
if [ "$DEV_WIRED" = 1 ]; then
  opts+=("Uninstall dev version (keeps project files)")
fi
if [ "$IN_CHECKOUT" = 1 ] && { [ "$DEV_WIRED" = 0 ] || [ "$WIRED" != "$DIR/pivotal.zsh" ]; }; then
  opts+=("Install dev version (live from this checkout)")
fi
if [ "$HAS_CACHE" = 1 ]; then
  opts+=("Delete cache (topics, briefings, search index — key kept)")
fi
opts+=("Read blog post announcing pivotal (opens browser)")

if [ "$PROD_WIRED" = 1 ]; then MENU_HEADER='Existing installation — pick an action (Esc quits)'
elif [ "$DEV_WIRED" = 1 ]; then MENU_HEADER='Dev installation — pick an action (Esc quits)'
elif [ "$HAS_CACHE" = 1 ]; then MENU_HEADER='Not installed (cache/config kept) — pick an action (Esc quits)'
else MENU_HEADER='Not installed — pick an action (Esc quits)'; fi

choice=$(menu_pick "${opts[@]}") || { note "no action."; exit 0; }
case "$choice" in
  "Add OpenAI key"|"Change OpenAI key ("*|key)
    change_key ;;
  "Install production"|install-prod)
    [ "$IN_CHECKOUT" = 0 ] && bootstrap_clone
    if [ "$DEV_WIRED" = 1 ]; then unwire_any; note "dev wiring removed — checkout untouched"; fi
    prod_install ;;
  "Install update"*|"Refresh production from this checkout"|"Update production (fetch latest)"|update)
    [ "$IN_CHECKOUT" = 0 ] && bootstrap_clone
    do_update ;;
  "Uninstall dev version (keeps project files)"|uninstall-dev)
    dev_uninstall "${WIRED%/pivotal.zsh}" ;;
  "Install dev version (live from this checkout)"|install-dev)
    if [ -n "$WIRED" ]; then unwire_any; note "previous wiring removed"; fi
    dev_install ;;
  "Uninstall"|uninstall)
    do_uninstall ;;
  "Delete cache (topics, briefings, search index — key kept)"|delete-cache)
    delete_cache ;;
  "Remove OpenAI key (fall back to Claude)"|remove-key)
    remove_key ;;
  "Read blog post announcing pivotal (opens browser)"|blog)
    POST_URL="https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal"
    say "announcing pivotal ☀️"
    note "$POST_URL"
    open "$POST_URL" 2>/dev/null || xdg-open "$POST_URL" 2>/dev/null || true ;;
  *)
    note "no action." ;;
esac
