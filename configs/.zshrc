# Alias for arsenal
alias a='arsenal -e'

precmd() {
  if [[ "$NEWLINE_BEFORE_PROMPT" == "yes" ]]; then
    echo
  fi
}
