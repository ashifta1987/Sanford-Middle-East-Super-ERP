# Sana performance (S4)

Timing runner: `scripts/local-stack/sana-timing.mjs`. The same 10 questions in English and Malayalam, as a sales user and a
finance user (40 requests), over the streaming path. Measured per request:

- **feedback**: first visible sign of progress (a lookup hint from the `tool` event, or the first text)
- **first text**: first non-empty `delta`
- **total**: `done`

## Step 1 · streaming text (`stream: true`, `tool` / `sources` events, sentence-level release)

Local stack, LOCAL-ONLY provider mock with a synthetic latency of 700 ms per model call and 20 ms per streamed chunk.
Mock numbers compare code paths only; they are not model latency.

| Run | feedback p50 / p90 | first text p50 / p90 | total p50 / p90 |
|---|---|---|---|
| before (16 Nov) | 1,494 / 1,515 ms | 1,494 / 1,515 ms | 1,558 / 1,581 ms |
| after Step 1 | **714 / 719 ms** | 1,471 / 1,496 ms | 1,553 / 1,579 ms |

Per user × language the picture is the same (sales/finance, en/ml within ±20 ms).

What Step 1 changes: the user sees what Sana is doing ("Looking up receivables…") as soon as the first model round asks for a
lookup, about half the wait earlier; text is released per finished sentence (or all but the last 48 characters) instead of
holding back 64 characters, so long answers type sooner. The first text still waits for the lookup round plus the answer
round; Steps 3–4 (parallel RPCs, logging after the response, round cap, fast model) attack that.

### Live (real Gemini, AE05, test users qa.sales / qa.finance)

| Run | feedback p50 / p90 | first text p50 / p90 | total p50 / p90 | errors |
|---|---|---|---|---|
| live-before (16 Nov 20:50, function as deployed before Step 1) | 5,538 / 15,421 ms | 5,538 / 15,421 ms | 6,443 / 15,452 ms | 0 / 40 |
| live-after Step 1 (16 Nov 21:23) | **2,613 / 3,891 ms** | 5,803 / 15,310 ms | 6,669 / 15,609 ms | 0 / 40 |

Step 1 live: the first sign of progress (lookup hint) comes 2.9 s earlier at p50 and 11.5 s earlier at p90; first text and total are
unchanged within noise (they still wait for the lookup round plus the answer round, every question used 1 tool round).

Per group (before): sales en 5,084 / 16,050 · sales ml 5,500 / 15,440 · finance en 5,587 / 7,574 · finance ml 5,538 / 6,707 (first
text p50 / p90). The p90 tail comes from two questions (customer balance C0001 and, for sales in Malayalam, the stock question),
which take about 15 s for every user — a long tool round, to be looked at in Steps 3–4. Raw rows: `~/erp-work/s4/live-before.json`.

## Step 2 · read aloud sentence by sentence

Browser: `src/features/sana/sentences.ts` splits the streamed text (first sentence alone, then pieces of at least 120 characters;
`.` `!` `?` `؟` `।` `۔` + space, or a new line, so 12,500.00 never splits), `speechQueue.ts` sends each piece to `sana-voice` as
soon as it is finished (requests in parallel) and plays the PCM back to back with the Web Audio API (each buffer starts at the
previous end time). New message, Stop, New chat or closing the panel stops and clears the queue. Phones with a system voice for
the answer language use it for answers under 200 characters; "Always use Sana's voice" in the panel forces Gemini. The engine
that spoke is on the bubble (`data-voice-engine`); Gemini calls are counted in `erp.sana_voice_use` (a cache hit shows the model
as `…:cache`). Device-voice use is not stored yet — that needs the Step 5 beacon (an SQL change, to be agreed).

`sana-voice`: `format: 'pcm16'` returns the raw 16-bit PCM (rate in `X-Sana-Rate`), WAV stays the default; it saves only the
44-byte header but lets the browser build the audio buffer directly instead of `decodeAudioData`. In-memory TTS cache per function
instance (model, voice, language, filtered text; 200 entries / 16 MB, least recently used out). Every call still counts toward
the daily voice limit.

Local stack, SYNTHETIC: model 700 ms per call, 20 ms per chunk; TTS mock 900 ms + 6 ms per character. Voice questions (`via: voice`).

| Run | first text p50 / p90 | total p50 / p90 | first audio p50 / p90 | TTS per piece p50 / p90 |
|---|---|---|---|---|
| before (whole reply to TTS after `done`, no cache) | 1,470 / 1,497 ms | 1,542 / 1,579 ms | 3,021 / 3,131 ms | 1,479 / 1,545 ms |
| after Step 2 (sentences while streaming, cache) | 1,469 / 1,493 ms | 1,551 / 1,575 ms | **1,562 / 3,080 ms** | 12 / 1,521 ms |

Read with care: the mock's voice answers are almost all one sentence (1.13 pieces per answer), so splitting saves little here;
most of the p50 gain is the cache (27 of 45 pieces were repeats: refusals and identical answers). With no cache hit the first audio
is the same as before (3,045 ms, n = 16). The real gain from splitting depends on Gemini's answer length and TTS speed and will
come from the live run (`sana-timing.mjs --remote --voice --voice-mode whole|sentence`).

### Live voice (real Gemini TTS, AE05)

| Run | first text p50 / p90 | total p50 / p90 | first audio p50 / p90 | TTS per piece p50 / p90 |
|---|---|---|---|---|
| live-voice-before (16 Nov 21:07, whole reply after `done`, WAV) | 6,571 / 15,219 ms | 6,746 / 15,256 ms | **15,653 / 23,151 ms** | 6,408 / 10,599 ms |
| live-voice-after Step 2 (16 Nov 21:29, sentences while streaming, pcm16, cache) | 6,066 / 17,968 ms | 6,881 / 18,221 ms | **12,266 / 22,888 ms** | 4,392 / 6,414 ms |

Same groups before → after (first audio p50): sales en 15,029 → 10,979 ms · sales ml 14,101 → 12,414 ms · finance en 15,528 → 9,890 ms.
2.08 TTS pieces per answer; 4 cache hits.

> [!WARNING]
> 15 of 40 after-run questions failed with `tts 502` from 16:05 UTC on, after about 100 successful Gemini TTS calls today
> (erp.audit_log `sana.voice*`: all ok before, all failed after). That pattern looks like a daily request cap on the Gemini TTS
> model for this key. Sentence-by-sentence voice makes about 2 TTS calls per answer instead of 1, so it reaches such a cap sooner.
> Check the key's TTS quota in Google AI Studio before relying on provider voice for many users.

Gemini TTS is the long pole: 6.4 s (p50) to 10.6 s (p90) for one whole reply, in both languages (Malayalam 5.6–7.6 s p50). TTS
time grows with text length, so the first piece (one sentence) should come back well before the whole reply would.


### Voice policy (16 Nov 2026, deployed)

Gemini 3.8 Flash TTS is limited to 10 requests per minute and 100 per day on the key. The rules are now:

- The device voice is the default wherever `speechSynthesis` has a voice for the answer language.
- Gemini speaks only when "Always use Sana's voice" is ticked.
- A failed Gemini piece is retried once, then the device voice reads it, silently.
- Each user gets at most 10 Gemini TTS calls a day (`TTS_DAILY_CAP` in sana-voice). This is counted from `sana_usage.voice_calls`,
  which also counts provider speech-to-text; it moves to `erp.sana_settings` later.
- Answers are read sentence by sentence with both engines.

## Steps 3–4 · parallel lookups, logging after the reply, 3 rounds, fast model (commit 99d2159, NOT deployed)

- `sana_whoami`, `sana_status`, the history and the fast-model check run in parallel.
- When streaming, `done` is sent first; `sana_log` then runs while the stream is still open and a `logged` event carries the ids.
  The JSON path still logs before it replies.
- Ask uses at most `SANA_MAX_ROUNDS` (default 3) lookup rounds; the last round has no tools, so the model answers with what it has.
- Tool descriptions are shortened to their first sentence. The security rules are unchanged.
- `SANA_MODEL_FAST` (default `gemini-3.8-flash-lite`) is used for Ask. It is checked once per cold start with a tiny request and
  falls back to `SANA_MODEL` on 400/403/404. `meta` reports `model` and `model_main`.

Local (mock, 700 ms per model call): first text p50 / p90 1,467 / 1,491 ms, total 1,549 / 1,568 ms. This is unchanged, as
expected: the mock's fixed per-call latency hides the RPC savings, and the mock has no faster model. Live baseline (Step 1): first
text 5,803 / 15,310 ms. The live after-run follows the deploy.

### Steps 3–4 live (deployed 16 Nov 22:07; 40 questions)

| Run | feedback p50 / p90 | first text p50 / p90 | total p50 / p90 | errors |
|---|---|---|---|---|
| Step 1 baseline | 2,613 / 3,891 ms | 5,803 / 15,310 ms | 6,669 / 15,609 ms | 0 |
| after Steps 3–4 | 2,729 / 3,725 ms | 5,870 / 16,602 ms | 6,837 / 16,602 ms | 1 (stream ended without done) |

The first text did not come down. Per question (median): feedback = profile checks + first model round; tool→text = lookup + second
model round; text→done = rest of the stream.

| q | question | before: feedback / tool→text / text→done | after |
|---|---|---|---|
| 1 | open sales orders | 3,585 / 2,306 / 58 | 3,624 / 2,212 / 12 |
| 2 | net sales this month | 3,315 / 2,767 / 253 | 3,805 / 2,968 / 511 |
| 3 | overdue invoices | 3,524 / 3,725 / 1,993 | 2,155 / 4,392 / 1,884 |
| 4 | stock of SMP-1010 | 3,285 / **14,585** / 170 | 3,418 / **14,914** / 46 |
| 5 | customers who owe most | 2,194 / 3,780 / 1,404 | 2,371 / 4,062 / 1,282 |
| 6 | balance of C0001 | 2,606 / **12,783** / 58 | 3,175 / **13,427** / 17 |
| 7 | owed to suppliers | 2,547 / 2,557 / 579 | 3,041 / 2,898 / 365 |
| 8 | open purchase orders | 2,768 / 1,862 / 1,309 | 3,072 / 2,291 / 1,288 |
| 9 | top items this month | 2,984 / 3,000 / 1,312 | 2,865 / 2,680 / 1,196 |
| 10 | receivables ageing | 2,329 / 3,181 / 1,348 | 2,517 / 3,269 / 1,182 |

What dominates:

1. **The fast model was not used.** All 40 answers were stored with `gemini-3.8-flash`, so the check for `gemini-3.8-flash-lite`
   fell back. Either the key does not have that model or the check failed; the name for this key is needed (`SANA_MODEL_FAST`).
2. **Two lookups hit the 8 s statement limit.** Measured as qa.sales / qa.finance on live (read-only):
   - `sana_find('SMP-1010')` and `sana_find('C0001')` are cancelled after 8,1 s: ILIKE over 651k documents with a per-row
     can_see / sana_doc_allowed. This is the 13–15 s on q4 and q6.
   - `sana_stock('SMP-1010')` takes 2,133 ms (name ILIKE '%…%' over items). `sana_receivables` takes 819–881 ms;
     `sana_partner('C0001')` takes 363 ms.
   - `sana_whoami` and `sana_status` take about 50–60 ms each, so making them parallel saves only about 50 ms.
3. **The model rounds are the rest.** The first round (deciding on a lookup) takes about 2–3 s and the second (the answer) about
   2–3 s. That gives roughly 5–6 s even when the lookup is fast.

### After 50_sana_search.sql + 3 s lookup guard + EarlyDrop fix (16 Nov 22:41; 40 questions)

| Run | feedback p50 / p90 | first text p50 / p90 | total p50 / p90 | errors |
|---|---|---|---|---|
| Step 1 baseline | 2,613 / 3,891 ms | 5,803 / 15,310 ms | 6,669 / 15,609 ms | 0 |
| after Steps 3–4 | 2,729 / 3,725 ms | 5,870 / 16,602 ms | 6,837 / 16,602 ms | 1 |
| after 50 + guard | 2,500 / 3,706 ms | **5,751 / 7,830 ms** | **6,458 / 8,310 ms** | 0 |

On live (qa.sales), `sana_find` now takes about 0.3 s (it was cancelled at 8 s) and `sana_stock` about 0.05 s (it was 2.1 s). The p90
tail is gone. The p50 is still two flash model rounds.

"Stream ended without done" (q10, sales/en, one in 40): the function logs show the runtime dropping a worker ("EarlyDrop") while
requests were in flight. The streaming work now runs under `EdgeRuntime.waitUntil`, so the worker stays alive until the stream is
closed; 0 errors in this run.

Fast model, from the models list of the live key (`GET /v1beta/models`, names containing "flash"):

- There is no `gemini-3.8-flash-lite`. The check got 404 "not found for API version v1beta, or is not supported for
  generateContent".
- Text models available: gemini-3.8-flash, gemini-3.7-flash, gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite,
  gemini-3.1-flash-lite, gemini-flash-lite-latest, gemini-flash-latest, gemini-3-flash-preview, gemini-2.5-flash,
  gemini-2.5-flash-lite.

Probe: one tool, "How many open sales orders…", 3 calls each.

| Model | median | tool called |
|---|---|---|
| gemini-3.8-flash | 2,821 ms | 1 / 3 |
| gemini-3.7-flash | 3,313 ms | 2 / 3 |
| gemini-3.5-flash-lite | 1,199 ms | 3 / 3 |
| gemini-3.1-flash-lite | 801 ms | 3 / 3 |
| gemini-flash-lite-latest | 1,103 ms | 3 / 3 |

## Final · all steps side by side (live, AE05, 40 questions, qa.sales + qa.finance, en + ml)

| Run | feedback p50 / p90 | first text p50 / p90 | total p50 / p90 | errors |
|---|---|---|---|---|
| Before S4 | 5,538 / 15,421 ms | 5,538 / 15,421 ms | 6,443 / 15,452 ms | 0 |
| Step 1 · streaming, lookup hint | 2,613 / 3,891 ms | 5,803 / 15,310 ms | 6,669 / 15,609 ms | 0 |
| Steps 3–4 · parallel, log after reply, 3 rounds | 2,729 / 3,725 ms | 5,870 / 16,602 ms | 6,837 / 16,602 ms | 1 |
| + 50 search, 3 s lookup limit, waitUntil | 2,500 / 3,706 ms | 5,751 / 7,830 ms | 6,458 / 8,310 ms | 0 |
| **Final: gemini-3.5-flash-lite for Ask, rule 1a, Step 5 live** | **916 / 1,134 ms** | **2,299 / 3,050 ms** | **2,406 / 3,394 ms** | 0 |
| same build with gemini-3.8-flash (comparison only) | 2,280 / 3,426 ms | 5,129 / 7,273 ms | 6,365 / 8,297 ms | 0 |

Against the S4 targets:

- **p90 total under 6 s: met** (3.4 s).
- **p90 first token under 1.5 s: not met.** First text p90 is 3.1 s, because two model rounds (lookup, then answer) remain;
  the lookup hint arrives at 1.1 s p90.
- **p90 first audio under 2.5 s:** the device voice is now the default, so the first sound follows the first sentence by tens of
  milliseconds. Real per-user numbers now come from the Step 5 beacon (Usage › Speed).

Other numbers:

- `now` (agent, purchase bill): 2,350 / 2,497 ms.
- Voice before / after Step 2 (Gemini TTS): 15,653 / 23,151 → 12,266 / 22,888 ms.

### Quality gate (scripts/local-stack/sana-live-eval.mjs; truth = the same RPCs with the same user's token)

| Model | tool when an answer was expected | figure right | refusal right |
|---|---|---|---|
| gemini-3.5-flash-lite | 34 / 34 | 40 / 40 after review (raw 37) | 40 / 40 |
| gemini-3.8-flash | 34 / 34 | 39 / 40 after review (raw 37) | 39 / 40 |

Review of the raw misses, with the grader rules fixed in the script:

- "No stock records were found for SMP-1010" was counted as a figure (1010 comes from the question).
- The Malayalam "ഒന്നും … ഇല്ല" (none) was not recognised.
- Refusals were counted as "no tool", but a refusal needs no lookup.

The one real difference is finance / ml / q6 (balance of C0001). gemini-3.8-flash refused it; the right answer is "not found",
and the lite model gave that. The lite model is not worse on any question.

## S5 · Sana Live and the finance lookup (17 Nov 2026, live, AE05, qa.sales + qa.finance)

### Sana Live: first audio on the same 10 turns (end of speech, or text sent, → Sana's first audio)

| Run | What changed | Tool turns p50 / p90 | Notes |
|---|---|---|---|
| 1 (M2) | — | 1.9 / 2.7 s | rupees for AED, "not found" for role-hidden items, one bare-code answer |
| 2 | 53: currency, denied parts, quantity rule, warm-up ping | 2.2 / 2.7 s | Malayalam stock total wrong (88 vs 122) |
| 3 | stock totals in Live results, script flag | 2.1 / 3.0 s | finance summary over 3 s (cut off) |
| 4 | 55: finance summary 30 s+ → 0.6 s | 2.0 / 2.8 s | every figure right; one turn without output transcript (flagged) |

Where the time goes, per tool turn (run 4):

| Step | Spoken | Typed |
|---|---|---|
| End of speech → the model asks for a lookup | 1.15–1.25 s | 0.5–0.6 s |
| Lookup round trip | stock 0.2–0.36 s · search 0.8–0.9 s · payables 0.7 s · receivables 1.3–1.5 s | same |
| Lookup result → first audio | 0.65–1.0 s | same |

**Non-tool turns:** about 1.3 s, matching the M1 browser test (p50 1.3 s, p90 1.6 s). The 2 s p90 target holds without a lookup and for fast lookups (stock). The heavier finance lookups (receivables 1.3–1.5 s) still put tool turns at about 2.8 s (p90). The first useful figure arrives under 4 s on every turn.

### Finance summary lookup (55: partial index on non-SAP journal entries, Southfield lines summed set-based)

| | Before 55 | After 55 |
|---|---|---|
| `erp.sana_finance_summary('AE05')` as qa.finance (database) | > 30 s (cancelled at 30 s) | 0.63–0.66 s |
| Through `sana-live-tool` (Live) | > 3 s → "no match" | 1.12–1.16 s |
| Ask, 6 finance questions (first text p50 / p90) | 5.1 / 6.7 s; 4 of the 5 summary questions answered "not found / timed out" | 3.1 / 4.4 s; all answered with the right figures (assets 17,076,843.38 AED, 3,105 journals in 30 days) |

Other Live lookup round trips after 55: payables 0.7–0.9 s, receivables 1.2–1.4 s, banking 0.2–0.7 s.
