#!/usr/bin/env bash
# Self-test: builds a throwaway git repo, installs Drawbridge, and checks the gate's decisions.
set -uo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); OUT=$(mktemp -d); E=$(mktemp); trap 'rm -rf "$T" "$OUT" "$E"' EXIT
T=$(cd "$T" && pwd); OUT=$(cd "$OUT" && pwd)
cd "$T"
git init -q -b main; git config user.email test@example.com; git config user.name test
"$SRC/install.sh" "$T" >/dev/null || { echo "install failed"; exit 1; }
G=.claude/skills/drawbridge/gate.sh
fails=0
hook() { jq -nc --arg c "$1" --arg d "${CWD:-$PWD}" '{cwd:$d, tool_input:{command:$c}}' | "$T/$G" 2>"$E"; }
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails+1)); }
expect() { # expect <exit-code> <command> [checks-substring]
  hook "$2"; local rc=$?
  if [ "$rc" != "$1" ] || { [ -n "${3:-}" ] && ! grep -q "checks $3 only" "$E"; }; then
    bad "'$2' -> exit $rc (want $1${3:+, checks $3})"; sed 's/^/      /' "$E"
  else ok "'$2' -> $rc${3:+ (checks $3)}"; fi
}
# Approve from outside the repo, the way a session sitting in a parent folder would.
approve() { (cd "$OUT" && "$T/$G" --approve "$T" >/dev/null); expect 0 "wrangler deploy"; }

printf '# app\n' > README.md
cat > package.json <<'EOF'
{
  "scripts": {
    "build": "echo build",
    "test": "echo test",
    "deploy": "wrangler deploy",
    "deploy:staging": "wrangler deploy --env staging",
    "ship": "npm run build && npm run deploy",
    "cf": "npm run release:cf --",
    "release:cf": "bash scripts/deploy.sh"
  },
  "dependencies": {
    "next": "15.1.0",
    "react": "19"
  }
}
EOF
mkdir -p scripts sub
printf '#!/usr/bin/env bash\nset -e\n# wrangler deploy --env staging  (a comment)\nnpm run build\nnpx wrangler@4 deploy\n' > scripts/deploy.sh
printf '#!/usr/bin/env bash\necho checking\n' > scripts/lint.sh
printf "import { execSync } from 'node:child_process'\nexecSync('npx wrangler deploy', { stdio: 'inherit' })\n" > scripts/release.mjs
printf 'console.log(1)\n' > scripts/hello.mjs
cat > scripts/mention.sh <<'EOF'
#!/usr/bin/env bash
echo "next: wrangler deploy"
msg=$'it\'s time to npm run deploy; then wrangler deploy'
check "npm run deploy" "wrangler deploy"
EOF
chmod +x scripts/mention.sh
printf 'build:\n\techo build\n\ndeploy: build migrate\n\techo deploying\n\nmigrate:\n\tnpx wrangler d1 migrations apply db --remote\n\nstage:\n\tnpx wrangler deploy --env staging\n' > Makefile
printf '{\n  "scripts": { "deploy": "wrangler deploy" }\n}\n' > sub/package.json
git add -A; git commit -qm init

for c in "git status" "npm test" "npm run build" "ls -la" "make build"; do expect 0 "$c"; done
[ ! -e .drawbridge ] && ok "nothing written for non-deploys" || bad ".drawbridge created by a non-deploy"
expect 2 "wrangler deploy"
grep -q -- "--approve $T" "$E" && ok "block message names the repo and approve command" || bad "no approve command in block message"
approve

echo more >> README.md; git commit -qam readme
expect 0 "wrangler deploy"
[ "$(cat .drawbridge/last-reviewed)" = "$(git rev-parse HEAD)" ] && ok "marker advanced to HEAD" || bad "marker not advanced"

mkdir -p app/api/login
printf 'export async function POST(req) {\n  if (!user) return Response.json({ error: "User not found" }, { status: 404 });\n}\n' > app/api/login/route.ts
git add -A; git commit -qm login
expect 2 "npm run build && npx wrangler deploy" "5,20"

echo "-- wrangler forms"
for c in "npx wrangler@4 deploy" "wrangler --config wrangler.toml deploy" "wrangler versions deploy --yes" "wrangler pages publish out" \
         "wrangler d1 migrations apply db --remote" "CLOUDFLARE_ENV=production wrangler deploy" "XDG_CONFIG_HOME=x TOKEN=\$(cat ~/t) wrangler deploy" \
         "npx opennextjs-cloudflare deploy" "wrangler deploy --env=production" "wrangler pages deploy out --branch=main"; do expect 2 "$c"; done
for c in "wrangler deploy --env staging" "wrangler deploy -e preview" "wrangler deploy --dry-run --outdir dist" "wrangler versions upload" \
         "wrangler triggers deploy" "wrangler d1 migrations apply db --local" "CLOUDFLARE_ENV=staging wrangler deploy" "wrangler dev" \
         "wrangler pages deploy out --branch feature-x" "echo wrangler deploy" "grep -r 'wrangler deploy' ."; do expect 0 "$c"; done

echo "-- package scripts, make, script files"
for c in "npm run deploy" "pnpm run deploy" "yarn deploy" "bun run deploy" "npm run ship" "npm run cf" "npm --prefix sub run deploy" \
         "make deploy" "make migrate" "./scripts/deploy.sh" "bash scripts/deploy.sh" "node scripts/release.mjs" \
         "turbo run deploy" "nx run web:deploy" "pnpm --filter web run deploy" "yarn workspace web deploy"; do expect 2 "$c"; done
for c in "npm run deploy -- --env staging" "npm run deploy:staging" "npm test" "pnpm deploy out" "make stage" "make build" "make" \
         "./scripts/lint.sh" "./scripts/mention.sh" "node scripts/hello.mjs" "turbo run deploy:staging" "npm install deploy-kit"; do expect 0 "$c"; done

echo "-- other routes"
for c in "gh pr merge 12 --squash" "curl -X PUT https://api.cloudflare.com/client/v4/accounts/a/workers/scripts/w -F metadata=@m.json"; do expect 2 "$c"; done
for c in "curl https://api.cloudflare.com/client/v4/accounts/a/workers/scripts" "gh pr view 12" "terraform apply"; do expect 0 "$c"; done
printf 'resource "cloudflare_workers_script" "w" {}\n' > main.tf
expect 2 "terraform apply -auto-approve"; rm main.tf

echo "-- working directory"
CWD=$OUT expect 2 "cd $T/sub && npm run deploy"
CWD=$OUT expect 0 "npm run deploy"
CWD=$T/sub expect 2 "npm run deploy"
CWD=$OUT expect 2 "(cd $T/sub && npm run deploy)"
CWD=$OUT expect 2 "bash -c 'cd $T/sub && npm run deploy'"
CWD=$OUT expect 2 "npm run deploy --prefix $T/sub"
CWD=$T/sub expect 2 "cdk synth && npm run deploy"
for c in "(wrangler deploy)" 'bash -c "wrangler deploy"' "{ npm run deploy; }" "pnpm turbo run deploy" "pnpm exec nx run web:deploy"; do expect 2 "$c"; done
for c in 'bash -c "echo wrangler deploy"' "(npm test)" "yarn add deploy-kit" 'echo "a && wrangler deploy"' \
         $'git commit -m "fix\n\nnpm run deploy now; wrangler deploy too"' $'cat > notes.md <<\'EOF\'\nrun npx wrangler deploy\nEOF' \
         $'python3 - <<\'EOF\'\nprint("wrangler deploy")\nEOF' "jq -r .x <<<'wrangler deploy'"; do expect 0 "$c"; done
expect 2 $'bash <<\'EOF\'\nwrangler deploy\nEOF'
expect 2 $'cat > n.md <<EOF\nSKIP_DRAWBRIDGE=1 is the bypass\nEOF\nwrangler deploy'

echo "-- git push"
for c in "wrangler deploy --env staging" "git push origin feature" "git status"; do expect 0 "$c"; done
for c in "git push origin HEAD:main" "git push" "git push -u origin main" "git -C $T push origin main" 'git -c user.name="A B" push origin main'; do expect 2 "$c"; done
for c in 'git -c user.name="A B" commit -m "wrangler deploy and git push origin main"' 'expect 0 "wrangler deploy"' \
         'for c in "npx wrangler deploy" "npm run deploy"; do run "$c"; done' 'wrangler deploy --env "staging"'; do expect 0 "$c"; done
for c in 'npm run "deploy"' 'CLOUDFLARE_API_TOKEN="$(cat ~/t)" wrangler deploy' 'cd "sub" && npm run deploy'; do expect 2 "$c"; done
expect 0 "SKIP_DRAWBRIDGE=1 TOKEN=s3cret wrangler deploy"
grep -q SKIPPED .drawbridge/skipped.log && ok "skip logged" || bad "skip not logged"
grep -q s3cret .drawbridge/skipped.log && bad "secret written to skip log" || ok "secret redacted in skip log"
approve

sed -i.bak 's/"19"/"19.1"/' package.json && rm package.json.bak; git commit -qam react
expect 0 "git push origin main"
sed -i.bak 's/15.1.0/15.2.3/' package.json && rm package.json.bak; git commit -qam next
expect 2 "git push origin main" "1"; approve

echo 'const r = redirect(url)' >> README.md   # uncommitted: wrangler ships it, git push does not
expect 2 "wrangler deploy" "19"
expect 2 "npm run deploy" "19"
expect 0 "git push origin main"
approve   # with uncommitted changes the approval holds for the next deploy of the same diff (migrate, then deploy)
expect 0 "wrangler d1 migrations apply db --remote"
expect 0 "npm run deploy"
git commit -qam redirect
expect 0 "git push origin main"
[ "$(cat .drawbridge/last-reviewed)" = "$(git rev-parse HEAD)" ] && ok "marker advanced once committed" || bad "marker not advanced after commit"

echo; [ "$fails" = 0 ] && echo "All tests passed." || { echo "$fails test(s) failed."; exit 1; }
