#!/usr/bin/env bash
# Self-test: builds a throwaway git repo, installs Drawbridge, and checks the gate's decisions.
set -uo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); E=$(mktemp); trap 'rm -rf "$T" "$E"' EXIT
cd "$T"
git init -q -b main; git config user.email test@example.com; git config user.name test
"$SRC/install.sh" "$T" >/dev/null || { echo "install failed"; exit 1; }
G=.claude/skills/drawbridge/gate.sh
fails=0
hook() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | "$G" 2>"$E"; }
expect() { # expect <exit-code> <command> [checks-substring]
  hook "$2"; local rc=$?
  if [ "$rc" != "$1" ] || { [ -n "${3:-}" ] && ! grep -q "checks $3 only" "$E"; }; then
    echo "FAIL: '$2' -> exit $rc (want $1${3:+, checks $3})"; sed 's/^/      /' "$E"; fails=$((fails+1))
  else echo "ok:   '$2' -> $rc${3:+ (checks $3)}"; fi
}
approve() { "$G" --approve >/dev/null; hook "wrangler deploy"; }

printf '# app\n' > README.md
printf '{\n  "dependencies": {\n    "next": "15.1.0",\n    "react": "19"\n  }\n}\n' > package.json
git add -A; git commit -qm init
expect 2 "wrangler deploy"; approve

echo more >> README.md; git commit -qam readme
expect 0 "wrangler deploy"
[ "$(cat .drawbridge/last-reviewed)" = "$(git rev-parse HEAD)" ] && echo "ok:   marker advanced to HEAD" || { echo "FAIL: marker not advanced"; fails=$((fails+1)); }

mkdir -p app/api/login
printf 'export async function POST(req) {\n  if (!user) return Response.json({ error: "User not found" }, { status: 404 });\n}\n' > app/api/login/route.ts
git add -A; git commit -qm login
expect 2 "npm run build && npx wrangler deploy" "5,20"
for c in "wrangler deploy --env staging" "wrangler deploy -e preview" "wrangler pages deploy out --branch feature-x" "git push origin feature" "git status"; do expect 0 "$c"; done
for c in "wrangler deploy --env=production" "wrangler pages deploy out --branch=main" "git push origin HEAD:main" "git push" "git push -u origin main"; do expect 2 "$c"; done
expect 0 "SKIP_DRAWBRIDGE=1 wrangler deploy"
grep -q SKIPPED .drawbridge/skipped.log && echo "ok:   skip logged" || { echo "FAIL: skip not logged"; fails=$((fails+1)); }
approve

sed -i.bak 's/"19"/"19.1"/' package.json && rm package.json.bak; git commit -qam react
expect 0 "git push origin main"
sed -i.bak 's/15.1.0/15.2.3/' package.json && rm package.json.bak; git commit -qam next
expect 2 "git push origin main" "1"; approve

echo 'const r = redirect(url)' >> README.md   # uncommitted: wrangler ships it, git push does not
expect 2 "wrangler deploy" "19"
expect 0 "git push origin main"

echo; [ "$fails" = 0 ] && echo "All tests passed." || { echo "$fails test(s) failed."; exit 1; }
