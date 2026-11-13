# Suijin shell integration: sources your .zlogin, then puts your ZDOTDIR back (see .zshenv in this directory).
__suijin_use_user_zdotdir
if [[ -r "${__suijin_user_zdotdir}/.zlogin" ]]; then
  source "${__suijin_user_zdotdir}/.zlogin"
fi
__suijin_restore_zdotdir
