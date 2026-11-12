# Sevinda shell integration: sources your .zlogin, then puts your ZDOTDIR back (see .zshenv in this directory).
__sevinda_use_user_zdotdir
if [[ -r "${__sevinda_user_zdotdir}/.zlogin" ]]; then
  source "${__sevinda_user_zdotdir}/.zlogin"
fi
__sevinda_restore_zdotdir
