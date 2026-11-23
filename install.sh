#!/usr/bin/env bash
# Copilot delivery pipeline: installer
#
#   install.sh [options] [target-dir]        target-dir defaults to the current directory
#
#   --update        update an existing install (keeps files you changed; see --force)
#   --uninstall     remove the pipeline (keeps .agent.env and .work/)
#   --force         with --update: overwrite files you changed (a .bak copy is kept)
#                   (without it, a file you changed is kept and the new version
#                   is written next to it as <file>.new, for you to merge)
#   --with-skills   also install the ponytail and caveman skills for Copilot
#   --local         keep the pipeline out of git: ignored in .git/info/exclude, on this machine only
#   --yes           don't ask questions (CI, scripts)
#   --version TAG   install a specific release when downloading (default: this script's version)
#
# Run from a clone:   ./install.sh /path/to/project
# Run via curl:       curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/TAG/install.sh | bash
set -euo pipefail

PIPELINE_VERSION="v2.2.0"
PIPELINE_REPO="${PIPELINE_REPO:-SuperEjay/copilot-delivery-pipeline}"
MANIFEST=".github/agent-pipeline.manifest"
UPDATE_FROM="v1.2.0"         # --update refuses an older install (ADR 0002)
UPDATE_VIA="v1.2.2"          # ... and says to update to this release first
BEGIN_MARK="<!-- BEGIN agent-pipeline (managed by install.sh; edits inside are replaced on update) -->"
END_MARK="<!-- END agent-pipeline -->"
GI_BEGIN="# BEGIN agent-pipeline"
GI_END="# END agent-pipeline"
LOCAL_RULES=".github/instructions/agent-pipeline.instructions.md"   # the rules, with --local

MODE=install; FORCE=false; SKILLS=false; YES=false; LOCAL=false; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update) MODE=update ;;
    --uninstall) MODE=uninstall ;;
    --force) FORCE=true ;;
    --with-skills) SKILLS=true ;;
    --local) LOCAL=true ;;
    --yes|-y) YES=true ;;
    --version) PIPELINE_VERSION="${2:?--version needs a tag}"; shift ;;
    -h|--help) sed -n '2,16p' "$0" 2>/dev/null || true; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
confirm() {   # confirm "question" -> 0 yes / 1 no; --yes or no terminal = yes
  $YES && return 0
  [ -r /dev/tty ] || return 0
  local a; read -r -p "$1 [y/N] " a </dev/tty || return 1
  [[ "$a" =~ ^[Yy] ]]
}
ask_no() {    # ask_no "question" -> 0 only on an explicit yes; --yes or no terminal = no
  $YES && return 1
  [ -r /dev/tty ] || return 1
  local a; read -r -p "$1 [y/N] " a </dev/tty || return 1
  [[ "$a" =~ ^[Yy] ]]
}
# remove_block <file> <begin> <end>: drop the lines between the markers, and the markers.
remove_block() {
  awk -v b="$2" -v e="$3" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
# put_block <file> <lines-file>: replace the lines inside the agent-pipeline
# block, or add the block at the end. Says which it did.
put_block() {
  local f="$1" lines="$2"
  if [ -f "$f" ] && grep -qF "$GI_BEGIN" "$f"; then
    awk -v b="$GI_BEGIN" -v e="$GI_END" -v l="$lines" '
      $0==b { print; while ((getline line < l) > 0) print line; skip=1; next }
      $0==e { skip=0; print; next }
      !skip' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    ok "updated the pipeline block in $f"
  else
    mkdir -p "$(dirname "$f")"
    { printf '\n%s\n' "$GI_BEGIN"; cat "$lines"; printf '%s\n' "$GI_END"; } >> "$f"
    ok "added the pipeline block to $f"
  fi
}
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# ---------- find this script's clone, if any ----------
# Before the cd below: a relative BASH_SOURCE (./install.sh) only resolves from the starting directory.
# Empty or not a file when piped from curl, so SELF_DIR stays empty and the payload is downloaded.
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ---------- locate the target project ----------
TARGET="${TARGET:-$PWD}"
[ -d "$TARGET" ] || die "Target directory not found: $TARGET"
TARGET="$(cd "$TARGET" && git rev-parse --show-toplevel 2>/dev/null)" || die "$TARGET is not inside a git repository."
cd "$TARGET"

# ---------- uninstall ----------
if [ "$MODE" = uninstall ]; then
  [ -f "$MANIFEST" ] || die "No pipeline install found here ($MANIFEST is missing)."
  say "Removing the agent pipeline from $TARGET"
  confirm "Remove all pipeline files listed in $MANIFEST?" || die "Cancelled."
  while IFS=$'\t' read -r _hash path; do
    case "$_hash" in "#"*|"") continue ;; esac
    rm -f "$path" "$path.new" && ok "removed $path"
  done < "$MANIFEST"
  rm -f "$MANIFEST"
  [ -f "$LOCAL_RULES" ] && rm -f "$LOCAL_RULES" && ok "removed $LOCAL_RULES"
  EXCLUDE="$(git rev-parse --git-path info/exclude)"
  if [ -f "$EXCLUDE" ] && grep -qF "$GI_BEGIN" "$EXCLUDE"; then
    remove_block "$EXCLUDE" "$GI_BEGIN" "$GI_END"; ok "removed the pipeline block from $EXCLUDE"
  fi
  if [ -f .github/copilot-instructions.md ] && grep -qF "$BEGIN_MARK" .github/copilot-instructions.md; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' .github/copilot-instructions.md > .github/copilot-instructions.md.tmp
    mv .github/copilot-instructions.md.tmp .github/copilot-instructions.md
    [ -s .github/copilot-instructions.md ] && grep -q '[^[:space:]]' .github/copilot-instructions.md || rm -f .github/copilot-instructions.md
    ok "removed the pipeline block from .github/copilot-instructions.md"
  fi
  if [ -f .gitignore ] && grep -qF "$GI_BEGIN" .gitignore; then
    remove_block .gitignore "$GI_BEGIN" "$GI_END"
    ok "removed the pipeline block from .gitignore"
  fi
  find .github/agents .github/instructions .github/prompts .github/skills/start-task .github/skills/fetch-review .github/skills/review-mr .github/skills .github/hooks scripts/agent/hooks scripts/agent docs -type d -empty -delete 2>/dev/null || true
  say ""
  say "Done. Kept: .agent.env (your settings) and .work/ (task folders). Delete them yourself if you no longer need them."
  exit 0
fi

# ---------- the oldest install --update accepts ----------
# The manifest's first line, written by every installer since v1.0.0, is
# "# agent-pipeline <version> installed <time>". --force doesn't skip this:
# an update from an older release is the path v2 dropped. It runs before the
# payload is downloaded, so a refused update touches nothing.
# minor_at_least <version> <floor>: vX.Y[.Z][-suffix] is at or above the floor's X.Y.
minor_at_least() {
  local v="${1#v}" f="${2#v}" vmaj vmin fmaj fmin
  vmaj="${v%%.*}"; vmin="${v#*.}"; vmin="${vmin%%[.-]*}"
  fmaj="${f%%.*}"; fmin="${f#*.}"; fmin="${fmin%%[.-]*}"
  case "$vmaj.$vmin" in *[!0-9.]*|.*|*.) return 2 ;; esac
  [ "$vmaj" -gt "$fmaj" ] || { [ "$vmaj" -eq "$fmaj" ] && [ "$vmin" -ge "$fmin" ]; }
}
if [ "$MODE" = update ] && [ -f "$MANIFEST" ]; then
  installed="$(head -n1 "$MANIFEST" | sed -n 's/^# agent-pipeline \(v[^ ]*\) installed.*/\1/p')"
  rc=0; [ -n "$installed" ] && { minor_at_least "$installed" "$UPDATE_FROM" || rc=$?; } || rc=2
  first_step="Update to $UPDATE_VIA first: curl -fsSL https://raw.githubusercontent.com/$PIPELINE_REPO/$UPDATE_VIA/install.sh | bash -s -- --update (or install.sh --update from a $UPDATE_VIA clone), then run this update again."
  [ "$rc" -eq 2 ] && die "Not updating: can't tell which version is installed (the first line of $MANIFEST should read '# agent-pipeline <version> installed …'). $first_step"
  [ "$rc" -ne 0 ] && die "Not updating: this install is $installed, and this release updates only from $UPDATE_FROM or later. $first_step"
fi

# ---------- get the payload ----------
if [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/payload" ]; then
  PAYLOAD="$SELF_DIR/payload"
  [ -f "$SELF_DIR/VERSION" ] && PIPELINE_VERSION="$(cat "$SELF_DIR/VERSION")"
else
  case "$PIPELINE_REPO" in __OWNER__/*) die "PIPELINE_REPO isn't set. Run from a clone, or set PIPELINE_REPO=owner/repo." ;; esac
  command -v curl >/dev/null || die "curl is required to download the pipeline."
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  say "Downloading $PIPELINE_REPO $PIPELINE_VERSION…"
  curl -fsSL "https://github.com/$PIPELINE_REPO/archive/refs/tags/$PIPELINE_VERSION.tar.gz" | tar -xz -C "$TMP" \
    || die "Download failed. Check the repo name and that tag $PIPELINE_VERSION exists."
  PAYLOAD="$(find "$TMP" -maxdepth 2 -type d -name payload | head -n1)"
  [ -n "$PAYLOAD" ] || die "Downloaded archive has no payload/ folder."
fi

if [ "$MODE" = install ] && [ -f "$MANIFEST" ]; then
  die "The pipeline is already installed here ($(head -n1 "$MANIFEST" | sed 's/^# //')). Use --update."
fi
if [ "$MODE" = update ] && [ ! -f "$MANIFEST" ]; then
  die "Nothing to update: the pipeline isn't installed here. Run without --update."
fi

# ---------- shared (committed) or local (kept out of git) ----------
# An update keeps the mode the manifest records; --local switches a shared install to local.
if [ -f "$MANIFEST" ] && grep -qx '# local' "$MANIFEST"; then LOCAL=true; fi
if [ "$MODE" = install ] && ! $LOCAL \
  && ask_no "Keep the pipeline out of git (only on this machine, not shared with your team)?"; then
  LOCAL=true
fi

say "Installing the agent pipeline $PIPELINE_VERSION into $TARGET"
$LOCAL && say "Local mode: the pipeline is ignored in .git/info/exclude and never committed."
say ""

# ---------- copy pipeline-owned files ----------
OLD_MANIFEST="$(mktemp)"
[ -f "$MANIFEST" ] && grep -v '^#' "$MANIFEST" > "$OLD_MANIFEST" || true
old_hash() { awk -F'\t' -v p="$1" '$2 == p { print $1; exit }' "$OLD_MANIFEST"; }

NEW_MANIFEST="$(mktemp)"
echo "# agent-pipeline $PIPELINE_VERSION installed $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NEW_MANIFEST"
$LOCAL && echo "# local" >> "$NEW_MANIFEST"
skipped=0; written=0; unchanged=0

while IFS= read -r rel; do
  case "$rel" in pipeline-instructions.md) continue ;; esac
  src="$PAYLOAD/$rel"; dst="$rel"
  new_hash="$(sha256 "$src")"
  if [ -f "$dst" ]; then
    cur_hash="$(sha256 "$dst")"
    if [ "$cur_hash" = "$new_hash" ]; then
      rm -f "$dst.new"   # merged: the .new is no longer needed
      unchanged=$((unchanged + 1)); printf '%s\t%s\n' "$new_hash" "$dst" >> "$NEW_MANIFEST"; continue
    fi
    recorded="$(old_hash "$dst")"
    if [ -n "$recorded" ] && [ "$cur_hash" != "$recorded" ] && ! $FORCE; then
      # Kept as you changed it; the new version goes next to it as <file>.new,
      # refreshed on each update. An agent file without the new version's
      # sections stops an auto run (next-stage.sh names it).
      cp "$src" "$dst.new"; case "$dst" in *.sh) chmod +x "$dst.new" ;; esac
      why=""; case "$dst" in .github/agents/*) why=" (an auto run needs the new agent files)" ;; esac
      warn "kept your changed $dst; the new version is in $dst.new. Merge it in$why, or re-run with --force to replace yours (a .bak is kept)"
      skipped=$((skipped + 1)); printf '%s\t%s\n' "$recorded" "$dst" >> "$NEW_MANIFEST"; continue
    fi
    if [ -z "$recorded" ] && [ "$MODE" = install ]; then
      cp "$dst" "$dst.bak"; warn "$dst already existed: saved your version as $dst.bak"
    elif $FORCE && [ -n "$recorded" ] && [ "$cur_hash" != "$recorded" ]; then
      cp "$dst" "$dst.bak"; warn "replaced your changed $dst (your version: $dst.bak)"
    fi
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"; rm -f "$dst.new"
  case "$dst" in *.sh) chmod +x "$dst" ;; esac
  printf '%s\t%s\n' "$new_hash" "$dst" >> "$NEW_MANIFEST"
  written=$((written + 1))
done < <(cd "$PAYLOAD" && find . -type f ! -name '.DS_Store' | sed 's#^\./##' | sort)

# Files dropped in this version: remove them if you never changed them.
while IFS=$'\t' read -r h p; do
  [ -z "$p" ] && continue
  awk -F'\t' -v p="$p" '$2 == p { found=1 } END { exit !found }' "$NEW_MANIFEST" && continue
  if [ -f "$p" ] && [ "$(sha256 "$p")" = "$h" ]; then rm -f "$p"; ok "removed $p (no longer part of the pipeline)"; fi
done < "$OLD_MANIFEST"
rm -f "$OLD_MANIFEST"
for d in .github/prompts .github/skills/start-task .github/skills/fetch-review .github/skills/review-mr; do
  [ -d "$d" ] && [ -z "$(ls -A "$d")" ] && rmdir "$d" 2>/dev/null || true
done
mkdir -p "$(dirname "$MANIFEST")"; mv "$NEW_MANIFEST" "$MANIFEST"
msg="pipeline files: $written written, $unchanged unchanged"; [ "$skipped" -gt 0 ] && msg="$msg, $skipped kept as you changed them"; ok "$msg"

# ---------- merge copilot-instructions.md ----------
INSTR=.github/copilot-instructions.md
if $LOCAL; then
  # Own file, so a tracked copilot-instructions.md stays unchanged and the tree clean.
  mkdir -p "$(dirname "$LOCAL_RULES")"
  { printf -- '---\napplyTo: "**"\n---\n\n'; cat "$PAYLOAD/pipeline-instructions.md"; } > "$LOCAL_RULES"
  ok "wrote the pipeline rules to $LOCAL_RULES"
  [ -f "$INSTR" ] && grep -qF "$BEGIN_MARK" "$INSTR" \
    && warn "$INSTR still has the pipeline block from a shared install: remove the lines between its BEGIN/END agent-pipeline markers (the rules are now in $LOCAL_RULES)"
else
block="$(printf '%s\n%s\n%s' "$BEGIN_MARK" "$(cat "$PAYLOAD/pipeline-instructions.md")" "$END_MARK")"
if [ -f "$INSTR" ] && grep -qF "$BEGIN_MARK" "$INSTR"; then
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$PAYLOAD/pipeline-instructions.md" '
    $0==b { print; while ((getline line < f) > 0) print line; skip=1; next }
    $0==e { skip=0; print; next }
    !skip' "$INSTR" > "$INSTR.tmp" && mv "$INSTR.tmp" "$INSTR"
  ok "updated the pipeline block in $INSTR"
elif [ -f "$INSTR" ]; then
  printf '\n%s\n' "$block" >> "$INSTR"; ok "appended the pipeline rules to your existing $INSTR"
else
  mkdir -p .github; printf '%s\n' "$block" > "$INSTR"; ok "created $INSTR"
fi
fi

# ---------- .gitignore ----------
GI_LINES='.work/
.agent.env
.auth/
*.bak
*.new'
gi_lines_file="$(mktemp)"; printf '%s\n' "$GI_LINES" > "$gi_lines_file"
if $LOCAL; then
  # Every pipeline path, anchored, so your own files in scripts/ or .github/ stay tracked.
  { printf '/%s\n' "$MANIFEST" "$LOCAL_RULES"
    grep -v '^#' "$MANIFEST" | cut -f2 | sed 's#^#/#'
    # Every skill folder, not just the ones --with-skills adds: `skills add` puts them all here.
    printf '%s\n' '/.agents/' '/skills-lock.json'
  } >> "$gi_lines_file"
  put_block "$(git rev-parse --git-path info/exclude)" "$gi_lines_file"
  # Ignoring doesn't untrack: pipeline files committed by a shared install stay in git.
  if [ -n "$(git ls-files -- "$MANIFEST" $(grep -v '^#' "$MANIFEST" | cut -f2))" ]; then
    warn "pipeline files are committed here, and ignoring them doesn't untrack them. To take them out of git (they stay on disk), run:"
    say  "      git rm -r --cached --quiet --ignore-unmatch -- $MANIFEST \$(grep -v '^#' $MANIFEST | cut -f2) && git commit -m 'Keep the agent pipeline out of git'"
  fi
  if [ -n "$(git ls-files -- .agents)" ]; then
    warn "files under .agents/ are committed here, so they stay tracked: only new, untracked skills are kept out of git. To take them out too, run:  git rm -r --cached --quiet .agents && git commit -m 'Keep agent skills out of git'"
  fi
else
  # On update, replace the block's lines, so an older install gets the ones added since.
  put_block .gitignore "$gi_lines_file"
fi
rm -f "$gi_lines_file"

# ---------- settings ----------
if [ -f .agent.env ]; then
  ok ".agent.env exists: left untouched"
  # Settings in the example that .agent.env doesn't set: listed, never written.
  new_keys="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' .agent.env.example | while read -r k; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$k=" .agent.env || printf '%s ' "$k"; done)"
  [ -n "$new_keys" ] && warn ".agent.env doesn't set: ${new_keys% } (new or unset settings: copy any you want from .agent.env.example)"
else
  cp .agent.env.example .agent.env; ok "created .agent.env from the example: fill in your project's values"
fi

# ---------- optional skills ----------
if $SKILLS || { [ "$MODE" = install ] && confirm "Install the ponytail and caveman skills for Copilot now?"; }; then
  if command -v npx >/dev/null 2>&1; then
    say ""
    # The second -y is skills' own: without it, and with stdin not a terminal,
    # `skills add` stops at its "Select skills" prompt and installs nothing.
    for repo in DietrichGebert/ponytail JuliusBrussee/caveman; do
      name="${repo#*/}"
      npx -y skills add "$repo" -a github-copilot -y </dev/null && ok "$name" \
        || warn "$name install failed: install it later with  npx -y skills add $repo -a github-copilot -y"
    done
  else
    warn "skipped skills: npx is missing"
  fi
fi

# ---------- check the setup ----------
# doctor.sh checks the tools, glab login, the token, .agent.env, line endings,
# the hook guard and VS Code, and changes nothing. A FAIL doesn't fail the
# install: the files are in place, and the setup steps below fix most FAILs.
say ""
say "Checking the setup (scripts/agent/doctor.sh):"
doctor_failed=false
bash scripts/agent/doctor.sh </dev/null || doctor_failed=true

say ""
say "Done. Next steps:"
$LOCAL && say "  (The pipeline is kept out of git, in .git/info/exclude: there's nothing to commit.)"
say "  1. Fill in .agent.env (test commands, Duo username, ClickUp workspace ID)."
say "  2. Export CLICKUP_API_TOKEN in your shell profile, and run 'glab auth login'."
say "  3. Check the model names in .github/agents/*.agent.md match your Copilot model picker."
say "  4. Fully quit and reopen VS Code, pick the pipeline agent, then type in Copilot Chat:  /start-task <clickup-id> <short-slug>"
say "Full guide: docs/agent-pipeline.md"
$doctor_failed && say "Fix the FAIL lines above, then run scripts/agent/doctor.sh again before your first task."
exit 0
