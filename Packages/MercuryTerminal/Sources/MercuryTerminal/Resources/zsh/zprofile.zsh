# Mercury shell integration: sources your .zprofile (see .zshenv in this directory).
__mercury_use_user_zdotdir
if [[ -r "${__mercury_user_zdotdir}/.zprofile" ]]; then
  source "${__mercury_user_zdotdir}/.zprofile"
fi
export ZDOTDIR="${__mercury_zdotdir}"
