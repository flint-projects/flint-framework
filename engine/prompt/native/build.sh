#!/bin/sh
set -eu
mkdir -p build
object=$(mktemp build/prompt-secret.XXXXXXXX.o)
trap 'if [ -f "$object" ]; then unlink "$object"; fi' EXIT
case " ${DFLAGS:-} " in
    *" -fsanitize=address "*) set -- -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer ;;
    *) set -- -O2 ;;
esac
"${CC:-cc}" -std=c11 -Wall -Wextra -Wpedantic -Werror -fPIC "$@" -c native/secret.c -o "$object"
mv "$object" build/prompt-secret.o
