# Suijin shell integration: sources your .zshrc, then Suijin's shell functions (see .zshenv in this directory).

# /etc/zshrc sets HISTFILE from ZDOTDIR, which pointed here while it ran; keep your history where it belongs.
if [[ "${HISTFILE:-}" == "${__suijin_zdotdir}/.zsh_history" ]]; then
  HISTFILE="${__suijin_user_zdotdir}/.zsh_history"
fi

__suijin_use_user_zdotdir
if [[ -r "${__suijin_user_zdotdir}/.zshrc" ]]; then
  source "${__suijin_user_zdotdir}/.zshrc"
fi
export ZDOTDIR="${__suijin_zdotdir}"

# Agent runs: Suijin's claude and codex functions announce the agent with a private OSC 6973 written to the terminal
# itself (never to a redirected stdout): `start;<agent>` before it starts, `end;<agent>;<status>` once it is done, so
# the tab shows the agent while it runs and goes back to Shell after. The prompt hook sends the end when Ctrl-C or a
# crash cut the function short.
function __suijin_agent_begin {
  typeset -g __suijin_agent="$1"
  { builtin printf '\e]6973;start;%s\a' "$1" >/dev/tty; } 2>/dev/null
}
function __suijin_agent_end {
  [[ -n "${__suijin_agent:-}" ]] || return 0
  { builtin printf '\e]6973;end;%s;%s\a' "$__suijin_agent" "${1:-}" >/dev/tty; } 2>/dev/null
  unset __suijin_agent
  return 0
}
function __suijin_agent_prompt {
  __suijin_agent_end "$?"
}
autoload -Uz add-zsh-hook && add-zsh-hook precmd __suijin_agent_prompt

# After your files, so a claude or codex function of your own wins.
if [[ -r "${__suijin_zdotdir:h}/claude-shell-function.zsh" ]]; then
  source "${__suijin_zdotdir:h}/claude-shell-function.zsh"
fi
if [[ -r "${__suijin_zdotdir:h}/codex-shell-function.zsh" ]]; then
  source "${__suijin_zdotdir:h}/codex-shell-function.zsh"
fi

# Reports the working directory at every prompt (OSC 7), so paths a command prints relative to it resolve against the
# directory the shell is in, not the one the session started in.
function __suijin_report_cwd {
  builtin printf '\e]7;file://%s%s\a' "${HOST}" "${PWD//\%/%25}"
}
add-zsh-hook precmd __suijin_report_cwd

# A non-login shell reads no further file.
if [[ ! -o login ]]; then
  __suijin_restore_zdotdir
fi
