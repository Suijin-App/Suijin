# Mercury shell integration: sources your .zlogin, then puts your ZDOTDIR back (see .zshenv in this directory).
__mercury_use_user_zdotdir
if [[ -r "${__mercury_user_zdotdir}/.zlogin" ]]; then
  source "${__mercury_user_zdotdir}/.zlogin"
fi
__mercury_restore_zdotdir
