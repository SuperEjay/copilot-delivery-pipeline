#!/usr/bin/env bash
# The test tooling table: per stack, how to detect it and, per check, the
# command to use or the tool to recommend. Source this file; don't run it.
# Usage: stack_tooling     (from the project root; prints one message per line)
#
# doctor.sh prints these lines in its "test tooling" section, and install.sh
# shows them through doctor.sh. It only recommends: it never writes .agent.env
# and never installs anything (ADR 0005). A check that .agent.env sets to
# something other than .agent.env.example's value (an empty value included)
# shows that command and no recommendation.
#
# One row per line, fields split by "|":  stack | check | probe | tool | command | install
#   check    detect, or install, lint, types, unit, integration, e2e.
#   probe    space-separated conditions, all of which must hold:
#              file:<path>   the path exists       dep:<npm package>   it's in package.json
#              always        always holds          -                   a recommendation row
#   tool     the name shown; on a detect row, the stack's name.
#   command  what goes in .agent.env. On an e2e row, "auto" means run-checks.sh
#            finds it by itself (Playwright, config.sh), and empty means the team
#            sets E2E_CMD by hand.
#   install  how to install a recommended tool (recommendation rows only).
#
# The first stack whose detect row holds wins, so a more specific stack comes
# first (a Laravel project has a package.json too). Per check, rows are in order
# of preference: the first row whose probe holds is used, and the recommendation
# rows above it are printed as recommended. When no row holds, every
# recommendation row is printed, the first one as the pick.
#
# To add a stack: add its detect row above any stack it overlaps, then its rows
# for each check. No code changes.
STACKS_TABLE='
laravel|detect|file:composer.json file:artisan|Laravel (composer.json, artisan)||
laravel|install|file:package-lock.json|Composer and npm|composer install && npm ci|
laravel|install|always|Composer|composer install|
laravel|lint|file:vendor/bin/pint|Pint|vendor/bin/pint --test|
laravel|lint|-|Pint|vendor/bin/pint --test|composer require laravel/pint --dev
laravel|types|file:vendor/bin/phpstan|PHPStan|vendor/bin/phpstan analyse|
laravel|types|-|Larastan|vendor/bin/phpstan analyse|composer require larastan/larastan --dev, then add a phpstan.neon that includes vendor/larastan/larastan/extension.neon
laravel|unit|file:vendor/bin/pest|Pest|vendor/bin/pest --testsuite=Unit|
laravel|unit|-|Pest|vendor/bin/pest --testsuite=Unit|composer require pestphp/pest --dev --with-all-dependencies && vendor/bin/pest --init
laravel|unit|file:vendor/bin/phpunit|PHPUnit|vendor/bin/phpunit --testsuite=Unit|
laravel|integration|file:vendor/bin/pest|Pest|vendor/bin/pest --testsuite=Feature|
laravel|integration|-|Pest|vendor/bin/pest --testsuite=Feature|composer require pestphp/pest --dev --with-all-dependencies && vendor/bin/pest --init
laravel|integration|file:vendor/bin/phpunit|PHPUnit|vendor/bin/phpunit --testsuite=Feature|
laravel|e2e|dep:@playwright/test|Playwright|auto|
laravel|e2e|file:vendor/pestphp/pest-plugin-browser|the Pest browser plugin||
laravel|e2e|-|the Pest browser plugin||composer require pestphp/pest-plugin-browser --dev && npm install playwright@latest && npx playwright install, then set E2E_CMD to the command that runs your browser tests (screenshots go to tests/Browser/Screenshots)
laravel|e2e|-|Playwright|auto|npm i -D @playwright/test && npx playwright install (run-checks.sh then finds it by itself)
node|detect|file:package.json|Node (package.json)||
node|install|always|npm|npm ci|
node|lint|always|npm|npm run lint --silent|
node|types|always|TypeScript|npx tsc --noEmit|
node|unit|always|npm|npm run test:unit --silent|
node|integration|always|npm|npm run test:integration --silent|
node|e2e|dep:@playwright/test|Playwright|auto|
node|e2e|-|Playwright|auto|npm i -D @playwright/test && npx playwright install (run-checks.sh then finds it by itself)
'

# _stack_holds <probe>: every condition in the probe holds here.
_stack_holds() {
  local c
  for c in $1; do
    case "$c" in
      always) ;;
      file:*) [ -e "${c#file:}" ] || return 1 ;;
      dep:*) grep -qs "\"${c#dep:}\"" package.json || return 1 ;;
      *) return 1 ;;
    esac
  done
}

# _stack_value <file> <key>: the key's value once the file is sourced.
_stack_value() {
  ( set +u; source "./$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2-}\"" )
}

# _stack_set <key>: .agent.env sets the key to something other than
# .agent.env.example's value (empty included). Prints the value.
_stack_set() {
  local re="^[[:space:]]*(export[[:space:]]+)?$1=" v
  [ -f .agent.env ] && grep -qE "$re" .agent.env || return 1
  v="$(_stack_value .agent.env "$1")"
  if [ -f .agent.env.example ] && grep -qE "$re" .agent.env.example \
     && [ "$v" = "$(_stack_value .agent.env.example "$1")" ]; then
    return 1
  fi
  printf '%s' "$v"
}

stack_tooling() {
  local stack="" name="" s c p t cmd inst
  while IFS='|' read -r s c p t cmd inst; do
    [ "$c" = detect ] && _stack_holds "$p" && { stack="$s"; name="$t"; break; }
  done <<EOF
$STACKS_TABLE
EOF
  if [ -z "$stack" ]; then
    echo "test tooling: unknown stack: set the commands in .agent.env by hand"
    return 0
  fi
  echo "test tooling: $name. Paste the lines you want into .agent.env (nothing is written or installed for you)"
  local check key set_v used_t used_cmd recs
  for check in install lint types unit integration e2e; do
    case "$check" in
      install) key=INSTALL_CMD ;; lint) key=LINT_CMD ;; types) key=TYPECHECK_CMD ;;
      unit) key=UNIT_CMD ;; integration) key=INTEGRATION_CMD ;; e2e) key=E2E_CMD ;;
    esac
    if set_v="$(_stack_set "$key")"; then
      echo "  $key is set in .agent.env: ${set_v:-(empty, so $check is skipped)}"
      continue
    fi
    # Scan the check's rows: the first that holds is used; recommendations above it are kept.
    used_t=""; used_cmd=""; recs=""
    while IFS='|' read -r s c p t cmd inst; do
      [ "$s" = "$stack" ] && [ "$c" = "$check" ] || continue
      if [ "$p" = - ]; then recs="$recs$t|$cmd|$inst
"
      elif _stack_holds "$p"; then used_t="$t"; used_cmd="$cmd"; break
      fi
    done <<EOF
$STACKS_TABLE
EOF
    _stack_print "$check" "$key" "$used_t" "$used_cmd" "$recs"
  done
}

# _stack_print <check> <key> <used tool> <used command> <recommendation rows>
_stack_print() {
  local check="$1" key="$2" used_t="$3" used_cmd="$4" recs="$5" first=true t cmd inst
  if [ -n "$used_t" ]; then
    if [ "$check" != e2e ]; then echo "  $key=\"$used_cmd\""
    elif [ "$used_cmd" = auto ]; then echo "  e2e: $used_t, which run-checks.sh finds by itself (no E2E_CMD line needed)"
    else echo "  e2e: $used_t is installed: set E2E_CMD to the command that runs your browser tests"
    fi
  fi
  while IFS='|' read -r t cmd inst; do
    [ -n "$t" ] || continue
    if $first; then
      first=false
      if [ -n "$used_t" ]; then echo "    recommended: $t: $inst"
      elif [ "$check" != e2e ]; then echo "  $key=\"$cmd\"   (recommended: $t, not installed: $inst)"
      else echo "  e2e: none found. Recommended: $t: $inst"
      fi
    else
      echo "    or $t: $inst"
    fi
  done <<EOF
$recs
EOF
}
