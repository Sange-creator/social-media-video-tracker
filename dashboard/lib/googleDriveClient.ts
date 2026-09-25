"use client";

export interface GoogleDriveUser {
  email: string;
  name?: string;
  picture?: string;
}

export interface GoogleDriveFolder {
  id: string;
  name: string;
  parents?: string[];
  modifiedTime?: string;
}

export interface GoogleDriveMediaFile {
  id: string;
  driveFileId: string;
  name: string;
  kind: "video" | "photo";
  mimeType: string;
  folder: string;
  folderId?: string;
  size: string;
  rawSizeBytes: number;
  updatedLabel: string;
  starred: boolean;
  trashed: boolean;
  canDownload: boolean;
  accent: "blue" | "teal" | "amber" | "rose" | "slate";
  uploadText: string;
  revision: number;
  thumbnailUrl: string | null;
  webViewLink?: string;
  webContentLink?: string;
}

const DRIVE_TOKEN_KEY = "gdrive_access_token";
const DRIVE_USER_KEY = "gdrive_user_info";
const DRIVE_CLIENT_ID_KEY = "gdrive_client_id";

export const DEFAULT_GOOGLE_CLIENT_ID = "1052590129919-qocu3h1ke92se8615pk7ndnn78odj6q5.apps.googleusercontent.com";

export function getStoredDriveToken(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem(DRIVE_TOKEN_KEY);
}

export function getStoredDriveUser(): GoogleDriveUser | null {
  if (typeof window === "undefined") return null;
  const raw = localStorage.getItem(DRIVE_USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export function getStoredGoogleClientId(): string {
  if (typeof window === "undefined") return DEFAULT_GOOGLE_CLIENT_ID;
  return localStorage.getItem(DRIVE_CLIENT_ID_KEY) || DEFAULT_GOOGLE_CLIENT_ID;
}

export function setStoredGoogleClientId(clientId: string) {
  if (typeof window !== "undefined") {
    localStorage.setItem(DRIVE_CLIENT_ID_KEY, clientId);
  }
}

export function setStoredDriveSession(token: string, user: GoogleDriveUser) {
  if (typeof window !== "undefined") {
    localStorage.setItem(DRIVE_TOKEN_KEY, token);
    localStorage.setItem(DRIVE_USER_KEY, JSON.stringify(user));
    window.dispatchEvent(new Event("gdrive-auth-change"));
  }
}

export function disconnectDriveSession() {
  if (typeof window !== "undefined") {
    localStorage.removeItem(DRIVE_TOKEN_KEY);
    localStorage.removeItem(DRIVE_USER_KEY);
    window.dispatchEvent(new Event("gdrive-auth-change"));
  }
}

export async function fetchGoogleUserInfo(token: string): Promise<GoogleDriveUser> {
  const res = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    throw new Error("Invalid or expired Google Drive access token.");
  }
  const data = (await res.json()) as { email: string; name?: string; picture?: string };
  return {
    email: data.email,
    name: data.name,
    picture: data.picture,
  };
}

export async function fetchDriveFolders(
  token: string,
  parentId?: string | null
): Promise<GoogleDriveFolder[]> {
  const pId = parentId && parentId !== "root" ? parentId : "root";
  const q = `'${pId.replace(/'/g, "\\'")}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false`;
  const url = new URL("https://www.googleapis.com/drive/v3/files");
  url.searchParams.set("q", q);
  url.searchParams.set("fields", "files(id, name, parents, modifiedTime)");
  url.searchParams.set("pageSize", "100");
  url.searchParams.set("orderBy", "name");
  url.searchParams.set("supportsAllDrives", "true");
  url.searchParams.set("includeItemsFromAllDrives", "true");

  const res = await fetch(url.toString(), {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    const errorText = await res.text().catch(() => "");
    throw new Error(`Google Drive folder error: ${errorText || res.statusText}`);
  }
  const data = (await res.json()) as { files?: GoogleDriveFolder[] };
  return data.files ?? [];
}

export async function fetchDriveMediaFiles(
  token: string,
  folderId?: string | null,
  folderName = "My Drive"
): Promise<GoogleDriveMediaFile[]> {
  const pId = folderId && folderId !== "root" ? folderId : "root";
  const q = `'${pId.replace(/'/g, "\\'")}' in parents and (mimeType contains 'video/' or mimeType contains 'image/') and trashed = false`;
  const url = new URL("https://www.googleapis.com/drive/v3/files");
  url.searchParams.set("q", q);
  url.searchParams.set(
    "fields",
    "files(id, name, mimeType, size, modifiedTime, thumbnailLink, webContentLink, webViewLink, description, starred, trashed, capabilities)"
  );
  url.searchParams.set("pageSize", "100");
  url.searchParams.set("orderBy", "modifiedTime desc");
  url.searchParams.set("supportsAllDrives", "true");
  url.searchParams.set("includeItemsFromAllDrives", "true");

  const res = await fetch(url.toString(), {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    const errorText = await res.text().catch(() => "");
    throw new Error(`Google Drive media error: ${errorText || res.statusText}`);
  }
  const data = (await res.json()) as {
    files?: Array<{
      id: string;
      name: string;
      mimeType: string;
      size?: string;
      modifiedTime?: string;
      thumbnailLink?: string;
      webContentLink?: string;
      webViewLink?: string;
      description?: string;
      starred?: boolean;
      trashed?: boolean;
      capabilities?: { canDownload?: boolean };
    }>;
  };

  return (data.files ?? []).map((file) => {
    const rawSizeBytes = file.size ? Number(file.size) : 0;
    const mime = file.mimeType || "";
    const isPhoto = mime.startsWith("image/");
    return {
      id: file.id,
      driveFileId: file.id,
      name: file.name,
      kind: isPhoto ? ("photo" as const) : ("video" as const),
      mimeType: mime,
      folder: folderName,
      folderId: folderId ?? "root",
      size: formatBytes(rawSizeBytes),
      rawSizeBytes,
      updatedLabel: file.modifiedTime
        ? new Date(file.modifiedTime).toLocaleDateString()
        : "Just now",
      starred: Boolean(file.starred),
      trashed: Boolean(file.trashed),
      canDownload: file.capabilities?.canDownload !== false,
      accent: isPhoto ? ("teal" as const) : ("blue" as const),
      uploadText: file.description || "",
      revision: 1,
      thumbnailUrl: file.thumbnailLink || null,
      webViewLink: file.webViewLink,
      webContentLink: file.webContentLink,
    };
  });
}

export async function uploadToGoogleDrive(
  token: string,
  params: {
    file: File;
    folderId?: string | null;
    caption?: string;
    onProgress?: (percent: number) => void;
  }
): Promise<GoogleDriveMediaFile> {
  const { file, folderId, caption = "", onProgress } = params;
  const pId = folderId && folderId !== "root" ? folderId : "root";

  // 1. Resumable upload session initialization
  const metadata = {
    name: file.name,
    parents: pId !== "root" ? [pId] : [],
    description: caption,
    mimeType: file.type || "application/octet-stream",
  };

  const initRes = await fetch(
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true",
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json; charset=UTF-8",
        "x-upload-content-type": file.type || "application/octet-stream",
        "x-upload-content-length": String(file.size),
      },
      body: JSON.stringify(metadata),
    }
  );

  if (!initRes.ok) {
    const err = await initRes.text().catch(() => "");
    throw new Error(`Failed to initiate Drive upload: ${err || initRes.statusText}`);
  }

  const uploadUrl = initRes.headers.get("location");
  if (!uploadUrl) {
    throw new Error("Google Drive did not return an upload session URL.");
  }

  // 2. Stream/Upload the binary data using XMLHttpRequest for progress events
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", uploadUrl);
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");

    if (xhr.upload && onProgress) {
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const pct = Math.round((e.loaded / e.total) * 100);
          onProgress(pct);
        }
      };
    }

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          const res = JSON.parse(xhr.responseText);
          const isPhoto = (file.type || "").startsWith("image/");
          resolve({
            id: res.id,
            driveFileId: res.id,
            name: res.name || file.name,
            kind: isPhoto ? "photo" : "video",
            mimeType: res.mimeType || file.type,
            folder: "Uploaded",
            folderId: pId,
            size: formatBytes(file.size),
            rawSizeBytes: file.size,
            updatedLabel: "Just now",
            starred: false,
            trashed: false,
            canDownload: true,
            accent: isPhoto ? "teal" : "blue",
            uploadText: caption,
            revision: 1,
            thumbnailUrl: null,
            webViewLink: res.webViewLink,
          });
        } catch (e) {
          reject(new Error("Failed to parse upload response"));
        }
      } else {
        reject(new Error(`Drive upload failed: ${xhr.status} ${xhr.responseText}`));
      }
    };

    xhr.onerror = () => {
      reject(new Error("Network error during Google Drive upload"));
    };

    xhr.send(file);
  });
}

export async function updateDriveDescription(
  token: string,
  fileId: string,
  description: string
): Promise<void> {
  const res = await fetch(
    `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?supportsAllDrives=true`,
    {
      method: "PATCH",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ description }),
    }
  );
  if (!res.ok) {
    const err = await res.text().catch(() => "");
    throw new Error(`Failed to update Drive description: ${err || res.statusText}`);
  }
}

export async function deleteDriveFile(token: string, fileId: string): Promise<void> {
  // Move to trash
  const res = await fetch(
    `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?supportsAllDrives=true`,
    {
      method: "PATCH",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ trashed: true }),
    }
  );
  if (!res.ok) {
    const err = await res.text().catch(() => "");
    throw new Error(`Failed to delete Drive file: ${err || res.statusText}`);
  }
}

export async function createDriveFolder(
  token: string,
  name: string,
  parentId?: string | null
): Promise<GoogleDriveFolder> {
  const pId = parentId && parentId !== "root" ? parentId : "root";
  const body: Record<string, unknown> = {
    name,
    mimeType: "application/vnd.google-apps.folder",
  };
  if (pId !== "root") {
    body.parents = [pId];
  }

  const res = await fetch(
    "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true",
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    }
  );

  if (!res.ok) {
    const err = await res.text().catch(() => "");
    throw new Error(`Failed to create Drive folder: ${err || res.statusText}`);
  }
  return res.json();
}

export async function toggleDriveStar(
  token: string,
  fileId: string,
  starred: boolean
): Promise<void> {
  const res = await fetch(
    `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?supportsAllDrives=true`,
    {
      method: "PATCH",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ starred }),
    }
  );
  if (!res.ok) {
    throw new Error("Failed to star file");
  }
}

function formatBytes(bytes: number) {
  if (!bytes) return "—";
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), 3);
  return `${(bytes / 1024 ** i).toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}
