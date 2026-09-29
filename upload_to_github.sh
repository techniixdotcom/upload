#!/bin/bash
set -e

# ---- Check that user is logged into git ----
echo "Checking GitHub authentication..."
if ! git ls-remote https://github.com/octocat/Hello-World.git HEAD &>/dev/null; then
    echo "You don't seem to be logged in to GitHub."
    echo "   Please configure git credentials (SSH key or PAT) first."
    exit 1
fi
echo "✓ Git authentication OK"
echo ""

# ---- Ask for repository ----
read -p "GitHub repository (user/repo or full URL): " REPO_INPUT
if [ -z "$REPO_INPUT" ]; then
    echo "No repository given."
    exit 1
fi

REPO_URL=""
if [[ "$REPO_INPUT" =~ ^https?:// ]]; then
    REPO_URL="$REPO_INPUT"
elif [[ "$REPO_INPUT" =~ ^git@ ]]; then
    REPO_URL="$REPO_INPUT"
elif [[ "$REPO_INPUT" =~ ^[^/]+/[^/]+$ ]]; then
    REPO_URL="https://github.com/${REPO_INPUT}.git"
else
    echo "Unrecognized repository format: '$REPO_INPUT'"
    exit 1
fi
echo "→ Will use: $REPO_URL"
echo ""

# ---- Ask for branch ----
read -p "Branch [main]: " BRANCH
BRANCH=${BRANCH:-main}

# ---- Ask for local folder ----
read -p "Local folder to upload: " SOURCE_FOLDER
SOURCE_FOLDER="${SOURCE_FOLDER/#\~/$HOME}"

if [ ! -d "$SOURCE_FOLDER" ]; then
    echo "Folder '$SOURCE_FOLDER' does not exist."
    exit 1
fi

# ---- List subfolders ----
echo ""
echo "Contents of '$SOURCE_FOLDER':"
i=1
declare -a SUBDIRS
for d in "$SOURCE_FOLDER"/*/; do
    [ -d "$d" ] || continue
    SUBDIRS[$i]="$(basename "$d")"
    echo "  $i) ${SUBDIRS[$i]}"
    ((i++))
done

if [ ${#SUBDIRS[@]} -eq 0 ]; then
    echo "  (no subfolders — the whole folder will be uploaded)"
    SELECTED=""
else
    echo ""
    echo "Enter subfolder number(s) (comma-separated),"
    echo "press Enter to upload ALL subfolders,"
    echo "or type 'whole' to upload the whole folder including loose files."
    read -p "> " CHOICE

    SELECTED=""
    if [ -z "$CHOICE" ]; then
        SELECTED="all"
    elif [ "$CHOICE" = "whole" ]; then
        SELECTED="whole"
    else
        IFS=',' read -ra PICKS <<< "$CHOICE"
        for p in "${PICKS[@]}"; do
            p=$(echo "$p" | xargs)
            if ! [[ "$p" =~ ^[0-9]+$ ]] || [ -z "${SUBDIRS[$p]}" ]; then
                echo "Invalid selection: '$p'"
                exit 1
            fi
        done
        SELECTED="$CHOICE"
    fi
fi

# ---- Ask for target path in repo ----
DEFAULT_TARGET="$(basename "$SOURCE_FOLDER")"
read -p "Target path in repo [$DEFAULT_TARGET]: " TARGET_FOLDER
TARGET_FOLDER=${TARGET_FOLDER:-$DEFAULT_TARGET}

# ---- Commit message ----
read -p "Commit message [Upload folder]: " COMMIT_MSG
COMMIT_MSG=${COMMIT_MSG:-Upload folder}

# ---- Clone repo ----
TEMP_DIR=$(mktemp -d)
echo ""
echo "Cloning $REPO_URL ..."
if ! git clone "$REPO_URL" "$TEMP_DIR"; then
    echo "Clone failed."
    rm -rf "$TEMP_DIR"
    exit 1
fi

cd "$TEMP_DIR"

# Switch to branch or create it
if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout "$BRANCH"
else
    echo "Branch '$BRANCH' doesn't exist on remote — creating it."
    git checkout -b "$BRANCH"
fi

cd - >/dev/null

# ---- Copy selected content ----
DEST="$TEMP_DIR/$TARGET_FOLDER"
mkdir -p "$DEST"

echo ""
echo "Copying files..."
case "$SELECTED" in
    whole)
        cp -r "$SOURCE_FOLDER"/. "$DEST"/
        ;;
    all)
        for d in "$SOURCE_FOLDER"/*/; do
            [ -d "$d" ] && cp -r "$d" "$DEST"/
        done
        ;;
    "")
        echo "  (nothing selected — skipping)"
        ;;
    *)
        IFS=',' read -ra PICKS <<< "$SELECTED"
        for p in "${PICKS[@]}"; do
            p=$(echo "$p" | xargs)
            cp -r "$SOURCE_FOLDER/${SUBDIRS[$p]}" "$DEST"/
        done
        ;;
esac

# ---- Commit and push ----
cd "$TEMP_DIR"
git add .
if git diff --cached --quiet; then
    echo "ℹ Nothing to commit (no changes)."
else
    git commit -m "$COMMIT_MSG"
    git push origin "$BRANCH"
    echo "✓ Pushed to $REPO_URL ($BRANCH)"
fi

cd - >/dev/null
rm -rf "$TEMP_DIR"
echo "Done!"
