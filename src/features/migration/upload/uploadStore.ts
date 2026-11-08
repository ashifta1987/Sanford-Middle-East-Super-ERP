// Small IndexedDB store for resumable uploads, so a closed tab or a dropped connection never restarts from zero.
//  - "tus": tus-js-client UrlStorage (upload URL per file fingerprint)
//  - "sessions": one record per run: company, kind, every file's path/size and whether it finished

import type { UrlStorage, PreviousUpload } from 'tus-js-client';

const DB = 'sanford-uploads';
const VERSION = 1;

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('tus')) db.createObjectStore('tus', { keyPath: 'urlStorageKey' });
      if (!db.objectStoreNames.contains('sessions')) db.createObjectStore('sessions', { keyPath: 'runId' });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  return new Promise<T>((resolve, reject) => {
    const t = db.transaction(store, mode);
    const r = fn(t.objectStore(store));
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

type Stored = PreviousUpload & { urlStorageKey: string };

export class IdbUrlStorage implements UrlStorage {
  async findAllUploads(): Promise<PreviousUpload[]> {
    return (await tx<Stored[]>('tus', 'readonly', (s) => s.getAll())) ?? [];
  }
  async findUploadsByFingerprint(fingerprint: string): Promise<PreviousUpload[]> {
    const all = (await tx<Stored[]>('tus', 'readonly', (s) => s.getAll())) ?? [];
    return all.filter((u) => u.urlStorageKey.startsWith(`tus::${fingerprint}::`));
  }
  async removeUpload(urlStorageKey: string): Promise<void> {
    await tx('tus', 'readwrite', (s) => s.delete(urlStorageKey));
  }
  async addUpload(fingerprint: string, upload: PreviousUpload): Promise<string> {
    const key = `tus::${fingerprint}::${Math.random().toString(36).slice(2)}`;
    await tx('tus', 'readwrite', (s) => s.put({ ...upload, urlStorageKey: key }));
    return key;
  }
}

export interface UploadSession {
  runId: string;
  company: string;
  kind: 'full' | 'tables' | 'structure_only';
  createdAt: string;
  /** path → size + done */
  files: Record<string, { size: number; done: boolean }>;
  /** client analysis kept for the Received table after reloads (rows in file, read as) */
  facts?: unknown;
  submitted?: boolean;
}

export const sessions = {
  get: (runId: string) => tx<UploadSession | undefined>('sessions', 'readonly', (s) => s.get(runId)),
  put: (sess: UploadSession) => tx('sessions', 'readwrite', (s) => s.put(sess)),
  remove: (runId: string) => tx('sessions', 'readwrite', (s) => s.delete(runId)),
  async forCompany(company: string): Promise<UploadSession[]> {
    const all = (await tx<UploadSession[]>('sessions', 'readonly', (s) => s.getAll())) ?? [];
    return all.filter((x) => x.company === company).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  },
  async markDone(runId: string, path: string) {
    const s = await sessions.get(runId);
    if (!s || !s.files[path]) return;
    s.files[path].done = true;
    await sessions.put(s);
  },
};
