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

Live (real Gemini) numbers: to be added from `--remote` runs before and after the deploy.
