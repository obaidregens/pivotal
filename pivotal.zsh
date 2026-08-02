# pivotal shell integration — source from ~/.zshrc:
#   source ~/Workspace/pivotal/pivotal.zsh
#
# Keys:
#   Down-arrow on EMPTY command line -> topic selector (with text: normal history)
#   Ctrl+T                          -> topic selector (always)
# Opt-outs (set before sourcing, atuin-style):
#   PIVOTAL_NOBIND=1     -> define widgets only, bind nothing
#   PIVOTAL_BIND_DOWN=0    -> keep down-arrow unbound; Ctrl+T still bound

PIVOTAL_SCRIPT="${PIVOTAL_SCRIPT:-$HOME/Workspace/pivotal/pivotal.ts}"

alias pivotal="bun $PIVOTAL_SCRIPT"

# Selector. Design rule: NEVER swallow a failure into an empty fzf ("0/0").
# Every failure mode prints what broke and how to reproduce it.
_pivotal-pick() {
  emulate -L zsh   # immune to user setopts/aliases (fzf key-bindings.zsh pattern)
  local err_file rc probe pick
  # probe run for error/empty detection; entries are NUL-separated (two-line
  # items) so the real list is piped straight into fzf, not through a variable
  err_file=$(mktemp)
  probe=$(bun "$PIVOTAL_SCRIPT" list-cached 2>"$err_file" | head -c 64); rc=$?
  if (( rc != 0 )); then
    print -u2 "pivotal: indexer failed (exit $rc): $(head -1 "$err_file")"
    print -u2 "  reproduce: bun ${(q)PIVOTAL_SCRIPT} list-cached"
    rm -f "$err_file"; return 1
  fi
  rm -f "$err_file"
  if [[ -z $probe ]]; then
    print -u2 "pivotal: no topics indexed yet — first index runs in background (or run: cct list)"
    return 1
  fi
  # header comes fully assembled from the indexer (stats/progress + keys guide,
  # single line) so pusher updates and the initial header can never diverge
  local header
  header=$(PIVOTAL_COLS=$COLUMNS bun "$PIVOTAL_SCRIPT" stats-cached 2>/dev/null)
  [[ -z $header ]] && header="Enter continue · ? details · ^R reanalyze · Esc cancel"
  # FZF_DEFAULT_OPTS cleared: a user's global fzf config (--select-1, custom
  # binds, --exit-0) must not change this widget's behavior.
  # ctrl-z:ignore: suspending a widget-spawned fzf has no prompt to fg from —
  # it wedges the terminal (fzf ships this default in its own bindings).
  # Binding actions are single flat commands ON PURPOSE — fzf parses actions by
  # paren-matching, so inline shell with $(…) corrupts the parse and leaks code
  # into the header. Progress-pushing logic lives in the indexer
  # (kick-reanalyze / attach-progress / push-progress), which inherits $FZF_PORT.
  pick=$(bun "$PIVOTAL_SCRIPT" list-cached 2>/dev/null | FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE='' fzf \
    --read0 --highlight-line --gap 1 --wrap=word --wrap-sign '  ' --no-info \
    --pointer '❯' \
    --color 'bg+:-1,fg+:173,pointer:173,hl:173,hl+:208,gutter:-1' \
    --height 70% --min-height 18 --reverse --no-sort --ansi \
    --delimiter '\t' --with-nth 2 --listen \
    --footer "$header" \
    --preview "bun ${(q)PIVOTAL_SCRIPT} preview {1} 2>&1" \
    --preview-window 'hidden,right:55%,<90(hidden,down:60%),wrap' \
    --bind '?:toggle-preview' --bind 'ctrl-z:ignore' \
    --bind 'up:transform([ "$FZF_POS" = 1 ] && echo abort || echo up)' \
    --bind "enter:transform(bun ${(q)PIVOTAL_SCRIPT} gate-select {1})" \
    --bind 'focus:change-header()' \
    --bind "ctrl-r:execute-silent(bun ${(q)PIVOTAL_SCRIPT} kick-reanalyze)+change-footer(⟳ reanalyzing — starting…)" \
    --bind "load:execute-silent(bun ${(q)PIVOTAL_SCRIPT} attach-progress)") || return 1
  echo "${pick%%$'\t'*}"
}

_pivotal-warm-bg() {
  # background blurb pre-warm, at most every 30 min, fully detached + silent.
  # stamp is millis written by the indexer; treat unreadable/garbage as "never ran".
  local stamp=~/.claude/cache/pivotal/warm-stamp now prev age
  now=$(date +%s)
  prev=$(<$stamp) 2>/dev/null
  if [[ $prev == <-> ]]; then
    age=$(( now - prev / 1000 ))
    (( age < 1800 )) && return
  fi
  ( bun "$PIVOTAL_SCRIPT" warm >/dev/null 2>&1 & ) 2>/dev/null
}

_pivotal-widget() {
  emulate -L zsh
  # degrade to plain history if deps vanish (bun/fzf uninstalled, script moved)
  if ! command -v bun >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1 || [[ ! -f $PIVOTAL_SCRIPT ]]; then
    zle down-line-or-history
    return
  fi
  # Ctrl+T can fire with text in the buffer — stash it instead of clobbering.
  # push-line auto-restores the user's half-typed command at the next prompt
  # (fzf ALT-C pattern).
  [[ -n $BUFFER ]] && zle push-line
  zle -I   # invalidate zle display before another program paints (atuin pattern)
  local slug err
  err=$(mktemp)
  slug=$(_pivotal-pick 2>"$err")
  # re-assert bracketed paste in case the TUI died before restoring it (atuin pattern)
  [[ -n ${zle_bracketed_paste-} ]] && print -n ${zle_bracketed_paste[1]} >/dev/tty
  zle reset-prompt
  # zle -M survives the prompt redraw; bare stderr prints get eaten by reset-prompt
  [[ -z $slug && -s $err ]] && zle -M "$(head -2 "$err")"
  rm -f "$err"
  if [[ -n $slug ]]; then
    # ${(q)...}: shell-quote — slugs are model-generated, never trust for eval.
    # accept-line (vs exec) puts the command in history as a real, rerunnable entry.
    BUFFER="bun ${(q)PIVOTAL_SCRIPT} continue ${(q)slug}"
    # PIVOTAL_AUTORUN=0: atuin-style — command lands on the line, Enter is yours
    [[ ${PIVOTAL_AUTORUN:-1} == 1 ]] && zle accept-line
  fi
}
zle -N _pivotal-widget

_pivotal-down-or-history() {
  if [[ -z $BUFFER ]]; then
    zle _pivotal-widget
  else
    zle down-line-or-history
  fi
}
zle -N _pivotal-down-or-history

if [[ ${PIVOTAL_NOBIND:-0} != 1 ]]; then
  bindkey '^T' _pivotal-widget
  if [[ ${PIVOTAL_BIND_DOWN:-1} == 1 ]]; then
    bindkey '^[[B' _pivotal-down-or-history   # arrow down
    bindkey '^[OB' _pivotal-down-or-history   # arrow down (application mode)
  fi
fi

# fresh-terminal hint (PIVOTAL_NO_HINT=1 to silence): concise, right-aligned,
# orange bold. Shows the real key if down-arrow binding is off.
if [[ ${PIVOTAL_NO_HINT:-0} != 1 && ${PIVOTAL_NOBIND:-0} != 1 && -o interactive ]] && [[ -t 1 ]]; then
  if [[ ${PIVOTAL_BIND_DOWN:-1} == 1 ]]; then
    _pivotal_hint="pivotal ↓ down arrow to see topics"
  else
    _pivotal_hint="pivotal ⌃T to see topics"
  fi
  _pivotal_pad=$(( ${COLUMNS:-80} - ${#_pivotal_hint} - 3 ))  # chip adds one space each side
  (( _pivotal_pad < 0 )) && _pivotal_pad=0
  printf '%*s\033[1;48;5;173;38;5;231m %s \033[0m\n' "$_pivotal_pad" '' "$_pivotal_hint"
  unset _pivotal_hint _pivotal_pad
fi

# keep blurbs fresh in background so continue is instant + token-free at open
if [[ -o interactive ]] && command -v bun >/dev/null 2>&1; then
  _pivotal-warm-bg
fi
true  # a sourced integration file must never report failure (set -e zshrc setups)
