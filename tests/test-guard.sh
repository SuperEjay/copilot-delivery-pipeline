#!/usr/bin/env bash
# Table test of the preToolUse guard: feeds tool calls on stdin and checks the
# decision (allow, deny or ask).
# Usage: tests/test-guard.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/payload/scripts/agent/hooks/pre-tool-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0

decision() {   # decision <tool> <args-json> -> allow|deny|ask
  jq -n --arg t "$1" --argjson a "$2" --arg cwd "$T" '{toolName: $t, toolArgs: $a, cwd: $cwd}' |
    PIPELINE_GUARD=on bash "$GUARD" | jq -r '.permissionDecision // "allow"'
}
expect() {     # expect <allow|deny|ask> <tool> <args-json>
  local got; got="$(decision "$2" "$3")"
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: expected $1, got $got: $2 $3"; fi
}
sh() { expect "$1" bash "$(jq -n --arg c "$2" '{command: $c}')"; }
ed() { expect "$1" "$2" "$(jq -n --arg p "$3" '{path: $p}')"; }

# ---------- ordinary work is allowed ----------
sh allow 'git status'
sh allow 'git add -A && git commit -m "feat: thing"'
sh allow 'ls src && cat package.json'
sh allow 'cat scripts/agent/config.sh'
sh allow 'scripts/agent/run-checks.sh T-1 test,lint'
sh allow 'rm -rf .work/T-1/tmp && scripts/agent/run-checks.sh T-1 test'
sh allow 'scripts/agent/run-checks.sh T-1 test > .work/T-1/checks.txt 2>&1'
sh allow 'sed -i s/foo/bar/ src/app.ts'
sh allow 'cp .agent.env.example /tmp/example'
sh allow 'scripts/agent/upload-evidence.sh T-1 --check'
sh allow 'scripts/agent/clickup.sh get T-1'

# ---------- evidence approval ----------
sh deny 'scripts/agent/approve-evidence.sh T-1'
sh deny 'touch .work/T-1/evidence/APPROVED'

# ---------- secrets ----------
sh deny 'echo $CLICKUP_API_TOKEN'
sh deny 'printenv'
sh deny 'cat ~/.ssh/id_ed25519'
sh deny 'cat .auth/session.json'
sh deny 'cat ~/.netrc'

# ---------- destructive git ----------
sh deny 'git push --force origin HEAD'
sh deny 'git push -f'
sh deny 'git reset --hard HEAD~1'
sh deny 'git clean -fd'
sh deny 'git branch -D feature'
sh deny 'git commit --no-verify -m x'

# ---------- raw writes to remotes ----------
sh deny 'git push origin HEAD'
sh deny 'glab mr create --title x'
sh deny 'glab api projects/1/merge_requests -X POST'
sh deny 'curl -s https://api.clickup.com/api/v2/task/1'

# ---------- raw test commands ----------
sh deny 'npm test'
sh deny 'npx vitest run'
sh deny 'pytest -q'
sh deny 'npx tsc --noEmit'

# ---------- publishing asks first ----------
sh ask 'scripts/agent/create-mr.sh T-1'
sh ask 'scripts/agent/push-branch.sh T-1'
sh ask 'scripts/agent/upload-evidence.sh T-1'
sh ask 'scripts/agent/clickup.sh comment T-1 "done"'

# ---------- shell writes to pipeline config ----------
sh deny "echo 'echo {}; exit 0' > scripts/agent/hooks/pre-tool-guard.sh"
sh deny 'echo x >> ./scripts/agent/config.sh'
sh deny 'echo x >"scripts/agent/config.sh"'
sh deny 'sed -i s/deny/allow/ scripts/agent/hooks/pre-tool-guard.sh'
sh deny 'sed -E -i "" s/a/b/ .github/agents/planner.agent.md'
sh deny 'cp /dev/null .github/hooks/pipeline-guard.json'
sh deny 'mv /tmp/x .github/copilot-instructions.md'
sh deny 'rm -rf scripts/agent'
sh deny 'chmod -x scripts/agent/hooks/pre-tool-guard.sh'
sh deny 'echo {} | tee .github/hooks/pipeline-guard.json'
sh deny 'ln -sf /tmp/guard.sh scripts/agent/hooks/pre-tool-guard.sh'
sh deny 'truncate -s0 .github/skills/start-task/SKILL.md'
sh deny 'echo MODEL=x >> .agent.env'
sh deny "python3 -c \"open('scripts/agent/config.sh','w')\""
sh deny "perl -pi -e s/a/b/ .github/agents/reviewer.agent.md"
sh deny 'git checkout -- .github/agents/planner.agent.md'
sh deny 'cd src && rm ../scripts/agent/run-checks.sh'

# ---------- edit and read tools ----------
ed allow editFiles 'src/app.ts'
ed allow read_file 'scripts/agent/config.sh'
ed deny  editFiles 'scripts/agent/hooks/pre-tool-guard.sh'
ed deny  create_file '.github/agents/new.agent.md'
ed deny  replace_string_in_file '.github/copilot-instructions.md'
ed deny  apply_patch '.agent.env'
ed deny  editFiles '.work/T-1/evidence/APPROVED'
ed deny  read_file '.auth/session.json'
ed deny  read_file "$HOME/.ssh/id_rsa"

# ---------- switch ----------
got="$(jq -n '{toolName: "bash", toolArgs: {command: "git push"}}' | PIPELINE_GUARD=off bash "$GUARD")"
if [ "$got" = "{}" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: PIPELINE_GUARD=off should allow"; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
