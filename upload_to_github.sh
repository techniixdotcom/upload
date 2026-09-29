#!/usr/bin/env bash
#
# upload_to_github.sh
# written by techniix - version 1.0.0
#
# pushes a local folder (or some of its subfolders) into a github repo.
# asks for your github username + token itself, no git setup needed.
# works with classic tokens, fine-grained tokens, oauth tokens and app tokens.

set -eu

TMP=""
AUTHDIR=""
cleanup() {
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
    if [ -n "$AUTHDIR" ]; then rm -rf "$AUTHDIR"; fi
}
trap cleanup EXIT

command -v git >/dev/null || { echo "git not found, install it first"; exit 1; }
HAVE_CURL=1
command -v curl >/dev/null || HAVE_CURL=0

# --- login ---
# github doesn't take real account passwords for git anymore, so the
# "password" has to be a token. any kind works, the script figures out which.
echo "github login"
read -r -p "username: " GH_USER
[ -z "$GH_USER" ] && { echo "no username"; exit 1; }
read -r -s -p "token (typing is hidden): " GH_TOKEN
echo
GH_TOKEN=$(printf '%s' "$GH_TOKEN" | tr -d '[:space:]')
[ -z "$GH_TOKEN" ] && { echo "no token"; exit 1; }

# --- work out what kind of token this is ---
KIND=unknown
case "$GH_TOKEN" in
    ghp_*)        KIND=classic ;;
    github_pat_*) KIND=fine ;;
    gho_*|ghu_*)  KIND=oauth ;;
    ghs_*)        KIND=app ;;
    ghr_*)        echo "that's a refresh token, not an access token. can't use it."; exit 1 ;;
    *)
        # old classic tokens were just 40 hex chars
        if [[ "$GH_TOKEN" =~ ^[0-9a-f]{40}$ ]]; then KIND=classic; fi ;;
esac

case "$KIND" in
    classic) echo "token type: classic personal access token" ;;
    fine)    echo "token type: fine-grained personal access token" ;;
    oauth)   echo "token type: oauth / github app user token" ;;
    app)     echo "token type: github app installation token"; GH_USER="x-access-token" ;;
    *)       echo "token type: not recognised, trying it anyway" ;;
esac

DEF_EMAIL="${GH_USER}@users.noreply.github.com"
[ "$KIND" = app ] && DEF_EMAIL="noreply@github.com"
read -r -p "commit author name [$GH_USER]: " AUTHOR
AUTHOR=${AUTHOR:-$GH_USER}
read -r -p "commit author email [$DEF_EMAIL]: " EMAIL
EMAIL=${EMAIL:-$DEF_EMAIL}

# hand the credentials to git through a tiny askpass script. keeps the token
# out of the url, out of ps output and out of .git/config
AUTHDIR=$(mktemp -d)
cat > "$AUTHDIR/askpass.sh" <<'EOF'
#!/bin/sh
case "$1" in
    Username*) printf '%s\n' "$GH_USER" ;;
    *)         printf '%s\n' "$GH_TOKEN" ;;
esac
EOF
chmod 700 "$AUTHDIR/askpass.sh"

export GH_USER GH_TOKEN
export GIT_ASKPASS="$AUTHDIR/askpass.sh"
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="$AUTHOR" GIT_COMMITTER_NAME="$AUTHOR"
export GIT_AUTHOR_EMAIL="$EMAIL" GIT_COMMITTER_EMAIL="$EMAIL"
# ignore stored credential helpers so only what you typed gets used
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=

echo
read -r -p "repo (user/repo or https url): " INPUT
[ -z "$INPUT" ] && { echo "no repo given"; exit 1; }

case "$INPUT" in
    https://*)
        URL="$INPUT" ;;
    http://*)
        echo "use https, not http"; exit 1 ;;
    git@github.com:*)
        URL="https://github.com/${INPUT#git@github.com:}" ;;
    git@*|ssh://*)
        echo "ssh urls can't use a token, give me user/repo or an https url"; exit 1 ;;
    *)
        if [[ "$INPUT" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
            URL="https://github.com/${INPUT%.git}.git"
        else
            echo "can't make sense of '$INPUT'"; exit 1
        fi ;;
esac
echo "using $URL"

# --- ask the github api what this token can actually do ---
# the token goes to curl on stdin so it never shows up in ps
api() {
    CODE=$(printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" | \
        curl -s -K - -H "Accept: application/vnd.github+json" \
        -D "$AUTHDIR/hdr" -o "$AUTHDIR/body" -w '%{http_code}' \
        "https://api.github.com$1") || CODE=000
}

hint() {
    case "$KIND" in
        classic)
            echo "  fix: your classic token needs the 'repo' scope."
            echo "  https://github.com/settings/tokens > click the token > tick 'repo' > update" ;;
        fine)
            echo "  fix: your fine-grained token needs, for this repo:"
            echo "    - the repo listed under 'Repository access' (or All repositories)"
            echo "    - 'Contents' set to 'Read and write' (default is read-only)"
            echo "    - 'Resource owner' set to the account/org that owns the repo"
            echo "  https://github.com/settings/personal-access-tokens" ;;
        oauth)
            echo "  fix: the app that issued this token needs write access to the repo's contents." ;;
        app)
            echo "  fix: the app installation needs 'Contents: write' and must be installed on this repo." ;;
        *)
            echo "  fix: make sure the token has write access to the repo contents." ;;
    esac
}

SLUG=""
case "$URL" in
    https://github.com/*)
        SLUG="${URL#https://github.com/}"; SLUG="${SLUG%/}"; SLUG="${SLUG%.git}" ;;
esac

if [ "$HAVE_CURL" -eq 1 ] && [ -n "$SLUG" ]; then
    echo "checking token with github..."

    # is the token even valid? (app installation tokens can't call /user, skip)
    if [ "$KIND" != app ]; then
        api /user
        if [ "$CODE" = 401 ]; then
            echo "github says the token is invalid, expired or revoked."
            exit 1
        fi
        if [ "$CODE" = 200 ]; then
            WHO=$(sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' "$AUTHDIR/body" | head -1)
            [ -n "$WHO" ] && echo "  token belongs to: $WHO"
        fi
        if [ "$KIND" = classic ]; then
            SCOPES=$(grep -i '^x-oauth-scopes:' "$AUTHDIR/hdr" | head -1 | cut -d: -f2- | tr -d '\r' | xargs || true)
            echo "  scopes: ${SCOPES:-none}"
            case ",$(echo "$SCOPES" | tr -d ' ')," in
                *,repo,*|*,public_repo,*) ;;
                *) echo "this token has no 'repo' or 'public_repo' scope, pushes will fail."
                   hint; exit 1 ;;
            esac
        fi
    fi

    api "/repos/$SLUG"
    case "$CODE" in
        200)
            PERMS=$(tr -d '\n' < "$AUTHDIR/body" | grep -o '"permissions": *{[^}]*}' | head -1 || true)
            if echo "$PERMS" | grep -q '"push": *true'; then
                echo "  write access to $SLUG: yes"
            elif [ -n "$PERMS" ]; then
                echo "  write access to $SLUG: NO (token can read it but not push)"
                hint
                exit 1
            fi ;;
        401)
            echo "github rejected the token."; exit 1 ;;
        404)
            echo "github says '$SLUG' doesn't exist, or this token can't see it."
            echo "  check the spelling first. if it's a private repo:"
            hint
            exit 1 ;;
        403)
            echo "github blocked the request (403)."
            if grep -qi '^x-github-sso' "$AUTHDIR/hdr"; then
                echo "  this org uses SSO: authorize the token for it under Settings > Tokens > Configure SSO."
            else
                hint
            fi
            exit 1 ;;
        000)
            echo "  couldn't reach api.github.com, skipping the pre-check" ;;
        *)
            echo "  api returned $CODE, continuing to the push test anyway" ;;
    esac
fi

# Final login/write test.
# ls-remote works with no credentials on public repos so it proves nothing.
# a dry-run push makes github check auth, so we dry-run an empty commit from
# a scratch repo. nothing gets created on the remote.
echo "testing push access..."
PROBE=$(mktemp -d)
git -C "$PROBE" init -q
git -C "$PROBE" commit -q --allow-empty -m probe
if ! git -C "$PROBE" push --dry-run -q "$URL" HEAD:refs/heads/auth-probe-do-not-create >/dev/null 2>"$PROBE/err"; then
    echo "push test failed. git said:"
    sed 's/^/  /' "$PROBE/err"
    hint
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
