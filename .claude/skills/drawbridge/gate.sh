#!/usr/bin/env bash
# Drawbridge: pre-deploy security gate. PreToolUse hook on Bash: reads hook JSON on stdin.
# Exit 0 = allow, exit 2 = block (stderr goes to Claude).
# Manual: gate.sh --check (report only, writes nothing), gate.sh --approve (after an all-PASS review).
set -uo pipefail

MODE=hook
case "${1:-}" in --check) MODE=check ;; --approve) MODE=approve ;; esac

if [ "$MODE" = hook ]; then
  CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
  # Fast path: almost every Bash call ends here.
  grep -qE 'wrangler|git[[:space:]].*push' <<<"$CMD" || exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0  # no git = nothing to diff
cd "$ROOT" || exit 0
STATE=.drawbridge
mkdir -p "$STATE"

PROD_BRANCH=$(grep -hoE 'production_branch"?[[:space:]]*[:=][[:space:]]*"[^"]+"' wrangler.toml wrangler.json wrangler.jsonc 2>/dev/null \
  | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
PROD_BRANCH=${PROD_BRANCH:-main}
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Value of a flag (--flag X or --flag=X) in a command segment.
flag() { grep -oE -- "(^|[[:space:]])$1(=|[[:space:]]+)[^[:space:];&|]+" <<<"$2" | head -1 | sed -E "s/.*$1(=|[[:space:]]+)//"; }

is_prod() {
  local seg rest br env ref dst
  while IFS= read -r seg; do
    if grep -qE 'wrangler[[:space:]]+pages[[:space:]]+deploy' <<<"$seg"; then
      br=$(flag --branch "$seg"); br=${br:-$CUR_BRANCH}
      [ "$br" = "$PROD_BRANCH" ] && return 0
    elif grep -qE 'wrangler[[:space:]]+(deploy|publish)' <<<"$seg"; then
      env=$(flag --env "$seg"); [ -z "$env" ] && env=$(flag -e "$seg")
      { [ -z "$env" ] || [ "$env" = production ]; } && return 0
    elif grep -qE 'git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*push' <<<"$seg"; then
      grep -qE -- '--(all|mirror)' <<<"$seg" && return 0
      # positionals after "push": remote, then refspecs
      rest=$(sed -E 's/.*push//' <<<"$seg" | tr ' ' '\n' | grep -vE '^(-|$)' | tail -n +2)
      [ -z "$rest" ] && [ "$CUR_BRANCH" = "$PROD_BRANCH" ] && return 0
      for ref in $rest; do
        dst=${ref##*:}; dst=${dst#+}; dst=${dst#refs/heads/}
        [ "$dst" = HEAD ] && dst=$CUR_BRANCH
        [ "$dst" = "$PROD_BRANCH" ] && return 0
      done
    fi
  done < <(sed -E 's/(&&|\|\||;|\|)/\n/g' <<<"$CMD")
  return 1
}

if [ "$MODE" = hook ]; then
  is_prod || exit 0
  if [ "${SKIP_DRAWBRIDGE:-}" = 1 ] || grep -q 'SKIP_DRAWBRIDGE=1' <<<"$CMD"; then
    echo "$(date -Is) SKIPPED head=$(git rev-parse --short HEAD) cmd=$CMD" >> "$STATE/skipped.log"
    exit 0
  fi
fi

# Base: last reviewed SHA, else last tag, else HEAD~20, else the empty tree (short history).
BASE=$(cat "$STATE/last-reviewed" 2>/dev/null)
git cat-file -e "${BASE:-x}^{commit}" 2>/dev/null || BASE=$(git describe --tags --abbrev=0 2>/dev/null) \
  || BASE=$(git rev-parse -q --verify HEAD~20) || BASE=$(git hash-object -t tree /dev/null)

# wrangler ships the working tree, so include uncommitted changes; git push ships commits only.
RANGE="$BASE..HEAD"
{ [ "$MODE" != hook ] || grep -q wrangler <<<"$CMD"; } && RANGE=$BASE

# Approval covers the whole working tree, so it also covers a later git push of the same commits.
DIFF_HASH=$(git diff "$BASE" | sha1sum | cut -c1-40)
if [ "$MODE" = approve ]; then echo "$DIFF_HASH" > "$STATE/approved"; echo "approved $RANGE"; exit 0; fi
pass() { git rev-parse HEAD > "$STATE/last-reviewed"; rm -f "$STATE/approved"; exit 0; }
[ "$(cat "$STATE/approved" 2>/dev/null)" = "$DIFF_HASH" ] && pass

# check  path-regex  added-line-regex   ("-" = any). Lowercase ERE, no spaces (use [[:space:]]).
RULES='
1  (^|/)middleware\.[jt]sx?$  -
1  -  x-middleware-subrequest
1  (^|/)package\.json$  "next"[[:space:]]*:
2  (^|/)public/|(^|/)\.assetsignore$|(^|/)_routes\.json$  -
2  -  pages_build_output_dir|^\[assets\]|"assets"[[:space:]]*:|distdir|outdir|output:[[:space:]]*.export
3  -  storage\.from\(|storage\.(buckets|objects)|storage_policy|bucket_id
4  (^|/)(api|functions|routes|server)/.*(checkout|cart|stripe|payment|order)  -
4  (^|/)(api|functions|routes|server)/|(^|/)route\.[jt]s$|\+server\.[jt]s$  (^|[^a-z_])(price|amount|total|unit_amount)([^a-z_]|$)
4  -  stripe\.(checkout|paymentintents|charges)|line_items
5  (login|signin|sign-in|log-in)  -
5  -  turnstile|rate.?limit
6  (^|/)supabase/migrations/|\.sql$  -
6  -  row[[:space:]]+level[[:space:]]+security|(create|alter|drop)[[:space:]]+policy|service_role|anon_key|supabase_anon|d1_databases|kv_namespaces
6  (^|/)package\.json$  "(@supabase/[^"]+|supabase)"[[:space:]]*:
7  -  <script[^>]*[[:space:]]src=|polyfill|unpkg\.com|jsdelivr|cdnjs|//cdn\.
8  (sms|otp|phone)  -
8  -  twilio|vonage|messagebird|send_?sms|verify\.services|(^|[^a-z])otp([^a-z]|$)
9  -  @anthropic-ai/sdk|from[[:space:]]+.openai.|@ai-sdk/|from[[:space:]]+.ai.|chat\.completions|messages\.create|generatetext|streamtext|env\.ai\.run
10 -  jwt|jose|jsonwebtoken|(^|[^a-z])sign\(|session_?secret|cookie_?secret|auth_secret|nextauth_secret
10 (^|/)package\.json$  "(next-auth|@auth/[^"]+|better-auth|lucia|@clerk/[^"]+|jose|jsonwebtoken|[^"]*jwt[^"]*)"[[:space:]]*:
11 -  (^|[^a-z])(balance|credits?|coupons?|inventory|redeem|quota)([^a-z]|$)
12 (signup|sign-up|register|oauth|verify-email|link-account)  -
12 -  signup|sign_up|linkidentity|link_identity|email_verified|emailverified|oauth
13 (^|/)[^/]*dns[^/]*$  -
13 (^|/)wrangler\.(toml|jsonc?)$  custom_domain|zone_name|zone_id|routes|route[[:space:]]*=|"route"
14 (^|/)(api|functions|routes|server|workers?)/|(^|/)route\.[jt]s$|\+server\.[jt]s$  fetch\(|axios|got\(|undici
14 -  searchparams\.get\(.(url|uri|target|src|link|webhook|callback|endpoint|image)|(query|body)\.(url|uri|target|link|webhook)
15 -  readfile|createreadstream|sendfile|path\.(join|resolve)|(bucket|r2|kv|env\.[a-z_]+)\.(get|put|delete|list)\(
16 (reset|forgot|magic|recover)  -
16 -  resetpasswordforemail|reset_?password|password_?reset|magic_?link|signinwithotp|x-forwarded-host|headers\.get\(.host.|headers\.host
17 \.map$  -
17 -  productionbrowsersourcemaps|sourcemap|source_map|upload_source_maps|devtool
18 (^|/)_headers$|(^|/)middleware\.[jt]sx?$  -
18 -  x-frame-options|frame-ancestors|content-security-policy|helmet
19 -  redirect\(|[?&]next=|returnto|return_to|callbackurl|redirect_to|redirect_uri|location\.href[[:space:]]*=
20 (login|signin|sign-in|signup|sign-up|register|reset|forgot)  -
20 -  user[[:space:]]not[[:space:]]found|no[[:space:]]account|(invalid|incorrect|wrong)[[:space:]]password|already[[:space:]](registered|exists)|email[[:space:]]not[[:space:]]found|does[[:space:]]not[[:space:]]exist
'

HITS=$(awk '
  FNR==NR { if (NF==3) { n++; C[n]=$1; P[n]=$2; L[n]=$3 } next }
  /^diff --git / { F=substr($0, index($0, " b/")+3); f=tolower(F); hdr=1
                   for (i=1;i<=n;i++) if (L[i]=="-" && f ~ P[i]) print C[i], F; next }
  hdr && /^deleted file/ && f ~ /(^|\/)wrangler\.(toml|jsonc?)$/ { print 13, F }
  /^@@/ { hdr=0; next }
  !hdr && /^\+/ { s=tolower(substr($0,2))
                  for (i=1;i<=n;i++) if (L[i]!="-" && (P[i]=="-" || f ~ P[i]) && s ~ L[i]) print C[i], F }
' <(printf '%s\n' "$RULES") <(git diff -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$RANGE" -- . ':(exclude).claude/skills/drawbridge') | sort -n -u)

if [ -z "$HITS" ]; then
  [ "$MODE" = check ] && { echo "No security-relevant changes in $RANGE."; exit 0; }
  pass
fi

{
  echo "DRAWBRIDGE RAISED: changes in $RANGE match the checks below. Production deploy is blocked until they are reviewed."
  awk '{ if ($1!=c) { if (c!="") print ""; c=$1; k=0; printf "  %s:", c } if (++k<=4) printf " %s", $2; else if (k==5) printf " ..." } END { print "" }' <<<"$HITS"
  echo "Run /drawbridge for checks $(cut -d' ' -f1 <<<"$HITS" | uniq | paste -sd, ) only. Diff: git diff -U15 $RANGE -- <files>"
} >&2
[ "$MODE" = check ] && exit 0
exit 2
