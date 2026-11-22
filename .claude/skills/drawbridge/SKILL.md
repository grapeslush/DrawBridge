---
name: drawbridge
description: "Security review of changes before a Cloudflare production deploy, limited to the checks the gate flagged. Use only when gate.sh blocks a deploy or the user runs /drawbridge."
---

# Drawbridge — production security gate

## Inputs
- From the gate's block message: the check numbers, files, and RANGE.
- Run manually with no block message: run `.claude/skills/drawbridge/gate.sh --check` and use its output. If it says nothing matched, report that and stop.

## Token rules
- Review ONLY the flagged checks. Skip every other check, even ones that look relevant.
- Read the diff hunks only: `git diff -U15 <RANGE> -- <files>`. Open a whole file only when a hunk can't be judged without it. Never scan the repo.
- Checks 2 and 17: inspect the built output, not the source. Find the dir from wrangler config (`pages_build_output_dir`, `assets.directory`), else the first of `out dist .vercel/output/static .open-next/assets build`. Run `find <dir> \( -name '.*' -o -name '*.map' \) | head`.
- No tutorials, no background, no restating the diff.

## What to verify (one per check)
1. Middleware auth can't be skipped via `x-middleware-subrequest`, and `next` is >= 15.2.3 / 14.2.25 / 13.5.9 / 12.3.5.
2. The build output has no `.git`, `.env` or other dotfiles, and public/ holds nothing private.
3. New buckets are private unless meant to be public, and storage policies scope objects to `auth.uid()`.
4. The server reads price and amount from the DB or Stripe price IDs, never from the request body.
5. Login is rate limited per IP and per account, or protected by Turnstile verified server-side.
6. Every new table has RLS on with a real policy, and service_role or admin bindings are never reachable from client code.
7. Each new third-party script is needed, pinned to a trusted domain, and SRI or CSP limited. No polyfill.io.
8. SMS/OTP sends are rate limited per number and IP, behind Turnstile, and limited to allowed country codes.
9. User or fetched content goes to the LLM as data, not instructions, and the model's output can't trigger privileged tools or actions on its own.
10. JWT secrets come from env, are 32+ random bytes, and verify pins the algorithm (`none` rejected).
11. Balance, credit, coupon and inventory changes are atomic (a conditional UPDATE, a transaction, or a Durable Object), not read-then-write.
12. Accounts aren't usable or linkable until email is verified, and OAuth linking requires the verified email or the user's consent.
13. No route, custom domain or DNS record points at a deleted Worker or Pages project or an unclaimed external host.
14. URLs taken from requests are allowlisted before a server-side fetch, with no requests to internal or metadata IPs.
15. File paths and R2/KV keys built from params are normalized and can't escape their prefix (`..`, `/`, encoded forms).
16. Reset and magic links use a configured base URL, not the Host or x-forwarded-host header.
17. The production build has no `.map` files and no source map upload to a public path.
18. Pages set `frame-ancestors` or `X-Frame-Options` to deny or self.
19. Redirect targets are checked against an allowlist or must be relative paths (`/x`, never `//x` or `\x`).
20. Login, signup and reset give the same message, status code and roughly the same timing whether the account exists or not.

## Report (whole report under 25 lines)
One line per flagged check, nothing else:
- `#N PASS`
- `#N FAIL file:line — issue — fix: one line`
- `#N NEEDS-HUMAN — what to confirm (e.g. the RLS policy in the Supabase dashboard, a CNAME in Cloudflare DNS)`

## After the report
- Any FAIL: do not deploy. Offer to apply the fixes. Once they're applied, rerun the deploy command so the gate checks the new diff.
- No FAIL, but some NEEDS-HUMAN: ask the user to confirm those items, then continue as if all passed.
- All PASS: run `.claude/skills/drawbridge/gate.sh --approve`, then rerun the original deploy command. The gate sees the approval, writes HEAD to `.drawbridge/last-reviewed`, and lets the deploy through.
- Never add `SKIP_DRAWBRIDGE=1` unless the user says to.
