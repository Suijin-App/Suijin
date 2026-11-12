# Mercury shell integration: sources your .zshrc, then Mercury's shell functions (see .zshenv in this directory).

# /etc/zshrc sets HISTFILE from ZDOTDIR, which pointed here while it ran; keep your history where it belongs.
if [[ "${HISTFILE:-}" == "${__mercury_zdotdir}/.zsh_history" ]]; then
  HISTFILE="${__mercury_user_zdotdir}/.zsh_history"
fi

__mercury_use_user_zdotdir
if [[ -r "${__mercury_user_zdotdir}/.zshrc" ]]; then
  source "${__mercury_user_zdotdir}/.zshrc"
fi
export ZDOTDIR="${__mercury_zdotdir}"

# After your files, so a claude or codex function of your own wins.
if [[ -r "${__mercury_zdotdir:h}/claude-shell-function.zsh" ]]; then
  source "${__mercury_zdotdir:h}/claude-shell-function.zsh"
fi
if [[ -r "${__mercury_zdotdir:h}/codex-shell-function.zsh" ]]; then
  source "${__mercury_zdotdir:h}/codex-shell-function.zsh"
fi

# A non-login shell reads no further file.
if [[ ! -o login ]]; then
  __mercury_restore_zdotdir
fi
