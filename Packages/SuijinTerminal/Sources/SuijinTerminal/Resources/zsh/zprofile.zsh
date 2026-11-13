# Suijin shell integration: sources your .zprofile (see .zshenv in this directory).
__suijin_use_user_zdotdir
if [[ -r "${__suijin_user_zdotdir}/.zprofile" ]]; then
  source "${__suijin_user_zdotdir}/.zprofile"
fi
export ZDOTDIR="${__suijin_zdotdir}"
