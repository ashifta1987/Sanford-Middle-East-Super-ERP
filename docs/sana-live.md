# Sana Live

Sana Live is a continuous voice conversation with Sana on the **Gemini Live API**. It answers in the session language, uses the same lookups as Ask (the user's role and companies, with the user's own sign-in) and logs every turn like a typed one. No audio is stored.

Status: **S5 complete, 17 Nov 2026.** Everything is live: M2 (52), the fixes from the first real run (53), the panel's Talk button with Usage › Speed Live columns (M3, 54) and the faster finance summary lookup (55). Final timing tables are in `docs/sana-performance.md` (S5 section).

**Warm-up ping:** the `sana-live-warm` pg_cron job stays on for as long as Live is in use. Turn it off only if Live is retired: `SELECT cron.unschedule('sana-live-warm');` (and log that in `erp.audit_log`).

## Model

**`gemini-3.1-flash-live-preview`** (default in `supabase/functions/sana/live.ts`; it can be overridden with the `SANA_LIVE_MODEL` secret).

Probe on 17 Nov, same 6 Malayalam turns for both models:

| | gemini-3.1-flash-live-preview | gemini-2.5-flash-native-audio |
|---|---|---|
| First audio p50 / p90 | 1,800 / 2,070 ms | 2,931 / 4,811 ms |
| Item codes right (after normalisation) | 2 of 4 | 3 of 4 |
| Input transcript pinned to `ml-IN` | accepted (Malayalam script) | rejected (error 1007) |

Browser test on AE05 in Malayalam (M1): first audio p50 1,298 ms, p90 1,567 ms.

**Voice verdict (Ashif, own Malayalam test on `/sana/live-test`, 17 Nov 2026):** it responded well, the Malayalam was good, no issues.

## How a session works

1. **Token.** The browser calls `sana-live-token` with `{company, language}`. That function:
   - runs the same checks as Ask: profile, company access ("All companies" means the home company), Sana and voice switched on, and the daily question limit;
   - starts a server-side session with `erp.sana_live_start`. This is refused once the daily Live-minutes cap is reached;
   - mints a **single-use ephemeral token**. It lasts 10 minutes at most and never longer than the minutes the user has left. The whole setup is **locked** in the token (no field mask): model, system prompt, the role's tools (the same list as Ask), audio out, and both speech and input transcription **pinned to the session language** (`ml-IN`, `ar-AE`, `en-US`, …).
   - The API key never leaves the Edge Function.
2. **Socket.** The browser connects straight to Gemini (`BidiGenerateContentConstrained?access_token=…`) and sends only `{setup:{model}}`. The token's setup applies.
3. **Lookups.** Each `toolCall` goes to `sana-live-tool` `{action:'tool'}`:
   - `erp.sana_live_check` checks that the session is the caller's own, open, not expired, and that the tool is on the minted list.
   - The tool's role rule is checked again.
   - The same `erp.sana_*` RPC as Ask runs with the user's JWT, under the 3 s limit.
   - The result is masked before it goes back.
4. **Turns.** `{action:'log_turn'}` writes the turn like a typed one (`via='live'`, label `live`), plus the timing and the audio beacon. A company figure given without a lookup is labelled `live-unverified`.
5. **End.** `{action:'end'}` closes the session once. The seconds counted stop at the token expiry.

## In the panel (M3)

| | |
|---|---|
| **Talk button** | Desktop: next to the microphone. Phone: a large button at the bottom of the panel. It is shown only when the browser has AudioWorklet, WebSocket and a microphone, voice is on for the company and Sana is enabled. Otherwise the push-to-talk microphone stays, and it always stays as the fallback. |
| **States** | connecting, listening ("just talk"), looking up, Sana speaking ("talk to interrupt"), then ended. The bar replaces the text box while Live is on and has a large **End** button. |
| **Transcript** | Normal message bubbles: the user on the right (input transcription, in the session language's script), Sana on the left. Source chips come from the tool results (the same links as Ask), plus a small mark when `log_turn` flagged the turn. |
| **Interruption** | When the Live API sends `interrupted` (the user talked over Sana), playback stops at once and the bar goes back to listening. |
| **End rules** | The End button; **60 s** with nobody speaking and Sana silent; the daily minutes cap (refused at the start with the message, or the token expiring); the tab hidden for more than **30 s**; closing the panel; switching company. The server session is ended once, with the reason. |
| **History** | Live turns are logged into a normal conversation, so History shows them and a typed question afterwards continues the same conversation. |

Code: `src/features/sana/liveClient.ts` (session: token, microphone worklet, socket, tools, logging, end rules), `speechQueue.ts` `PcmStreamPlayer` (24 kHz PCM playback, stop on barge-in), `SanaPanel.tsx` (button, bar, bubbles), `SanaProvider.tsx` (`upsertMessage` / `patchMessage` / `adoptConversation`).

## Checks on a spoken answer (Live cannot re-ask)

`log_turn` labels the question row and returns flags; the panel shows the mark.

| Label | When | Mark |
|---|---|---|
| `live-unverified` | a company figure and no lookup in the turn (rule 1a, same detector as Ask) | "Unverified: this figure did not come from a lookup" |
| `live-no-quantity` | a stock lookup ran and the reply names the item code but no quantity (a choice between codes is not flagged) | "Check this: Sana named the item but no quantity" |
| `live-currency` | the reply names another currency than the company's (`erp.company.currency`), unless a lookup returned that currency | "Check this: the currency may be wrong" |
| `live-script` | letters from another script (for example a Hindi word in Malayalam), or no letter of the session language | "Check this: the answer mixed in another language" |

Ask does the same currency check but **re-asks once on gemini-3.8-flash**. That retry is counted like the other guard retries (`model_fast = '<model>:currency-retry'`).

The Live prompt also says: company amounts are in AED (UAE dirhams, ദിർഹം in Malayalam); state the stock quantity first; use `total_available` from the result and never add up warehouses (Live stock results carry the item totals and only the warehouses that hold stock); a part that is `{"denied": true}` is "not available for your role", never "not found".

## Empty vs denied in search (53)

`sana_find` returns a part the role may not see as `{"denied": true}` (for example `"items": {"denied": true}` for a finance user) instead of leaving it out. Sana then says it is not available for the role, not "not found". It is the same rule as Ask's guard, which now also counts a denied *part* as a refused lookup.

## Speed (where the time goes)

Measured on live on 17 Nov over 3 runs × 10 turns. "Speech end" is the end of the clip; for typed turns it is the moment the text was sent.

| Step | Typical | Notes |
|---|---|---|
| Speech end → model asks for a tool | 1.1 s spoken / 0.5 s typed | includes the Live API's end-of-speech detection |
| Tool round trip (browser → `sana-live-tool` → RPC → back) | stock 0.16–0.37 s; search 0.7–1.1 s; payables 0.7–0.9 s; receivables 1.2–1.5 s; finance summary 1.1 s (it was over 3 s and cut off before 55) | the RPC itself is most of it (receivables 1.25–1.5 s, payables 0.7 s, find 0.6 s, whoami 0.08 s) |
| Tool result → first audio | 0.65–0.9 s | the model |
| Token (`sana-live-token`) | warm 0.55–0.9 s; cold start +1.3 s | kept warm by the ping below; it comes before the session, so it is not part of first audio |

**Warm-up:** the pg_cron job `sana-live-warm` (53) posts `{"ping": true}` to `sana-live-token` and `sana-live-tool` every 5 minutes. The functions answer before any check (no auth, no data). Because the ping carries no JWT, both functions are deployed with `--no-verify-jwt`. Every real call is still checked: no Bearer gives 401, and each RPC runs with the caller's JWT, which PostgREST verifies (a bad token gives 401).

## Item codes

Spoken codes come back with other spaces, dashes, slashes and case ("SF5160-IC/KC", "sf 5160 ic kc" → `SF5160IC KC`):

- `sana_find` and `sana_stock` (Ask and Live) also match the code with only letters and digits, ignoring case. This uses an expression index; the key-only definer helper is `_sana_item_keys`.
- When nothing matches, `sana_stock` returns up to 3 near codes as `did_you_mean` (pg_trgm similarity ≥ 0.4). Sana asks which one was meant and never guesses.

## Limits and settings (`erp.sana_settings`, admin only, audited via `erp.sana_caps_save`)

| Setting | Default | Meaning |
|---|---|---|
| `live_minutes_daily` | 30 | Live minutes per user per day (Dubai day). At the cap the token is refused with a message in the session language. |
| `tts_daily_cap` | 10 | Sana voice answers (Gemini TTS) per user per day; read by `sana-voice` |

## Cost

Google's pricing page (confirmed 17 Nov 2026): audio in **\$3 / 1M tokens**, audio out **\$12 / 1M tokens**, at **25 tokens per second** of audio.

| | per second | per minute |
|---|---|---|
| Audio in (the microphone streams for the whole session) | 25 tokens = \$0.000075 | ≈ \$0.0045 (≈ \$0.005) |
| Audio out (only while Sana speaks) | 25 tokens = \$0.0003 | ≈ \$0.018 |

- **Worst case** (Sana speaking the whole minute): about **\$0.0225 per session minute**.
- **One user at the 30-minute cap:** at most about **\$0.68 a day**.
- **Example:** 20 users × 10 minutes a day = 200 minutes, at most about **\$4.50 a day** (about \$100 a month over 22 working days).
- **Realistic case:** Sana speaks perhaps a third of the time, which comes to about \$0.01 per minute, or \$2 a day for the same 20 users.
- **Not included:** text tokens (system prompt, tool results), which are small next to audio.

## Rate limits (AI Studio, project "southfield erp", Tier 1, read 17 Nov 2026)

| Model (AI Studio name) | Used for | RPM | TPM | RPD | Peak use, last 28 days |
|---|---|---|---|---|---|
| Gemini 3 Flash Live | Sana Live (`gemini-3.1-flash-live-preview`) | unlimited | **150K** | unlimited | 3 RPM · 1.27K TPM · 28 RPD |
| Gemini 2.5 Flash Native Audio Dialog | not used (lost the M2 probe) | unlimited | 1M | unlimited | 1 RPM · 556 TPM · 2 RPD |
| Gemini 3.8 Flash TTS | `sana-voice` read-aloud when "Always use Sana's voice" is ticked | 10 | 10K | 100 | 10 RPM · 108 RPD (at the limit) |

What 150K TPM means for Live: audio counts 25 tokens per second each way. The microphone streams the whole session (1,500 tokens a minute) and Sana's speech adds up to 1,500 a minute, plus the prompt and tool results as text. One busy session therefore uses roughly 2–4K tokens a minute, so **about 40–70 sessions at the same minute** fit under 150K TPM. That is well above 20 users. If the limit is reached, the Live API refuses new turns: the panel ends the session with the error note, and the push-to-talk microphone (Ask) still works.

The TTS row is the tight one: 10 RPM / 100 RPD, already reached once (108 / 100). That is why the device voice is the default, and why `sana-voice` falls back to it on a 429. Live does not use this quota.

## Final results (live, AE05, 10-turn run 4)

| | Result |
|---|---|
| First audio, turns without a lookup | about 1.3 s (M1 browser test: p50 1.3 s, p90 1.6 s) |
| First audio, turns with a lookup | p50 2.0 s, p90 2.8 s (the lookup time dominates: receivables 1.3–1.5 s) |
| Item codes | spoken codes found after normalisation; near misses give `did_you_mean` (Malayalam and English) |
| Currency | AED / dirhams / ദിർഹം every time |
| Role-hidden items | "not available for your role" (Malayalam and English) |
| Stock totals | 122 pieces in both languages (the item total from the result) |
| Tampered tool calls | 403 every time (a tool outside the session's list) |
| Auth with the platform JWT check off | no sign-in → 401, bad token → 401 (in `sana-live-e2e.mjs`) |
| Known gap | the model now and then sends no output transcription for a spoken answer (1 of 10 turns in run 4); the turn is flagged "check this" and its audio was played |

## Security rules (same as Ask)

- The user's JWT is used for every RPC. The API key is kept only in Edge secrets.
- Tokens are single-use, last at most 10 minutes and have the config locked.
- The tool list is fixed at minting and checked on every call against the server-side session and the role.
- The platform JWT check is off on `sana-live-token` and `sana-live-tool`, because the warm-up ping has no JWT. The handlers verify the user's JWT themselves (no Bearer → 401; PostgREST rejects a bad token → 401), and `sana-live-e2e.mjs` tests both cases.
- Definer helpers are used only for key-only search (`_sana_item_keys`, `_sana_item_similar`, `_sana_text_keys`) and counts, never for row data.
- No audio is stored. Only transcripts are kept, like typed turns.

## Tests

- `supabase/tests/sana_live.sql`: sessions, cap, expiry, end, tool list, logging, item codes.
- `scripts/local-stack/sana-live-e2e.mjs`: local, with the Live socket mocked. Covers the role tools, the locked setup with the language pin, GRP, refusals, codes, `did_you_mean`, masking, `log_turn`, end, expiry and the cap.
- `scripts/local-stack/sana-live-run.mjs`: one real run on live with the qa users (enabled only for the run). It prints the time split per turn.
- `scripts/local-stack/sana-live-panel-e2e.mjs`: local panel test with the Live socket mocked through Playwright `routeWebSocket`. Covers the Talk button (desktop and phone), the states, bubbles, source chips, the unverified mark, barge-in, the end rules (button, silence, hidden tab, cap), the fallback without AudioWorklet, and the rows in the database.

