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
check "hooks copied" '[ -f .github/hooks/pipeline-guard.json ]'
check "scripts executable" '[ -x scripts/agent/run-checks.sh ] && [ -x scripts/agent/hooks/pre-tool-guard.sh ]'
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
rm "$T/v2/payload/scripts/agent/push-branch.sh"; echo v1.1.0 > "$T/v2/VERSION"
"$T/v2/install.sh" --yes --update "$T/proj" > "$T/out.txt" 2>&1
check "changed file kept" 'grep -q "my tweak" .github/agents/planner.agent.md && ! grep -q "v2 change" .github/agents/planner.agent.md'
check "unchanged file updated" 'grep -q "v2 change" .github/agents/shipper.agent.md'
check "dropped file removed" '[ ! -f scripts/agent/push-branch.sh ]'
check "manifest version bumped" 'head -n1 .github/agent-pipeline.manifest | grep -q v1.1.0'

# 5. --force replaces the changed file and keeps a backup
"$T/v2/install.sh" --yes --update --force "$T/proj" > "$T/out.txt" 2>&1
check "forced update applied" 'grep -q "v2 change" .github/agents/planner.agent.md'
check "backup kept" 'grep -q "my tweak" .github/agents/planner.agent.md.bak'

# 6. uninstall
"$T/v2/install.sh" --yes --uninstall "$T/proj" > "$T/out.txt" 2>&1
check "agents removed" '[ ! -d .github/agents ] || [ -z "$(ls -A .github/agents | grep -v .bak)" ]'
check "scripts removed" '[ ! -f scripts/agent/run-checks.sh ]'
check "manifest removed" '[ ! -f .github/agent-pipeline.manifest ]'
check "team rules survive uninstall" 'grep -q "TypeScript strict" .github/copilot-instructions.md && ! grep -q "agent-pipeline" .github/copilot-instructions.md'
check "gitignore restored" 'grep -q node_modules .gitignore && ! grep -q "agent-pipeline" .gitignore'
check ".agent.env kept" '[ -f .agent.env ]'

# 7. not a git repo
mkdir "$T/plain"; "$ROOT/install.sh" --yes "$T/plain" > "$T/out.txt" 2>&1
check "non-git target refused" 'grep -q "not inside a git repository" "$T/out.txt"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
