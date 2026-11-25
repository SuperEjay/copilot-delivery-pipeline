#!/usr/bin/env bash
# End-to-end test of install.sh against a scratch git repo.
# Usage: tests/test-install.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
run() { "$ROOT/install.sh" --yes "$@" "$T/proj" > "$T/out.txt" 2>&1; }
unset CLICKUP_API_TOKEN   # so doctor.sh, run at the end of each install, has a FAIL to report

git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
mkdir -p .github
printf '# Our team rules\n- Use TypeScript strict mode.\n' > .github/copilot-instructions.md
printf 'node_modules/\n' > .gitignore
git add -A; git commit -qm init

# 1. fresh install
run; check "install exits 0" '[ $? -eq 0 ]'
check "the /cleanup skill and its script are installed, in the manifest (#132)" '[ -f .github/skills/cleanup/SKILL.md ] && [ -x scripts/agent/cleanup-task.sh ] && grep -q ".github/skills/cleanup/SKILL.md" .github/agent-pipeline.manifest'
check "agents copied" '[ -f .github/agents/reviewer.agent.md ]'
check "orchestrator copied" '[ -f .github/agents/pipeline.agent.md ]'
check "gap-checker copied, listed in the manifest (#123)" '[ -f .github/agents/gap-checker.agent.md ] && grep -q ".github/agents/gap-checker.agent.md" .github/agent-pipeline.manifest'
check "hooks copied" '[ -f .github/hooks/pipeline-guard.json ]'
check "scripts executable" '[ -x scripts/agent/run-checks.sh ] && [ -x scripts/agent/hooks/pre-tool-guard.sh ]'
check "every payload script is 100755 in git" '[ -z "$(git -C "$ROOT" ls-files -s -- "payload/*.sh" | awk "\$1 != \"100755\" { print \$4 }")" ]'
check "manifest written" '[ -f .github/agent-pipeline.manifest ]'
check "team rules kept" 'grep -q "TypeScript strict" .github/copilot-instructions.md'
check "pipeline rules appended once" '[ "$(grep -c "BEGIN agent-pipeline" .github/copilot-instructions.md)" -eq 1 ]'
check "gitignore kept + block added" 'grep -q node_modules .gitignore && grep -q "^.work/$" .gitignore'
check ".agent.env created" '[ -f .agent.env ]'
check "guard smoke test passed" 'grep -q "hook guard works" "$T/out.txt"'
check "the installer ends by running doctor.sh" 'grep -q "^Checking the setup (scripts/agent/doctor.sh)" "$T/out.txt" && grep -qE "^(PASS|WARN|FAIL|INFO) " "$T/out.txt"'
check "a FAIL from doctor.sh doesn't fail the install, and says to run it again" 'grep -q "^FAIL " "$T/out.txt" && grep -q "run scripts/agent/doctor.sh again" "$T/out.txt"'
check "the installer has no guard test of its own (doctor.sh does it)" '! grep -q "permissionDecision" "$ROOT/install.sh"'
check "a fresh install shows doctor's test tooling section, and step 1 points at it (#131)" 'grep -q "^INFO  test tooling: unknown stack" "$T/out.txt" && grep -q "1\. Fill in \.agent\.env.*test tooling" "$T/out.txt"'

# 2. second install refused
run; check "reinstall refused" 'grep -q "already installed" "$T/out.txt"'

# 3. update with no changes
echo 'MY_SETTING=1' >> .agent.env
echo '{}' > composer.json; touch artisan; cp .agent.env "$T/env.before"
run --update; check "update ok" 'grep -q "0 written" "$T/out.txt"'
check ".agent.env untouched" 'grep -q MY_SETTING .agent.env && cmp -s .agent.env "$T/env.before"'
check "--update shows the test tooling section for the stack (#131)" 'grep -q "^INFO  test tooling: Laravel" "$T/out.txt" && grep -q "1\. Fill in \.agent\.env.*test tooling" "$T/out.txt"'
check "--update installs nothing the section recommends (#131)" '[ ! -e vendor ] && [ ! -e node_modules ] && [ ! -e composer.lock ]'
rm composer.json artisan
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

# 7b. run by a relative path from the clone: it installs from the clone's payload, not a download
git init -q -b main "$T/rel"
mkdir "$T/nocurl"; printf '#!/bin/sh\necho "fake curl: no network" >&2\nexit 1\n' > "$T/nocurl/curl"; chmod +x "$T/nocurl/curl"
(cd "$ROOT" && PATH="$T/nocurl:$PATH" PIPELINE_REPO=nobody/unreachable ./install.sh --yes "$T/rel") > "$T/out.txt" 2>&1
check "relative-path run exits 0" '[ $? -eq 0 ]'
check "relative-path run doesn't download" '! grep -q "Downloading" "$T/out.txt"'
check "relative-path run installs the clone's payload" 'cmp -s "$T/rel/.github/agents/pipeline.agent.md" "$ROOT/payload/.github/agents/pipeline.agent.md"'

# 7c. piped like curl | bash: the script arrives on stdin, so no step may read
# stdin, or it eats the rest of the script. A fake npx that reads stdin (as the
# real one can) and a fake curl that serves this clone's payload as the release.
git init -q -b main "$T/piped"; git -C "$T/piped" commit -q --allow-empty -m init
mkdir -p "$T/pipebin" "$T/rel-src/copilot-delivery-pipeline-x"
cp -r "$ROOT/install.sh" "$ROOT/VERSION" "$ROOT/payload" "$T/rel-src/copilot-delivery-pipeline-x/"
tar -czf "$T/release.tgz" -C "$T/rel-src" copilot-delivery-pipeline-x
printf '#!/bin/sh\ncat "%s"\n' "$T/release.tgz" > "$T/pipebin/curl"
printf '#!/bin/sh\ncat > /dev/null\nexit 0\n' > "$T/pipebin/npx"
printf '#!/bin/sh\ncat > /dev/null\nexit 1\n' > "$T/pipebin/glab"
chmod +x "$T/pipebin/curl" "$T/pipebin/npx" "$T/pipebin/glab"
(cd "$T/piped" && PATH="$T/pipebin:$PATH" bash -s -- --yes --with-skills < "$ROOT/install.sh") > "$T/out.txt" 2>&1
check "piped install: the skills step doesn't eat the rest of the script" 'grep -q "^Checking the setup (scripts/agent/doctor.sh)" "$T/out.txt"'
check "piped install: doctor.sh doesn't eat it either, the install reaches Done" 'grep -q "^Done. Next steps:" "$T/out.txt"'

# 7d. the skills on a first install, run by a person (no agent detected): with
# stdin not a terminal, the real `skills add` stops at its "Select skills" prompt
# and installs nothing unless it gets -y. This fake npx does the same.
git init -q -b main "$T/skilled"; git -C "$T/skilled" commit -q --allow-empty -m init
mkdir -p "$T/skillbin"
cat > "$T/skillbin/npx" <<'EOF'
#!/bin/sh
[ "$1" = -y ] && shift
[ "$1" = skills ] && [ "$2" = add ] || exit 1
repo="$3"; shift 3; yes=false
for a in "$@"; do case "$a" in -y|--yes) yes=true ;; esac; done
$yes || { echo "[SKILLS_PROMPT_REQUIRES_TTY] Nothing was installed." >&2; exit 1; }
mkdir -p ".agents/skills/${repo#*/}"
EOF
chmod +x "$T/skillbin/npx"
PATH="$T/skillbin:$PATH" "$ROOT/install.sh" --yes --with-skills "$T/skilled" > "$T/out.txt" 2>&1
check "first install: the ponytail skill is installed" '[ -d "$T/skilled/.agents/skills/ponytail" ] && grep -q "✓ ponytail" "$T/out.txt"'
check "first install: the caveman skill is installed" '[ -d "$T/skilled/.agents/skills/caveman" ] && grep -q "✓ caveman" "$T/out.txt"'
check "first install: no skill install failed" '! grep -q "install failed" "$T/out.txt"'

# 7e. --local: the pipeline stays on this machine. The ignores go in
# .git/info/exclude, the rules in their own ignored file, and no tracked file
# changes, so start-task.sh and the ship gate see a clean tree.
git init -q -b main "$T/loc"; cd "$T/loc"
git config user.email t@t; git config user.name t
mkdir -p .github scripts
printf '# Our team rules\n' > .github/copilot-instructions.md
printf 'node_modules/\n' > .gitignore
printf 'echo build\n' > scripts/build.sh
git add -A; git commit -qm init
EXCLUDE="$(git rev-parse --git-path info/exclude)"
LOCAL_RULES=.github/instructions/agent-pipeline.instructions.md
PATH="$T/skillbin:$PATH" "$ROOT/install.sh" --yes --local --with-skills . > "$T/out.txt" 2>&1
check "local: install exits 0" '[ $? -eq 0 ]'
check "local: pipeline files installed" '[ -x scripts/agent/run-checks.sh ] && [ -f .github/agents/pipeline.agent.md ]'
check "local: git status shows nothing, not even untracked files" '[ -z "$(git status --porcelain)" ]'
check "local: copilot-instructions.md and .gitignore untouched" 'git diff --quiet HEAD -- .github/copilot-instructions.md .gitignore'
check "local: the rules are in their own file, applied to every chat" 'head -n3 "$LOCAL_RULES" | grep -q "^applyTo: \"\*\*\"" && grep -q "Delivery pipeline" "$LOCAL_RULES"'
check "local: the ignores are in .git/info/exclude, once" '[ "$(grep -c "BEGIN agent-pipeline" "$EXCLUDE")" -eq 1 ] && grep -qx "/scripts/agent/run-checks.sh" "$EXCLUDE" && grep -qx ".work/" "$EXCLUDE"'
check "local: the project's own scripts/ files aren't ignored" '! git check-ignore -q scripts/new.sh && ! git check-ignore -q .github/agents/ours.agent.md'
check "local: the manifest records local mode" 'grep -qx "# local" .github/agent-pipeline.manifest'
check "local: the next steps don't say to commit the pipeline" 'grep -q "kept out of git" "$T/out.txt"'
mkdir -p .agents/skills/grilling; echo x > .agents/skills/grilling/SKILL.md
check "local: the whole .agents/ is excluded, so any other skill stays out of git (#115)" 'grep -qx "/.agents/" "$EXCLUDE" && ! grep -q "ponytail" "$EXCLUDE" && [ -z "$(git status --porcelain)" ]'
# An install from before #115 excluded only the ponytail and caveman folders.
sed -i 's#^/\.agents/$#/.agents/skills/ponytail*/\n/.agents/skills/caveman*/#' "$EXCLUDE"
"$ROOT/install.sh" --yes --update . > "$T/out.txt" 2>&1
check "local: --update stays local without the flag" '[ -z "$(git status --porcelain)" ] && [ "$(grep -c "BEGIN agent-pipeline" "$EXCLUDE")" -eq 1 ] && grep -qx "# local" .github/agent-pipeline.manifest'
check "local: --update replaces the old ponytail/caveman lines with /.agents/" 'grep -qx "/.agents/" "$EXCLUDE" && ! grep -q "ponytail" "$EXCLUDE"'
"$ROOT/install.sh" --yes --uninstall . > "$T/out.txt" 2>&1
check "local: uninstall removes the rules file and the exclude block" '[ ! -f "$LOCAL_RULES" ] && ! grep -q "agent-pipeline" "$EXCLUDE"'
check "local: uninstall leaves the tracked files as they were" 'git diff --quiet HEAD'

# 7f. --update --local on a shared install whose files are committed: ignoring
# doesn't untrack them, so the installer says how.
git init -q -b main "$T/sw"; cd "$T/sw"; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init
"$ROOT/install.sh" --yes . > /dev/null 2>&1; git add -A; git commit -qm pipeline
check "shared install: .gitignore doesn't ignore .agents/ (#115)" '! grep -q "agents" .gitignore'
mkdir -p .agents/skills/team; echo x > .agents/skills/team/SKILL.md; git add -A; git commit -qm "team skill"
"$ROOT/install.sh" --yes --update --local . > "$T/out.txt" 2>&1
check "switch to local: warns that committed .agents/ files stay tracked" 'grep -q "under .agents/ are committed" "$T/out.txt"'
check "switch to local: says how to untrack the committed pipeline files" 'grep -q "git rm -r --cached" "$T/out.txt"'
check "switch to local: says the old rules block is still in copilot-instructions.md" 'grep -q "copilot-instructions.md still has the pipeline block" "$T/out.txt"'
cd "$T/proj"

# ---------- 8. updates accept v1.2.x and later only (ADR 0002) ----------
version="$(cat "$ROOT/VERSION")"
# old_install <tag> <dir>: a real install of that release, by its own installer.
# Old installers add skills by default through `npx skills add`, which would
# fetch from npm and GitHub (#133): a fake npx stands in, reading stdin as the
# real one can and logging each call to $T/old-npx.log.
mkdir -p "$T/oldbin"
printf '#!/bin/sh\necho "$*" >> "%s"\ncat > /dev/null\nexit 0\n' "$T/old-npx.log" > "$T/oldbin/npx"; chmod +x "$T/oldbin/npx"
old_install() {
  mkdir -p "$T/src-$1"; git -C "$ROOT" archive "$1" install.sh VERSION payload | tar -x -C "$T/src-$1"
  git init -q -b main "$2"; git -C "$2" config user.email t@t; git -C "$2" config user.name t
  printf 'node_modules/\n' > "$2/.gitignore"; git -C "$2" add -A; git -C "$2" commit -qm init
  PATH="$T/oldbin:$PATH" "$T/src-$1/install.sh" --yes "$2" > "$T/out.txt" 2>&1
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
  check "the old installers added skills through the fake npx, never npm or GitHub (#133)" 'grep -q "skills add" "$T/old-npx.log"'
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
via="$(sed -n 's/^UPDATE_VIA="\(.*\)".*/\1/p' "$ROOT/install.sh")"
check "README: every pinned release (clone --branch, checkout, curl URL) is this version" '[ -z "$(grep -oE "(--branch|checkout|copilot-delivery-pipeline/) ?v[0-9]+\.[0-9]+\.[0-9]+" "$README" | grep -v "$version\$" | grep -v "copilot-delivery-pipeline/$via\$")" ]'
check "README: the one other pin is the update-first step, to UPDATE_VIA ($via), with --update" '[ "$(grep -c "copilot-delivery-pipeline/$via/install.sh | bash -s -- --update\$" "$README")" -eq 1 ] && readme_section "## Updating an existing install" | grep -q "v1.2.0 or later"'
check "README: the update links the CHANGELOG's Upgrading to v2" 'grep -q "(CHANGELOG.md#upgrading-to-v2)" "$README" && grep -qx "### Upgrading to v2" "$ROOT/CHANGELOG.md"'
check "VERSION, install.sh and the CHANGELOG's newest release agree" '[ "$(cat "$ROOT/VERSION")" = "$version" ] && [ "$(grep -m1 "^## v" "$ROOT/CHANGELOG.md")" = "## $version" ]'
for flag in $(sed -n 's/^    \(--[a-z-]*\)[)|].*/\1/p' "$ROOT/install.sh"); do
  check "README: the $flag option is documented" 'grep -q -- "\`install.sh [^\`]*$flag" "$README"'
done
for platform in "### macOS" "### Linux" "### Windows with WSL" "### Windows with Git Bash"; do
  check "README: $platform has its own steps" '[ -n "$(readme_section "$platform")" ]'
  for t in git jq curl glab node; do
    check "README: $platform says how to get $t" 'readme_section "$platform" | grep -qw "$t"'
  done
done
check "README: Git Bash is marked unsupported (ADR 0002)" 'readme_section "### Windows with Git Bash" | grep -q "\*\*Unsupported"'
check "README: Git Bash says the guard may not run" 'readme_section "### Windows with Git Bash" | grep -qi "guard"'
check "README: WSL is the supported way on Windows" 'readme_section "### Windows with WSL" | grep -qi "the supported way"'
# ---------- auto run first, manual mode as the fallback (ADR 0002) ----------
# line_of <file> <fixed text>: the first line number containing it, or 99999.
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1 | grep . || echo 99999; }
check "README: What it does leads with the pipeline agent, manual mode after" '[ "$(readme_section "## What it does" | grep -nF "**pipeline**" | head -n1 | cut -d: -f1)" -lt "$(readme_section "## What it does" | grep -nF "manual mode" | head -n1 | cut -d: -f1 || echo 0)" ]'
check "guide: Daily use: auto run comes before Manual mode (fallback)" '[ "$(line_of "$GUIDE" "## Daily use: auto run")" -lt "$(line_of "$GUIDE" "## Manual mode (fallback)")" ] && [ "$(line_of "$GUIDE" "## Manual mode (fallback)")" -lt 99999 ]'
check "guide: no section still named for the old modes" '! grep -qE "^## (Hands-off: auto run|Daily use: stage by stage)" "$GUIDE"'
check "guide: manual mode moves on through the Next: line" 'awk "/^## Manual mode \\(fallback\\)/{on=1;next} /^## /{on=0} on" "$GUIDE" | grep -q "\*\*Next:\*\*"'
check "guide: the diagram caption names the auto run first" 'sed -n "/^\`\`\`/,/^\`\`\`/p" "$GUIDE" | sed -n 2p | grep -q "^Auto run"'
check "README and guide: no handoff buttons" '! grep -qi "handoff button" "$README" "$GUIDE"'
check "guide: alerts are optional and unverified" 'awk "/^### /{on=(\$0 ~ /alerts/)} on" "$GUIDE" | grep -qi "optional" && awk "/^### /{on=(\$0 ~ /alerts/)} on" "$GUIDE" | grep -qi "unverified"'
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
