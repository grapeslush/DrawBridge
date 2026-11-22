#!/usr/bin/env bash
# Drawbridge: pre-deploy security gate. PreToolUse hook on Bash: reads hook JSON on stdin.
# Exit 0 = allow, exit 2 = block (stderr goes to Claude).
# Manual: gate.sh --check [dir] (report only, writes nothing), gate.sh --approve [dir] (after an all-PASS review).
# Scripts, Makefiles and package.json are read as text to find the deploy inside them, never run.
set -uo pipefail

MODE=hook DIR=$PWD CMD= PROD_DIR= SHIPS=
case "${1:-}" in --check) MODE=check ;; --approve) MODE=approve ;; esac
[ "$MODE" != hook ] && [ -d "${2:-}" ] && DIR=$(cd "$2" && pwd)

if [ "$MODE" = hook ]; then
  IN=$(jq -r '(.cwd // "") + "\n" + (.tool_input.command // "")' 2>/dev/null) || exit 0
  CMD=${IN#*$'\n'}
  # Fast path: almost every Bash call ends here.
  grep -qE 'wrangler|opennext|push|merge|workflow|deploy|release|ship|npm|pnpm|yarn|bun|make|just|turbo|nx|lerna|task|mise|\.sh|node|tsx|deno|python|terraform|tofu|terragrunt|pulumi|cloudflare' <<<"$CMD" || exit 0
  [ -d "${IN%%$'\n'*}" ] && DIR=${IN%%$'\n'*}
fi

# --- Is this command a production deploy? -------------------------------------------------------
# A task name that means "ship it", and words that mean it isn't production.
TASK='^([^[:space:]]*[:/@#])?(deploy|release|ship)([:_-][^[:space:]]*)?$'
NONPROD='(^|[^a-z])(stag(e|ing)?|preview|dev|develop|test|local|qa|sandbox|canary)([^a-z]|$)'
# Code (JS/TS/Python...) that deploys: shells out to wrangler or calls the upload API.
CODE='wrangler.*(deploy|publish)|opennextjs-cloudflare.*deploy|api\.cloudflare\.com.*(workers/scripts|pages/projects)'
CF_API='api\.cloudflare\.com[^[:space:]]*/(workers/scripts|workers/services|workers/dispatch|pages/projects/[^/[:space:]]+/deployments)'
WRITES='(-X|--request|--method)[=[:space:]]*["'\'']?(PUT|POST|PATCH)|(^|[[:space:]])(-F|--form|--form-string|-d|--data[a-z-]*|-T|--upload-file|--post-data|--post-file)([=[:space:]]|$)'
IAC='(^|[[:space:]/])((terraform|tofu|terragrunt)[[:space:]](.*[[:space:]])?apply|pulumi[[:space:]](.*[[:space:]])?(up|update))([[:space:]]|$)'
CF_IAC='cloudflare_workers?_(script|deployment|version|route)|cloudflare_pages_(project|domain)|cloudflare\.(workers?script|workersdeployment|pagesproject)'
# git's own options before the subcommand: -c key="a value", -C dir, --git-dir=...
GITOPT='^(([^[:space:]]*/)?git)[[:space:]]+(-c[[:space:]]+[^[:space:]=]+=("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]*)|-C[[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]*)?)[[:space:]]+(.*)$'
# Leading VAR=value assignments and wrappers (env, sudo...) before the real command.
LEAD='^[[:space:](]*(([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'\''[^'\'']*'\''|\$\([^)]*\)|[^[:space:]]*))|env|sudo|time|exec|nohup|command|then|do|else|!)[[:space:]]+(.*)$'

# Value of a flag (--flag X or --flag=X) in a command segment.
flag() { grep -oE -- "(^|[[:space:]])$1(=|[[:space:]]+)[^[:space:];&|]+" <<<"$2" | head -1 | sed -E "s/.*$1(=|[[:space:]]+)//" | tr -d "\"'"; }
root_of() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }
cur_branch() { git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null; }
prod_branch() { # production_branch from the nearest wrangler config, default main
  local r b; r=$(root_of "$1") || r=$1
  b=$(grep -hoE 'production_branch"?[[:space:]]*[:=][[:space:]]*"[^"]+"' "$1"/wrangler.toml "$1"/wrangler.json "$1"/wrangler.jsonc \
    "$r"/wrangler.toml "$r"/wrangler.json "$r"/wrangler.jsonc 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  echo "${b:-main}"
}
# abspath <base> <dir>: the directory resolved against base, or base itself if it doesn't exist.
abspath() { local p=${2//[\"\']/}; case $p in /*) ;; '~'|'~/'*) p=$HOME${p#\~} ;; *) p=$1/$p ;; esac; if [ -d "$p" ]; then (cd "$p" && pwd); else echo "$1"; fi; }
# fpath <base> <file>: the file resolved against base, if it exists.
fpath() { local p=${2//[\"\']/}; case $p in /*) ;; '~/'*) p=$HOME${p#\~} ;; *) p=$1/$p ;; esac; [ -f "$p" ] && echo "$p"; }
# The command a segment runs, without leading assignments and wrappers.
words() { local s=$1; while [[ $s =~ $LEAD ]]; do s=${BASH_REMATCH[4]}; done; printf '%s' "${s#"${s%%[![:space:](]*}"}"; }
# One command per line: split on && || ; | and newlines outside quotes, drop comments and heredoc bodies
# (text written to a file isn't a command), but keep the body fed to a shell (bash <<EOF).
split() {
  awk '
    function flush() { print cur; cur = "" }
    {
      line = $0
      if (hd != "") { l = line; sub(/^[\t ]*/, "", l); if (l == hd) hd = ""; next }
      if (q == "" && match(line, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        h = substr(line, RSTART, RLENGTH); sub(/^[^<]?<<-?[[:space:]]*/, "", h); gsub(/["\047]/, "", h)
        if (line !~ /(^|[[:space:]\/])(ba|z|da)?sh[[:space:]]*(-[a-z]+[[:space:]]*)*<</) hd = h
      }
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "\047") { cur = cur c; if (c == "\047") q = ""; continue }
        if (q == "$") { cur = cur c; if (c == "\\") { cur = cur substr(line, i + 1, 1); i++ } else if (c == "\047") q = ""; continue }  # $'..\'..'
        if (q == "" && c == "$" && substr(line, i + 1, 1) == "\047") { q = "$"; cur = cur "$\047"; i++; continue }
        if (c == "\\") { cur = cur c substr(line, i + 1, 1); i++; continue }
        if (q == "\"") { cur = cur c; if (c == "\"") q = ""; continue }
        if (c == "\047" || c == "\"") { q = c; cur = cur c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:](]/)) break
        t = substr(line, i, 2)
        if (t == "&&" || t == "||") { flush(); i++; continue }
        if (c == ";" || c == "|") { flush(); continue }
        cur = cur c
      }
      if (q == "") flush(); else cur = cur " "
    }
    END { if (cur != "") print cur }
  ' <<<"$1"
}
# Wrangler picks the environment from --env, -e or CLOUDFLARE_ENV; none means the top-level (production) config.
prod_env() {
  local e; e=$(flag --env "$1"); [ -n "$e" ] || e=$(flag -e "$1")
  [ -n "$e" ] || e=$(grep -oE 'CLOUDFLARE_ENV=[^[:space:]]+' <<<"$1" | head -1 | cut -d= -f2 | tr -d "\"'")
  [ -z "$e" ] || [[ $e =~ ^prod(uction)?$ ]]
}
# recipe <make|just> <file> <target>: the target's command lines, plus "<tool> <dep>" per prerequisite. Empty target = the default (first) one.
recipe() {
  awk -v tool="$1" -v t="$3" '
    /^[^[:space:]#.][^=:]*:([^=]|$)/ && !/^[^:]*:=/ {
      split($0, a, ":"); n = split(a[1], nm, /[[:space:]]+/); if (t == "") t = nm[1]; inr = 0
      for (i = 1; i <= n; i++) if (nm[i] == t) inr = 1
      if (inr) { d = substr($0, index($0, ":") + 1); sub(/#.*/, "", d); m = split(d, dd, /[[:space:]]+/)
                 for (j = 1; j <= m; j++) if (dd[j] ~ /^[A-Za-z0-9_.-]+$/) print tool, dd[j] }
      next }
    inr && /^[[:space:]]/ { print; next }
    inr && NF { inr = 0 }
  ' "$2" 2>/dev/null
}
ship() { PROD_DIR=$1 SHIPS=$2; }  # tree: deploys the working tree; head: ships commits only

# scan <text> <dir> <depth>: succeeds if the text deploys to production, following cd, package scripts,
# make/just targets and script files (read, never run) up to 6 levels deep.
scan() {
  local seg w g a f r t br rest ref dst i name run ws dd pdir text targets list dir=$2 d=$(( $3 + 1 ))
  local -a tok
  [ "$d" -gt 6 ] && return 1
  while IFS= read -r seg; do
    w=$(words "$seg"); [ -n "$w" ] || continue
    if [[ $w =~ ^(bash|sh|zsh|dash)[[:space:]]+-[a-z]*c[[:space:]]+(.*)$ ]]; then  # sh -c "...": scan the inner command
      a=${BASH_REMATCH[2]}; case $a in \'*|\"*) t=${a:0:1}; a=${a#?}; a=${a%"$t"*} ;; esac
      scan "$a" "$dir" "$d" && return 0; continue
    fi
    g=$w; while [[ $g =~ $GITOPT ]]; do g="git ${BASH_REMATCH[6]}"; done; [[ $g =~ ^[^[:space:]]*/git([[:space:]].*)$ ]] && g="git${BASH_REMATCH[1]}"
    case $w in echo\ *|printf\ *|grep\ *|egrep\ *|rg\ *|cat\ *|head\ *|tail\ *|less\ *|sed\ *|awk\ *|man\ *|which\ *|type\ *|ls\ *|find\ *|jq\ *) continue ;; esac
    case $g in git\ commit*|git\ log*|git\ show*|git\ diff*|git\ grep*|git\ status*|git\ add*|git\ tag*|git\ blame*|git\ stash*) continue ;; esac
    if [[ $w =~ ^(cd|pushd)([[:space:]]+([^[:space:]\)]+))?([[:space:]]|$) ]]; then dir=$(abspath "$dir" "${BASH_REMATCH[3]:-$HOME}"); continue; fi
    seg=${seg//[\(\)\{\}\`]/ }  # (subshells), { groups } and `backticks`: match on the words inside
    # Quoted text is data ("a message about wrangler deploy"); a quoted single word ("staging") stays a word.
    seg=$(sed -E "s/\"([^\"[:space:]]*)\"/\1/g; s/'([^'[:space:]]*)'/\1/g; s/\"[^\"]*\"/ /g; s/'[^']*'/ /g" <<<"$seg")

    # wrangler deploy / versions deploy / pages deploy / d1 migrations apply --remote (also npx, bunx, wrangler@x)
    if [[ $seg =~ (^|[[:space:]/])wrangler(@[^[:space:]]*)?([[:space:]].*)?$ ]]; then
      a=" ${BASH_REMATCH[3]} "
      [[ $a =~ [[:space:]]--dry-run[[:space:]=] ]] && continue
      if [[ $a =~ [[:space:]]pages[[:space:]](.*[[:space:]])?(deploy|publish)[[:space:]] ]]; then
        br=$(flag --branch "$a"); [ "${br:-$(cur_branch "$dir")}" = "$(prod_branch "$dir")" ] && { ship "$dir" tree; return 0; }
      elif [[ $a =~ [[:space:]](triggers|versions[[:space:]]+upload)[[:space:]] ]]; then :
      elif [[ $a =~ [[:space:]](deploy|publish)[[:space:]] ]] || { [[ $a =~ [[:space:]]migrations[[:space:]]+apply[[:space:]] ]] && [[ $a =~ [[:space:]]--remote[[:space:]=] ]]; }; then
        prod_env "$seg" && { ship "$dir" tree; return 0; }
      fi
      continue
    fi
    if [[ $seg =~ (^|[[:space:]/])(opennextjs-cloudflare|@opennextjs/cloudflare)(@[^[:space:]]*)?[[:space:]](.*[[:space:]])?deploy([[:space:]]|$) ]]; then
      prod_env "$seg" && { ship "$dir" tree; return 0; }; continue
    fi

    # git push to the production branch (Pages / Workers Builds deploy from it)
    if [[ $g =~ ^git[[:space:]]+push([[:space:]]|$) ]]; then
      t=$(flag -C "$seg"); if [ -n "$t" ]; then t=$(abspath "$dir" "$t"); else t=$dir; fi
      [[ $seg =~ [[:space:]]--(all|mirror)([[:space:]]|$) ]] && { ship "$t" head; return 0; }
      br=$(prod_branch "$t"); r=$(cur_branch "$t")
      rest=$(sed -E 's/.*push//' <<<"$seg" | tr ' ' '\n' | grep -vE '^(-|$)' | tail -n +2)  # positionals after the remote
      [ -z "$rest" ] && [ "$r" = "$br" ] && { ship "$t" head; return 0; }
      for ref in $rest; do
        dst=${ref##*:}; dst=${dst#+}; dst=${dst#refs/heads/}; [ "$dst" = HEAD ] && dst=$r
        [ "$dst" = "$br" ] && { ship "$t" head; return 0; }
      done
      continue
    fi
    # Merging a PR or starting a workflow that deploys. shortcut: gated against local HEAD, not the PR's own commits.
    if [[ $seg =~ (^|[[:space:]/])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]; then
      [[ $seg =~ --disable-auto ]] || { ship "$dir" head; return 0; }; continue
    fi
    if [[ $seg =~ (^|[[:space:]/])gh[[:space:]]+workflow[[:space:]]+run([[:space:]]+([^-[:space:]][^[:space:]]*))? ]]; then
      t=${BASH_REMATCH[3]//[\"\']/}; r=$(root_of "$dir") || continue
      for f in "$r"/.github/workflows/*.yml "$r"/.github/workflows/*.yaml; do
        [ -f "$f" ] || continue
        { [ "${f##*/}" = "$t" ] || grep -qsF -- "$t" "$f"; } && grep -qsE 'wrangler|cloudflare/(wrangler|pages)-action' "$f" && { ship "$dir" head; return 0; }
      done
      continue
    fi
    # Direct upload through the Cloudflare API, and Terraform/Pulumi in repos that manage Workers or Pages
    if [[ $seg =~ $CF_API ]] && [[ $seg =~ $WRITES ]]; then ship "$dir" tree; return 0; fi
    if [[ $seg =~ $IAC ]]; then
      r=$(root_of "$dir") && git -C "$r" grep -qIiE --untracked "$CF_IAC" && { ship "$dir" tree; return 0; }; continue
    fi

    # A script file: shell scripts are scanned line by line, anything else is searched for deploy code.
    read -r t f _ <<<"$w"
    case $t in */*) f=$t ;; bash|sh|zsh|dash|node|tsx|ts-node|deno|bun|python|python3) case ${f:-} in -*|run) f= ;; esac ;; *) f= ;; esac
    if [ -n "${f:-}" ] && f=$(fpath "$dir" "$f"); then
      a=; case "$t $f" in bash\ *|sh\ *|zsh\ *|dash\ *|*.sh|*.bash) a=sh ;; *) head -c 64 "$f" | head -1 | grep -qE '^#!.*(sh|bash|zsh)' && a=sh ;; esac
      if [ "$a" = sh ]; then scan "$(head -c 262144 "$f")" "$dir" "$d" && return 0
      else head -c 262144 "$f" | grep -qE "$CODE" && { ship "$dir" tree; return 0; }; fi
      continue
    fi

    # npm / pnpm / yarn / bun scripts: expand pre<name>, <name> (+ its args) and post<name> from package.json.
    if [[ $seg =~ (^|[[:space:]/])(npm|pnpm|yarn|bun)[[:space:]]+(.*)$ ]]; then
      r=${BASH_REMATCH[2]}; read -ra tok <<<"${BASH_REMATCH[3]}"
      pdir=$dir name= run= ws= rest= dd=
      for ((i = 0; i < ${#tok[@]}; i++)); do
        t=${tok[i]}
        if [ -n "$name" ]; then  # after the name: script args, except npm's own flags before the first --
          if [ "$t" = -- ] && [ -z "$dd" ]; then dd=1
          elif [ "$r" = npm ] && [ -z "$dd" ] && [ "$t" = --prefix ]; then i=$((i + 1)); pdir=$(abspath "$dir" "${tok[i]:-}")
          elif [ "$r" = npm ] && [ -z "$dd" ] && [[ $t == --prefix=* ]]; then pdir=$(abspath "$dir" "${t#*=}")
          else rest="$rest $t"; fi
          continue
        fi
        case $t in
          --prefix|-C|--cwd|--dir) i=$((i + 1)); pdir=$(abspath "$dir" "${tok[i]:-}") ;;
          --prefix=*|--cwd=*|--dir=*) pdir=$(abspath "$dir" "${t#*=}") ;;
          --workspace|--filter|-F) i=$((i + 1)); ws=1 ;;
          -w) [ "$r" = npm ] && i=$((i + 1)); ws=1 ;;
          --workspace=*|--filter=*|--workspaces|-ws|-r|--recursive) ws=1 ;;
          -*) ;;
          run|run-script) run=1 ;;
          *) [ -n "$run" ] || [ "$r" != npm ] || break; name=$t ;;
        esac
      done
      [ -n "$name" ] || continue
      [ "$r" = pnpm ] && [ -z "$run" ] && [ "$name" = deploy ] && continue  # pnpm's own "deploy" command, not a script
      text=
      [ -z "$ws" ] && [ -f "$pdir/package.json" ] && text=$(jq -r --arg n "$name" --arg a "$rest" \
        '.scripts // {} | select(.[$n]) | [.["pre" + $n], .[$n] + $a, .["post" + $n]] | map(select(. != null)) | join("\n")' "$pdir/package.json" 2>/dev/null)
      if [ -n "$text" ]; then scan "$text" "$pdir" "$d" && return 0; continue; fi
      # Can't resolve it (workspace filter, no package.json): go by the task name.
      list=$name; case $name in workspace|workspaces|exec|dlx|x|turbo|nx|lerna|moon|rush|task|mise) list=$rest ;; esac
      for t in $list; do [[ $t =~ $TASK ]] && ! [[ "$rest $t" =~ $NONPROD ]] && { ship "$pdir" tree; return 0; }; done
      continue
    fi
    # Monorepo and task runners whose tasks live elsewhere: go by the task name.
    if [[ $seg =~ (^|[[:space:]/])(turbo|nx|lerna|moon|rush|task|mise)[[:space:]]+(.*)$ ]]; then
      a=${BASH_REMATCH[3]}
      for t in $a; do [[ $t =~ $TASK ]] && ! [[ $a =~ $NONPROD ]] && { ship "$dir" tree; return 0; }; done
      continue
    fi
    # make / just: expand the target's recipe and prerequisites.
    if [[ $seg =~ (^|[[:space:]/])(make|gmake|just)([[:space:]]+(.*))?$ ]]; then
      r=${BASH_REMATCH[2]}; [ "$r" = gmake ] && r=make; a=${BASH_REMATCH[4]:-}; read -ra tok <<<"$a"
      pdir=$dir f= targets=
      for ((i = 0; i < ${#tok[@]}; i++)); do
        t=${tok[i]}
        case "$r $t" in
          "make -C"|"make --directory"|"just -d"|"just --working-directory") i=$((i + 1)); pdir=$(abspath "$dir" "${tok[i]:-}") ;;
          "make -f"|"make --file"|"make --makefile"|"just -f"|"just --justfile") i=$((i + 1)); f=${tok[i]:-} ;;
          *\ -*|*=*) ;;
          *) targets="$targets $t" ;;
        esac
      done
      if [ -n "$f" ]; then f=$(fpath "$pdir" "$f"); else
        if [ "$r" = just ]; then list="justfile Justfile .justfile"; else list="GNUmakefile makefile Makefile"; fi
        for t in $list; do [ -f "$pdir/$t" ] && { f=$pdir/$t; break; }; done
      fi
      for t in ${targets:-@default}; do
        text=; [ -n "$f" ] && text=$(recipe "$r" "$f" "${t#@default}")
        if [ -n "$text" ]; then scan "$text" "$pdir" "$d" && return 0
        elif [[ $t =~ $TASK ]] && ! [[ $a =~ $NONPROD ]]; then ship "$pdir" tree; return 0; fi
      done
      continue
    fi
  done <<<"$(split "$1")"
  return 1
}

if [ "$MODE" = hook ]; then
  scan "$CMD" "$DIR" 0 || exit 0
  DIR=$PROD_DIR
fi

ROOT=$(root_of "$DIR") || exit 0  # no git = nothing to diff
cd "$ROOT" || exit 0
STATE=.drawbridge
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

if [ "$MODE" = hook ] && { [ "${SKIP_DRAWBRIDGE:-}" = 1 ] || split "$CMD" | grep -qE '^[[:space:](]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*SKIP_DRAWBRIDGE=1[[:space:]]'; }; then
  mkdir -p "$STATE"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIPPED head=$(git rev-parse --short HEAD) cmd=$(sed -E 's/([A-Za-z_]*(TOKEN|KEY|SECRET|PASSWORD)[A-Za-z_]*=)[^[:space:]]+/\1***/g' <<<"$CMD")" >> "$STATE/skipped.log"
  exit 0
fi

# Base: last reviewed SHA, else last tag, else HEAD~20, else the empty tree (short history).
BASE=$(cat "$STATE/last-reviewed" 2>/dev/null)
git cat-file -e "${BASE:-x}^{commit}" 2>/dev/null || BASE=$(git describe --tags --abbrev=0 2>/dev/null) \
  || BASE=$(git rev-parse -q --verify HEAD~20) || BASE=$(git hash-object -t tree /dev/null)

# Most deploys upload the working tree, so uncommitted changes count; a push or merge ships commits only.
RANGE="$BASE..HEAD"
[ "${SHIPS:-tree}" = tree ] && RANGE=$BASE

# Approval covers the whole working tree, so it also covers a later git push of the same commits.
DIFF_HASH=$(git diff "$BASE" | git hash-object --stdin)
if [ "$MODE" = approve ]; then mkdir -p "$STATE"; echo "$DIFF_HASH" > "$STATE/approved"; echo "approved $RANGE in $ROOT"; exit 0; fi
pass() {  # uncommitted changes: keep the approval, so a migrate-then-deploy of the same diff isn't asked twice
  git diff --quiet HEAD 2>/dev/null && { mkdir -p "$STATE"; git rev-parse HEAD > "$STATE/last-reviewed"; rm -f "$STATE/approved"; }
  exit 0
}
[ "$MODE" = hook ] && [ "$(cat "$STATE/approved" 2>/dev/null)" = "$DIFF_HASH" ] && pass

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
  echo "DRAWBRIDGE RAISED in $ROOT: changes in $RANGE match the checks below. Production deploy is blocked until they are reviewed."
  awk '{ if ($1!=c) { if (c!="") print ""; c=$1; k=0; printf "  %s:", c } if (++k<=4) printf " %s", $2; else if (k==5) printf " ..." } END { print "" }' <<<"$HITS"
  echo "Run /drawbridge for checks $(cut -d' ' -f1 <<<"$HITS" | uniq | paste -sd, ) only. Diff: git -C $ROOT diff -U15 $RANGE -- <files>"
  echo "After an all-PASS review, approve with: $SELF --approve $ROOT"
} >&2
[ "$MODE" = check ] && exit 0
exit 2
