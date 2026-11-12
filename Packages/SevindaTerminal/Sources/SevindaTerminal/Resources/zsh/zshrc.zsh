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

# A non-login shell reads no further file.
if [[ ! -o login ]]; then
  __sevinda_restore_zdotdir
fi
