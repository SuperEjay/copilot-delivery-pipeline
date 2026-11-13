#!/usr/bin/env bash
# Copilot delivery pipeline: installer
#
#   install.sh [options] [target-dir]        target-dir defaults to the current directory
#
#   --update        update an existing install (keeps files you changed; see --force)
#   --uninstall     remove the pipeline (keeps .agent.env and .work/)
#   --force         with --update: overwrite files you changed (a .bak copy is kept)
#   --with-skills   also install the ponytail and caveman skills for Copilot
#   --yes           don't ask questions (CI, scripts)
#   --version TAG   install a specific release when downloading (default: this script's version)
#
# Run from a clone:   ./install.sh /path/to/project
# Run via curl:       curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/TAG/install.sh | bash
set -euo pipefail

PIPELINE_VERSION="v1.1.0"
PIPELINE_REPO="${PIPELINE_REPO:-SuperEjay/copilot-delivery-pipeline}"
MANIFEST=".github/agent-pipeline.manifest"
BEGIN_MARK="<!-- BEGIN agent-pipeline (managed by install.sh; edits inside are replaced on update) -->"
END_MARK="<!-- END agent-pipeline -->"
GI_BEGIN="# BEGIN agent-pipeline"
GI_END="# END agent-pipeline"

MODE=install; FORCE=false; SKILLS=false; YES=false; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update) MODE=update ;;
    --uninstall) MODE=uninstall ;;
    --force) FORCE=true ;;
    --with-skills) SKILLS=true ;;
    --yes|-y) YES=true ;;
    --version) PIPELINE_VERSION="${2:?--version needs a tag}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" 2>/dev/null || true; exit 0 ;;
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
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

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
    rm -f "$path" && ok "removed $path"
  done < "$MANIFEST"
  rm -f "$MANIFEST"
  if [ -f .github/copilot-instructions.md ]; then
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' .github/copilot-instructions.md > .github/copilot-instructions.md.tmp
    mv .github/copilot-instructions.md.tmp .github/copilot-instructions.md
    [ -s .github/copilot-instructions.md ] && grep -q '[^[:space:]]' .github/copilot-instructions.md || rm -f .github/copilot-instructions.md
    ok "removed the pipeline block from .github/copilot-instructions.md"
  fi
  if [ -f .gitignore ]; then
    awk -v b="$GI_BEGIN" -v e="$GI_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' .gitignore > .gitignore.tmp && mv .gitignore.tmp .gitignore
    ok "removed the pipeline block from .gitignore"
  fi
  find .github/agents .github/prompts .github/skills/start-task .github/skills/fetch-review .github/skills .github/hooks scripts/agent/hooks scripts/agent docs -type d -empty -delete 2>/dev/null || true
  say ""
  say "Done. Kept: .agent.env (your settings) and .work/ (task folders). Delete them yourself if you no longer need them."
  exit 0
fi

# ---------- get the payload ----------
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
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

say "Installing the agent pipeline $PIPELINE_VERSION into $TARGET"
say ""

# ---------- copy pipeline-owned files ----------
OLD_MANIFEST="$(mktemp)"
[ -f "$MANIFEST" ] && grep -v '^#' "$MANIFEST" > "$OLD_MANIFEST" || true
old_hash() { awk -F'\t' -v p="$1" '$2 == p { print $1; exit }' "$OLD_MANIFEST"; }

NEW_MANIFEST="$(mktemp)"
echo "# agent-pipeline $PIPELINE_VERSION installed $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$NEW_MANIFEST"
skipped=0; written=0; unchanged=0

while IFS= read -r rel; do
  case "$rel" in pipeline-instructions.md) continue ;; esac
  src="$PAYLOAD/$rel"; dst="$rel"
  new_hash="$(sha256 "$src")"
  if [ -f "$dst" ]; then
    cur_hash="$(sha256 "$dst")"
    if [ "$cur_hash" = "$new_hash" ]; then
      unchanged=$((unchanged + 1)); printf '%s\t%s\n' "$new_hash" "$dst" >> "$NEW_MANIFEST"; continue
    fi
    recorded="$(old_hash "$dst")"
    if [ -n "$recorded" ] && [ "$cur_hash" != "$recorded" ] && ! $FORCE; then
      warn "kept your changed $dst (re-run with --force to replace it; a .bak is kept)"
      skipped=$((skipped + 1)); printf '%s\t%s\n' "$recorded" "$dst" >> "$NEW_MANIFEST"; continue
    fi
    if [ -z "$recorded" ] && [ "$MODE" = install ]; then
      cp "$dst" "$dst.bak"; warn "$dst already existed: saved your version as $dst.bak"
    elif $FORCE && [ -n "$recorded" ] && [ "$cur_hash" != "$recorded" ]; then
      cp "$dst" "$dst.bak"; warn "replaced your changed $dst (your version: $dst.bak)"
    fi
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
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
for d in .github/prompts .github/skills/start-task .github/skills/fetch-review; do
  [ -d "$d" ] && [ -z "$(ls -A "$d")" ] && rmdir "$d" 2>/dev/null || true
done
mkdir -p "$(dirname "$MANIFEST")"; mv "$NEW_MANIFEST" "$MANIFEST"
msg="pipeline files: $written written, $unchanged unchanged"; [ "$skipped" -gt 0 ] && msg="$msg, $skipped kept as you changed them"; ok "$msg"

# ---------- merge copilot-instructions.md ----------
INSTR=.github/copilot-instructions.md
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

# ---------- .gitignore ----------
gi_block="$(printf '%s\n.work/\n.agent.env\n.auth/\n*.bak\n%s' "$GI_BEGIN" "$GI_END")"
if [ -f .gitignore ] && grep -qF "$GI_BEGIN" .gitignore; then
  ok ".gitignore already has the pipeline block"
else
  printf '\n%s\n' "$gi_block" >> .gitignore; ok "added .work/, .agent.env, .auth/ and *.bak to .gitignore"
fi

# ---------- settings ----------
if [ -f .agent.env ]; then
  ok ".agent.env exists: left untouched (compare with .agent.env.example for new settings)"
else
  cp .agent.env.example .agent.env; ok "created .agent.env from the example: fill in your project's values"
fi

# ---------- dependencies ----------
say ""
say "Checking tools:"
missing=0
for t in git jq curl glab; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else warn "$t is missing"; missing=$((missing + 1)); fi
done
if command -v npx >/dev/null 2>&1; then ok "node/npx"; else warn "node/npx is missing (needed for Playwright evidence and skills)"; fi
for t in pdftotext pandoc; do command -v "$t" >/dev/null 2>&1 && ok "$t (optional)" || say "  - $t (optional) not found: attachments won't be converted to text"; done
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) warn "Windows detected: run the pipeline scripts from Git Bash or WSL." ;; esac

# ---------- guard smoke test ----------
if command -v jq >/dev/null 2>&1; then
  d="$(jq -n --arg c "$TARGET" '{toolName:"bash",toolArgs:{command:"git push origin main"},cwd:$c}' \
       | PIPELINE_GUARD=on scripts/agent/hooks/pre-tool-guard.sh | jq -r '.permissionDecision // "allow"')"
  [ "$d" = deny ] && ok "hook guard works (a test 'git push' was blocked)" || warn "hook guard test failed: got '$d' instead of deny"
fi

# ---------- optional skills ----------
if $SKILLS || { [ "$MODE" = install ] && confirm "Install the ponytail and caveman skills for Copilot now?"; }; then
  if command -v npx >/dev/null 2>&1; then
    say ""
    npx -y skills add DietrichGebert/ponytail -a github-copilot && ok "ponytail" || warn "ponytail install failed: install it later"
    npx -y skills add JuliusBrussee/caveman -a github-copilot && ok "caveman" || warn "caveman install failed: install it later"
  else
    warn "skipped skills: npx is missing"
  fi
fi

say ""
say "Done. Next steps:"
say "  1. Fill in .agent.env (test commands, Duo username, ClickUp workspace ID)."
say "  2. Export CLICKUP_API_TOKEN in your shell profile, and run 'glab auth login'."
say "  3. Check the model names in .github/agents/*.agent.md match your Copilot model picker."
say "  4. Fully quit and reopen VS Code, then type in Copilot Chat:  /start-task <clickup-id> <short-slug>"
say "Full guide: docs/agent-pipeline.md"
[ "$missing" -gt 0 ] && say "Install the missing tools above before your first task."
exit 0
