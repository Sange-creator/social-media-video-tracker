export type ScannedDriveFile = {
  id: string;
  name: string;
  mimeType: string;
  size?: string;
  modifiedTime?: string;
  thumbnailLink?: string;
  resourceKey?: string;
  description?: string;
  starred?: boolean;
  capabilities?: { canDownload?: boolean };
  folderPath: string;
};
type DriveChild = Omit<ScannedDriveFile, 'folderPath'>;

// A complete scan is required before declaring anything missing. Pagination or
// permission failures reject the scan so a partial response cannot hide files.
export async function scanDriveFolder(token: string, folderId: string, folderName: string): Promise<ScannedDriveFile[]> {
  const found: ScannedDriveFile[] = [];
  const visited = new Set<string>();
  const pending = [{ id: folderId, path: folderName }];
  while (pending.length) {
    const folder = pending.pop()!;
    if (visited.has(folder.id)) continue;
    visited.add(folder.id);
    let pageToken: string | undefined;
    do {
      const url = new URL('https://www.googleapis.com/drive/v3/files');
      url.searchParams.set('q', `'${folder.id.replace(/'/g, "\\'")}' in parents and trashed = false`);
      url.searchParams.set('fields', 'nextPageToken,files(id,name,mimeType,size,modifiedTime,thumbnailLink,resourceKey,description,starred,capabilities(canDownload))');
      url.searchParams.set('pageSize', '1000');
      url.searchParams.set('supportsAllDrives', 'true');
      url.searchParams.set('includeItemsFromAllDrives', 'true');
      if (pageToken) url.searchParams.set('pageToken', pageToken);
      const response = await fetch(url, { cache: 'no-store', headers: { authorization: `Bearer ${token}` } });
      if (!response.ok) throw new Error(`Drive folder scan failed (${response.status})`);
      const page = await response.json() as { files?: DriveChild[]; nextPageToken?: string };
      if (!Array.isArray(page.files)) throw new Error('Invalid Drive folder listing');
      for (const file of page.files) {
        if (file.mimeType === 'application/vnd.google-apps.folder') pending.push({ id: file.id, path: `${folder.path} / ${file.name}` });
        else if (file.mimeType.startsWith('video/') || file.mimeType.startsWith('image/')) found.push({ ...file, folderPath: folder.path });
      }
      pageToken = page.nextPageToken;
    } while (pageToken);
  }
  return found;
}
