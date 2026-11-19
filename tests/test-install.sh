#!/usr/bin/env bash
# End-to-end test of install.sh against a scratch git repo.
# Usage: tests/test-install.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
run() { "$ROOT/install.sh" --yes "$@" "$T/proj" > "$T/out.txt" 2>&1; }

git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
mkdir -p .github
printf '# Our team rules\n- Use TypeScript strict mode.\n' > .github/copilot-instructions.md
printf 'node_modules/\n' > .gitignore
git add -A; git commit -qm init

# 1. fresh install
run; check "install exits 0" '[ $? -eq 0 ]'
check "agents copied" '[ -f .github/agents/reviewer.agent.md ]'
check "orchestrator copied" '[ -f .github/agents/pipeline.agent.md ]'
check "hooks copied" '[ -f .github/hooks/pipeline-guard.json ]'
check "scripts executable" '[ -x scripts/agent/run-checks.sh ] && [ -x scripts/agent/hooks/pre-tool-guard.sh ]'
check "every payload script is 100755 in git" '[ -z "$(git -C "$ROOT" ls-files -s -- "payload/*.sh" | awk "\$1 != \"100755\" { print \$4 }")" ]'
check "manifest written" '[ -f .github/agent-pipeline.manifest ]'
check "team rules kept" 'grep -q "TypeScript strict" .github/copilot-instructions.md'
check "pipeline rules appended once" '[ "$(grep -c "BEGIN agent-pipeline" .github/copilot-instructions.md)" -eq 1 ]'
check "gitignore kept + block added" 'grep -q node_modules .gitignore && grep -q "^.work/$" .gitignore'
check ".agent.env created" '[ -f .agent.env ]'
check "guard smoke test passed" 'grep -q "hook guard works" "$T/out.txt"'

# 2. second install refused
run; check "reinstall refused" 'grep -q "already installed" "$T/out.txt"'

# 3. update with no changes
echo 'MY_SETTING=1' >> .agent.env
run --update; check "update ok" 'grep -q "0 written" "$T/out.txt"'
check ".agent.env untouched" 'grep -q MY_SETTING .agent.env'
check "rules block not duplicated" '[ "$(grep -c "BEGIN agent-pipeline" .github/copilot-instructions.md)" -eq 1 ]'
check "gitignore block not duplicated" '[ "$(grep -c "BEGIN agent-pipeline" .gitignore)" -eq 1 ]'

# 4. user changes a file, then a new version changes the same file
echo "# my tweak" >> .github/agents/planner.agent.md
cp -r "$ROOT" "$T/v2"; echo "# v2 change" >> "$T/v2/payload/.github/agents/planner.agent.md"
echo "# v2 change" >> "$T/v2/payload/.github/agents/shipper.agent.md"
rm "$T/v2/payload/scripts/agent/push-branch.sh"; echo v9.9.9 > "$T/v2/VERSION"
"$T/v2/install.sh" --yes --update "$T/proj" > "$T/out.txt" 2>&1
check "changed file kept" 'grep -q "my tweak" .github/agents/planner.agent.md && ! grep -q "v2 change" .github/agents/planner.agent.md'
check "unchanged file updated" 'grep -q "v2 change" .github/agents/shipper.agent.md'
check "dropped file removed" '[ ! -f scripts/agent/push-branch.sh ]'
check "manifest version bumped" 'head -n1 .github/agent-pipeline.manifest | grep -q v9.9.9'

# 5. --force replaces the changed file and keeps a backup
"$T/v2/install.sh" --yes --update --force "$T/proj" > "$T/out.txt" 2>&1
check "forced update applied" 'grep -q "v2 change" .github/agents/planner.agent.md'
check "backup kept" 'grep -q "my tweak" .github/agents/planner.agent.md.bak'

# 6. uninstall
"$T/v2/install.sh" --yes --uninstall "$T/proj" > "$T/out.txt" 2>&1
check "agents removed" '[ ! -d .github/agents ] || [ -z "$(ls -A .github/agents | grep -v .bak)" ]'
check "orchestrator removed" '[ ! -f .github/agents/pipeline.agent.md ]'
check "scripts removed" '[ ! -f scripts/agent/run-checks.sh ]'
check "manifest removed" '[ ! -f .github/agent-pipeline.manifest ]'
check "team rules survive uninstall" 'grep -q "TypeScript strict" .github/copilot-instructions.md && ! grep -q "agent-pipeline" .github/copilot-instructions.md'
check "gitignore restored" 'grep -q node_modules .gitignore && ! grep -q "agent-pipeline" .gitignore'
check ".agent.env kept" '[ -f .agent.env ]'

# 7. not a git repo
mkdir "$T/plain"; "$ROOT/install.sh" --yes "$T/plain" > "$T/out.txt" 2>&1
check "non-git target refused" 'grep -q "not inside a git repository" "$T/out.txt"'

# ---------- 8. updates accept v1.2.x and later only (ADR 0002) ----------
version="$(cat "$ROOT/VERSION")"
# old_install <tag> <dir>: a real install of that release, by its own installer.
old_install() {
  mkdir -p "$T/src-$1"; git -C "$ROOT" archive "$1" install.sh VERSION payload | tar -x -C "$T/src-$1"
  git init -q -b main "$2"; git -C "$2" config user.email t@t; git -C "$2" config user.name t
  printf 'node_modules/\n' > "$2/.gitignore"; git -C "$2" add -A; git -C "$2" commit -qm init
  "$T/src-$1/install.sh" --yes "$2" > "$T/out.txt" 2>&1
}
# snapshot <dir>: every file and its content, to check nothing changed.
snapshot() { (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum); }
up() { "$ROOT/install.sh" --yes --update "$@" > "$T/out.txt" 2>&1; }
tags_present() { for t in "$@"; do git -C "$ROOT" cat-file -e "$t^{commit}" 2>/dev/null || return 1; done; }

if tags_present v1.1.0 v1.2.0 v1.2.1 v1.2.2; then
  old_install v1.1.0 "$T/old110"
  check "v1.1.0 installs (by its own installer)" 'head -n1 "$T/old110/.github/agent-pipeline.manifest" | grep -q "agent-pipeline v1.1.0 installed"'
  snapshot "$T/old110" > "$T/before"
  for force in "" --force; do
    up $force "$T/old110"; rc=$?
    check "update ${force:-without --force} from v1.1.0 is refused" '[ $rc -ne 0 ] && grep -q "v1.1.0" "$T/out.txt" && grep -q "v1.2.0 or later" "$T/out.txt"'
    check "the refusal ${force:+(--force) }says how to update to v1.2.2 first" 'grep -qF "SuperEjay/copilot-delivery-pipeline/v1.2.2/install.sh | bash -s -- --update" "$T/out.txt"'
    check "a refused update ${force:+(--force) }changes no file" 'snapshot "$T/old110" | cmp -s - "$T/before"'
  done
  # The refusal comes before the payload is fetched: the installer alone, as
  # curl | bash runs it, with a curl that only records it was called.
  mkdir -p "$T/lone" "$T/fakebin"; cp "$ROOT/install.sh" "$T/lone/"
  printf '#!/bin/sh\necho called > "%s/curl-called"\nexit 1\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
  PATH="$T/fakebin:$PATH" "$T/lone/install.sh" --yes --update "$T/old110" > "$T/out.txt" 2>&1
  check "a refused update downloads nothing" 'grep -q "v1.2.0 or later" "$T/out.txt" && [ ! -f "$T/curl-called" ]'
  sed -i '1s/.*/# hand-edited/' "$T/old110/.github/agent-pipeline.manifest"
  up "$T/old110"; rc=$?
  check "a manifest with no readable version is refused, saying so" '[ $rc -ne 0 ] && grep -q "can.t tell which version" "$T/out.txt"'

  for tag in v1.2.0 v1.2.1 v1.2.2; do
    old_install $tag "$T/old-$tag"
    up "$T/old-$tag"; rc=$?
    check "update from $tag works" '[ $rc -eq 0 ] && head -n1 "$T/old-$tag/.github/agent-pipeline.manifest" | grep -q "agent-pipeline $version installed"'
  done

  # Kept files and .new copies, on a real v1.2.2 install.
  P="$T/old-v1.2.2b"; old_install v1.2.2 "$P"; cd "$P"
  cp .agent.env "$T/env.v122"
  sed -i 's/^model: .*/model: my-pinned-model/' .github/agents/planner.agent.md   # a pinned model, say
  echo "# my tweak" >> scripts/agent/clickup.sh
  up "$P"
  check "update from v1.2.2: .agent.env untouched" 'cmp -s .agent.env "$T/env.v122"'
  check "update from v1.2.2: changed agent kept" 'grep -q "my-pinned-model" .github/agents/planner.agent.md'
  check "update from v1.2.2: the new version next to it as .new" 'cmp -s .github/agents/planner.agent.md.new "$ROOT/payload/.github/agents/planner.agent.md"'
  check "update from v1.2.2: the warning names the .new and auto run" 'grep "planner.agent.md" "$T/out.txt" | grep -q "planner.agent.md.new" && grep "planner.agent.md.new" "$T/out.txt" | grep -qi "auto run"'
  check "a kept script gets a .new too, but no auto-run warning (only agent files need it)" '[ -x scripts/agent/clickup.sh.new ] && grep -q "clickup.sh.new" "$T/out.txt" && ! grep "clickup.sh" "$T/out.txt" | grep -qi "auto run"'
  check "update from v1.2.2: no .new for a file you didn't change" '[ ! -f .github/agents/shipper.agent.md.new ]'
  check "update from v1.2.2: *.new in the .gitignore block" 'awk "/^# BEGIN agent-pipeline/,/^# END agent-pipeline/" .gitignore | grep -qx "\*.new"'
  check "update from v1.2.2: .gitignore block still once" '[ "$(grep -c "BEGIN agent-pipeline" .gitignore)" -eq 1 ] && grep -q node_modules .gitignore'
  echo stale >> .github/agents/planner.agent.md.new
  up "$P"
  check "a second update refreshes a stale .new" 'cmp -s .github/agents/planner.agent.md.new "$ROOT/payload/.github/agents/planner.agent.md"'
  sed -i '/^MAX_AUTO_FIX_ROUNDS=/d' .agent.env; up "$P"
  check "a setting .agent.env doesn't set is listed" 'grep -q "MAX_AUTO_FIX_ROUNDS" "$T/out.txt"'
  echo "MAX_AUTO_FIX_ROUNDS=3" >> .agent.env; up "$P"
  check "a setting you added isn't listed as missing" '! grep -q "MAX_AUTO_FIX_ROUNDS" "$T/out.txt"'
  up --force "$P"
  check "--force replaces the changed agent" 'cmp -s .github/agents/planner.agent.md "$ROOT/payload/.github/agents/planner.agent.md"'
  check "--force deletes the .new" '[ ! -f .github/agents/planner.agent.md.new ]'
  cd "$T/proj"
else
  echo "skip: update-floor tests (the v1.1.0-v1.2.2 tags aren't in this clone, e.g. a shallow one)"
fi

# ---------- the README's install and update steps match the installer ----------
README="$ROOT/README.md"
GUIDE="$ROOT/payload/docs/agent-pipeline.md"
# readme_section <heading>: the lines under that "##"/"###" heading, up to the next heading of that level or higher.
readme_section() { awk -v h="$1" 'index($0, "#") == 1 { lvl = index($0, " ") - 1; if (on && lvl <= L) exit; if ($0 == h) { on = 1; L = lvl; next } } on' "$README"; }
# slug <heading text>: GitHub's anchor for a heading.
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9 _-]//g; s/ /-/g'; }
version="$(sed -n 's/^PIPELINE_VERSION="\(.*\)"$/\1/p' "$ROOT/install.sh")"
check "README: the pinned curl install is this version" 'grep -q "copilot-delivery-pipeline/$version/install.sh | bash$" "$README"'
check "README: the pinned curl update is this version" 'grep -q "copilot-delivery-pipeline/$version/install.sh | bash -s -- --update$" "$README"'
check "README: every pinned release (clone --branch, checkout, curl URL) is this version" '[ -z "$(grep -oE "(--branch|checkout|copilot-delivery-pipeline/) ?v[0-9]+\.[0-9]+\.[0-9]+" "$README" | grep -v "$version\$")" ]'
for flag in $(sed -n 's/^    \(--[a-z-]*\)[)|].*/\1/p' "$ROOT/install.sh"); do
  check "README: the $flag option is documented" 'grep -q -- "\`install.sh [^\`]*$flag" "$README"'
done
for platform in "### macOS" "### Linux" "### Windows with WSL" "### Windows with Git Bash"; do
  check "README: $platform has its own steps" '[ -n "$(readme_section "$platform")" ]'
  for t in git jq curl glab node; do
    check "README: $platform says how to get $t" 'readme_section "$platform" | grep -qw "$t"'
  done
done
check "README: Git Bash is marked unverified" 'readme_section "### Windows with Git Bash" | grep -qi "unverified"'
check "README: Windows warns about CRLF in .sh files" 'readme_section "## Requirements" | grep -q "eol=lf"'
check "README: the update finds the installed version in the manifest" 'readme_section "## Updating an existing install" | grep -q "agent-pipeline.manifest"'
check "README: the update says to merge each .new" 'readme_section "## Updating an existing install" | grep -q "\.new"'
check "README: the update links the CHANGELOG's per-version steps" 'readme_section "## Updating an existing install" | grep -q "(CHANGELOG.md"'
# readme_guide_links_resolve: every link into the guide names a heading that exists there.
readme_guide_links_resolve() {
  local a slugs
  slugs="$(grep '^#' "$GUIDE" | sed -E 's/^#+ //' | while IFS= read -r h; do slug "$h"; echo; done)"
  for a in $(grep -oE 'payload/docs/agent-pipeline\.md#[a-z0-9_-]+' "$README" | sed 's/.*#//' | sort -u); do
    printf '%s\n' "$slugs" | grep -qx "$a" || { echo "  no heading for #$a" >&2; return 1; }
  done
}
check "README: links into the guide's Setup" 'grep -q "payload/docs/agent-pipeline.md#setup-about-15-minutes" "$README"'
check "README: every link into the guide resolves" 'readme_guide_links_resolve'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
