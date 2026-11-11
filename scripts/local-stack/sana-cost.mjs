// Sana · cost per 100 questions (S2). AN ESTIMATE, not a bill.
//   node scripts/local-stack/sana-cost.mjs <stats.json> [--md out.md]
// <stats.json> comes from `sana-eval.mjs --provider both --stats <file>`: the LOCAL-ONLY provider mock records the size of
// every request the real adapters build (system prompt, tool declarations, tool results, history) — so the prompt sizes are
// MEASURED from Sana's actual requests over the 83 evaluation questions; only the token count per character is estimated.
//
// Token estimate (documented method, provider-mock.mjs estimateTokens): ASCII text ≈ 4 characters per token, other scripts
// (Arabic, Malayalam, …) ≈ 2 characters per token. Real counts are logged once a key is set: every AI answer's audit row
// (erp.audit_log action 'sana.ask') carries detail.tokens {in, out} from the provider's own usage report.
// Output tokens are ASSUMED (the mock's answers are not model answers): 30 per tool-call turn, 120 per final text answer
// (60 when spoken). Audio: Gemini counts 32 tokens per second of input audio and ~25 per second of TTS output audio.
// Prices: public list prices per 1M tokens, paid tier, checked 11 Nov 2026 (see PRICES.source). Free tiers, caching,
// batch discounts and taxes are not counted. Re-check the price pages before budgeting.
import fs from 'node:fs';

export const PRICES = {
  checked: '2026-11-11',
  source: {
    gemini: 'https://ai.google.dev/gemini-api/docs/pricing (Gemini Developer API, paid tier)',
    anthropic: 'https://www.anthropic.com/pricing (Claude API)',
  },
  'gemini-2.5-flash': { in: 0.30, audio_in: 1.00, out: 2.50 },             // USD per 1M tokens; output includes thinking tokens
  'gemini-2.5-flash-preview-tts': { in: 0.50, audio_out: 10.00 },
  'claude-sonnet-5-5': { in: 2.00, out: 10.00 },
};
const A = { callOut: 30, answerOut: 120, voiceAnswerOut: 60, sttSeconds: 6, sttPrompt: 95, sttOut: 25, ttsSeconds: 12, ttsIn: 70, audioInPerSec: 32, audioOutPerSec: 25, historyExchanges: 3 };

const file = process.argv[2];
if (!file) { console.error('usage: node scripts/local-stack/sana-cost.mjs <stats.json> [--md out.md]'); process.exit(2); }
const runs = JSON.parse(fs.readFileSync(file, 'utf8'));
const avg = (xs) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : 0);
const usd = (n) => `$${n < 0.1 ? n.toFixed(4) : n.toFixed(2)}`;
const lines = [];
const out = (s = '') => { lines.push(s); console.log(s); };

const measured = {};
for (const r of runs) {
  const text = r.requests.filter((q) => q.kind === 'text');
  const first = text.filter((q) => (q.function_response_chars ?? 2) <= 2);      // round 1 of a question (no tool results yet)
  const later = text.filter((q) => (q.function_response_chars ?? 2) > 2);
  const questions = first.length;
  const calls = text.filter((q) => q.function_call).length;
  measured[r.provider] = {
    model: r.model, questions, requests: text.length, rounds: questions ? text.length / questions : 0, toolCallTurns: questions ? calls / questions : 0,
    system: avg(first.map((q) => q.est_system ?? Math.ceil(q.system_chars / 4))),
    tools: avg(first.map((q) => q.est_tools ?? Math.ceil(q.tools_chars / 4))),
    question: avg(first.map((q) => (q.est_contents ?? Math.ceil(q.contents_chars / 4)))),
    toolResult: avg(later.map((q) => q.est_function_response ?? Math.ceil(q.function_response_chars / 4))),
    promptPerQuestion: questions ? text.reduce((s, q) => s + q.est_prompt_tokens, 0) / questions : 0,
  };
}

out('# Sana · estimated cost per 100 questions');
out('');
out(`Prompt sizes measured from Sana's real adapter requests (LOCAL-ONLY provider mock, ${Object.values(measured)[0]?.questions ?? 0} model questions of the evaluation set; guard refusals never reach a model). Token counts estimated (ASCII ≈ 4 chars/token, other scripts ≈ 2). Prices checked ${PRICES.checked}: ${PRICES.source.gemini}; ${PRICES.source.anthropic}. **Estimate — not a quote.**`);
out('');
out('| Measured per question (tokens, estimated) | ' + Object.keys(measured).join(' | ') + ' |');
out('|---|' + Object.keys(measured).map(() => '---:').join('|') + '|');
const row = (label, f) => out(`| ${label} | ${Object.values(measured).map(f).join(' | ')} |`);
row('System prompt', (m) => Math.round(m.system));
row('Tool declarations (role-filtered)', (m) => Math.round(m.tools));
row('Question (+ history, new conversation)', (m) => Math.round(m.question));
row('Typical tool result', (m) => Math.round(m.toolResult));
row('Model calls per question (rounds)', (m) => m.rounds.toFixed(2));
row('Input tokens per question, all rounds', (m) => Math.round(m.promptPerQuestion));
out('');

const textCost = (m, price, withHistory) => {
  const history = withHistory ? A.historyExchanges * (m.question + A.answerOut) * m.rounds : 0;
  const inTok = m.promptPerQuestion + history;
  const outTok = m.toolCallTurns * A.callOut + A.answerOut;
  return { inTok, outTok, usd: (inTok * price.in + outTok * price.out) / 1e6 };
};
const g = PRICES['gemini-2.5-flash'];
const tts = PRICES['gemini-2.5-flash-preview-tts'];
const stt = (A.sttSeconds * A.audioInPerSec * g.audio_in + A.sttPrompt * g.in + A.sttOut * g.out) / 1e6;
const speak = (A.ttsIn * tts.in + A.ttsSeconds * A.audioOutPerSec * tts.audio_out) / 1e6;
out('| Per 100 questions (USD, estimate) | text only | + provider speech-to-text | + provider text-to-speech | voice both ways |');
out('|---|---:|---:|---:|---:|');
for (const [prov, m] of Object.entries(measured)) {
  const price = prov === 'gemini' ? g : PRICES['claude-sonnet-5-5'];
  for (const h of [false, true]) {
    const t = textCost(m, price, h).usd;
    out(`| ${prov === 'gemini' ? 'Gemini 2.5 Flash' : 'Anthropic Claude Sonnet 5.5 (fallback)'} — ${h ? `follow-up (${A.historyExchanges} earlier exchanges)` : 'new conversation'} | ${usd(100 * t)} | ${usd(100 * (t + stt))} | ${usd(100 * (t + speak))} | ${usd(100 * (t + stt + speak))} |`);
  }
}
out('');
out(`Voice add-ons per 100 questions (always Gemini): speech-to-text ${usd(100 * stt)} (${A.sttSeconds} s question = ${A.sttSeconds * A.audioInPerSec} audio tokens at $${g.audio_in}/1M + ~${A.sttPrompt} prompt tokens + ~${A.sttOut} output tokens), text-to-speech ${usd(100 * speak)} (~${A.ttsSeconds} s answer ≈ ${A.ttsSeconds * A.audioOutPerSec} audio tokens at $${tts.audio_out}/1M + ~${A.ttsIn} text tokens). Browser voice (voice mode "browser") costs nothing.`);
out('');
out(`Assumptions: output ${A.callOut} tokens per tool-call turn and ${A.answerOut} per answer; Gemini thinking off (thinkingBudget 0 on Flash; thinking tokens would be billed as output). Daily limit 200 questions per person caps the worst case.`);
const md = process.argv.indexOf('--md');
if (md > 0) fs.writeFileSync(process.argv[md + 1], lines.join('\n') + '\n');
