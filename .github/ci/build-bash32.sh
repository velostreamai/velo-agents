#!/bin/bash
# build-bash32.sh <prefix> - GNU bash 3.2.57, built from source into <prefix>/bin/bash.
#
# Bar B14 of docs/velo-task-spec.md says the velo-task scripts and hooks run under bash 3.2, the /bin/bash macOS ships, and
# tests/test_velo_task_bash32.sh and tests/test_velo_task_hooks.sh prove it by running them under one. A Linux host has none (its
# /bin/bash is 5.x, which runs the bash-4 constructs those suites exist to refuse), so CI builds the same release and the suites
# take its path from VELO_TEST_BASH32. The source is checked against its published SHA-256 before anything is built.
# Idempotent: a <prefix>/bin/bash that already reports 3.2.57 is left alone, so a restored cache costs nothing.
set -euo pipefail
PREFIX="${1:?usage: build-bash32.sh <prefix>}"
VERSION=3.2.57
SHA256=3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4
MIRRORS=("https://ftpmirror.gnu.org/gnu/bash" "https://ftp.gnu.org/gnu/bash")

if [ -x "$PREFIX/bin/bash" ] && have=$("$PREFIX/bin/bash" -c 'echo "$BASH_VERSION"') && [ "${have#"$VERSION"}" != "$have" ]; then
  echo "build-bash32: bash $have is already in $PREFIX"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tarball="$WORK/bash-$VERSION.tar.gz"
fetched=""
for mirror in "${MIRRORS[@]}"; do
  if curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 \
       --output "$tarball" "$mirror/bash-$VERSION.tar.gz"; then
    fetched="$mirror"; break
  fi
  echo "build-bash32: could not fetch bash-$VERSION.tar.gz from $mirror" >&2
done
[ -n "$fetched" ] || { echo "build-bash32: no mirror served bash-$VERSION.tar.gz" >&2; exit 1; }
sum=$(sha256sum "$tarball" | cut -d' ' -f1)
[ "$sum" = "$SHA256" ] || { echo "build-bash32: the tarball from $fetched has SHA-256 $sum, not $SHA256" >&2; exit 1; }

command -v bison >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y -qq --no-install-recommends bison; }

tar -xzf "$tarball" -C "$WORK"
(
  cd "$WORK/bash-$VERSION"
  # The release ships a generated parser (y.tab.c) that a current compiler rejects; build it from parse.y instead. -std=gnu89 is
  # the dialect this 2014 release is written in (a newer default turns its K&R declarations and implicit ints into errors), and
  # --build names the host because the release's config.guess predates arm64 Linux.
  rm -f y.tab.c y.tab.h
  CFLAGS="-O2 -std=gnu89 -w" ./configure --prefix="$PREFIX" --build="$(uname -m)-unknown-linux-gnu" --without-bash-malloc \
    >"$WORK/configure.log" 2>&1 || { tail -n 40 "$WORK/configure.log" >&2; exit 1; }
  make YACC="bison -y" >"$WORK/make.log" 2>&1 || { tail -n 60 "$WORK/make.log" >&2; exit 1; }
  install -d "$PREFIX/bin"
  install -m 755 bash "$PREFIX/bin/bash"
)

got=$("$PREFIX/bin/bash" -c 'echo "$BASH_VERSION"')
[ "${got#"$VERSION"}" != "$got" ] || { echo "build-bash32: built a bash that reports '$got', not $VERSION" >&2; exit 1; }
echo "build-bash32: built bash $got in $PREFIX"
