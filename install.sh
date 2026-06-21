#!/bin/sh
# install.sh - install agent-done-or-not into the current directory.
set -eu

REPO_URL="https://raw.githubusercontent.com/mohamedzhioua/agent-done-or-not"
REF="${REF:-main}"
BASE_URL="$REPO_URL/$REF"

say() {
  printf 'install: %s\n' "$1"
}

die() {
  printf 'install: ERROR: %s\n' "$1" >&2
  exit 1
}

fetch_file() {
  file="$1"
  tmp=".$file.tmp.$$"

  if [ -n "${AGENT_DONE_LOCAL_SRC:-}" ]; then
    src="$AGENT_DONE_LOCAL_SRC/$file"
    [ -f "$src" ] || die "local source missing $src"
    say "copying $file from $AGENT_DONE_LOCAL_SRC"
    cp "$src" "$tmp" || die "failed to copy $src"
  else
    url="$BASE_URL/$file"
    say "fetching $url"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" > "$tmp" || die "failed to fetch $url with curl"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- "$url" > "$tmp" || die "failed to fetch $url with wget"
    else
      die "need curl or wget to download scripts"
    fi
  fi

  if [ -e "$file" ]; then
    say "updating existing $file"
  else
    say "installing $file"
  fi
  mv "$tmp" "$file" || die "failed to write $file"
  chmod +x "$file" || die "failed to chmod +x $file"
  say "made $file executable"
}

add_gitignore_entry() {
  entry=".agent-proof/"

  if [ -f .gitignore ] && grep -Fx "$entry" .gitignore >/dev/null 2>&1; then
    say ".gitignore already contains $entry"
    return
  fi

  if [ ! -f .gitignore ]; then
    say "creating .gitignore"
    printf '%s\n' "$entry" > .gitignore || die "failed to create .gitignore"
  else
    say "adding $entry to .gitignore"
    if [ -s .gitignore ] && [ "$(tail -c 1 .gitignore 2>/dev/null || printf x)" != "" ]; then
      printf '\n' >> .gitignore || die "failed to update .gitignore"
    fi
    printf '%s\n' "$entry" >> .gitignore || die "failed to update .gitignore"
  fi
}

say "installing into $(pwd)"
fetch_file done-gate.sh
fetch_file stop-gate.sh
add_gitignore_entry

say "done"
printf '\nNext steps:\n'
printf '  Wire the Stop hook in .claude/settings.json.\n'
printf '  See examples/install.md for the snippet; this installer does not edit settings.\n'
