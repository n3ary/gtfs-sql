/**
 * Shared HTTP helpers — single User-Agent + small fetch utilities.
 */

import { createWriteStream } from 'node:fs';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

export const UA = 'neary-gtfs/2.0 (https://github.com/ciotlosm/neary-gtfs)';

export async function fetchJson(url, extraHeaders = {}) {
  const res = await fetch(url, { headers: { 'User-Agent': UA, ...extraHeaders } });
  if (!res.ok) throw new Error(`GET ${url}: HTTP ${res.status}`);
  return res.json();
}

export async function fetchText(url) {
  const res = await fetch(url, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`GET ${url}: HTTP ${res.status}`);
  return res.text();
}

export async function fetchToFile(url, dest) {
  const res = await fetch(url, { headers: { 'User-Agent': UA } });
  if (!res.ok || !res.body) throw new Error(`GET ${url}: HTTP ${res.status}`);
  await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
}
