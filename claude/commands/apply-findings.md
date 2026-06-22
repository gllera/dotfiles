---
description: Turn INVESTIGATION-*.md findings into one unified, safe apply-plan (default), then optionally apply them
argument-hint: [<slug>] [--apply [-i]] [--context] [--only F#,…] [--severity lvl] [--file path] [--deep]
---

Consume the verified findings that `/investigate` wrote (`INVESTIGATION-<slug>.md`) and turn
them into action: by default a single **unified, safe, ordered apply-plan** (`FINDINGS-PLAN.md`);
on request, the applied edits themselves.

> $ARGUMENTS

The source reports are an **immutable record of what was found** — never edit them. This command
only ever writes `FINDINGS-PLAN.md` and, in `--apply`, source code.

## Arguments

- **`<slug>`** (positional, optional) — restrict to one report, `INVESTIGATION-<slug>.md`.
  Omitted → unify **all** `INVESTIGATION-*.md` in the repo root into one plan.
- **`--apply`** — execute the plan (see **Apply**). Add **`-i`** / **`--interactive`** to gate
  each finding (approve / skip / defer).
- **`--context`** — "take into account": load the findings as working context and summarize
  them, write nothing, edit nothing. Use before doing related work yourself.
- **`--only …`** — restrict to specific ids. When **planning**, these are source ids: `F1,F3`
  (combine with `<slug>` to disambiguate) or fully-qualified `auth#F3`. When **applying** an
  existing plan, these are the plan's own **step ids**: `S1,S3` — what you actually see in
  `FINDINGS-PLAN.md`. **`--severity high[,med]`** — by severity. **`--file <path>`** — by file
  substring. Filters compose.
- **`--deep`** — re-verify findings against current code with a capped agent fan-out before
  planning (Workflow; off by default). **`--parallel N`** / **`-p N`** caps it (default 3,
  clamp 1–8).

Default (no mode flag) = **plan-only**.

## Inputs — gather + parse

1. Resolve the repo root (`git rev-parse --show-toplevel`, so it works from any subdir) and look
   there for `INVESTIGATION-*.md` (or the single file matching `<slug>`). **None found** → say
   so, suggest running `/investigate` first, stop.
2. Read each. Derive its **slug** from the filename (`INVESTIGATION-auth-flow.md` → `auth-flow`).
   **Prefer the machine-readable contract**: parse the trailing fenced ` ```json ` block that
   `/investigate` appends — it holds the run-health (`complete`/`stopped`/`dropped`/`capHit`/
   `unexaminedAreas`) and the `confirmed` array (each finding with `id, title, file, line,
   category, severity, evidence, fix, verdict.why`). Only if that block is absent (an older
   report) fall back to scraping the markdown by stable id (`F1`…). Either way record the
   `COMPLETE`/`PARTIAL` banner + partial reasons. Reports carry only confirmed findings; treat
   anything malformed as a warning and skip it (don't guess).
3. Apply `--only` / `--severity` / `--file` filters now, before planning.

## Plan-only (default)

Runs in the **main loop** — deterministic, cheap, you stay in the loop. No agents (that's
`--deep`). Steps:

1. **Re-check each finding against the CURRENT code — judge the DEFECT, not the line number.**
   Work **file-by-file**: read each cited file once and check all of its findings against that
   single read (don't re-open per finding). `file:line` is only a starting hint — **search the
   file for the evidence/pattern** (code moves within a file constantly, and the file may have
   been renamed or deleted). Decide whether the *described problem* still exists, using the
   finding's `fix` as the template for what "fixed" would look like. Classify:
   - **ACTIONABLE** — the defect is still present. Record where you *actually* found it, not the
     stale cited line.
   - **ALREADY-FIXED** — the defect is gone / the `fix` (or an equivalent) is already in place,
     including the file being deleted. Skip. *Distinguishing "fixed" from merely "evidence
     changed" is what makes the command idempotent — a re-run after a partial apply marks the
     applied steps ALREADY-FIXED (clean skip), not STALE (noise).*
   - **STALE** — the area changed enough that you can't confidently tell whether the defect
     remains (e.g. it was refactored). **Never auto-apply** — route to the re-check appendix for
     a human (or a fresh `/investigate`).
   - **REJECTED** — verdict was not-real (shouldn't appear; defensive). Skip.
   The defect-presence verdict is also the **tiebreaker** when two reports disagree about a site.
2. **Dedup across reports** by normalized `file` + `category` + the *defect* (same problem at
   the same place), **tolerant of line drift** — reports written at different times cite
   different line numbers for one issue, so don't split them on line alone. Merge duplicates
   into one step but keep **all** provenance (`auth#F3` + `config#F7`).
3. **Order safely + assign STABLE ids.** Honor the reports' overlap flags: findings touching the
   same file region become one ordered block, not parallel edits. Group steps by file. Give each
   step a plan id `S1, S2…` in a **deterministic order** — sort by file, then by the defect's
   provenance key — so the *same* defect always gets the *same* `S#` across regenerations
   (per-report `F#` ids collide once unified; `S#` must be stable, because after a partial apply +
   regen `--only S3` and any note you made against an id must still point at the same step).
4. **Write `FINDINGS-PLAN.md`** at the repo root (format below) and print its absolute path.
   Always regenerate it fresh from current reports + current code — do not merge a previous plan.
   If nothing is actionable (no findings, or all already-fixed/stale), still write the plan with
   an empty Apply order and say plainly "nothing to apply" — don't invent steps.

## `FINDINGS-PLAN.md` format

```markdown
# Findings Apply Plan

**Sources:** <N> report(s) — <slug1>, <slug2>, …  ·  **Net actionable:** <K> step(s)
**Coverage:** COMPLETE — every source report was COMPLETE
              ‖ PARTIAL — <slug2> hit its round ceiling (3 areas unexamined); this plan is
              NOT exhaustive of the codebase, only of what the reports found.

> Unified from all INVESTIGATION-*.md. Source reports are immutable; this plan is regenerable.
> Apply with `/apply-findings --apply` (or `--apply -i` to gate each step).

## Apply order

### <file/path.go>
- [ ] **S1** — <title>  ·  **high**  ·  from auth#F3 (+ config#F7 dup)
  - **Edit:** <smallest concrete change that resolves it>
  - **Why:** <verifier's `why`>
  - **Verify:** <specific check — a test name, a manual repro, or "covered by `make verify`">
  - **Risk / deps:** <overlap notes; must land before/after S2; behavior caveats>
- [ ] **S2** — …

### <other/file.ts>
- [ ] **S3** — …

## Stale / unverified — needs re-check (NOT auto-applied)
- **config#F5** <title> — the area was refactored; can't confirm the defect still holds.
  Re-investigate before applying.
- **auth#F8** <title> — couldn't re-verify (`--deep` agent failed past retries); NOT dropped —
  re-run `--deep` or check by hand.

## Skipped
- **auth#F2** already fixed — <what current code shows>
- **auth#F9** rejected verdict — excluded

## Coverage detail
- auth (COMPLETE) · config (PARTIAL — round ceiling, areas left: "rate limiter", "session GC")
- This plan covers only what those reports surfaced. Partial sources ⇒ gaps remain; consider
  re-running `/investigate` on the unexamined areas.
```

Severity-sort within each file by line; keep overlapping steps adjacent and in safe order.

## Apply (`--apply`)

Generate the plan (as above) first, then execute it in the **main loop**:

0. **Pre-flight: the working tree should be clean.** Check `git status --porcelain`. If there
   are unrelated uncommitted changes, the apply diff tangles with them and a verify-failure
   rollback gets messy — warn and ask before proceeding (or let the user stash). A clean start
   makes the whole apply one isolated, `git restore`-able diff.
1. Walk **unchecked** steps in plan order. For each: **re-read the current code** at the site
   and **anchor the edit by content** — find the exact snippet, never trust a line number that
   earlier same-file edits may have shifted — then make the **smallest** edit that resolves the
   finding, matching surrounding style. When several steps touch one file, apply them
   **bottom-up** (highest line first) so untouched cited locations stay valid. Tick the step
   `[x]` in `FINDINGS-PLAN.md` as you go.
2. **Never apply a STALE step** — those live in the appendix, not the apply order.
3. **Verify — scoped to what you touched, but escalate at contract boundaries.** A scoped check
   is only valid if the change can't break a consumer that scope doesn't exercise. So: edits
   confined to one subproject's *internals* → its scoped target (here `make verify-fe` /
   `make verify-be`); **but any edit that touches a shared contract → the FULL check**
   (`make verify`, which includes the `test-contract` e2e parity layer that `verify-be`/`verify-fe`
   alone skip). In SRR that boundary is the idx/data/meta wire format (`db.go`, `idx_read.go`,
   `idx.ts`), the `gen-ts`'d constants, and sanitizer parity — anywhere writer and reader must
   agree. When in doubt, run the full check. If no make target fits: `make test`, else `npm test` /
   `npm run test` (package.json), else `go test ./...` (go.mod), else `cargo test` (Cargo.toml).
   None detected → say "no verify command detected — verify manually" and stop short of claiming
   success.
   - Default `--apply`: verify once after all steps.
   - `--apply -i`: present each step, wait for approve / skip / defer, and verify after each
     applied step. Record a **skip** distinctly ("skipped by user", not a bare `[ ]`) so it isn't
     re-prompted; a **defer** stays `[ ]` (= "ask me again next run").
4. **If verify fails: STOP.** Report the failure output and the step(s) most likely responsible;
   leave the rest unchecked. Because the tree started clean, `git restore .` cleanly reverts the
   whole apply. Do not keep editing on a broken build.
5. Idempotent + resumable: a re-run regenerates the plan (applied steps now classify
   ALREADY-FIXED → Skipped) and continues with what's left. The one thing carried across a
   regeneration is **user-skip decisions** (keyed by stable `S#`) — a step you explicitly skipped
   stays skipped instead of being re-offered.

## Context (`--context`)

Read + dedup + a light staleness pass, then print a concise digest into the conversation —
grouped by file, severity-sorted, each line `id(s) · file:line · title · one-line fix` — and
**stop**. Write no plan, edit nothing. The findings now inform whatever you do next by hand.

## Deep re-verify (`--deep`, optional)

Same output as plan-only, but the per-finding re-check + edit-drafting runs as a capped agent
fan-out instead of the main loop — worth it for large or `PARTIAL` reports. **Dedup the parsed
findings first** (so each unique defect is re-verified once, not once per report it appears in —
the waste bites hardest on exactly the big reports `--deep` is for), then author a small Workflow
(explicit opt-in), pass `args: { findings, parallel }` (the deduped set), and build the plan from
its results. Reuses `/investigate`'s limiter + backoff discipline (see [[workflow-sandbox-facts]]:
`args` arrives as a JSON **string**, `setTimeout` works):

> **Authoring footgun — the prompt strings are JS template literals.** When you adapt the
> judge prompt to your findings, do **NOT** put a literal backtick (`` ` ``) or a literal
> `${` inside it — both are template-literal syntax and silently terminate the string. The
> parser then trips further down and emits a **misleading** error blaming TypeScript
> (*"Unexpected token … Workflow scripts must be plain JavaScript — TypeScript syntax …
> fails to parse"*), when the real cause is an unescaped backtick or `${` in your prose
> (e.g. mentioning `` `git diff` `` or a `${VAR}`-looking snippet). Refer to commands/code
> as plain text or in single quotes, or concatenate single-quoted strings instead of one big
> template literal.

```js
export const meta = {
  name: 'apply-findings-deep',
  description: 'Re-verify investigation findings against current code, in parallel',
  phases: [{ title: 'Re-verify' }],
}
function makeLimiter(max){let a=0;const q=[];const p=()=>{if(a>=max||!q.length)return;a++;const{fn,ok,no}=q.shift();Promise.resolve().then(fn).then(ok,no).finally(()=>{a--;p()})};return (fn)=>new Promise((ok,no)=>{q.push({fn,ok,no});p()})}
const A = typeof args === 'string' ? JSON.parse(args) : (args || {})  // runtime delivers args as a JSON string
const PAR = Math.min(8, Math.max(1, A.parallel || 3))
const limit = makeLimiter(PAR)
const sleep = (ms) => typeof setTimeout === 'function' ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve()
async function run(prompt, opts, tries = 4){
  for (let i = 0; i < tries; i++){ const r = await limit(() => agent(prompt, opts)); if (r !== null) return r
    if (i < tries - 1){ const ms = 15000 * Math.pow(2, i); log(`retry ${opts.label} (+${ms/1000}s)`); await sleep(ms) } }
  log(`permanently failed: ${opts.label}`); return null }
const SCHEMA = { type:'object', required:['status','edit','verify','risk'], properties:{
  status:{enum:['actionable','stale','already-fixed']}, edit:{type:'string'}, verify:{type:'string'}, risk:{type:'string'} } }
const findings = A.findings || []  // PRE-DEDUPED unique defects: [{ id, title, file, line, category, severity, evidence, fix, why }]
const results = await parallel(findings.map((f) => () =>             // every input returns — nothing dropped
  run(`Judge this finding against the repo's CURRENT code. ${f.file}:${f.line ?? '?'} is only a hint — SEARCH the file for the described defect (code moves; the file may be renamed/deleted). Do NOT trust the quoted evidence; judge whether the *problem itself* still exists, using its 'fix' as the template for what "fixed" looks like.\n${JSON.stringify(f)}\n` +
      `status=already-fixed if the defect is gone / an equivalent fix is already in place (incl. file deleted); actionable if it's still present — then give the smallest concrete edit, where it ACTUALLY is, a specific verify, and any risk/ordering note; stale ONLY if the area changed so much you can't tell (propose NO edit).`,
      { label: `recheck:${f.id}`, phase: 'Re-verify', schema: SCHEMA })
    .then((r) => r ? { ...f, ...r } : { ...f, status: 'unverified' }))  // agent failed past retries → surface, never drop
)
return { results }  // every finding present; main loop orders by overlap and writes FINDINGS-PLAN.md
```

After it returns, fold `results` into the plan format: actionable → Apply order, already-fixed →
Skipped, stale **and** `unverified` (the agent failed past its retries — surfaced, never dropped)
→ re-check appendix. Then order with stable `S#` ids and write `FINDINGS-PLAN.md`.

## Hard rules (invariants — keep all)

- **Source reports are read-only.** Only `FINDINGS-PLAN.md` and (in `--apply`) source code are
  written.
- **Re-check against current code before trusting any finding** — judge the *defect's presence*
  by content, not the cited line — and again before every edit; reports go stale. A STALE
  finding (can't tell if it still holds) is never auto-applied; it's surfaced for a human.
- **Unify, don't fragment:** one `FINDINGS-PLAN.md` across all reports, deduped by `file` +
  `category` + the defect (tolerant of line drift), every duplicate's provenance preserved.
- **Safe order:** respect overlap flags; same-region fixes sequenced, not raced.
- **No silent degradation:** if any source report was `PARTIAL`, the plan says so loudly and is
  marked non-exhaustive; stale/skipped findings are listed, never dropped quietly.
- **Keep the build green:** `--apply` starts from a clean tree, verifies (auto-detected, scoped
  to what it touched), and stops on failure rather than piling edits onto a broken tree — so the
  whole apply stays one revertable diff.

## Relay when done

- **Plan-only / `--deep`:** report counts (actionable / stale / already-fixed / skipped), how
  many source reports and whether coverage is COMPLETE or PARTIAL, and the `FINDINGS-PLAN.md`
  path. Point to the file; don't dump it inline. Mention they can apply with
  `/apply-findings --apply`.
- **`--apply`:** report which steps were applied vs skipped/deferred, the verify result
  (pass/fail, with output on fail), and any STALE steps left for manual handling.
- **`--context`:** the digest is the output; note nothing was written or changed.
