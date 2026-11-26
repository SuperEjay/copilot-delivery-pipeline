#!/usr/bin/env bash
# Tests doctor.sh, which checks a project's pipeline setup and changes nothing,
# in a scratch repo with a PATH made only of the tools each case allows.
# Usage: tests/test-doctor.sh     (exit 0 = all passed)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"; sed 's/^/      /' "$T/out.txt" 2>/dev/null
  fi
}

# ---------- a PATH with only what we allow ----------
# Real system tools the scripts need, linked into $T/sys. Fakes for the tools a
# case turns on or off go in $T/fake: glab (the shared fake), code (a version),
# node, npx, curl, pdftotext, pandoc.
mkdir -p "$T/sys" "$T/fake"
for t in bash sh env git jq sed awk grep cat head tail tr sort uniq cut find xargs wc mktemp rm mkdir dirname basename date uname printf sha256sum shasum od ls; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$T/sys/$t"
done
fake() {   # fake <name> <exit code> [stdout]
  printf '#!/bin/sh\n[ -n "%s" ] && printf "%%s\\n" "%s"\nexit %s\n' "${3:-}" "${3:-}" "$2" > "$T/fake/$1"; chmod +x "$T/fake/$1"
}
unfake() { rm -f "$T/fake/$1"; }
for t in node npx curl; do fake "$t" 0; done
# glab is the shared fake (tests/lib/fake-glab), its state in $T/forge:
# logged in as "me" until a case adds logged-out.
export FAKE_FORGE="$T/forge"; mkdir -p "$FAKE_FORGE"; echo me > "$FAKE_FORGE/me"
glab_on() { cp "$ROOT/tests/lib/fake-glab/glab" "$T/fake/glab"; rm -f "$FAKE_FORGE/logged-out"; }
glab_logged_out() { glab_on; touch "$FAKE_FORGE/logged-out"; }
glab_on
fake code 0 "1.146.0"

# ---------- scratch project with the pipeline installed ----------
git init -q -b main "$T/proj"; cd "$T/proj"
git config user.email t@t; git config user.name t
mkdir -p scripts .github; cp -r "$ROOT/payload/scripts/agent" scripts/
cp -r "$ROOT/payload/.github/hooks" .github/
cp "$ROOT/payload/.agent.env.example" .agent.env.example; cp .agent.env.example .agent.env
printf '.work/\n.agent.env\n' > .gitignore
git add -A; git commit -qm init

# doc [env...]: run doctor.sh with the allowed PATH and a token exported, unless
# the case says otherwise. Output in $T/out.txt, exit code in $rc.
doc() {
  env -i HOME="$T" PATH="$T/fake:$T/sys" FAKE_FORGE="${FAKE_FORGE:-}" CLICKUP_API_TOKEN="pk_test_123" "$@" \
    bash scripts/agent/doctor.sh > "$T/out.txt" 2>&1; rc=$?
}
line() { grep -E "^$1 +$2" "$T/out.txt"; }   # line <PASS|WARN|FAIL|INFO> <ERE>: a result line
snapshot() { find . -path ./.git -prune -o -type f -print | sort | xargs sha256sum; }

# ---------- all good ----------
snapshot > "$T/before"
doc
check "a good setup: exit 0, no FAIL" '[ $rc -eq 0 ] && ! grep -q "^FAIL" "$T/out.txt"'
for t in git curl jq glab node npx; do
  check "PASS: $t found" 'line PASS "$t\\b"'
done
check "PASS: glab logged in" 'line PASS "glab is logged in"'
check "PASS: the token is exported" 'line PASS "CLICKUP_API_TOKEN is exported"'
check "PASS: .agent.env sets every setting" 'line PASS "\.agent\.env sets every setting"'
check "PASS: no CRLF in the scripts" 'line PASS "no CRLF"'
check "PASS: the guard blocked a test git push" 'line PASS "hook guard works"'
check "PASS: VS Code 1.146.0" 'line PASS "VS Code 1\.146\.0"'
check "INFO: pinned models are checked by hand" 'line INFO "pinned models"'
check "the optional tools missing are WARN, not FAIL" 'line WARN "pdftotext" && line WARN "pandoc"'
check "every line is PASS, WARN, FAIL or INFO" '! grep -vqE "^(PASS|WARN|FAIL|INFO) " "$T/out.txt"'
check "it changes no file in the project" 'snapshot | cmp -s - "$T/before"'
check "the guard test leaves no .work/hooks.log behind" '[ ! -e .work ]'
check "it never prints the token" '! grep -q "pk_test_123" "$T/out.txt"'

# ---------- each FAIL ----------
unfake glab; doc
check "glab missing: FAIL, exit 1" '[ $rc -eq 1 ] && line FAIL "glab is missing"'
glab_logged_out; doc
check "glab not logged in: FAIL, says how" '[ $rc -eq 1 ] && line FAIL "glab isn.t logged in" && grep -q "glab auth login" "$T/out.txt"'
glab_on
env -i HOME="$T" PATH="$T/fake:$T/sys" bash scripts/agent/doctor.sh > "$T/out.txt" 2>&1; rc=$?
check "token not exported: FAIL, says where to put it" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN isn.t exported" && grep -q "shell profile" "$T/out.txt"'
echo 'CLICKUP_API_TOKEN="pk_test_123"' >> .agent.env; doc
check "token in .agent.env: FAIL, value not printed" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN is set in \.agent\.env" && ! grep -q "pk_test_123" "$T/out.txt"'
sed -i '/CLICKUP_API_TOKEN/d' .agent.env
echo 'token: pk_test_123' > notes.txt; git add notes.txt; git commit -qm notes; doc
check "token value in a tracked file: FAIL, names the file, not the value" '[ $rc -eq 1 ] && line FAIL "CLICKUP_API_TOKEN.s value is in a tracked file" && grep -q "notes.txt" "$T/out.txt" && ! grep -q "pk_test_123" "$T/out.txt"'
git rm -q notes.txt; git commit -qm rm
sed -i '/^MAX_AUTO_FIX_ROUNDS=/d' .agent.env; doc
check ".agent.env missing a setting: WARN naming it, exit 0" '[ $rc -eq 0 ] && line WARN "\.agent\.env doesn.t set: MAX_AUTO_FIX_ROUNDS"'
mv .agent.env "$T/env.keep"; doc
check "no .agent.env: FAIL" '[ $rc -eq 1 ] && line FAIL "no \.agent\.env"'
mv "$T/env.keep" .agent.env
printf 'echo hi\r\n' >> scripts/agent/clickup.sh; doc
check "CRLF in a script: FAIL naming it" '[ $rc -eq 1 ] && line FAIL "CRLF" && grep -q "scripts/agent/clickup.sh" "$T/out.txt"'
git checkout -q scripts/agent/clickup.sh
doc PIPELINE_GUARD=off
check "PIPELINE_GUARD=off in this shell: FAIL, the guard is off" '[ $rc -eq 1 ] && line FAIL "hook guard" && grep -q "PIPELINE_GUARD=off" "$T/out.txt"'
mv scripts/agent/hooks/pre-tool-guard.sh "$T/guard.keep"; doc
check "the guard script missing: FAIL" '[ $rc -eq 1 ] && line FAIL "hook guard"'
mv "$T/guard.keep" scripts/agent/hooks/pre-tool-guard.sh
fake code 0 "1.99.2"; doc
check "VS Code older than 1.106: FAIL" '[ $rc -eq 1 ] && line FAIL "VS Code 1\.99\.2 is older than 1\.106"'
unfake code; doc
check "no code on PATH: WARN, can't tell" '[ $rc -eq 0 ] && line WARN "can.t tell the VS Code version"'
fake code 0 "1.146.0"
fake uname 0 "MINGW64_NT-10.0"; doc
check "Windows with Git Bash: FAIL, unsupported, use WSL" '[ $rc -eq 1 ] && line FAIL "Windows with Git Bash is unsupported" && grep -q "WSL" "$T/out.txt"'
unfake uname

# ---------- finished tasks to clean up (ADR 0003, #87, #132) ----------
# mrstate <iid> <state>: the MR as the fake forge has it.
mrstate() { jq -n --argjson i "$1" --arg s "$2" '{iid: $i, state: $s, target_branch: "main"}' > "$FAKE_FORGE/mr-$1.json"; }
# work_task <task> <state.env lines>: a task's work folder, as the scripts leave it.
work_task() { mkdir -p ".work/$1"; printf '%b' "$2" > ".work/$1/state.env"; }
doc
check "no tasks: no line about cleaning up" '! grep -q "/cleanup" "$T/out.txt"'
work_task mr-5 'TASK=mr-5\nKIND=MR_REVIEW\nMR_IID=5\n'
work_task T6 'TASK=T6\nBRANCH=feature/T6-x\nMR_IID=6\n'
work_task mr-8 'TASK=mr-8\nKIND=MR_REVIEW\nMR_IID=8\n'
work_task T9 'TASK=T9\nBRANCH=feature/T9-x\n'
mrstate 5 merged; mrstate 6 closed; mrstate 8 opened
doc
check "an MR review whose MR is merged: WARN with the /cleanup command" '[ $rc -eq 0 ] && line WARN "mr-5 is finished: MR !5 is merged" && grep -q "/cleanup mr-5" "$T/out.txt"'
check "a delivery task whose MR is closed: WARN too" 'line WARN "T6 is finished: MR !6 is closed" && grep -q "/cleanup T6" "$T/out.txt"'
check "an open MR's task is fine: no line" '! grep -q "MR !8" "$T/out.txt"'
check "a task with no MR yet: no line" '! grep -q "T9" "$T/out.txt"'
rm "$FAKE_FORGE/mr-6.json"; doc
check "an MR glab can't read: INFO, not a guess" 'line INFO "can.t tell whether MR !6 .T6. is finished"'
glab_logged_out; doc
check "glab not logged in: the states are ignored, one INFO with the count" 'line INFO "tasks with an MR: 3" && ! grep -q "is merged" "$T/out.txt" && grep -q "/cleanup <task-id>" "$T/out.txt"'
glab_on
rm -rf .work/mr-5 .work/T6 .work/mr-8 .work/T9

# ---------- e2e without Playwright (#112) ----------
doc
check "no @playwright/test, E2E_CMD not set: INFO, e2e is skipped" '[ $rc -eq 0 ] && line INFO "e2e: skipped"'
echo '{"devDependencies":{"@playwright/test":"^1.50.0"}}' > package.json; doc
check "@playwright/test in package.json: no skip line" '! line INFO "e2e: skipped"'
rm package.json
echo 'E2E_CMD="npx playwright test --reporter=line"' >> .agent.env; doc
check "E2E_CMD runs Playwright, but no @playwright/test: WARN, says how to skip" '[ $rc -eq 0 ] && line WARN "E2E_CMD runs Playwright" && grep -q "E2E_CMD=" "$T/out.txt"'
sed -i '/^E2E_CMD=/d' .agent.env; echo 'E2E_CMD="npm run e2e"' >> .agent.env; doc
check "E2E_CMD set to something else: no e2e skip or WARN line" '! line INFO "e2e: skipped" && ! line WARN "E2E_CMD runs"'
sed -i '/^E2E_CMD=/d' .agent.env

# ---------- test tooling per stack (#131) ----------
# tooling: the lines of the test tooling section.
tooling() { sed -n '/test tooling/,$p' "$T/out.txt"; }
doc
check "unknown stack: one line, set the commands by hand" 'line INFO "test tooling: unknown stack: set the commands in \.agent\.env by hand" && [ "$(grep -c "test tooling" "$T/out.txt")" -eq 1 ]'

# AC-1: Node. .agent.env is the example's copy, so no check counts as set.
echo '{"name":"app"}' > package.json; doc
check "Node: the section names the stack" 'line INFO "test tooling: Node \(package\.json\)"'
for l in 'INSTALL_CMD="npm ci"' 'LINT_CMD="npm run lint --silent"' 'TYPECHECK_CMD="npx tsc --noEmit"' \
         'UNIT_CMD="npm run test:unit --silent"' 'INTEGRATION_CMD="npm run test:integration --silent"'; do
  check "Node: prints $l" 'tooling | grep -qF "INFO    $l"'
done
check "Node without @playwright/test: recommends Playwright, with its install commands" 'line INFO " +e2e: none found\. Recommended: Playwright: npm i -D @playwright/test && npx playwright install"'
check "a recommendation is never a WARN or FAIL" '[ $rc -eq 0 ] && ! tooling | grep -qE "^(WARN|FAIL)"'
echo '{"devDependencies":{"@playwright/test":"^1.50.0"}}' > package.json; doc
check "Node with @playwright/test: no recommendation, found by itself" '! tooling | grep -q "ecommended" && line INFO " +e2e: Playwright, which run-checks\.sh finds by itself"'
rm package.json

# AC-2: Laravel (composer.json + artisan) with only Pest. It has a package.json
# too, as Laravel apps do: Laravel wins over Node.
echo '{"name":"app"}' > package.json; echo '{}' > composer.json; touch artisan
mkdir -p vendor/bin; touch vendor/bin/pest; doc
check "Laravel: the section names the stack, not Node" 'line INFO "test tooling: Laravel \(composer\.json, artisan\)" && ! grep -q "Node" "$T/out.txt"'
check "Laravel with Pest: unit runs Pest" 'tooling | grep -qF "INFO    UNIT_CMD=\"vendor/bin/pest --testsuite=Unit\""'
check "Laravel with Pest: integration runs Pest" 'tooling | grep -qF "INFO    INTEGRATION_CMD=\"vendor/bin/pest --testsuite=Feature\""'
check "Laravel with Pest: Pest isn't recommended" '! tooling | grep -q "Recommended: Pest\|recommended: Pest"'
check "Laravel without Pint: recommends it, with its install command" 'tooling | grep -qF "INFO    LINT_CMD=\"vendor/bin/pint --test\"   (recommended: Pint, not installed: composer require laravel/pint --dev)"'
check "Laravel without PHPStan: recommends Larastan, with its install command" 'tooling | grep -qF "INFO    TYPECHECK_CMD=\"vendor/bin/phpstan analyse\"   (recommended: Larastan, not installed: composer require larastan/larastan --dev"'
check "Laravel without e2e: recommends the Pest browser plugin first, with its install commands" 'line INFO " +e2e: none found\. Recommended: the Pest browser plugin: composer require pestphp/pest-plugin-browser --dev && npm install playwright@latest && npx playwright install"'
check "Laravel without e2e: Playwright as the alternative" 'line INFO " +or Playwright: npm i -D @playwright/test && npx playwright install"'
check "Laravel: never suggests Dusk" '! grep -qi "dusk" "$T/out.txt"'
check "Laravel without package-lock.json: install is composer install" 'tooling | grep -qF "INFO    INSTALL_CMD=\"composer install\""'
touch package-lock.json; doc
check "Laravel with package-lock.json: install adds npm ci" 'tooling | grep -qF "INFO    INSTALL_CMD=\"composer install && npm ci\""'
touch vendor/bin/pint vendor/bin/phpstan; doc
check "Laravel with Pint and PHPStan: no recommendation for them" 'tooling | grep -qF "INFO    LINT_CMD=\"vendor/bin/pint --test\"" && tooling | grep -qF "INFO    TYPECHECK_CMD=\"vendor/bin/phpstan analyse\"" && ! tooling | grep -q "Pint,\|Larastan"'
echo '{"devDependencies":{"@playwright/test":"^1.50.0"}}' > package.json; doc
check "Laravel with @playwright/test: found by itself, nothing recommended" 'line INFO " +e2e: Playwright, which run-checks\.sh finds by itself" && ! tooling | grep -q "ecommended"'
echo '{"name":"app"}' > package.json

# AC-3: Laravel with only PHPUnit: PHPUnit is used, and Pest recommended.
rm vendor/bin/pest; touch vendor/bin/phpunit; doc
check "Laravel with PHPUnit only: unit and integration run PHPUnit" 'tooling | grep -qF "INFO    UNIT_CMD=\"vendor/bin/phpunit --testsuite=Unit\"" && tooling | grep -qF "INFO    INTEGRATION_CMD=\"vendor/bin/phpunit --testsuite=Feature\""'
check "Laravel with PHPUnit only: recommends Pest, with its install command" '[ "$(tooling | grep -cF "recommended: Pest: composer require pestphp/pest --dev")" -eq 2 ]'
rm vendor/bin/phpunit; doc
check "Laravel with neither: recommends Pest and prints its command" 'tooling | grep -qF "INFO    UNIT_CMD=\"vendor/bin/pest --testsuite=Unit\"   (recommended: Pest, not installed:"'

# AC-4: a command .agent.env sets (to other than the example's value) wins.
# The example's Node defaults, as install.sh copies them, don't count as set.
echo 'E2E_CMD="vendor/bin/pest tests/Browser"' >> .agent.env
sed -i 's#^LINT_CMD=.*#LINT_CMD="vendor/bin/phpcs"#; s#^TYPECHECK_CMD=.*#TYPECHECK_CMD=#' .agent.env
snapshot > "$T/before"; doc
check "E2E_CMD set: shows it, recommends no e2e tool" 'line INFO " +E2E_CMD is set in \.agent\.env: vendor/bin/pest tests/Browser" && ! tooling | grep -q "Pest browser\|Playwright"'
check "LINT_CMD set: shows it, doesn't recommend Pint" 'line INFO " +LINT_CMD is set in \.agent\.env: vendor/bin/phpcs" && ! tooling | grep -q "Pint"'
check "TYPECHECK_CMD set to empty: shown as skipped, no Larastan" 'line INFO " +TYPECHECK_CMD is set in \.agent\.env: \(empty, so types is skipped\)" && ! tooling | grep -q "Larastan"'
check "UNIT_CMD at the example's Node value: not counted as set, Pest recommended" '! grep -q "UNIT_CMD is set" "$T/out.txt" && tooling | grep -q "UNIT_CMD=\"vendor/bin/pest"'
check "the section changes no file (.agent.env included)" 'snapshot | cmp -s - "$T/before"'
cp .agent.env.example .agent.env
rm -rf vendor composer.json artisan package.json package-lock.json

# AC-7: the stacks live in one table in stacks.sh, which says how to add one.
check "doctor.sh names no stack's tools: they're all in stacks.sh" '! grep -qiE "composer|artisan|pest|phpunit|pint|larastan" "$ROOT/payload/scripts/agent/doctor.sh"'
check "stacks.sh says how to add a stack" 'grep -q "^# To add a stack" "$ROOT/payload/scripts/agent/stacks.sh"'

# ---------- it's a pipeline script ----------
check "installed as a pipeline file, executable in git" '[ "$(git -C "$ROOT" ls-files -s payload/scripts/agent/doctor.sh | cut -d" " -f1)" = 100755 ]'
check "runs on bash 3.2: no bash 4 features" '! grep -nE "(declare|local) -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}" "$ROOT/payload/scripts/agent/doctor.sh"'

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
