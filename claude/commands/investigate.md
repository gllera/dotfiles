---
description: Bounded, verified multi-agent investigation toward a goal; saves a findings report for later application
argument-hint: [--rounds N] [--parallel N] <what to investigate>
---

Run a **dynamic, bounded, adversarially-verified multi-agent investigation** toward:

> $ARGUMENTS

This is explicit opt-in to the **Workflow** tool. First parse the optional knobs out of the
argument string (see **Arguments**), then author a dynamic Workflow inline and run it. Pass
`args: { goal, rounds, parallel }` — note the runtime delivers `args` to the script as a JSON
**string** (verified by probe), so the skeleton's `JSON.parse` guard is **required**, not
optional. The skeleton below is the reference implementation; adapt prompts/schemas to the
goal but keep every invariant.

## Arguments

- `--rounds N` / `-r N` — max **waves** (exploration depth): wave 1 is the scouted scope, each
  completeness-critic refill appends another wave. Default **3**, clamp to **1–10**.
- `--parallel N` / `-p N` (alias `--agents` / `-a`) — max agents in flight at once, which is
  also the size of the continuous area pool. Default **3**, clamp to **1–8**.
- Everything left after stripping those flags is the **goal** text.

Examples: `/investigate -r 5 -p 4 simplify the config layer` · `/investigate the auth flow`
(defaults to 3 / 3).

## How it runs

1. **Scout** (once, cheap model) — map the concrete scope: which files/areas to examine and
   which distinct angles to split reviewers across. Targeted finders read far less than
   blind ones, so this both sharpens coverage and cuts tokens.
2. **Continuous area pool (no round barrier)** — a single dispatcher keeps up to `parallel`
   area-pipelines open at once and opens the next area the *instant* any one finishes its
   find→verify chain, so a freed slot never idles waiting for a whole batch to drain (each
   finder is told what's already confirmed, so it breaks new ground instead of re-surfacing
   dupes). Within an area, findings stream straight into verification (no find-all-then-verify
   barrier). A **dedup-gate** drops any finding whose key was already seen *before* a verifier
   is spent on it. Survivors get **lens-diverse adversarial verification**: a 3-lens quorum
   (reachability / reproduce / fix-safety) for `high`, a single skeptic otherwise — each opens
   the cited code itself rather than trusting the finding's evidence, and defaults to not-real
   when uncertain.
3. **Completeness critic** — when the area queue drains, the dispatcher runs one critic (it's
   the only thing pulling at that moment, so no refill race) that names areas/angles which went
   unexamined; non-empty gaps are appended as the next **wave**, empty gaps mean genuine
   convergence. Any areas left unexamined if the agent cap cuts the run short are logged, not
   dropped.
4. **Stop** at convergence OR after `rounds` waves — whichever first.
5. **Return data** — the workflow returns the structured confirmed findings + run summary.
6. **Main loop writes the report** — after the workflow returns, *you* (not an agent) write
   `INVESTIGATION-<slug>.md` from the returned data. Atomic, resumable, no half-written file.

## Hard constraints (invariants — keep all)

- **≤`parallel` agents in flight, always** (default 3), across every stage (scout, finders,
  verifiers, critic). Enforced by a global semaphore every agent call passes through — not
  the runtime's default cap, and not just per-stage.
- **Auto-retry with incremental backoff.** A `null` return = terminal failure after the
  runtime's own retries (usually rate-limiting under fan-out). Retry up to 3 more times with
  an **incremental sleep** (15s → 30s → 60s). `setTimeout` is confirmed present in the sandbox
  (probe-verified), so the backoff genuinely sleeps; the `typeof setTimeout` guard stays as
  cheap insurance (falls back to immediate retry if that ever changes). `log()` each backoff
  and anything permanently dropped.
- **Schema-validated output.** Every finding/verdict/critic result comes back through an
  `agent()` `schema` so it's a validated object (the tool retries on mismatch) — never
  free-text you parse.
- **Strong dedup key** = normalized `file:line:category`, NOT the raw title. Dedup against
  everything *seen* (including rejected) so a rejected finding can't reappear and stall the
  loop. Claim keys synchronously in the dedup-gate so within-round dupes don't double-verify.
- **Model/effort tiering.** Scout + mechanical steps → cheap model, low effort. Finders →
  session model. Verify + critic → high effort (judgment earns its cost there).
- **Runaway guards.** `.filter(Boolean)` every `parallel()`/retry result before use; the
  wave ceiling (`rounds`) plus a self-imposed total-agent cap (`log()`s and stops spawning if
  a weak key spirals) bound the worst case; any areas left unexamined if that cap cuts the run
  short are `log()`'d, never silently dropped.
- **Report only — no code edits** during the run. Fixes are applied later, separately.

## Reference workflow skeleton

> **Authoring footgun — the prompt strings are JS template literals.** When you adapt the
> scout/finder/verify/critic prompts to your goal, do **NOT** put a literal backtick
> (`` ` ``) or a literal `${` inside them — both are template-literal syntax and will
> silently terminate the string mid-prompt. The parser then trips further down and emits a
> **misleading** error: *"Script parse error: Unexpected token … Workflow scripts must be
> plain JavaScript — TypeScript syntax … fails to parse."* It blames TypeScript, but the real
> cause is almost always an unescaped backtick or `${` you wrote in prose (e.g. referring to
> `` `make generate-check` ``, a `` `git diff` `` command, or a `${VAR}`-looking shell
> snippet). **Fixes:** refer to commands/code in prose as plain text (run make generate-check)
> or in single quotes; or build the prompt by concatenating single-quoted strings
> (`'Investigate ' + GOAL + ' focusing on ' + area`) instead of one big template literal —
> single-quoted strings treat backticks and `${` as ordinary characters. Escaping each
> backtick as `` \` `` works too but is easy to miss across edits, so prefer concatenation
> when a prompt must mention shell/code tokens.

```js
export const meta = {
  name: 'investigate',
  description: 'Bounded, verified multi-agent investigation toward a goal',
  phases: [{ title: 'Scout' }, { title: 'Wave 1' }, { title: 'Wave 2' }, { title: 'Wave 3' }],
} // waves beyond those listed just get their own progress group — fine

// Global hard cap: PAR agents in flight, across every stage.
function makeLimiter(max) {
  let active = 0; const q = []
  const pump = () => {
    if (active >= max || !q.length) return
    active++; const { fn, ok, no } = q.shift()
    Promise.resolve().then(fn).then(ok, no).finally(() => { active--; pump() })
  }
  return (fn) => new Promise((ok, no) => { q.push({ fn, ok, no }); pump() })
}
const A = typeof args === 'string' ? JSON.parse(args) : (args || {}) // runtime delivers args as a JSON string — parse it
const GOAL = A.goal
const ROUNDS = Math.min(10, Math.max(1, A.rounds || 3))    // clamp in-script too: a bad/0/negative value
const PAR    = Math.min(8,  Math.max(1, A.parallel || 3))  // must not spin or deadlock makeLimiter(0)
const limit = makeLimiter(PAR)

// Guarded sleep — setTimeout confirmed present in-sandbox; guard is belt-and-suspenders.
const sleep = (ms) =>
  typeof setTimeout === 'function' ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve()

let spawned = 0, dropped = 0, capHit = false                  // run-health counters for the confidence verdict
const CAP = Math.max(120, ROUNDS * PAR * 25)                  // runaway backstop, scales with the knobs
// One agent call: hard-capped concurrency + incremental-backoff retry on null (rate limits).
async function run(prompt, opts, tries = 4) {
  if (spawned >= CAP) { capHit = true; log(`agent cap ${CAP} hit — skipping further spawns`); return null }
  spawned++
  for (let i = 0; i < tries; i++) {
    const r = await limit(() => agent(prompt, opts))
    if (r !== null) return r
    if (i < tries - 1) {
      const ms = 15000 * Math.pow(2, i) // 15s → 30s → 60s, incremental
      log(`null (try ${i + 1}/${tries}) on ${opts.label || 'agent'} — backing off ${ms / 1000}s`)
      await sleep(ms)
    }
  }
  dropped++; log(`permanently failed: ${opts.label || 'agent'}`); return null
}

// Stable dedup key — normalized file:line:category, NOT the title.
const key = (f) => `${(f.file || '').toLowerCase()}:${f.line ?? ''}:${(f.category || '').toLowerCase()}`

const AREAS    = { type: 'object', required: ['areas'], properties: { areas: { type: 'array', items: { type: 'string' } } } }
const FINDINGS = { type: 'object', required: ['findings'], properties: { findings: { type: 'array', items: {
  type: 'object', required: ['title','file','category','severity','evidence','fix'], properties: {
    title:{type:'string'}, file:{type:'string'}, line:{type:'integer'}, category:{type:'string'},
    severity:{enum:['low','med','high']}, evidence:{type:'string'}, fix:{type:'string'} } } } } }
const VERDICT  = { type: 'object', required: ['real','why'], properties: { real:{type:'boolean'}, why:{type:'string'}, line:{type:'integer'} } }
const CRITIC   = { type: 'object', required: ['gaps'], properties: { gaps: { type:'array', items:{type:'string'} } } }

// GOAL, ROUNDS, PAR were destructured from args at the top
if (!GOAL || !GOAL.trim()) { log('empty goal — nothing to investigate'); return { goal: GOAL || '', rounds: 0, stopped: 'empty goal', candidates: 0, confirmed: [], spawned: 0 } }

// 1 ─ scout the work-list (cheap model)
phase('Scout')
const scout = await run(
  `Map the concrete scope for this investigation: ${GOAL}. Using your tools (ls/grep/read), list ONLY files/areas that actually exist in the repo (verify each path — no guesses), plus the distinct angles reviewers should split across. Be concrete.`,
  { label: 'scout', phase: 'Scout', schema: AREAS, model: 'haiku', effort: 'low' })
let scope = (scout && scout.areas && scout.areas.length) ? scout.areas : ['(whole target)']

// 2 ─ continuous worker pool: keep up to PAR area-pipelines in flight AT ALL TIMES (no round
//      barrier). The dispatcher opens the next area the *instant* ANY area finishes its
//      find→verify chain, so a freed slot never idles waiting for a whole batch to drain.
//      Each area internally pipelines find → dedup-gate → lens-diverse verify. When the queue
//      drains, ONE completeness critic (run from the single dispatcher, so no refill race)
//      appends fresh gaps as the next "wave".
const seen = new Set(), confirmed = []
const waveStats = new Map()                                       // openWave -> { areas, candidates, kept }
let scopeIdx = 0, wave = 1, dry = false

// Pull the next area; refill the scope via the critic when it drains. Returns an area string,
// or null when work is exhausted (converged / wave ceiling / agent cap).
async function takeArea() {
  while (scopeIdx >= scope.length) {                              // current wave fully examined
    if (dry || capHit || wave >= ROUNDS) return null             // 4 ─ stop: converged / cap / wave ceiling
    const critic = await run(                                     // 3 ─ completeness critic refills the scope
      `Investigation goal: ${GOAL}\nConfirmed so far: ${confirmed.map((c) => c.title).join('; ') || 'none'}\nAll currently-known areas are examined. What area/angle/modality was NOT examined and could still hold findings? Return gaps (empty array if genuinely none).`,
      { label: `critic:w${wave}`, phase: `Wave ${wave}`, schema: CRITIC, effort: 'high' })
    if (!critic || !critic.gaps.length) { dry = true; return null } // empty gaps ⇒ converged
    scope = scope.concat(critic.gaps); wave++                     // append the gaps as the next wave
  }
  if (capHit) return null
  return scope[scopeIdx++]
}

// Examine one area end-to-end: find → dedup-gate → lens-diverse verify. Returns kept + candidate count.
async function processArea(area, idx, tag) {
  const known = confirmed.map((c) => c.title)                     // anti-repetition: snapshot at launch (grows over the run)
  const found = await run(
    `Investigate toward: ${GOAL}\nFocus area/angle: ${area}\n` +
      (known.length ? `Already found — do NOT repeat; surface only NEW issues:\n- ${known.join('\n- ')}\n` : '') +
      `Return concrete, individually-actionable findings with file+line, a VERBATIM evidence snippet, and a suggested fix. Only real issues.`,
    { label: `find:${idx}`, phase: tag, schema: FINDINGS })
  if (!found) return { kept: [], candidates: 0 }
  const fresh = found.findings.filter((x) => {                    // dedup-gate (atomic — no await before seen.add)
    const k = key(x); if (seen.has(k)) return false; seen.add(k); return true })
  const verified = await parallel(fresh.map((x) => () => {        // verify streams as findings arrive
    // lens-diverse quorum for high severity; single skeptic otherwise
    const lenses = x.severity === 'high'
      ? ['reachability — is the cited code actually reached at runtime?',
         'reproduce — can you construct an input/path that actually triggers it?',
         'fix-safety — would the suggested fix break behavior or miss a case?']
      : ['is this finding real and worth acting on?']
    return parallel(lenses.map((lens, j) => () =>
      run(`REFUTE this finding through the "${lens}" lens. Open ${x.file}:${x.line ?? '?'} and judge from the ACTUAL code — do NOT trust the finding's quoted evidence. Default real=false if uncertain. Also set "line" to the ACTUAL current line where the cited code/defect lives (you have the file open), even if it differs from the cited line.\n${JSON.stringify(x)}`,
          { label: `verify:${idx}:${j}`, phase: tag, schema: VERDICT, effort: 'high' })
    )).then((votes) => {
      const v = votes.filter(Boolean)
      const real = v.length > 0 && v.filter((o) => o.real).length * 2 > lenses.length // strict majority of lenses
      const located = v.find((o) => o.real && o.line) || v.find((o) => o.line) // verifier's confirmed line beats the finder's drifted cite
      return { ...x, line: located ? located.line : x.line, verdict: { real, votes: v } }
    })
  }))
  return { kept: verified.filter(Boolean).filter((r) => r.verdict && r.verdict.real), candidates: fresh.length }
}

// Dispatcher: keep the pool full; the instant one area resolves, open the next.
const inflight = new Set()
let nextIdx = 0
async function openArea() {                                       // returns true if an area was opened
  const area = await takeArea()                                   // runs the critic inline on drain — single dispatcher, so no race
  if (area == null) return false
  const idx = nextIdx++, openWave = wave, tag = `Wave ${openWave}`
  const st = waveStats.get(openWave) || { areas: 0, candidates: 0, kept: 0 }
  st.areas++; waveStats.set(openWave, st)
  const p = processArea(area, idx, tag).then(({ kept, candidates }) => {
    confirmed.push(...kept); st.candidates += candidates; st.kept += kept.length
    log(`${tag}: area examined, ${kept.length} kept, ${confirmed.length} confirmed total`)
    inflight.delete(p)
  })
  inflight.add(p)
  return true
}
while (inflight.size < PAR && await openArea()) { }               // prime the pool to PAR open areas
while (inflight.size > 0) {                                       // keep it full: refill the instant one finishes
  await Promise.race(inflight)
  while (inflight.size < PAR && await openArea()) { }
}
if (scopeIdx < scope.length)                                      // no silent caps: only the agent cap can cut us off mid-scope
  log(`agent cap stopped the run — ${scope.length - scopeIdx} area(s) left unexamined: ${scope.slice(scopeIdx).join(', ')}`)

// 5 ─ assign stable ids (sorted by file, then line) and return; the MAIN LOOP writes the report
const trace = [...waveStats.entries()].sort((a, b) => a[0] - b[0]).map(([w, s]) => ({ wave: w, ...s }))
const ordered = confirmed.slice()
  .sort((a, b) => (a.file || '').localeCompare(b.file || '') || (a.line ?? 0) - (b.line ?? 0))
  .map((c, i) => ({ id: `F${i + 1}`, ...c }))
const unexamined = Math.max(0, scope.length - scopeIdx)
const complete = dry && dropped === 0 && !capHit && unexamined === 0 // clean convergence vs degraded stop
return { goal: GOAL, rounds: wave, stopped: dry ? 'converged' : (capHit ? 'agent cap' : 'wave ceiling'),
         complete, dropped, capHit, unexaminedAreas: unexamined,
         candidates: seen.size, confirmed: ordered, trace, spawned }
```

## Report

After the workflow returns, write `INVESTIGATION-<slug>.md` in the current repo root (slug
from the goal). **Open with a status banner**: `COMPLETE` only when `complete === true`,
otherwise `PARTIAL` with the reasons drawn straight from the return — hit the wave ceiling
(`stopped`), `dropped > 0` agents lost to rate-limiting, `capHit`, or `unexaminedAreas > 0`.
A throttled run must NOT read as a clean bill of health. Then **group findings by file,
ordered by line**, and head each with its stable `id` (e.g. `F3`) so the later apply step can
reference it unambiguously. Per finding: id, title, `file:line`, severity, category,
evidence, the verifier verdict (`why` + how many lenses/votes agreed), and the suggested fix.
**Flag overlaps** — when two findings touch the same file region, note it so fixes get applied
in a safe order. End with a summary: the per-wave `trace` (areas / candidates / kept),
candidates seen, confirmed vs rejected, where it stopped and why, agents spawned/dropped.

**Then append a machine-readable contract block** (the last thing in the file) for the companion
`/apply-findings` reader: a fenced ` ```json ` block holding the workflow's return verbatim —
`{ goal, complete, stopped, dropped, capHit, unexaminedAreas, trace, confirmed: [...] }`, each
confirmed finding carrying `id, title, file, line` (the **verifier-confirmed** current line, not
the finder's possibly-drifted cite), `category, severity, evidence, fix` and its `verdict.why`. The human markdown above is for people; this block is the parsed contract, so
`/apply-findings` never has to scrape prose. Keep the two in sync (same findings, same ids).

Print the report's absolute path. Do not apply any fix.

## Relay when done

Briefly report: what was investigated, **whether the run was COMPLETE or PARTIAL** (and why,
if partial — dropped agents / wave ceiling / unexamined areas), waves run, count of verified
findings, and the report path. Don't dump the full report inline — point to the file.

## If it fails mid-run

If the run is killed (e.g. sustained rate-limiting), **resume — don't restart**: relaunch
`Workflow({ scriptPath, resumeFromRunId })`. Cached agents return instantly; only the failed
tail re-runs. Restarting from scratch just re-hits the limit and wastes tokens.
