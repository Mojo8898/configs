# Alias for arsenal
alias a='arsenal'

precmd() {
  if [[ "$NEWLINE_BEFORE_PROMPT" == "yes" ]]; then
    echo
  fi
}
