#!/usr/bin/env bash
# Turn the current release-X.Y.Z branch of this fork into Gentoo user patches for
# x11-terms/kitty-X.Y.Z, so that the Portage ebuild builds the fork.
#
# The difference between upstream vX.Y.Z and the release branch is installed as:
#   /etc/portage/patches/x11-terms/kitty-X.Y.Z/<name>.patch   text changes, applied by eapply_user
#   /etc/portage/patches/x11-terms/kitty-X.Y.Z/files/...      changed binary files (patch cannot apply binary diffs)
#   /etc/portage/env/x11-terms/kitty-X.Y.Z                    post_src_prepare hook copying files/ into the source
#
# The upstream remote (kovidgoyal/kitty) is added if missing and the vX.Y.Z tag is fetched
# from it every run. This gentoo/ directory is never part of the generated patch.
#
# Usage: gentoo/make-portage-patch.sh [-n|--dry-run] [--name NAME.patch]

set -euo pipefail

CATEGORY=x11-terms
PN=kitty
PATCH_NAME=akujin-remix.patch
DRY_RUN=0
EXCLUDE=':(exclude)gentoo'
UPSTREAM_REMOTE=upstream
UPSTREAM_URL=https://github.com/kovidgoyal/kitty.git

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

usage() {
    sed -n '2,15s/^# \{0,1\}//p' "$0"
    exit "${1:-0}"
}

while (($#)); do
    case $1 in
        -n|--dry-run) DRY_RUN=1 ;;
        --name) shift; (($#)) || die '--name needs a value'; PATCH_NAME=$1 ;;
        --name=*) PATCH_NAME=${1#--name=} ;;
        -h|--help) usage ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
    esac
    shift
done
[[ $PATCH_NAME == *.patch || $PATCH_NAME == *.diff ]] || die "--name must end in .patch or .diff, eapply_user ignores anything else"
[[ $PATCH_NAME != */* ]] || die '--name must be a plain file name'

REPO=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
g() { git -C "$REPO" "$@"; }

# 1. Versions
BRANCH=$(g symbolic-ref --quiet --short HEAD) || die 'HEAD is detached, check out a release-X.Y.Z branch'
[[ $BRANCH =~ ^release-([0-9]+(\.[0-9]+)*)$ ]] || die "current branch '$BRANCH' is not a release-X.Y.Z branch"
VER=${BASH_REMATCH[1]}

# The patch is made against upstream's release tag, which is what the Portage
# distfile is built from, fetched from kovidgoyal/kitty every run.
if url=$(g remote get-url "$UPSTREAM_REMOTE" 2>/dev/null); then
    [[ $url =~ github\.com[:/]kovidgoyal/kitty(\.git)?/?$ ]] ||
        die "remote '$UPSTREAM_REMOTE' points to $url, not kovidgoyal/kitty, fix it with: git remote set-url $UPSTREAM_REMOTE $UPSTREAM_URL"
else
    g remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    info "Added remote '$UPSTREAM_REMOTE' -> $UPSTREAM_URL"
fi
BASE=refs/tags/v$VER
info "Fetching v$VER from $UPSTREAM_REMOTE..."
if ! out=$(g fetch --quiet --no-tags "$UPSTREAM_REMOTE" "+refs/tags/v$VER:refs/upstream-check/v$VER" 2>&1); then
    printf '%s\n' "$out" >&2
    g show-ref --verify --quiet "$BASE" || die "could not fetch tag v$VER from $UPSTREAM_REMOTE, does upstream have that release?"
    warn "could not fetch v$VER from $UPSTREAM_REMOTE, using the local tag as is"
else
    fetched=$(g rev-parse "refs/upstream-check/v$VER^{commit}")
    g update-ref -d "refs/upstream-check/v$VER"
    if g show-ref --verify --quiet "$BASE"; then
        [[ $(g rev-parse "$BASE^{commit}") == "$fetched" ]] ||
            die "local tag v$VER does not match upstream's, delete it with 'git tag -d v$VER' and run again"
    else
        g fetch --quiet --no-tags "$UPSTREAM_REMOTE" "refs/tags/v$VER:refs/tags/v$VER"
    fi
fi
if g show-ref --verify --quiet "refs/heads/v$VER" &&
    [[ $(g rev-parse "refs/heads/v$VER") != $(g rev-parse "$BASE^{commit}") ]]; then
    warn "local branch v$VER does not match upstream's tag v$VER, the tag is used"
fi
g merge-base --is-ancestor "$BASE" HEAD ||
    warn "$BRANCH does not contain upstream v$VER, merge it first or the patch will revert upstream changes"
if [[ -n $(g status --porcelain --untracked-files=no) ]]; then
    ((DRY_RUN)) || die 'the working tree has uncommitted changes, commit them first so the patch matches the branch'
    warn 'the working tree has uncommitted changes, they are not part of the patch'
fi
HEAD_REV=$(g rev-parse --short HEAD)
BASE_REV=$(g rev-parse --short "$BASE^{commit}")
info "Fork:     $BRANCH ($HEAD_REV)"
info "Upstream: $BASE ($BASE_REV)"

# 2. Ebuild
P=$PN-$VER
GENTOO_REPO=$(portageq get_repo_path / gentoo 2>/dev/null || true)
GENTOO_REPO=${GENTOO_REPO:-/var/db/repos/gentoo}
[[ -f $GENTOO_REPO/$CATEGORY/$PN/$P.ebuild ]] || die "no ebuild $GENTOO_REPO/$CATEGORY/$PN/$P.ebuild, sync the tree or wait for Gentoo to package $VER"
for repo in $(portageq get_repos / 2>/dev/null || true); do
    [[ $repo == gentoo ]] && continue
    path=$(portageq get_repo_path / "$repo" 2>/dev/null || true)
    [[ -n $path && -f $path/$CATEGORY/$PN/$P.ebuild ]] && warn "overlay '$repo' also has $P.ebuild, it may be the one emerged"
done
info "Ebuild:   $GENTOO_REPO/$CATEGORY/$PN/$P.ebuild"

# 3. Changed files
binaries=()
while IFS=$'\t' read -r added deleted path; do
    [[ $added == - && $deleted == - ]] && binaries+=("$path")
done < <(g diff --no-renames --numstat "$BASE" HEAD -- . "$EXCLUDE")

to_copy=() skipped=()
for path in "${binaries[@]}"; do
    if ! g cat-file -e "HEAD:$path" 2>/dev/null; then
        die "binary file '$path' was deleted by the fork, the copy hook cannot express that"
    elif g cat-file -e "$BASE:$path" 2>/dev/null; then
        to_copy+=("$path")   # replaces a file kitty ships
    else
        skipped+=("$path")   # only used by the fork's README, not part of the build
    fi
done

excludes=("$EXCLUDE")
for path in "${binaries[@]}"; do excludes+=(":(exclude,literal)$path"); done

# 4. Stage
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STAGE=$TMP/stage
mkdir -p "$STAGE/files"
g diff --no-color --no-ext-diff --no-renames --full-index "$BASE" HEAD -- . "${excludes[@]}" > "$STAGE/$PATCH_NAME"
[[ -s $STAGE/$PATCH_NAME ]] || die "no text changes between $BASE and $BRANCH"
for path in "${to_copy[@]}"; do
    mkdir -p "$STAGE/files/$(dirname "$path")"
    g show "HEAD:$path" > "$STAGE/files/$path"
done
cat > "$STAGE/hook" <<'EOF'
# Generated by gentoo/make-portage-patch.sh in the kitty fork, do not edit.
# Copies the fork's changed binary files, which a patch cannot carry, into the source.
post_src_prepare() {
	local patch_dir="${PORTAGE_CONFIGROOT%/}/etc/portage/patches/${CATEGORY}/${P}"
	if [[ -d ${patch_dir}/files ]]; then
		cp -r "${patch_dir}"/files/. ./ || die "kitty fork: copying binary files failed"
	fi
}
EOF

info ''
info "Patch $PATCH_NAME, $(grep -c '^diff --git ' "$STAGE/$PATCH_NAME") files:"
g diff --no-renames --stat=100 "$BASE" HEAD -- . "${excludes[@]}" | sed 's/^/  /'
if ((${#to_copy[@]})); then
    info 'Binary files copied by the hook:'
    printf '  %s\n' "${to_copy[@]}"
fi
if ((${#skipped[@]})); then
    info 'Binary files skipped (new files not shipped by upstream):'
    printf '  %s\n' "${skipped[@]}"
fi

# 5. Check the patch applies to the tarball the ebuild unpacks
DISTDIR=$(portageq envvar DISTDIR 2>/dev/null || true)
TARBALL=${DISTDIR:-/var/cache/distfiles}/$P.tar.xz
info ''
if [[ -f $TARBALL ]]; then
    tar -xf "$TARBALL" -C "$TMP"
    [[ -d $TMP/$P ]] || die "$TARBALL did not unpack to $P/"
    if ! out=$(patch -d "$TMP/$P" -p1 -f -g0 --dry-run -i "$STAGE/$PATCH_NAME" 2>&1); then
        printf '%s\n' "$out" >&2
        die "the patch does not apply to $TARBALL"
    fi
    info "Patch applies cleanly to $TARBALL"
else
    warn "$TARBALL not found, cannot check the patch applies, fetch it with: emerge --fetchonly =$CATEGORY/$P"
fi

PATCH_DIR=/etc/portage/patches/$CATEGORY/$P
HOOK=/etc/portage/env/$CATEGORY/$P
if ((DRY_RUN)); then
    info ''
    info "Dry run, would install:"
    info "  $PATCH_DIR/$PATCH_NAME"
    for path in "${to_copy[@]}"; do info "  $PATCH_DIR/files/$path"; done
    info "  $HOOK"
    exit 0
fi

# 6. Install
info ''
# Install src as dest with a .bak of a differing previous version
install_file() {
    local src=$1 dest=$2
    if sudo test -e "$dest"; then
        if sudo cmp -s "$src" "$dest"; then
            info "unchanged  $dest"
            return
        fi
        if grep -Iq . "$src"; then sudo diff -u "$dest" "$src" | sed 's/^/    /' || true; fi
        sudo cp -a "$dest" "$dest.bak"
        info "updated    $dest (previous saved as $dest.bak)"
    else
        info "installed  $dest"
    fi
    sudo install -D -m644 "$src" "$dest"
}

sudo install -d -m755 "$PATCH_DIR" "$(dirname "$HOOK")"
install_file "$STAGE/$PATCH_NAME" "$PATCH_DIR/$PATCH_NAME"
for path in "${to_copy[@]}"; do install_file "$STAGE/files/$path" "$PATCH_DIR/files/$path"; done
# Drop binary files from earlier runs that the fork no longer changes
if sudo test -d "$PATCH_DIR/files"; then
    while IFS= read -r -d '' f; do
        rel=${f#"$PATCH_DIR/files/"}
        if [[ ! -e $STAGE/files/$rel ]]; then
            sudo rm -f "$f"
            info "removed    $f"
        fi
    done < <(sudo find "$PATCH_DIR/files" -type f -print0)
    sudo find "$PATCH_DIR/files" -depth -type d -empty -delete
fi
install_file "$STAGE/hook" "$HOOK"

others=$(sudo find "$PATCH_DIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) ! -name "$PATCH_NAME" -printf '  %p\n')
[[ -n $others ]] && warn "other patches in $PATCH_DIR will also be applied:"$'\n'"$others"

# 7. Done
info ''
info "Done. Build it with: sudo emerge -1av =$CATEGORY/$P"
