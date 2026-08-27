#!/bin/bash
# pivotal installer.
#
#   curl -fsSL https://pivotal.obaid.wtf/install.sh | bash   one-off: clone + install (or update)
#   bash install.sh                                          from a checkout or ~/.local/share/pivotal:
#                                                            state-aware menu (install / update / key / uninstall)
#   bash install.sh --uninstall-hook                         remove only the Claude Code hooks
#
# Scriptable: PIVOTAL_MENU_CHOICE=install-prod|install-dev|update|uninstall|uninstall-dev|key|remove-key|delete-cache|list
set -euo pipefail

PROD_DIR="$HOME/.local/share/pivotal"
CACHE_DIR="$HOME/.claude/cache/pivotal"
CONFIG="$CACHE_DIR/config.json"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="$HOME/.zshrc"
REPO_URL="${PIVOTAL_REPO:-https://github.com/obaidregens/pivotal.git}"
POST_URL="https://obaid.wtf/jotbook/2026/08/02/announcing-pivotal"
FZF_VERSION="0.74.2"
HOOK_EVENTS="Stop SessionStart SessionEnd PreCompact"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
dim()  { printf '  \033[90m%s\033[0m\n' "$*"; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

# ---------- stage 0: guarantee a checkout on disk and a terminal on stdin -----
# Piped (`curl | bash`): stdin is the script itself, so any prompt or `select`
# would eat script text. Clone once, then re-exec from the file with the
# terminal on stdin — everything below can assume both. Also used when the
# prod copy (no checkout) wants to install/update.
bootstrap() {  # never returns
  command -v git >/dev/null || die "git is required"
  [ -e /dev/tty ] || die "pivotal needs an interactive terminal to install"
  local tmp; tmp="$(mktemp -d)"
  say "fetching pivotal…"
  git clone -q --depth 1 "$REPO_URL" "$tmp/pivotal" || die "clone failed: $REPO_URL"
  PIVOTAL_BOOTSTRAP=1 exec bash "$tmp/pivotal/install.sh" </dev/tty
}
[ -n "${BASH_SOURCE[0]:-}" ] || bootstrap
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -t 0 ] || { ( : </dev/tty ) 2>/dev/null && exec </dev/tty; } || true   # no tty at all (CI): prompts read EOF

# Where am I running from? A real checkout offers dev mode; the prod copy
# (no .git) and a bootstrap clone (temporary) do not.
IN_CHECKOUT=0
[ -d "$DIR/.git" ] && [ -z "${PIVOTAL_BOOTSTRAP:-}" ] && IN_CHECKOUT=1

# ---------- hooks (Claude Code) -----------------------------------------------
hook_cmd() {  # $1 = app dir → the hook command line, $HOME-relative when possible
  local p="$1/pivotal.ts"
  case "$p" in "$HOME"/*) p="\$HOME${p#"$HOME"}" ;; esac
  printf 'bun "%s" touch' "$p"
}

write_plugin_hooks() {  # $1 = app dir; the plugin is copied into Claude's cache, so paths must be absolute
  bun -e '
    const [dir, cmd, events] = process.argv.slice(1);
    const hooks = {};
    for (const e of events.split(" ")) hooks[e] = [{ hooks: [{ type: "command", command: cmd, timeout: 15 }] }];
    require("fs").writeFileSync(dir + "/plugin/hooks/hooks.json", JSON.stringify({ hooks }, null, 2) + "\n");
  ' "$1" "$(hook_cmd "$1")" "$HOOK_EVENTS"
}

settings_hooks() {  # $1 = add|remove, $2 = command (add) — fallback when the plugin CLI is unavailable
  bun -e '
    const fs = require("fs");
    const [p, mode, cmd, events] = process.argv.slice(1);
    let s = {};
    try { s = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
    fs.writeFileSync(p + ".pivotal-backup", JSON.stringify(s, null, 2));
    s.hooks ??= {};
    for (const e of events.split(" ")) {
      const kept = (s.hooks[e] ?? []).filter(g => !(g.hooks ?? []).some(h => /pivotal\.ts|cc-topics\.ts/.test(h.command ?? "")));
      if (mode === "add") kept.push({ hooks: [{ type: "command", command: cmd, timeout: 15 }] });
      if (kept.length) s.hooks[e] = kept; else delete s.hooks[e];
    }
    if (!Object.keys(s.hooks).length) delete s.hooks;
    fs.writeFileSync(p, JSON.stringify(s, null, 2));
  ' "$SETTINGS" "$1" "${2:-}" "$HOOK_EVENTS"
}

install_hooks() {  # $1 = app dir
  write_plugin_hooks "$1"
  if command -v claude >/dev/null \
     && { claude plugin marketplace add "$1" >/dev/null 2>&1 || true; } \
     && claude plugin install pivotal@pivotal >/dev/null 2>&1; then
    say "hooks installed as plugin pivotal@pivotal"
  else
    note "plugin CLI unavailable — writing hooks to settings.json"
    settings_hooks add "$(hook_cmd "$1")"
  fi
}

remove_hooks() {
  if command -v claude >/dev/null; then
    claude plugin uninstall pivotal@pivotal >/dev/null 2>&1 || true
    claude plugin marketplace remove pivotal >/dev/null 2>&1 || true
  fi
  settings_hooks remove
}

# ---------- shell wiring ------------------------------------------------------
wired_zsh_path() {  # echoes the pivotal.zsh currently sourced from ~/.zshrc (empty if none)
  grep -h 'pivotal\.zsh' "$ZSHRC" 2>/dev/null | grep -v '^[[:space:]]*#' \
    | sed -E 's/^[[:space:]]*source[[:space:]]+//' | head -1 || true
}

wire_shell() {  # $1 = app dir
  grep -q 'pivotal\.zsh' "$ZSHRC" 2>/dev/null && return 0
  printf '\n# pivotal: topic selector (down-arrow on empty line, or Ctrl+T)\nsource %s/pivotal.zsh\n' "$1" >> "$ZSHRC"
  say "added source line to ~/.zshrc"
}

unwire_shell() {  # also scrubs legacy cc-topics lines; rewrites in place (portable, keeps symlinks)
  grep -qE 'pivotal\.zsh|cct\.zsh' "$ZSHRC" 2>/dev/null || return 0
  local tmp; tmp="$(mktemp)"
  grep -vE '# (pivotal|cc-topics): topic selector|pivotal\.zsh|cct\.zsh' "$ZSHRC" > "$tmp" || true
  cat "$tmp" > "$ZSHRC"; rm -f "$tmp"
  note "shell integration removed from ~/.zshrc"
}

# ---------- provider / OpenAI key --------------------------------------------
LUNA_ID="gpt-5.6-luna"

validate_key() {  # also resolves the exact luna model id into LUNA_ID
  local models id
  models=$(curl -sf -m 10 https://api.openai.com/v1/models -H "Authorization: Bearer $1") || return 1
  id=$(printf '%s' "$models" | grep -oE '"id": *"[^"]*luna[^"]*"' | head -1 | sed -E 's/.*"id": *"([^"]*)".*/\1/' || true)
  [ -n "$id" ] && LUNA_ID="$id"
  return 0
}

discover_key() {  # prints "<key>\t<source>" or nothing
  if [ -n "${OPENAI_API_KEY:-}" ]; then printf '%s\tenv\n' "$OPENAI_API_KEY"; return; fi
  local f found
  for f in "$HOME/.zshenv" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.config/openai/key" "$HOME/.openai"; do
    found=$(grep -shoE 'sk-[A-Za-z0-9_-]{20,}' "$f" 2>/dev/null | head -1 || true)
    [ -n "$found" ] && { printf '%s\tfile:%s\n' "$found" "$f"; return; }
  done
  return 0
}

write_config() {  # $1 = openai|claude, $2 = key, $3 = source (env → don't persist the key)
  mkdir -p "$CACHE_DIR"
  if [ "$1" = openai ]; then
    local stored="\"$2\""; [ "$3" = env ] && stored='"env"'
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

prompt_key() {  # $1 = prompt text; prints the pasted key (may be empty)
  local key; printf '  %s' "$1" >&2; read -rs key || true; echo >&2; printf '%s' "$key"
}

setup_provider() {
  local pair key source
  pair=$(discover_key); key="${pair%%$'\t'*}"; source="${pair##*$'\t'}"
  if [ -n "$key" ] && validate_key "$key"; then
    say "OpenAI key found ($source) → using $LUNA_ID"; show_savings
    write_config openai "$key" "$source"; return
  fi
  [ -n "$key" ] && note "found a key ($source) but it failed validation — ignoring it"
  say "No working OpenAI key found."; show_savings
  key=$(prompt_key "Paste an OpenAI API key to use Luna, or press Enter to skip: ")
  if [ -n "$key" ] && validate_key "$key"; then
    say "key valid → using $LUNA_ID"; write_config openai "$key" manual
  else
    [ -n "$key" ] && note "key failed validation."
    note "Using Claude Sonnet via the claude CLI (no extra setup, works now)."
    write_config claude "" ""
  fi
}

change_key() {
  say "Add / change OpenAI key"; show_savings
  local key; key=$(prompt_key "Paste key (Enter to cancel): ")
  [ -z "$key" ] && { note "cancelled."; return; }
  if validate_key "$key"; then write_config openai "$key" manual; say "saved → provider now $LUNA_ID"
  else note "key failed validation — config unchanged."; fi
}

remove_key() {
  say "remove OpenAI key"
  note "clears the key from pivotal's config; provider falls back to Claude"
  [ -n "${OPENAI_API_KEY:-}" ] && dim "note: OPENAI_API_KEY in your shell env is yours — not touched"
  confirm || return 0
  write_config claude "" ""
  say "key removed — pivotal now uses Claude until a key is re-added."
}

confirm() {  # skipped when scripted
  [ -n "${PIVOTAL_MENU_CHOICE:-}" ] && return 0
  local ans; printf '  type yes to confirm: '; read -r ans || true
  [ "$ans" = yes ] || { note "cancelled."; return 1; }
}

# ---------- fzf (bundled, pinned — the picker relies on newer flags) ---------
vendor_fzf() {  # $1 = app dir; returns 1 on any failure
  local dest="$1/bin/fzf" os arch asset base tmp sum want
  [ -x "$dest" ] && "$dest" --version 2>/dev/null | grep -q "^$FZF_VERSION " && return 0
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) return 1 ;; esac
  asset="fzf-$FZF_VERSION-${os}_${arch}.tar.gz"
  base="https://github.com/junegunn/fzf/releases/download/v$FZF_VERSION"
  tmp="$(mktemp -d)"
  curl -fsSL -m 90 -o "$tmp/$asset" "$base/$asset" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  # verify against the release manifest when reachable; a mismatch always rejects
  want=$(curl -fsSL -m 30 "$base/fzf_${FZF_VERSION}_checksums.txt" 2>/dev/null | grep " $asset\$" | cut -d' ' -f1 || true)
  if [ -n "$want" ]; then
    sum=$( (shasum -a 256 "$tmp/$asset" 2>/dev/null || sha256sum "$tmp/$asset") | cut -d' ' -f1)
    [ "$sum" = "$want" ] || { rm -rf "$tmp"; return 1; }
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" fzf 2>/dev/null || { rm -rf "$tmp"; return 1; }
  mkdir -p "$1/bin" && install -m 755 "$tmp/fzf" "$dest"
  rm -rf "$tmp"
}

ensure_fzf() {  # $1 = app dir; bundled preferred, PATH fzf is a silent fallback
  vendor_fzf "$1" || command -v fzf >/dev/null \
    || die "install failed: could not fetch required components (network needed) — rerun when online"
}

any_fzf() {  # the fzf to use for this installer's own menu (empty → plain select)
  local f
  for f in "$PROD_DIR/bin/fzf" "$DIR/bin/fzf"; do [ -x "$f" ] && { echo "$f"; return; }; done
  command -v fzf || true
}

menu_pick() {  # $@ = options; prints the chosen line (empty = none)
  case "${PIVOTAL_MENU_CHOICE:-}" in
    list) printf '· %s\n' "$@" >&2; return 1 ;;
    ?*)   echo "$PIVOTAL_MENU_CHOICE"; return ;;
  esac
  local fzf; fzf=$(any_fzf)
  if [ -n "$fzf" ]; then
    printf '%s\n' "$@" | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' "$fzf" \
      --height 40% --reverse --no-info --pointer '❯' \
      --color 'bg+:-1,fg+:173,pointer:173,hl:173,hl+:208,gutter:-1' \
      --prompt 'pivotal ▸ ' --header "$MENU_HEADER" || true
  else
    printf '%s\n' "$MENU_HEADER" >&2
    local o; select o in "$@"; do echo "$o"; break; done
  fi
}

# ---------- install / update / uninstall -------------------------------------
require_deps() {
  command -v bun >/dev/null || die "bun required: curl -fsSL https://bun.sh/install | bash"
  command -v claude >/dev/null || note "warning: claude CLI not found — needed for the continue flow"
}

deploy_prod_copy() {  # frozen copy outside the checkout; only changes on explicit update
  mkdir -p "$PROD_DIR"
  rm -rf "$PROD_DIR/plugin" "$PROD_DIR/.claude-plugin"
  cp "$DIR/pivotal.ts" "$DIR/pivotal.zsh" "$DIR/install.sh" "$PROD_DIR/"   # install.sh: the ⚙ settings entry reopens it
  cp -R "$DIR/plugin" "$DIR/.claude-plugin" "$PROD_DIR/"
  say "app copied to $PROD_DIR"
}

wire_app() {  # $1 = app dir — everything that points Claude Code and zsh at an app dir
  ensure_fzf "$1"
  install_hooks "$1"
  wire_shell "$1"
}

unwire_all() { remove_hooks; unwire_shell; }

handoff_shell() {  # make the wiring live in THIS terminal by replacing the installer with a zsh
  if [ -z "${PIVOTAL_MENU_CHOICE:-}" ] && [ -t 1 ] && command -v zsh >/dev/null; then
    say "done — pivotal is live in this terminal: down-arrow on an empty line."
    exec zsh -i
  fi
  say "done. Open a new terminal (or: exec zsh), press down-arrow on an empty line."
}

prod_install() {
  say "pivotal install (production)"
  require_deps; setup_provider
  [ -n "$WIRED" ] && unwire_all
  deploy_prod_copy; wire_app "$PROD_DIR"
  handoff_shell
}

dev_install() {
  say "pivotal install (DEVELOPMENT — wired to this checkout: $DIR)"
  require_deps; setup_provider
  [ -n "$WIRED" ] && unwire_all
  wire_app "$DIR"
  note "every edit to $DIR is live immediately."
  handoff_shell
}

do_update() {
  if [ "$IN_CHECKOUT" = 1 ]; then
    say "updating checkout…"
    git -C "$DIR" pull --ff-only && note "pulled." || note "pull failed — continuing with local copy."
  fi
  deploy_prod_copy; wire_app "$PROD_DIR"
  say "updated."
}

do_uninstall() {
  say "uninstalling pivotal"
  unwire_all
  rm -rf "$PROD_DIR"
  note "removed $PROD_DIR (a checkout is never touched)"
  note "kept: $CACHE_DIR (topics, briefings, provider config) — full purge: rm -rf $CACHE_DIR"
  say "uninstalled. Open a new terminal for a clean shell."
}

dev_uninstall() {
  say "uninstalling dev version"
  unwire_all
  note "dev wiring removed — project files untouched (${WIRED%/pivotal.zsh})"
}

delete_cache() {  # analysis data only — provider config (and any pasted key) survives
  say "delete cache"
  note "removes analysis data from $CACHE_DIR:"
  dim "topics, briefings, digests, search index, metrics — rebuilt on next run (costs one LLM pass)"
  dim "provider config + OpenAI key are KEPT"
  confirm || return 0
  find "$CACHE_DIR" -maxdepth 1 -type f ! -name config.json -delete 2>/dev/null || true
  say "cache deleted (config kept)."
}

welcome() {
  local w line
  w=$(( ${COLUMNS:-$(tput cols 2>/dev/null || echo 100)} - 2 )); (( w > 90 )) && w=90
  printf '\n  \033[1;38;5;173mpivotal\033[0m\n\n'
  fold -s -w "$w" <<< "a new model for agent harnesses: works with claude code, but everything you do is categorized into topics — instead of directories and chat sessions." \
    | while IFS= read -r line; do note "$line"; done
  dim "an experiment, so far."; printf '\n'
}

# ---------- entry -------------------------------------------------------------
[ "${1:-}" = "--uninstall-hook" ] && { remove_hooks; note "hooks removed."; exit 0; }

# Current state: what (if anything) ~/.zshrc points at.
WIRED="$(wired_zsh_path)"
MODE=none
[ "$WIRED" = "$PROD_DIR/pivotal.zsh" ] && MODE=prod
[ -n "$WIRED" ] && [ "$MODE" = none ] && MODE=dev
HAS_CACHE=0; [ -n "$(ls -A "$CACHE_DIR" 2>/dev/null)" ] && HAS_CACHE=1

[ "$MODE" = none ] && [ "$HAS_CACHE" = 0 ] && welcome

# One-off bootstrap: no menu — install, or update an existing production install.
if [ -n "${PIVOTAL_BOOTSTRAP:-}" ]; then
  if [ "$MODE" = prod ]; then do_update; else prod_install; fi
  exit 0
fi

# Menu: options appear only when they apply.
opts=()
if [ "$MODE" != none ] && [ -f "$CONFIG" ]; then
  stored=$(grep -oE '"openaiKey": *"[^"]*"' "$CONFIG" | sed -E 's/.*: *"([^"]*)"/\1/' || true)
  [ "$stored" = env ] && stored="${OPENAI_API_KEY:-}"
  if [ -n "$stored" ]; then
    opts+=("Change OpenAI key (sk-…${stored: -4})" "Remove OpenAI key (fall back to Claude)")
  else
    opts+=("Add OpenAI key")
  fi
fi
if [ "$MODE" = prod ]; then
  if [ "$IN_CHECKOUT" = 1 ]; then opts+=("Update production from this checkout")
  else opts+=("Update production (fetch latest)"); fi
  opts+=("Uninstall")
else
  opts+=("Install production")
fi
[ "$MODE" = dev ] && opts+=("Uninstall dev version (keeps project files)")
[ "$IN_CHECKOUT" = 1 ] && [ "$WIRED" != "$DIR/pivotal.zsh" ] && opts+=("Install dev version (live from this checkout)")
[ "$HAS_CACHE" = 1 ] && opts+=("Delete cache (topics, briefings, search index — key kept)")
opts+=("Read blog post announcing pivotal (opens browser)")

case "$MODE:$HAS_CACHE" in
  prod:*) MENU_HEADER='Existing installation — pick an action (Esc quits)' ;;
  dev:*)  MENU_HEADER='Dev installation — pick an action (Esc quits)' ;;
  none:1) MENU_HEADER='Not installed (cache/config kept) — pick an action (Esc quits)' ;;
  *)      MENU_HEADER='Not installed — pick an action (Esc quits)' ;;
esac

choice=$(menu_pick "${opts[@]}") || { note "no action."; exit 0; }
case "$choice" in
  "Add OpenAI key"|"Change OpenAI key ("*|key)            change_key ;;
  "Remove OpenAI key"*|remove-key)                        remove_key ;;
  "Install production"|install-prod)
    if [ "$IN_CHECKOUT" = 1 ]; then prod_install; else bootstrap; fi ;;
  "Update production"*|update)
    if [ "$IN_CHECKOUT" = 1 ]; then do_update; else bootstrap; fi ;;
  "Install dev version"*|install-dev)                     dev_install ;;
  "Uninstall dev version"*|uninstall-dev)                 dev_uninstall ;;
  Uninstall|uninstall)                                    do_uninstall ;;
  "Delete cache"*|delete-cache)                           delete_cache ;;
  "Read blog post"*|blog)
    say "announcing pivotal ☀️"; note "$POST_URL"
    open "$POST_URL" 2>/dev/null || xdg-open "$POST_URL" 2>/dev/null || true ;;
  *) note "no action." ;;
esac
