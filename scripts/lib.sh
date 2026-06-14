# FINFA shared shell helpers — sourced by setup.sh and friends. Keep tiny.
# shellcheck shell=bash

# Colors (disabled if not a tty)
if [[ -t 1 ]]; then
  _C_B=$'\e[1m'; _C_G=$'\e[32m'; _C_Y=$'\e[33m'; _C_R=$'\e[31m'; _C_D=$'\e[2m'; _C_0=$'\e[0m'
else
  _C_B=; _C_G=; _C_Y=; _C_R=; _C_D=; _C_0=
fi

say()  { printf '%s\n' "${_C_G}$*${_C_0}"; }
note() { printf '%s\n' "${_C_D}$*${_C_0}"; }
warn() { printf '%s\n' "${_C_Y}! $*${_C_0}" >&2; }
err()  { printf '%s\n' "${_C_R}✗ $*${_C_0}" >&2; }
step() { printf '\n%s\n' "${_C_B}══ $* ${_C_0}"; }

# ask "Question" "default" -> echoes answer (default if user hits enter)
ask() {
  local q="$1" def="${2:-}" ans
  if [[ -n "$def" ]]; then
    read -r -p "$q [${def}]: " ans || true
    printf '%s' "${ans:-$def}"
  else
    read -r -p "$q: " ans || true
    printf '%s' "$ans"
  fi
}

# ask_secret "Question" -> echoes typed value without showing it; empty allowed
ask_secret() {
  local q="$1" ans
  read -r -s -p "$q: " ans || true
  echo >&2
  printf '%s' "$ans"
}

# confirm "Question" [default y|n] -> returns 0 for yes, 1 for no
confirm() {
  local q="$1" def="${2:-y}" ans hint="[Y/n]"
  [[ "$def" == n ]] && hint="[y/N]"
  read -r -p "$q $hint " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

# Run a step only after a yes/skip/abort choice. Returns 0=do, 1=skip.
gate() {
  local q="$1" ans
  read -r -p "$q [Y]es / [s]kip / [a]bort: " ans || true
  case "${ans:-y}" in
    [Yy]*) return 0 ;;
    [Ss]*) warn "skipped"; return 1 ;;
    *)     err "aborted by user"; exit 130 ;;
  esac
}

genpw() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24; echo; }
