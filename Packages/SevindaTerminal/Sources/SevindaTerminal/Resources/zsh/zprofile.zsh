# Sevinda shell integration: sources your .zprofile (see .zshenv in this directory).
__sevinda_use_user_zdotdir
if [[ -r "${__sevinda_user_zdotdir}/.zprofile" ]]; then
  source "${__sevinda_user_zdotdir}/.zprofile"
fi
export ZDOTDIR="${__sevinda_zdotdir}"
