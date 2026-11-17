# Sana Live

Sana Live is a continuous voice conversation with Sana on the **Gemini Live API**. It answers in the session language, uses the same lookups as Ask (the user's role and companies, with the user's own sign-in) and logs every turn like a typed one. No audio is stored.

Status: **M2 live on 17 Nov 2026** (server side, plus the hidden test page `/sana/live-test`). The panel Talk button and the Usage Live columns are M3.

## Model

**`gemini-3.1-flash-live-preview`** (default in `supabase/functions/sana/live.ts`; it can be overridden with the `SANA_LIVE_MODEL` secret).

Probe on 17 Nov, same 6 Malayalam turns for both models:

| | gemini-3.1-flash-live-preview | gemini-2.5-flash-native-audio |
|---|---|---|
| First audio p50 / p90 | 1,800 / 2,070 ms | 2,931 / 4,811 ms |
| Item codes right (after normalisation) | 2 of 4 | 3 of 4 |
| Input transcript pinned to `ml-IN` | accepted (Malayalam script) | rejected (error 1007) |

Browser test on AE05 in Malayalam (M1): first audio p50 1,298 ms, p90 1,567 ms.

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
- **Rate limits:** see the AI Studio rate-limit page for the project (Live models).

## Security rules (same as Ask)

- The user's JWT is used for every RPC. The API key is kept only in Edge secrets.
- Tokens are single-use, last at most 10 minutes and have the config locked.
- The tool list is fixed at minting and checked on every call against the server-side session and the role.
- Definer helpers are used only for key-only search (`_sana_item_keys`, `_sana_item_similar`, `_sana_text_keys`) and counts, never for row data.
- No audio is stored. Only transcripts are kept, like typed turns.

## Tests

- `supabase/tests/sana_live.sql`: sessions, cap, expiry, end, tool list, logging, item codes.
- `scripts/local-stack/sana-live-e2e.mjs`: local, with the Live socket mocked. Covers the role tools, the locked setup with the language pin, GRP, refusals, codes, `did_you_mean`, masking, `log_turn`, end, expiry and the cap.
- `scripts/local-stack/sana-live-run.mjs`: one real run on live with the qa users (enabled only for the run).

