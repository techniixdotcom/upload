#!/usr/bin/env bash
#
# upload_to_github.sh
# written by techniix - version 1.0.0
#
# pushes a local folder (or some of its subfolders) into a github repo

set -eu

TMP=""
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT

command -v git >/dev/null || { echo "git not found, install it first"; exit 1; }

if [ -z "$(git config --get user.name || true)" ] || [ -z "$(git config --get user.email || true)" ]; then
    echo "git user.name / user.email not set. do this first:"
    echo "  git config --global user.name \"you\""
    echo "  git config --global user.email \"you@example.com\""
    exit 1
fi

# don't let git sit there waiting on a password prompt
export GIT_TERMINAL_PROMPT=0

read -r -p "repo (user/repo or full url): " INPUT
[ -z "$INPUT" ] && { echo "no repo given"; exit 1; }

case "$INPUT" in
    http://*|https://*|git@*|ssh://*)
        URL="$INPUT" ;;
    */*)
        if [[ "$INPUT" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            URL="https://github.com/${INPUT%.git}.git"
        else
            echo "can't make sense of '$INPUT'"; exit 1
        fi ;;
    *)
        echo "can't make sense of '$INPUT'"; exit 1 ;;
esac
echo "using $URL"

# Real login check.
# Reading a public repo works with no credentials at all, so ls-remote proves
# nothing. Pushing (even with --dry-run) makes github ask for auth, so we
# dry-run a push of an empty commit from a scratch repo. Nothing gets created
# on the remote.
echo "checking that you're logged in and can push..."
PROBE="$(mktemp -d)"
git -C "$PROBE" init -q
git -C "$PROBE" -c user.name=probe -c user.email=probe@localhost commit -q --allow-empty -m probe
if ! git -C "$PROBE" push --dry-run -q "$URL" HEAD:refs/heads/auth-probe-do-not-create >/dev/null 2>"$PROBE/err"; then
    echo "not logged in, or no write access to that repo."
    echo "git said:"
    sed 's/^/  /' "$PROBE/err"
    echo "set up an SSH key or a personal access token and try again."
    rm -rf "$PROBE"
    exit 1
fi
rm -rf "$PROBE"
echo "login ok"
echo

read -r -p "branch [main]: " BRANCH
BRANCH=${BRANCH:-main}
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || { echo "bad branch name"; exit 1; }

read -r -p "local folder to upload: " SRC
[ -z "$SRC" ] && { echo "no folder given"; exit 1; }
SRC="${SRC/#\~/$HOME}"
SRC="${SRC%/}"
[ -d "$SRC" ] || { echo "'$SRC' isn't a folder"; exit 1; }

echo
echo "in $SRC:"
SUBS=()
for d in "$SRC"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [ "$n" = ".git" ] && continue
    SUBS+=("$n")
    echo "  ${#SUBS[@]}) $n"
done

MODE=whole
PICKED=()
if [ ${#SUBS[@]} -eq 0 ]; then
    echo "  no subfolders, uploading the whole thing"
else
    echo
    echo "numbers separated by commas, enter for every subfolder,"
    echo "or 'whole' to include loose files too"
    read -r -p "> " CHOICE
    if [ -z "$CHOICE" ]; then
        MODE=all
    elif [ "$CHOICE" != "whole" ]; then
        MODE=picks
        IFS=',' read -ra RAW <<< "$CHOICE"
        for x in "${RAW[@]}"; do
            x=$(echo "$x" | xargs)
            if ! [[ "$x" =~ ^[0-9]+$ ]] || [ "$x" -lt 1 ] || [ "$x" -gt ${#SUBS[@]} ]; then
                echo "bad number: '$x'"; exit 1
            fi
            PICKED+=("${SUBS[$((x-1))]}")
        done
    fi
fi

DEF=$(basename "$SRC")
read -r -p "path inside repo [$DEF]: " TARGET
TARGET=${TARGET:-$DEF}
TARGET="${TARGET#/}"; TARGET="${TARGET%/}"
case "/$TARGET/" in
    */../*) echo "no '..' in the target path"; exit 1 ;;
    /.git/*) echo "can't write into .git"; exit 1 ;;
esac
[ -z "$TARGET" ] && TARGET=.

read -r -p "commit message [Upload folder]: " MSG
MSG=${MSG:-Upload folder}

TMP=$(mktemp -d)
echo
echo "cloning..."
git clone -q "$URL" "$TMP" || { echo "clone failed"; exit 1; }

if git -C "$TMP" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git -C "$TMP" checkout -q "$BRANCH"
else
    echo "branch '$BRANCH' isn't on the remote yet, making it"
    git -C "$TMP" checkout -q -b "$BRANCH"
fi

DEST="$TMP/$TARGET"
mkdir -p "$DEST"

# tar so we can skip .git dirs (cp -r would drag them along)
copy() { (cd "$1" && tar --exclude=.git -cf - .) | (cd "$2" && tar -xf -); }

echo "copying..."
if [ "$MODE" = whole ]; then
    copy "$SRC" "$DEST"
elif [ "$MODE" = all ]; then
    for n in "${SUBS[@]}"; do mkdir -p "$DEST/$n"; copy "$SRC/$n" "$DEST/$n"; done
else
    for n in "${PICKED[@]}"; do mkdir -p "$DEST/$n"; copy "$SRC/$n" "$DEST/$n"; done
fi

git -C "$TMP" add -A
if git -C "$TMP" diff --cached --quiet; then
    echo "nothing changed, nothing to push"
    exit 0
fi

git -C "$TMP" commit -q -m "$MSG"
git -C "$TMP" push -q -u origin "$BRANCH"
echo "pushed to $URL on $BRANCH"
