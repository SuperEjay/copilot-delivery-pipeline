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
sh allow 'scripts/agent/run-checks.sh T-1 unit lint'
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
# Redirects with | or & in them: the clobber >| and csh-style >&word (and
# >& word) write the file too, and must not be cut in half at that | or &.
sh deny 'echo x >| scripts/agent/config.sh'
sh deny 'echo x >|./scripts/agent/config.sh'
sh deny 'cat a >&scripts/agent/config.sh'
sh deny 'cat a >& scripts/agent/config.sh'
sh deny 'cat a &>scripts/agent/config.sh'
sh deny 'true && echo x >| .agent.env'
sh allow 'cat scripts/agent/config.sh >| /tmp/x'
sh allow 'scripts/agent/run-checks.sh T-1 test >&2'
sh allow 'scripts/agent/run-checks.sh T-1 test >| .work/T-1/checks.txt 2>&1'

# ---------- verified commit marker ----------
sh deny 'git rev-parse HEAD > .work/T-1/verified-head'
sh deny 'cat .work/T-1/verified-head'
sh allow 'scripts/agent/run-checks.sh T-1 all'

# ---------- edit and read tools ----------
ed allow editFiles 'src/app.ts'
ed allow read_file 'scripts/agent/config.sh'
ed deny  editFiles 'scripts/agent/hooks/pre-tool-guard.sh'
ed deny  create_file '.github/agents/new.agent.md'
ed deny  replace_string_in_file '.github/copilot-instructions.md'
ed deny  apply_patch '.agent.env'
ed deny  editFiles '.work/T-1/evidence/APPROVED'
ed deny  create_file '.work/T-1/verified-head'
ed deny  read_file '.auth/session.json'
ed deny  read_file "$HOME/.ssh/id_rsa"

# ---------- protected paths: every table entry behaves as its kind says ----------
# Per kind: shell write, shell mention, edit tool, read tool.
declare -A want=(
  [secret]='deny deny deny deny'
  [record]='deny deny deny allow'
  [config]='deny allow deny allow'
  [state]='deny allow deny allow'
  [review]='deny allow deny allow'
)
list="$(bash "$GUARD" --list-protected)"
for kind in secret record config state review; do
  if grep -q "^$kind	" <<<"$list"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --list-protected has no $kind entries"; fi
done
while IFS=$'\t' read -r kind entry; do
  [ -n "$kind" ] || continue
  read -r w_write w_mention w_edit w_read <<<"${want[$kind]:-unknown}"
  [ "$w_write" = unknown ] && { fail=$((fail + 1)); echo "FAIL: unknown kind '$kind' for $entry"; continue; }
  file="${entry//\*/T-1}"                                           # a "*" segment: a task id
  [ "${entry%/}" != "$entry" ] && file="${file}x"                   # a file inside a folder entry
  sh "$w_write"   "echo x > $file"
  sh "$w_mention" "cat $file"
  ed "$w_edit"    editFiles "$file"
  ed "$w_edit"    editFiles "/home/u/proj/$file"
  ed "$w_edit"    editFiles "C:\\proj\\${file//\//\\}"   # Windows path
  ed "$w_read"    read_file "$file"
  ed "$w_read"    read_file "C:\\proj\\${file//\//\\}"
  sh "$w_write"   "echo x > ${file^^}"                  # case-insensitive file systems (macOS, Windows)
  ed "$w_edit"    editFiles "${file^^}"
  if [ "${entry%/}" != "$entry" ]; then   # the folder itself
    sh deny "rm -rf ${entry%/}"
    ed deny editFiles "${entry%/}"
  fi
done <<<"$list"

# ---------- task state: agents read it, only the scripts write it ----------
sh allow 'ls .work/T-1/state.env'
sh allow 'grep MR_IID .work/T-1/state.env'
sh allow 'scripts/agent/start-task.sh T-1 login-form'
sh allow 'scripts/agent/start-review.sh 142 86abc'
sh allow 'scripts/agent/set-review-spec.sh 142 86abc'
sh deny  'echo CLICKUP_ID=1 >> .work/mr-142/state.env'
sh deny  'echo x > .github/skills/review-mr/SKILL.md'
ed deny  editFiles '.github/skills/review-mr/SKILL.md'
ed allow read_file '.work/T-1/state.env'
sh deny  'echo REVIEW_ROUND=0 >> .work/T-1/state.env'
sh deny  'sed -i s/REVIEW_ROUND=3/REVIEW_ROUND=0/ .work/T-1/state.env'
ed deny  editFiles '.work/T-1/state.env'

# ---------- the auto run's record: next-stage.sh writes it, agents read it ----------
# status.md holds stop approvals ("Approved <stop-id>: <checksum>"); a forged
# line would walk an auto run past a stop the user never approved.
ed deny  editFiles '.work/T-1/status.md'
ed deny  create_file '/home/u/proj/.work/T-1/status.md'
sh deny  'echo "Approved pre-ship: x" >> .work/T-1/status.md'
sh deny  'sed -i s/stop/run/ .work/T-1/status.md'
sh deny  'echo "Approved pre-ship: x" >> .work/*/status.md'
sh deny  'echo "Approved pre-ship: x" >| .work/T-1/status.md'
sh deny  'echo "Approved pre-ship: x" >&.work/T-1/status.md'
sh deny  'echo REVIEW_ROUND=0 >| .work/T-1/state.env'
sh deny  'echo REVIEW_ROUND=0 >&.work/T-1/state.env'
ed allow read_file '.work/T-1/status.md'
sh allow 'cat .work/T-1/status.md'
sh allow 'scripts/agent/next-stage.sh T-1 approve'
# run.log: next-stage.sh appends a line per decision and approval (ADR 0002).
ed deny  editFiles '.work/T-1/run.log'
ed deny  create_file '/home/u/proj/.work/T-1/run.log'
sh deny  'echo "approve pre-ship" >> .work/T-1/run.log'
sh deny  'sed -i /stop/d .work/T-1/run.log'
sh deny  ': > .work/T-1/run.log'
sh deny  'rm .work/T-1/run.log'
ed allow read_file '.work/T-1/run.log'
sh allow 'cat .work/T-1/run.log'
sh allow 'tail -n 20 .work/T-1/run.log'
ed allow editFiles 'logs/run.log'
sh allow 'echo done > logs/run.log'
ed allow editFiles '.work/run.log'
# Only under .work/<id>/: a product file named status.md stays editable.
ed allow editFiles 'docs/status.md'
sh allow 'echo x > docs/status.md'
ed allow editFiles '.workx/T-1/status.md'
ed allow editFiles '.work/status.md'
ed allow editFiles '.work/T-1/sub/status.md'
# Other shapes of the same path: doubled slashes, "." and ".." segments.
ed deny  editFiles '.work//T-1/status.md'
ed deny  editFiles '.work/T-1//status.md'
ed deny  editFiles '.work/./T-1/status.md'
ed deny  editFiles '.work/T-1/./status.md'
ed deny  editFiles '.work/T-1/../T-1/status.md'
ed deny  editFiles '../proj/.work/T-1/status.md'
sh deny  'echo x >> .work//T-1/status.md'
sh deny  'echo x >> .work/./T-1/status.md'
sh deny  'echo x >> .work/T-1/../T-1/status.md'
sh deny  'cp /tmp/s.md .work/T-1//status.md'
ed deny  editFiles 'scripts//agent/config.sh'
sh deny  'echo x > scripts/./agent/config.sh'
ed allow editFiles '.work/T-1/../status.md'
sh allow 'echo x > .work/T-1/../../docs/status.md'

# ---------- the pipeline's scripts are run, never sourced ----------
sh deny "bash -c 'source scripts/agent/config.sh; source scripts/agent/ship-gate.sh; gate_record_run T-1 0'"
sh deny "bash -c 'source scripts/agent/config.sh; source scripts/agent/evidence-lib.sh; approval_write T-1 AC-1.md'"
sh deny "bash -c 'source scripts/agent/config.sh; state_set_review T-1 0 x'"
sh deny '. ./scripts/agent/config.sh && set_state T-1 REVIEW_ROUND 0'
sh deny 'bash -c ". \"$PWD/scripts/agent/config.sh\"; state_set_mr_iid T-1 1"'
sh deny 'cd src; source ../scripts/agent/task-state.sh'
sh deny 'source Scripts/Agent/config.sh'   # case-insensitive file systems
sh allow 'ls . scripts/agent'
sh allow 'source .venv/bin/activate && python app.py'
sh allow 'bash scripts/agent/run-checks.sh T-1 unit'
sh allow 'grep -n source scripts/agent/config.sh'

# ---------- protected paths: a match starts at a path segment, the same in both channels ----------
sh allow 'echo x > my.agent.env'
ed allow editFiles 'my.agent.env'
sh allow 'rm vendor/myscripts/agent/x.sh'
ed allow editFiles 'vendor/myscripts/agent/x.sh'
sh allow 'cat .npmrc.example'
ed allow read_file '.npmrc.example'
sh allow 'cat docs/oauth.auth/x'
ed allow read_file 'docs/oauth.auth/x'
sh allow 'echo x > .agent.env.bak'
ed allow editFiles '.agent.env.bak'
sh deny 'grep -rn verified-head docs/'
sh deny "echo x > './scripts/agent/config.sh'"
sh deny 'cat --netrc-file=.netrc'

# ---------- the auto run's router: only the top level runs it ----------
# A subagent's call carries agentId (the top-level call doesn't): a stage agent
# in an auto run could otherwise approve a stop itself, or upset stall detection.
sub_sh() {   # sub_sh <allow|deny|ask> <command>: the call comes from a subagent
  local got
  got="$(jq -n --arg c "$2" --arg cwd "$T" '{toolName: "bash", toolArgs: {command: $c}, cwd: $cwd, agentId: "a1", agentType: "reviewer", parentAgentId: "p1"}' |
    PIPELINE_GUARD=on bash "$GUARD" | jq -r '.permissionDecision // "allow"')"
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: expected $1, got $got (subagent): $2"; fi
}
sh allow 'scripts/agent/next-stage.sh T-1'
sh allow 'scripts/agent/next-stage.sh T-1 approve'
sub_sh deny 'scripts/agent/next-stage.sh T-1 approve'
sub_sh deny 'scripts/agent/next-stage.sh T-1'
sub_sh deny 'bash ./scripts/agent/next-stage.sh T-1 approve'
sub_sh allow 'cat scripts/agent/next-stage.sh'
sub_sh allow 'scripts/agent/run-checks.sh T-1 all'
# Other spellings of running it: a quoted path, a variable, a glob, split
# quotes, a pipe into xargs or a shell, a command substitution, find -exec.
sub_sh deny '"scripts/agent/next-stage.sh" T-1 approve'
sub_sh deny "'scripts/agent/next-stage.sh' T-1 approve"
sub_sh deny 'N=scripts/agent/next-stage.sh; $N T-1 approve'
sub_sh deny 'x=next-stage; scripts/agent/$x.sh T-1 approve'
sub_sh deny 'scripts/agent/next-st*.sh T-1 approve'
sub_sh deny 'scripts/agent/next-sta""ge.sh T-1 approve'
sub_sh deny 'scripts/agent/next-stage\.sh T-1 approve'
sub_sh deny 'echo T-1 approve | xargs scripts/agent/next-stage.sh'
sub_sh deny 'cat scripts/agent/next-stage.sh | bash -s T-1 approve'
sub_sh deny 'cat $(scripts/agent/next-stage.sh T-1 approve)'
sub_sh deny 'find scripts -name next-stage.sh -exec {} T-1 approve \;'
sub_sh deny 'bash -c "scripts/agent/next-stage.sh T-1 approve"'
sub_sh deny 'cd scripts/agent && ./next-stage.sh T-1 approve'
# Reading it is fine: the name in a read-only command.
sub_sh allow 'cat scripts/agent/next-stage.sh 2>/dev/null'
sub_sh allow 'head -n 40 scripts/agent/next-stage.sh'
sub_sh allow 'grep -rn next-stage.sh docs/'
sub_sh allow 'grep -n approve scripts/agent/next-stage.sh | head -5'
sub_sh allow 'git diff main -- scripts/agent/next-stage.sh tests/test-next-stage.sh'
sub_sh allow 'git log --oneline -- scripts/agent/next-stage.sh'
sub_sh allow 'wc -l scripts/agent/next-stage.sh'
sub_sh allow 'echo x > notes/next-steps.md'
sub_sh allow 'bash tests/test-next-stage.sh'

# ---------- splitting a command doesn't depend on GNU sed ----------
# GNU sed turns "\n" in a replacement into a newline; BSD/macOS sed may write
# a literal "n". This fake sed passes everything to the real one, with each
# "\n" in a replacement made an "n", the way BSD sed does.
real_sed="$(command -v sed)"
mkdir -p "$T/bsd-sed"
cat > "$T/bsd-sed/sed" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do args+=("\${a//\\\\n\\//n/}"); done
exec "$real_sed" "\${args[@]}"
EOF
chmod +x "$T/bsd-sed/sed"
gnu_path="$PATH"; PATH="$T/bsd-sed:$PATH"
if [ "$(printf 'a;b\n' | sed -E 's/;/\n/g')" = "anb" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: the fake BSD sed should write n for \\n"; fi
sub_sh deny 'cat x; scripts/agent/next-stage.sh T-1 approve'
sub_sh deny 'cat x && scripts/agent/next-stage.sh T-1 approve'
sub_sh deny 'cat x | scripts/agent/next-stage.sh T-1 approve'
sub_sh allow 'grep -n approve scripts/agent/next-stage.sh | head -5'
sub_sh allow 'cat scripts/agent/next-stage.sh 2>&1'
sh deny  'true && echo x > .work/T-1/status.md'
sh deny  'true; cp /tmp/s.md .work/T-1/status.md'
sh allow 'rm -rf .work/T-1/tmp && scripts/agent/run-checks.sh T-1 test'
sh allow 'cp a b; cat scripts/agent/config.sh'
PATH="$gnu_path"
# A redirect to a descriptor (2>&1, >&2) doesn't split a segment at its "&":
# that would part a writer from the path it writes.
sh deny  'cp /tmp/s.md 2>&1 .work/T-1/status.md'
sh deny  'rm 2>&1 scripts/agent/config.sh'
sh deny  'cp /tmp/x >&2 .agent.env'
sh allow 'rm -rf .work/T-1/tmp 2>&1 && cat scripts/agent/config.sh 2>&1'

# ---------- switch ----------
got="$(jq -n '{toolName: "bash", toolArgs: {command: "git push"}}' | PIPELINE_GUARD=off bash "$GUARD")"
if [ "$got" = "{}" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: PIPELINE_GUARD=off should allow"; fi

# ---------- an MR review is read-only (ADR 0003) ----------
WTP=.git/pipeline-reviews/mr-142
# sh_in <dir> <decision> <command>: the command run with <dir> as the working folder.
sh_in() {
  local got; got="$(jq -n --arg c "$3" --arg cwd "$1" '{toolName: "bash", toolArgs: {command: $c}, cwd: $cwd}' |
    PIPELINE_GUARD=on bash "$GUARD" | jq -r '.permissionDecision // "allow"')"
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: expected $2, got $got in $1: $3"; fi
}
mkdir -p "$T/$WTP/src"
ed deny  editFiles "$WTP/src/a.ts"
ed deny  editFiles "/home/u/proj/$WTP/src/a.ts"
ed allow read_file "$WTP/src/a.ts"
sh allow "git -C $WTP diff origin/main...HEAD"
sh allow "cat $WTP/src/a.ts"
sh deny  "echo x > $WTP/src/a.ts"
sh deny  "sed -i s/a/b/ $WTP/src/a.ts"
sh deny  "git -C $WTP commit -am fix"
sh deny  "cd $WTP && git commit -am fix"
sh deny  "git -C $WTP push origin HEAD:refs/heads/fix"
sh_in "$T/$WTP" deny  'git commit -am fix'
sh_in "$T/$WTP" deny  'echo x > src/a.ts'
sh_in "$T/$WTP" deny  'sed -i s/a/b/ src/a.ts'
sh_in "$T/$WTP" allow 'git log --oneline -5'
sh_in "$T/$WTP" allow 'grep -rn TODO src'
sh_in "$T" allow 'git commit -am "feat: mine"'          # the user's own checkout is unaffected
sh deny  'scripts/agent/clickup.sh comment mr-142 note.md'
sh deny  'scripts/agent/clickup.sh status mr-142 done'
sh deny  'scripts/agent/clickup.sh attach mr-142 x.png'
sh deny  'scripts/agent/upload-evidence.sh mr-142'
sh allow 'scripts/agent/clickup.sh fetch mr-142'
sh ask   'scripts/agent/clickup.sh comment T-1 note.md'    # delivery: still a confirmation
sh ask   'scripts/agent/post-review-thread.sh 142 CR-3'
sh ask   'scripts/agent/reply-thread.sh mr-142 disc1 .work/mr-142/replies/CR-1.md'
sh deny  'scripts/agent/reply-thread.sh mr-142 disc1 .work/mr-142/replies/CR-1.md --resolve'
sh allow 'scripts/agent/reply-thread.sh T-1 disc1 .work/T-1/reply.md --resolve'   # delivery: the duo stop confirmed it
sh ask   'bash scripts/agent/post-review-thread.sh 142 CR-1'

# ---------- the review worktree where config.sh's review_worktree puts it ----------
# In a plain repo, and in one whose git folder isn't named .git (--separate-git-dir).
for layout in plain separate; do
  d="$T/layout-$layout"
  if [ $layout = plain ]; then git init -q "$d/proj"; else git init -q --separate-git-dir "$d/repo.git" "$d/proj"; fi
  mkdir -p "$d/proj/scripts"; cp -r "$ROOT/payload/scripts/agent" "$d/proj/scripts/"
  wt="$(cd "$d/proj" && bash -c 'source scripts/agent/config.sh; review_worktree mr-142')"
  mkdir -p "$wt/src"
  ed deny  editFiles "$wt/src/a.ts"
  sh deny  "echo x > $wt/src/a.ts"
  sh_in "$wt" deny  'echo x > src/a.ts'
  sh_in "$wt" deny  'git commit -am fix'
  sh_in "$wt" allow 'git log --oneline -5'
done

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
