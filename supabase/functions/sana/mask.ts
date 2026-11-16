// SANA input masker (S3 rule 6): ID numbers, bank accounts, card numbers, passwords and OTPs never reach a model prompt.
// Runs on every string that goes into the facts for `now` / `line` (and is safe to run on anything). The output filter
// (core.ts redact) still runs on everything that comes back. Runtime-neutral, erasable TypeScript, no imports.

const RULES: Array<[RegExp, (m: string, ...g: string[]) => string]> = [
  // IBAN (AE07 0331 2345 6789 0123 456) → ••last4
  [/\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,8}(?:[ ]?[A-Z0-9]{1,3})?\b/g, (m) => `••${m.replace(/\s/g, '').slice(-4)}`],
  // Emirates ID 784-YYYY-NNNNNNN-N
  [/\b784-?\d{4}-?\d{7}-?\d\b/g, () => '[ID hidden]'],
  // card numbers (13–19 digits with spaces / dashes)
  [/\b(?:\d[ -]?){13,19}\b/g, () => '[card hidden]'],
  // Aadhaar 1234 5678 9012
  [/\b\d{4}[ -]?\d{4}[ -]?\d{4}\b/g, () => '[ID hidden]'],
  // PAN ABCDE1234F
  [/\b[A-Z]{5}\d{4}[A-Z]\b/g, () => '[ID hidden]'],
  // passport / national id written next to the word
  [/\b(passport|passport no\.?|national id|id no\.?|emirates id)\s*[:#]?\s*[A-Z0-9-]{6,15}\b/gi, (_m, w) => `${w} [hidden]`],
  // bank account numbers next to the word → ••last4
  [/\b(account|a\/c|acct)(\s*(?:no\.?|number)?\s*[:#]?\s*)(\d[\d -]{6,20}\d)\b/gi, (_m, w, sep, n) => `${w}${sep}••${n.replace(/\D/g, '').slice(-4)}`],
  // passwords and one-time codes
  [/\b(password|passcode|pwd|pin)\s*[:=]?\s*\S+/gi, (_m, w) => `${w} [hidden]`],
  [/\b(otp|one[- ]time (?:code|password)|verification code)\s*(?:is)?\s*[:=]?\s*\d{4,8}\b/gi, (_m, w) => `${w} [hidden]`],
];

export function maskInput(text: string): string {
  let out = text;
  for (const [re, fn] of RULES) out = out.replace(re, fn as (substring: string, ...args: string[]) => string);
  return out;
}

/** Mask every string inside a JSON value (facts, record summaries). Keys are kept. */
export function maskDeep<T>(v: T): T {
  if (typeof v === 'string') return maskInput(v) as unknown as T;
  if (Array.isArray(v)) return v.map((x) => maskDeep(x)) as unknown as T;
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v as Record<string, unknown>).map(([k, x]) => [k, maskDeep(x)])) as T;
  return v;
}
