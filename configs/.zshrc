# Go
export GOPATH=$HOME/go
export PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# Alias for arsenal
alias a='arsenal'

precmd() {
  if [[ "$NEWLINE_BEFORE_PROMPT" == "yes" ]]; then
    echo
  fi
}
