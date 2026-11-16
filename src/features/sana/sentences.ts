// S4 · step 2: split a streamed answer into pieces that can be read aloud while the rest is still arriving.
// Pure and runtime-neutral (no imports, erasable TypeScript): the panel, the e2e checks and the timing runner use this file.
//
// A sentence ends at . ! ? ؟ । ۔ followed by a space (so 12,500.00 or SMP-1010.5 never split) or at a new line. Malayalam
// uses "." too. The first sentence is sent alone (the shortest way to first audio); after that sentences are grouped until a
// piece is at least `restMin` characters, so a long answer costs a few TTS calls, not one per sentence.

const END = /[.!?؟।۔](?=\s)|\n/g;

/** Same clean-up as the server's plainForVoice (sana/core.ts): no markdown, no bullets, no code. */
export const plainForSpeech = (t: string) =>
  t.replace(/```[\s\S]*?```/g, '').replace(/[*_#`>|]+/g, '').replace(/^\s*[-•]\s+/gm, '').replace(/\n{2,}/g, '\n').trim();
const norm = (t: string) => plainForSpeech(t).replace(/\s+/g, ' ').trim();

export class SentenceSplitter {
  private taken = 0;        // characters of the streamed text already handed out
  private consumed = '';    // that text, for the divergence check
  private pieces = 0;
  diverged = false;
  readonly restMin: number;
  constructor(restMin = 120) { this.restMin = restMin; }

  /** The whole streamed text so far → newly finished pieces (in order). */
  push(full: string): string[] {
    if (this.diverged) return [];
    if (!full.startsWith(this.consumed)) { this.diverged = true; return []; }   // the server replaced the text (reset)
    const out: string[] = [];
    for (;;) {
      const rest = full.slice(this.taken);
      let cut = -1;
      END.lastIndex = 0;
      for (let m = END.exec(rest); m; m = END.exec(rest)) {
        const end = m.index + m[0].length;
        if (!rest.slice(0, end).trim()) continue;
        cut = end;
        if (this.pieces === 0 || end >= this.restMin) break;   // first piece: first sentence; later: at least restMin chars
      }
      if (cut < 0 || (this.pieces > 0 && cut < this.restMin)) break;
      const piece = rest.slice(0, cut);
      this.taken += cut; this.consumed = full.slice(0, this.taken);
      const said = plainForSpeech(piece);
      if (said) { out.push(said); this.pieces++; }
    }
    return out;
  }

  /** Everything after the pieces handed out so far, as one last piece (end of the stream). */
  rest(full: string): string[] {
    if (this.diverged || !full.startsWith(this.consumed)) return [];
    const said = plainForSpeech(full.slice(this.taken));
    this.taken = full.length; this.consumed = full;
    if (said) this.pieces++;
    return said ? [said] : [];
  }

  /**
   * The final reply → what is still to be said. When the final text does not continue what was already handed out (a refusal
   * replaced the stream, or the reply was rewritten for voice), `restart` is true and `pieces` is the whole final reply.
   */
  finish(final: string): { restart: boolean; pieces: string[] } {
    const done = norm(this.consumed), all = norm(final);
    if (this.diverged || !all.startsWith(done)) return { restart: true, pieces: split(final, this.restMin) };
    const left = all.slice(done.length).trim();
    return { restart: false, pieces: left ? (this.pieces === 0 ? split(left, this.restMin) : [left]) : [] };
  }
}

/** A whole text → pieces, with the same rule (first sentence alone, then groups of at least restMin characters). */
export function split(text: string, restMin = 120): string[] {
  const s = new SentenceSplitter(restMin);
  return [...s.push(text), ...s.rest(text)];
}
