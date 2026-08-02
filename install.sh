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
# Scriptable: PIVOTAL_MENU_CHOICE=key|update|uninstall bash install.sh
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$HOME/.local/share/pivotal"
CACHE_DIR="$HOME/.claude/cache/pivotal"
CONFIG="$CACHE_DIR/config.json"
SETTINGS="$HOME/.claude/settings.json"
REPO_URL="https://github.com/obaidregens/pivotal.git"
mkdir -p "$CACHE_DIR"

# Am I running inside the dev project (a clone), or as a standalone one-off
# (e.g. curl | bash)? Dev mode is only offered from inside a real checkout;
# a one-off bootstrap-clones the repo and installs production from it.
IN_CHECKOUT=0
[ -f "$DIR/pivotal.ts" ] && [ -d "$DIR/plugin" ] && IN_CHECKOUT=1

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
  read -rs key; echo
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
  if ! command -v fzf >/dev/null; then
    if command -v brew >/dev/null; then note "installing fzf…"; brew install -q fzf; else
      echo "fzf required: https://github.com/junegunn/fzf"; exit 1; fi
  fi
}

deploy_prod_copy() {
  # frozen copy outside the checkout: prod only changes on explicit update,
  # unlike --dev where the live checkout is wired directly
  mkdir -p "$PROD_DIR"
  cp "$DIR/pivotal.ts" "$DIR/pivotal.zsh" "$PROD_DIR/"
  rm -rf "$PROD_DIR/plugin" "$PROD_DIR/.claude-plugin"
  cp -R "$DIR/plugin" "$DIR/.claude-plugin" "$PROD_DIR/"
  # point the copy's own references at the copy
  sed -i '' "s|\$HOME/Workspace/pivotal/pivotal.ts|$PROD_DIR/pivotal.ts|g" \
    "$PROD_DIR/pivotal.zsh" "$PROD_DIR/plugin/hooks/hooks.json" 2>/dev/null || true
  sed -i '' "s|\${PIVOTAL_SCRIPT:-[^}]*}|\${PIVOTAL_SCRIPT:-$PROD_DIR/pivotal.ts}|" "$PROD_DIR/pivotal.zsh"
  note "app copied to $PROD_DIR"
}

prod_install() {
  say "pivotal install (production)"
  install_deps
  setup_provider
  deploy_prod_copy
  install_hook "$PROD_DIR" "$PROD_DIR"
  wire_shell "$PROD_DIR"
  say "done. Open a new terminal (or: exec zsh), press down-arrow on an empty line."
}

dev_install() {
  say "pivotal install (DEVELOPMENT — wired to this checkout: $DIR)"
  install_deps
  setup_provider
  install_hook "$DIR" "$DIR"
  wire_shell "$DIR"
  say "dev install done. Every edit to $DIR is live immediately."
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
menu_pick() {
  if [ "${PIVOTAL_MENU_CHOICE:-}" = "list" ]; then printf '· %s\n' "$@" >&2; return 1; fi
  if [ -n "${PIVOTAL_MENU_CHOICE:-}" ]; then echo "$PIVOTAL_MENU_CHOICE"; return; fi
  if command -v fzf >/dev/null; then
    printf '%s\n' "$@" | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf \
      --height 40% --reverse --no-info \
      --pointer '❯' \
      --color 'bg+:-1,fg+:173,pointer:173,hl:173,hl+:208,gutter:-1' \
      --prompt 'pivotal ▸ ' --header 'Existing installation — pick an action (Esc quits)'
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
  local key; read -rs key; echo
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

# ---------- entry -------------------------------------------------------------
if [ "${1:-}" = "--uninstall-hook" ]; then
  remove_hook; note "Stop hook removed."; exit 0
fi

WIRED="$(wired_zsh_path || true)"
DEV_WIRED=0; PROD_WIRED=0
if [ -n "$WIRED" ]; then
  if [ "$WIRED" = "$PROD_DIR/pivotal.zsh" ]; then PROD_WIRED=1; else DEV_WIRED=1; fi
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
say "pivotal"
opts=()
[ -f "$CONFIG" ] && opts+=("Add/Change OpenAI key")
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

choice=$(menu_pick "${opts[@]}") || { note "no action."; exit 0; }
case "$choice" in
  *key*|key)
    change_key ;;
  "Install production"|install-prod)
    [ "$IN_CHECKOUT" = 0 ] && bootstrap_clone
    if [ "$DEV_WIRED" = 1 ]; then unwire_any; note "dev wiring removed — checkout untouched"; fi
    prod_install ;;
  *update*|*Refresh*|*Update*|update)
    [ "$IN_CHECKOUT" = 0 ] && bootstrap_clone
    do_update ;;
  "Uninstall dev version (keeps project files)"|uninstall-dev)
    dev_uninstall "${WIRED%/pivotal.zsh}" ;;
  "Install dev version (live from this checkout)"|install-dev)
    if [ -n "$WIRED" ]; then unwire_any; note "previous wiring removed"; fi
    dev_install ;;
  "Uninstall"|uninstall)
    do_uninstall ;;
  *)
    note "no action." ;;
esac
