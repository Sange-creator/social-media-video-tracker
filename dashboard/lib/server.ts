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

export async function supabase<T>(auth: AuthContext, path: string, init?: RequestInit): Promise<T> {
  const supabaseUrl = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl) throw new Error("Missing SUPABASE_URL");
  const isService = auth.userId === "admin-user" && Boolean(serviceKey);
  const useKey = isService ? serviceKey : anonKey;
  if (!useKey) throw new Error("Missing Supabase API key");
  return databaseRequest<T>(supabaseUrl, useKey, isService ? useKey : auth.token, path, init);
}

export async function serviceSupabase<T>(path: string, init?: RequestInit): Promise<T> {
  return databaseRequest<T>(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), env("SUPABASE_SERVICE_ROLE_KEY"), path, init);
}

async function databaseRequest<T>(url: string, key: string, token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${url}/rest/v1/${path}`, {
    ...init,
    cache: "no-store",
    headers: {
      apikey: key,
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      prefer: "return=representation",
      ...init?.headers,
    },
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({})) as { code?: string };
    const status = body.code === "40001" ? 409 : response.status;
    throw new Response(JSON.stringify({ error: status === 409 ? "Upload text changed elsewhere. Refresh before saving again." : "Database request failed." }), {
      status, headers: { "content-type": "application/json" },
    });
  }
  const text = await response.text();
  return (text ? JSON.parse(text) : null) as T;
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
