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
| live-after Step 1 | _pending: function deploy_ | | | |

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
| live-voice-after Step 2 | _pending: deploy of sana-voice + panel_ | | | |

Gemini TTS is the long pole: 6.4 s (p50) to 10.6 s (p90) for one whole reply, in both languages (Malayalam 5.6–7.6 s p50). TTS
time grows with text length, so the first piece (one sentence) should come back well before the whole reply would.

