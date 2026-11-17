// Sana Live (S5): microphone frames from the AudioWorklet to the page (16 kHz context, mono Float32).
// Served from our own origin so it passes script-src 'self' (a blob: URL would need a wider CSP).
class SanaMic extends AudioWorkletProcessor {
  process(inputs) { const c = inputs[0] && inputs[0][0]; if (c) this.port.postMessage(c.slice(0)); return true; }
}
registerProcessor('sana-mic', SanaMic);
