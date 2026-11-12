# Sevinda shell integration: sources your .zshrc, then Sevinda's shell functions (see .zshenv in this directory).

# /etc/zshrc sets HISTFILE from ZDOTDIR, which pointed here while it ran; keep your history where it belongs.
if [[ "${HISTFILE:-}" == "${__sevinda_zdotdir}/.zsh_history" ]]; then
  HISTFILE="${__sevinda_user_zdotdir}/.zsh_history"
fi

__sevinda_use_user_zdotdir
if [[ -r "${__sevinda_user_zdotdir}/.zshrc" ]]; then
  source "${__sevinda_user_zdotdir}/.zshrc"
fi
export ZDOTDIR="${__sevinda_zdotdir}"

# After your files, so a claude or codex function of your own wins.
if [[ -r "${__sevinda_zdotdir:h}/claude-shell-function.zsh" ]]; then
  source "${__sevinda_zdotdir:h}/claude-shell-function.zsh"
fi
if [[ -r "${__sevinda_zdotdir:h}/codex-shell-function.zsh" ]]; then
  source "${__sevinda_zdotdir:h}/codex-shell-function.zsh"
fi

# Reports the working directory at every prompt (OSC 7), so paths a command prints relative to it resolve against the
# directory the shell is in, not the one the session started in.
function __sevinda_report_cwd {
  builtin printf '\e]7;file://%s%s\a' "${HOST}" "${PWD//\%/%25}"
}
autoload -Uz add-zsh-hook && add-zsh-hook precmd __sevinda_report_cwd

# A non-login shell reads no further file.
if [[ ! -o login ]]; then
  __sevinda_restore_zdotdir
fi
