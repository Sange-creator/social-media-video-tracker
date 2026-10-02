export type DriveChange = {
  fileId?: string;
  removed?: boolean;
  file?: { id: string; name: string; mimeType: string; parents?: string[]; trashed?: boolean };
};

export async function driveStartToken(token: string): Promise<string> {
  const response = await fetch('https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=true', {
    cache: 'no-store', headers: { authorization: `Bearer ${token}` },
  });
  if (!response.ok) throw new Error(`Drive cursor failed (${response.status})`);
  const data = await response.json() as { startPageToken?: string };
  if (!data.startPageToken) throw new Error('Invalid Drive cursor');
  return data.startPageToken;
}

// Return a cursor only after every page succeeds. Callers commit it after saving.
export async function readDriveChanges(token: string, cursor: string): Promise<{ changes: DriveChange[]; cursor: string }> {
  const changes: DriveChange[] = [];
  for (;;) {
    const url = new URL('https://www.googleapis.com/drive/v3/changes');
    url.searchParams.set('pageToken', cursor);
    url.searchParams.set('supportsAllDrives', 'true');
    url.searchParams.set('includeItemsFromAllDrives', 'true');
    url.searchParams.set('fields', 'nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,parents,trashed))');
    const response = await fetch(url, { cache: 'no-store', headers: { authorization: `Bearer ${token}` } });
    if (!response.ok) throw new Error(`Drive changes failed (${response.status})`);
    const page = await response.json() as { changes?: DriveChange[]; nextPageToken?: string; newStartPageToken?: string };
    if (!Array.isArray(page.changes)) throw new Error('Invalid Drive changes');
    changes.push(...page.changes);
    if (page.nextPageToken) { cursor = page.nextPageToken; continue; }
    if (!page.newStartPageToken) throw new Error('Missing Drive change cursor');
    return { changes, cursor: page.newStartPageToken };
  }
}

// Resolve new memberships using parents; callers add old memberships for moves/deletes.
export async function affectedDriveRoots(token: string, changes: DriveChange[], roots: Set<string>): Promise<Set<string>> {
  const affected = new Set<string>();
  const cache = new Map<string, string[]>();
  for (const change of changes) {
    if (change.fileId && roots.has(change.fileId)) affected.add(change.fileId);
    if (change.removed || !change.file) continue;
    const pending = [...(change.file.parents ?? [])];
    const visited = new Set<string>();
    while (pending.length) {
      const id = pending.pop()!;
      if (visited.has(id)) continue;
      visited.add(id);
      if (roots.has(id)) affected.add(id);
      if (!cache.has(id)) {
        const url = new URL(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(id)}`);
        url.searchParams.set('fields', 'parents');
        url.searchParams.set('supportsAllDrives', 'true');
        const response = await fetch(url, { cache: 'no-store', headers: { authorization: `Bearer ${token}` } });
        if (response.status === 403 || response.status === 404) {
          cache.set(id, []);
          continue;
        }
        if (!response.ok) throw new Error(`Drive parent lookup failed (${response.status})`);
        const item = await response.json() as { parents?: string[] };
        cache.set(id, item.parents ?? []);
      }
      pending.push(...cache.get(id)!);
    }
  }
  return affected;
}

export function viewAffectedByChanges(changes: DriveChange[], folderID: string, visibleIDs: Set<string>, filter: string): boolean {
  return changes.some(change => {
    if (change.fileId && visibleIDs.has(change.fileId)) return true;
    if (!change.file || change.removed) return false;
    const isMedia = /^(video|image)\//.test(change.file.mimeType);
    return isMedia && (filter !== 'all' || change.file.parents?.includes(folderID) === true);
  });
}
