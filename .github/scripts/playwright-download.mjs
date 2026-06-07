#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { request } from 'playwright';

const [, , url, outputDir, fallbackName = 'download'] = process.argv;

if (!url || !outputDir) {
  console.error('Usage: playwright-download.mjs <url> <output-dir> [fallback-name]');
  process.exit(2);
}

function sanitizeName(name) {
  const sanitized = name
    .replace(/[\\/:*?"<>|]+/g, '_')
    .replace(/\s+/g, ' ')
    .trim();
  return sanitized || fallbackName;
}

function nameFromDisposition(value) {
  if (!value) return '';

  const encoded = value.match(/filename\*\s*=\s*([^']*)''([^;]+)/i);
  if (encoded?.[2]) {
    try {
      return decodeURIComponent(encoded[2].replace(/^"|"$/g, ''));
    } catch {
      return encoded[2].replace(/^"|"$/g, '');
    }
  }

  const plain = value.match(/filename\s*=\s*"([^"]+)"/i) || value.match(/filename\s*=\s*([^;]+)/i);
  return plain?.[1]?.trim() || '';
}

function nameFromUrl(value) {
  try {
    const parsed = new URL(value);
    const base = path.posix.basename(parsed.pathname);
    return base ? decodeURIComponent(base) : '';
  } catch {
    return '';
  }
}

function uniquePath(dir, filename) {
  const parsed = path.parse(filename);
  let candidate = path.join(dir, filename);
  let index = 1;

  while (fs.existsSync(candidate)) {
    candidate = path.join(dir, `${parsed.name}-${index}${parsed.ext}`);
    index += 1;
  }

  return candidate;
}

fs.mkdirSync(outputDir, { recursive: true });

const api = await request.newContext({
  ignoreHTTPSErrors: true,
  extraHTTPHeaders: {
    'User-Agent':
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125 Safari/537.36',
  },
});

try {
  const response = await api.get(url, {
    failOnStatusCode: false,
    maxRedirects: 20,
    timeout: 0,
  });

  if (!response.ok()) {
    throw new Error(`HTTP ${response.status()} ${response.statusText()}`);
  }

  const headers = response.headers();
  const filename = sanitizeName(
    nameFromDisposition(headers['content-disposition']) || nameFromUrl(response.url()) || fallbackName,
  );
  const destination = uniquePath(outputDir, filename);

  fs.writeFileSync(destination, await response.body());
  console.log(destination);
} finally {
  await api.dispose();
}
