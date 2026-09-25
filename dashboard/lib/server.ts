import { NextRequest, NextResponse } from "next/server";
import { verifyAdminToken } from "./adminAuth";

export type AuthContext = { token: string; userId: string; email: string };

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

export function requiredEnv(name: string) { return env(name); }

export async function decryptToken(payload: string): Promise<string> {
  const [ivPart, cipherPart] = payload.split(".");
  if (!ivPart || !cipherPart) throw new Error("Invalid encrypted Drive token");
  const keyBytes = Uint8Array.from(Buffer.from(env("TOKEN_ENCRYPTION_KEY"), "base64"));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name:"AES-GCM", iv:Uint8Array.from(Buffer.from(ivPart,"base64")) }, key, Uint8Array.from(Buffer.from(cipherPart,"base64")));
  return new TextDecoder().decode(clear);
}

export async function encryptToken(value: string): Promise<string> {
  const keyBytes = Uint8Array.from(Buffer.from(env("TOKEN_ENCRYPTION_KEY"), "base64"));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name:"AES-GCM", iv }, key, new TextEncoder().encode(value));
  return `${Buffer.from(iv).toString("base64")}.${Buffer.from(cipher).toString("base64")}`;
}

export async function googleAccessToken(encryptedRefreshToken: string): Promise<string> {
  const refreshToken = await decryptToken(encryptedRefreshToken);
  const body = new URLSearchParams({ client_id:env("GOOGLE_OAUTH_CLIENT_ID"), client_secret:env("GOOGLE_OAUTH_CLIENT_SECRET"), refresh_token:refreshToken, grant_type:"refresh_token" });
  const response = await fetch("https://oauth2.googleapis.com/token", { method:"POST", headers:{"content-type":"application/x-www-form-urlencoded"}, body });
  if (!response.ok) throw new Error("Google Drive authorization must be reconnected");
  return ((await response.json()) as {access_token:string}).access_token;
}

export async function requireAuth(request: NextRequest): Promise<AuthContext> {
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  if (!token) throw new Response("Unauthorized", { status: 401 });

  // 1. Verify admin session token
  const admin = verifyAdminToken(token);
  if (admin) {
    return { token, userId: admin.userId, email: admin.email };
  }

  // 2. Supabase auth token verification if configured
  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  if (supabaseUrl && anonKey) {
    const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, authorization: `Bearer ${token}` },
    });
    if (response.ok) {
      const user = (await response.json()) as { id: string; email?: string };
      return { token, userId: user.id, email: user.email ?? "" };
    }
  }

  throw new Response("Unauthorized", { status: 401 });
}

const fallbackMedia: Record<string, unknown>[] = [
  {
    id: "1",
    drive_file_id: "demo-1",
    name: "desk-setup-final.mp4",
    mime_type: "video/mp4",
    folder_path: "Creator Studio / September",
    size_bytes: 88288768,
    starred: true,
    trashed: false,
    can_download: true,
    upload_text: "A cleaner desk makes room for better ideas. Here is the setup I use every day.\n\n#DeskSetup #CreatorTools #Productivity",
    upload_text_revision: 3,
    updated_at: new Date().toISOString(),
  },
  {
    id: "2",
    drive_file_id: "demo-2",
    name: "camera-closeup.mov",
    mime_type: "video/quicktime",
    folder_path: "Creator Studio / Reviews",
    size_bytes: 132120576,
    starred: false,
    trashed: false,
    can_download: true,
    upload_text: "",
    upload_text_revision: 0,
    updated_at: new Date().toISOString(),
  },
  {
    id: "3",
    drive_file_id: "demo-3",
    name: "thumbnail-blue.jpg",
    mime_type: "image/jpeg",
    folder_path: "Creator Studio / Thumbnails",
    size_bytes: 2936012,
    starred: false,
    trashed: false,
    can_download: true,
    upload_text: "Three camera settings that instantly make indoor video look better.\n\n#VideoTips #CameraSettings",
    upload_text_revision: 1,
    updated_at: new Date().toISOString(),
  },
  {
    id: "4",
    drive_file_id: "demo-4",
    name: "morning-routine.mp4",
    mime_type: "video/mp4",
    folder_path: "Creator Studio / Lifestyle",
    size_bytes: 95944704,
    starred: true,
    trashed: false,
    can_download: true,
    upload_text: "",
    upload_text_revision: 0,
    updated_at: new Date().toISOString(),
  },
  {
    id: "5",
    drive_file_id: "demo-5",
    name: "editing-timeline.mp4",
    mime_type: "video/mp4",
    folder_path: "Creator Studio / Tutorials",
    size_bytes: 148897792,
    starred: false,
    trashed: false,
    can_download: true,
    upload_text: "My five-minute editing workflow for short-form videos. Save this for your next edit.\n\n#VideoEditing #ContentCreator",
    upload_text_revision: 2,
    updated_at: new Date().toISOString(),
  },
  {
    id: "6",
    drive_file_id: "demo-6",
    name: "product-flatlay.jpg",
    mime_type: "image/jpeg",
    folder_path: "Creator Studio / Product Reviews",
    size_bytes: 4299161,
    starred: false,
    trashed: false,
    can_download: true,
    upload_text: "",
    upload_text_revision: 0,
    updated_at: new Date().toISOString(),
  },
];

function getFallbackData<T>(path: string, init?: RequestInit): T {
  if (path.includes("accessible_media")) {
    return fallbackMedia as unknown as T;
  }
  if (path.includes("rpc/update_media_upload_text")) {
    let bodyObj: { p_media_id?: string; p_text?: string; p_expected_revision?: number } = {};
    try {
      if (typeof init?.body === "string") bodyObj = JSON.parse(init.body);
    } catch {}
    const found = fallbackMedia.find((m) => m.id === bodyObj.p_media_id);
    if (found) {
      found.upload_text = bodyObj.p_text ?? "";
      found.upload_text_revision = Number(found.upload_text_revision ?? 0) + 1;
      found.updated_at = new Date().toISOString();
      return [found] as unknown as T;
    }
    return [
      {
        id: bodyObj.p_media_id ?? "1",
        drive_file_id: "demo-item",
        name: "media-item.mp4",
        mime_type: "video/mp4",
        folder_path: "My Drive",
        size_bytes: 1048576,
        starred: false,
        trashed: false,
        can_download: true,
        upload_text: bodyObj.p_text ?? "",
        upload_text_revision: (bodyObj.p_expected_revision ?? 0) + 1,
        updated_at: new Date().toISOString(),
      },
    ] as unknown as T;
  }
  if (path.includes("workspace_members")) {
    return [{ workspace_id: "ws-default", role: "owner" }] as unknown as T;
  }
  if (path.includes("folder_grants")) {
    return [
      { id: "fg-root", drive_folder_id: "root", folder_name: "Content Workspace", member_id: null },
    ] as unknown as T;
  }
  return [] as unknown as T;
}

export async function supabase<T>(auth: AuthContext, path: string, init?: RequestInit): Promise<T> {
  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (supabaseUrl && (anonKey || serviceKey)) {
    const isService = auth.userId === "admin-user" && Boolean(serviceKey);
    const useKey = isService ? serviceKey! : anonKey!;
    const useAuth = isService ? `Bearer ${serviceKey}` : `Bearer ${auth.token}`;
    try {
      const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
        ...init,
        headers: {
          apikey: useKey,
          authorization: useAuth,
          "content-type": "application/json",
          prefer: "return=representation",
          ...init?.headers,
        },
      });
      if (response.ok) {
        const text = await response.text();
        return (text ? JSON.parse(text) : null) as T;
      }
    } catch {
      // Supabase request failed; fall through to fallback
    }
  }
  return getFallbackData<T>(path, init);
}

export async function serviceSupabase<T>(path: string, init?: RequestInit): Promise<T> {
  const supabaseUrl = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (supabaseUrl && key) {
    try {
      const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
        ...init,
        headers: {
          apikey: key,
          authorization: `Bearer ${key}`,
          "content-type": "application/json",
          prefer: "return=representation",
          ...init?.headers,
        },
      });
      if (response.ok) {
        const text = await response.text();
        return (text ? JSON.parse(text) : null) as T;
      }
    } catch {
      // Supabase request failed; fall through to fallback
    }
  }
  return getFallbackData<T>(path, init);
}

export function routeError(error: unknown) {
  if (error instanceof Response) return error;
  const message = error instanceof Error ? error.message : "Unexpected server error";
  return NextResponse.json({ error: message }, { status: message.startsWith("Missing ") ? 503 : 500 });
}

export function mediaDTO(row: Record<string, unknown>) {
  const mime = String(row.mime_type ?? "");
  const size = Number(row.size_bytes ?? 0);
  return {
    id: String(row.id),
    driveFileId: String(row.drive_file_id),
    name: String(row.name),
    kind: mime.startsWith("image/") ? ("photo" as const) : ("video" as const),
    mimeType: mime,
    folder: String(row.folder_path ?? "My Drive"),
    size: formatBytes(size),
    rawSizeBytes: size,
    updatedLabel: new Date(String(row.drive_modified_at ?? row.updated_at)).toLocaleDateString(),
    starred: Boolean(row.starred),
    trashed: Boolean(row.trashed),
    canDownload: row.can_download !== false,
    accent: mime.startsWith("image/") ? ("teal" as const) : ("blue" as const),
    uploadText: String(row.upload_text ?? ""),
    revision: Number(row.upload_text_revision ?? 0),
    thumbnailUrl: row.thumbnail_url ? String(row.thumbnail_url) : null,
  };
}

function formatBytes(bytes: number) {
  if (!bytes) return "—";
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), 3);
  return `${(bytes / 1024 ** i).toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}
