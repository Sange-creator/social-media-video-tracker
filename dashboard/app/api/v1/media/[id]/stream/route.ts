import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, requireAuth, routeError, serviceSupabase } from "@/lib/server";

type MediaRow = {
  id: string;
  workspace_id: string;
  drive_file_id: string;
  name: string;
  mime_type: string;
  size_bytes: number;
  can_download: boolean;
};

type Connection = { id: string; encrypted_refresh_token: string };

export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  try {
    const auth = await requireAuth(request);
    const { id } = await params;

    const rows = await serviceSupabase<MediaRow[]>(
      `media_items?id=eq.${id}&select=id,workspace_id,drive_file_id,name,mime_type,size_bytes,can_download&limit=1`
    );
    const item = rows[0];
    if (!item) return NextResponse.json({ error: "Media item not found" }, { status: 404 });

    const memberships = await serviceSupabase<{ workspace_id: string }[]>(
      `workspace_members?workspace_id=eq.${item.workspace_id}&user_id=eq.${auth.userId}&select=workspace_id&limit=1`
    );
    if (!memberships[0]) return NextResponse.json({ error: "Access denied" }, { status: 403 });

    const connections = await serviceSupabase<Connection[]>(
      `drive_connections?workspace_id=eq.${item.workspace_id}&select=id,encrypted_refresh_token&limit=1`
    );
    const connection = connections[0];
    if (!connection) throw new Error("Drive connection is unavailable");
    const token = await googleAccessToken(connection.encrypted_refresh_token);

    const range = request.headers.get("range");
    const googleHeaders: Record<string, string> = {
      authorization: `Bearer ${token}`,
    };
    if (range) {
      googleHeaders.Range = range;
    }

    const driveRes = await fetch(
      `https://www.googleapis.com/drive/v3/files/${item.drive_file_id}?alt=media&supportsAllDrives=true`,
      {
        headers: googleHeaders,
      }
    );

    if (!driveRes.ok && driveRes.status !== 206) {
      return NextResponse.json(
        { error: "Google Drive media fetch failed" },
        { status: driveRes.status }
      );
    }

    const responseHeaders = new Headers();
    responseHeaders.set("Content-Type", driveRes.headers.get("Content-Type") || item.mime_type || "application/octet-stream");
    responseHeaders.set("Accept-Ranges", "bytes");

    const contentRange = driveRes.headers.get("Content-Range");
    if (contentRange) responseHeaders.set("Content-Range", contentRange);

    const contentLength = driveRes.headers.get("Content-Length");
    if (contentLength) responseHeaders.set("Content-Length", contentLength);

    const isDownload = request.nextUrl.searchParams.get("download") === "1";
    if (isDownload) {
      responseHeaders.set("Content-Disposition", `attachment; filename="${encodeURIComponent(item.name)}"`);
    } else {
      responseHeaders.set("Content-Disposition", `inline; filename="${encodeURIComponent(item.name)}"`);
    }

    return new NextResponse(driveRes.body, {
      status: driveRes.status,
      headers: responseHeaders,
    });
  } catch (error) {
    return routeError(error);
  }
}
