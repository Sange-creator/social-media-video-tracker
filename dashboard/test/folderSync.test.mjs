import test from 'node:test';
import assert from 'node:assert/strict';
import { affectedDriveRoots, readDriveChanges, viewAffectedByChanges } from '../lib/driveChanges.ts';
const originalFetch = globalThis.fetch;
test.afterEach(() => { globalThis.fetch = originalFetch; });
const upload = (id, parent) => ({fileId: id, file: {id, name: 'Video.mp4', mimeType: 'video/mp4', parents: [parent]}});
test('An upload refreshes its folder and leaves unrelated folders untouched', () => {
  const changes = [upload('new', 'folder-a')];
  assert.equal(viewAffectedByChanges(changes, 'folder-a', new Set(), 'all'), true);
  assert.equal(viewAffectedByChanges(changes, 'folder-b', new Set(), 'all'), false);
  assert.equal(viewAffectedByChanges([{fileId: 'existing', removed: true}], 'folder-a', new Set(['existing']), 'all'), true);
  assert.equal(viewAffectedByChanges([{fileId: 'unknown', removed: true}], 'folder-a', new Set(['existing']), 'all'), false);
});
test('Nested uploads resolve only their connected roots and share ancestor lookups', async () => {
  const calls = [];
  globalThis.fetch = async url => {
    const id = new URL(url).pathname.split('/').at(-1);
    calls.push(id);
    return Response.json({parents: id === 'nested' ? ['folder-a'] : []});
  };
  const affected = await affectedDriveRoots('token', [upload('one', 'nested'), upload('two', 'nested')], new Set(['folder-a','folder-b']));
  assert.deepEqual([...affected], ['folder-a']);
  assert.equal(calls.filter(id => id === 'nested').length, 1);
  assert.equal(calls.includes('folder-b'), false);
});
test('Moves refresh old visible membership and the new destination', () => {
  const changes = [upload('moved', 'folder-b')];
  assert.equal(viewAffectedByChanges(changes, 'folder-a', new Set(['moved']), 'all'), true);
  assert.equal(viewAffectedByChanges(changes, 'folder-b', new Set(), 'all'), true);
  assert.equal(viewAffectedByChanges(changes, 'folder-c', new Set(), 'all'), false);
});
test('Change cursor follows every page and rejects later failures', async () => {
  let calls = 0;
  globalThis.fetch = async () => Response.json(++calls === 1
    ? {changes: [upload('one','a')], nextPageToken: 'second'}
    : {changes: [upload('two','b')], newStartPageToken: 'committed'});
  const page = await readDriveChanges('token','old');
  assert.equal(page.changes.length, 2);
  assert.equal(page.cursor, 'committed');
  calls = 0;
  globalThis.fetch = async () => ++calls === 1 ? Response.json({changes: [], nextPageToken: 'second'}) : new Response('', {status: 503});
  await assert.rejects(readDriveChanges('token','old'));
});
