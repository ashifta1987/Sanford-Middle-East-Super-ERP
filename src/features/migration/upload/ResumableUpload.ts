// Resumable (TUS) upload of a company's export to Supabase Storage bucket sap-exports.
// Object names: <company>/<run_id>/<relative path>. 6 MB chunks (Supabase's required TUS chunk size), 4 files at a time.
// Upload URLs live in IndexedDB, so after a dropped connection or a closed tab the same files continue where they stopped.

import { Upload } from 'tus-js-client';
import { SUPABASE_URL, supabase } from '@/lib/supabase';
import type { PickedFile } from './classify';
import { IdbUrlStorage, sessions } from './uploadStore';

export const BUCKET = 'sap-exports';
const CHUNK = 6 * 1024 * 1024;
const PARALLEL = 4;
const urlStorage = new IdbUrlStorage();

export interface FileProgress { path: string; size: number; sent: number; state: 'waiting' | 'uploading' | 'done' | 'error'; error?: string }
export interface Progress { files: Record<string, FileProgress>; sentBytes: number; totalBytes: number; done: number; total: number; failed: number }

async function token() {
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error('Not signed in');
  return data.session.access_token;
}

function contentType(name: string) {
  const n = name.toLowerCase();
  if (n.endsWith('.csv') || /data(\.csv(\.\d+)?)?$/.test(n)) return 'text/csv';
  if (n.endsWith('.sql')) return 'text/plain';
  if (n.endsWith('.xlsx')) return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  if (n.endsWith('.zip')) return 'application/zip';
  if (n.endsWith('.gz') || n.endsWith('.tgz')) return 'application/gzip';
  return 'application/octet-stream';
}

/** Storage object keys accept a limited character set; replace anything else (the worker keeps relative paths). */
export function safeKey(path: string) {
  return path.split('/').map((seg) => seg.replace(/[^\w!\-.*'() &$@=;:+,]/g, '_')).join('/');
}

export class ResumableUpload {
  private uploads = new Map<string, Upload>();
  private pending = new Map<string, () => void>();
  private stopped = false;
  progress: Progress;

  constructor(
    private runId: string,
    private company: string,
    private picked: PickedFile[],
    private onProgress: (p: Progress) => void,
    alreadyDone: Set<string> = new Set(),
  ) {
    const files: Record<string, FileProgress> = {};
    for (const p of picked) {
      files[p.path] = { path: p.path, size: p.file.size, sent: alreadyDone.has(p.path) ? p.file.size : 0, state: alreadyDone.has(p.path) ? 'done' : 'waiting' };
    }
    this.progress = this.totals(files);
  }

  private totals(files: Record<string, FileProgress>): Progress {
    const list = Object.values(files);
    return {
      files,
      sentBytes: list.reduce((a, f) => a + f.sent, 0),
      totalBytes: list.reduce((a, f) => a + f.size, 0),
      done: list.filter((f) => f.state === 'done').length,
      failed: list.filter((f) => f.state === 'error').length,
      total: list.length,
    };
  }

  private emit(path: string, patch: Partial<FileProgress>) {
    const files = { ...this.progress.files, [path]: { ...this.progress.files[path], ...patch } };
    this.progress = this.totals(files);
    this.onProgress(this.progress);
  }

  private uploadOne(p: PickedFile): Promise<void> {
    return new Promise((done) => {
      const resolve = () => { this.pending.delete(p.path); done(); };
      this.pending.set(p.path, resolve);
      const objectName = `${this.company}/${this.runId}/${safeKey(p.path)}`;
      const up = new Upload(p.file, {
        endpoint: `${SUPABASE_URL}/storage/v1/upload/resumable`,
        retryDelays: [0, 1000, 3000, 5000, 10000, 20000, 30000, 60000],
        chunkSize: CHUNK,
        uploadDataDuringCreation: true,
        removeFingerprintOnSuccess: true,
        storeFingerprintForResuming: true,
        urlStorage,
        fingerprint: async () => `${this.runId}::${p.path}::${p.file.size}::${p.file.lastModified}`,
        headers: { 'x-upsert': 'false' },
        metadata: { bucketName: BUCKET, objectName, contentType: contentType(p.file.name), cacheControl: '3600' },
        // fresh access token on every request: long uploads outlive a single token
        onBeforeRequest: async (req) => { req.setHeader('authorization', `Bearer ${await token()}`); },
        onProgress: (sent) => this.emit(p.path, { sent, state: 'uploading' }),
        onSuccess: async () => {
          await sessions.markDone(this.runId, p.path);
          this.emit(p.path, { sent: p.file.size, state: 'done' });
          resolve();
        },
        onError: async (err) => {
          // 409 = the object already exists (finished before the tab closed): count it as done
          const status = (err as { originalResponse?: { getStatus(): number } }).originalResponse?.getStatus?.();
          if (status === 409) {
            await sessions.markDone(this.runId, p.path);
            this.emit(p.path, { sent: p.file.size, state: 'done' });
          } else {
            this.emit(p.path, { state: 'error', error: err.message?.slice(0, 300) });
          }
          resolve();
        },
      });
      this.uploads.set(p.path, up);
      up.findPreviousUploads().then((prev) => {
        if (prev.length) up.resumeFromPreviousUpload(prev[0]);
        if (!this.stopped) up.start();
        else resolve();
      });
    });
  }

  /** Upload everything not yet done, PARALLEL at a time. Resolves when every file finished or failed. */
  async start() {
    this.stopped = false;
    const queue = this.picked.filter((p) => this.progress.files[p.path].state !== 'done');
    this.onProgress(this.progress);
    const worker = async () => {
      while (!this.stopped) {
        const next = queue.shift();
        if (!next) return;
        await this.uploadOne(next);
      }
    };
    await Promise.all(Array.from({ length: Math.min(PARALLEL, queue.length || 1) }, worker));
    return this.progress;
  }

  /** Pause: in-flight chunks stop; the stored URLs let the next start() continue. */
  pause() {
    this.stopped = true;
    for (const u of this.uploads.values()) void u.abort(false);
    for (const r of [...this.pending.values()]) r();
    for (const f of Object.values(this.progress.files)) if (f.state === 'uploading') f.state = 'waiting';
    this.onProgress({ ...this.progress });
  }
}
