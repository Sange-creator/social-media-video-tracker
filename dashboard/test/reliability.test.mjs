import test from 'node:test';
import assert from 'node:assert/strict';
import { fetchDriveFolders, fetchDriveMediaFiles } from '../lib/googleDriveClient.ts';
import { scanDriveFolder } from '../lib/driveScan.ts';
import { readSyncPages } from '../lib/syncPagination.ts';
import { supabase, serviceSupabase } from '../lib/server.ts';
import { verifyAdminToken, validateAdminCredentials } from '../lib/adminAuth.ts';

const originalFetch = globalThis.fetch;
const originalEnv = { ...process.env };
test.afterEach(() => {
  globalThis.fetch = originalFetch;
  for (const name of ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY']) {
    if (originalEnv[name] === undefined) delete process.env[name];
    else process.env[name] = originalEnv[name];
  }
});

test('Drive folder listing consumes every page beyond 100 files', async () => {
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push(new URL(url));
    assert.equal(options.cache, 'no-store');
    return Response.json(requests.length === 1
      ? { files: [{ id: 'first', name: 'First' }], nextPageToken: 'page-two' }
      : { files: [{ id: 'second', name: 'Second' }] });
  };
  const folders = await fetchDriveFolders('fake-test-token');
  assert.deepEqual(folders.map(f => f.id), ['first', 'second']);
  assert.equal(requests[1].searchParams.get('pageToken'), 'page-two');
  assert.match(requests[0].searchParams.get('fields'), /nextPageToken/);
});

test('Media listing preserves multiline captions across pages', async () => {
  let calls = 0;
  globalThis.fetch = async () => Response.json(++calls === 1
    ? { files: [{ id: 'video', name: 'video.mp4', mimeType: 'video/mp4', description: 'Hello\n#tag' }], nextPageToken: 'more' }
    : { files: [{ id: 'photo', name: 'photo.jpg', mimeType: 'image/jpeg' }] });
  const media = await fetchDriveMediaFiles('fake-test-token', 'folder');
  assert.equal(media.length, 2);
  assert.equal(media[0].uploadText, 'Hello\n#tag');
  assert.equal(media[1].kind, 'photo');
});

test('A failed later Drive page rejects rather than returning a partial library', async () => {
  let calls = 0;
  globalThis.fetch = async () => ++calls === 1
    ? Response.json({ files: [], nextPageToken: 'more' }) : new Response('', { status: 401 });
  await assert.rejects(fetchDriveMediaFiles('fake-test-token'), /session expired/);
});

test('Sync pagination includes tied timestamps and fails atomically', async () => {
  const timestamp = '2026-10-01T00:00:00Z';
  const rows = Array.from({ length: 1000 }, (_, i) => ({ id: `id-${String(i).padStart(4, '0')}`, updated_at: timestamp }));
  const requests = [];
  const result = await readSyncPages('media', timestamp, timestamp, async query => {
    requests.push(new URL(`https://test/${query}`));
    return requests.length === 1 ? rows : [{ id: 'last', updated_at: timestamp }];
  });
  assert.equal(result.length, 1001);
  assert.deepEqual(requests[0].searchParams.getAll('updated_at'), [`gte.${timestamp}`, `lte.${timestamp}`]);
  assert.match(requests[1].searchParams.get('or'), /id.gt.id-0999/);
  let calls = 0;
  await assert.rejects(readSyncPages('media', timestamp, timestamp, async () => {
    if (++calls === 1) return rows;
    throw new Error('offline');
  }), /offline/);
});

test('Missing database configuration never returns successful demo records', async () => {
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  await assert.rejects(supabase({ token: 'test', userId: 'member', email: '' }, 'accessible_media'), /Missing/);
  await assert.rejects(serviceSupabase('workspace_members'), /Missing/);
});

test('Database errors preserve failure status and revision conflicts return 409', async () => {
  process.env.SUPABASE_URL = 'https://db.test';
  process.env.SUPABASE_ANON_KEY = 'test';
  globalThis.fetch = async () => Response.json({ code: '40001' }, { status: 400 });
  const auth = { token: 'test', userId: 'member', email: '' };
  await assert.rejects(supabase(auth, 'rpc/update_media_upload_text'), error => error instanceof Response && error.status === 409);
  globalThis.fetch = async () => { throw new Error('offline'); };
  await assert.rejects(supabase(auth, 'accessible_media'), /offline/);
});

test('Public default admin credentials and forged tokens are rejected', () => {
  assert.equal(validateAdminCredentials('admin@gmail.com', 'admin123'), false);
  const payload = Buffer.from(JSON.stringify({ userId: 'admin-user', role: 'admin', exp: Date.now() + 10000 })).toString('base64url');
  assert.equal(verifyAdminToken(`admin.${payload}.bad`), null);
});


test('Backend baseline scans nested folders and follows page tokens', async () => {
  const requested = [];
  globalThis.fetch = async (input) => {
    const url = new URL(input);
    requested.push(url);
    const query = url.searchParams.get('q');
    if (query.includes("'root-folder'") && !url.searchParams.has('pageToken')) {
      return Response.json({files: [{id: 'nested', name: 'Nested', mimeType: 'application/vnd.google-apps.folder'}], nextPageToken: 'second'});
    }
    if (query.includes("'root-folder'")) return Response.json({files: [{id: 'root-video', name: 'Root.mp4', mimeType: 'video/mp4'}]});
    return Response.json({files: [{id: 'nested-video', name: 'Nested.mp4', mimeType: 'video/mp4', description: 'Caption'}]});
  };
  const files = await scanDriveFolder('test', 'root-folder', 'Account');
  assert.deepEqual(files.map(file => file.id), ['root-video', 'nested-video']);
  assert.equal(files[1].folderPath, 'Account / Nested');
  assert.equal(requested[1].searchParams.get('pageToken'), 'second');
});

test('Backend scan rejects permission failures and malformed listings', async () => {
  globalThis.fetch = async () => new Response('', {status: 403});
  await assert.rejects(scanDriveFolder('test', 'folder', 'Account'), /403/);
  globalThis.fetch = async () => Response.json({});
  await assert.rejects(scanDriveFolder('test', 'folder', 'Account'), /Invalid/);
});


test('Starred and Trash views query their actual Drive collections', async () => {
  const urls = [];
  globalThis.fetch = async url => { urls.push(new URL(url)); return Response.json({files: []}); };
  await fetchDriveMediaFiles('test', 'root', 'My Drive', 'starred');
  assert.match(urls[0].searchParams.get('q'), /starred = true/);
  assert.doesNotMatch(urls[0].searchParams.get('q'), /in parents/);
  await fetchDriveMediaFiles('test', 'root', 'My Drive', 'trash');
  assert.match(urls[1].searchParams.get('q'), /trashed = true/);
});
