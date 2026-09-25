import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, mediaDTO, requireAuth, routeError, serviceSupabase } from "@/lib/server";

type Membership = { workspace_id: string; role: string };
type Connection = { id: string; encrypted_refresh_token: string };
type MediaRow = {
  id: string;
  workspace_id: string;
  drive_file_id: string;
  name: string;
  folder_path: string;
  starred: boolean;
  trashed: boolean;
  upload_text: string;
};

export async function POST(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const body = (await request.json()) as {
      action: "rename" | "move" | "star" | "trash" | "copy";
      mediaId?: string;
      mediaIds?: string[];
      name?: string;
      destinationFolderId?: string;
      starred?: boolean;
      trashed?: boolean;
      copyUploadText?: boolean;
      idempotencyKey?: string;
    };

    const targetIds = body.mediaIds && body.mediaIds.length > 0 ? body.mediaIds : body.mediaId ? [body.mediaId] : [];
    if (targetIds.length === 0) {
      return NextResponse.json({ error: "At least one media ID is required" }, { status: 400 });
    }

    const members = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&role=in.(owner,editor)&select=workspace_id,role&limit=1`
    );
    const member = members[0];
    if (!member) {
      return NextResponse.json({ error: "Editor or owner role required for media operations" }, { status: 403 });
    }

    const connections = await serviceSupabase<Connection[]>(
      `drive_connections?workspace_id=eq.${member.workspace_id}&select=id,encrypted_refresh_token&limit=1`
    );
    const connection = connections[0];
    if (!connection) throw new Error("Drive connection is unavailable");
    const token = await googleAccessToken(connection.encrypted_refresh_token);

    const filterIds = targetIds.map((id) => `"${id}"`).join(",");
    const rows = await serviceSupabase<MediaRow[]>(
      `media_items?workspace_id=eq.${member.workspace_id}&id=in.(${filterIds})&select=*`
    );
    if (rows.length === 0) {
      return NextResponse.json({ error: "No matching media items found" }, { status: 404 });
    }

    const results: Record<string, unknown>[] = [];

    switch (body.action) {
      case "rename": {
        if (!body.name || !body.name.trim()) {
          return NextResponse.json({ error: "New name is required" }, { status: 400 });
        }
        const item = rows[0];
        const res = await fetch(`https://www.googleapis.com/drive/v3/files/${item.drive_file_id}?supportsAllDrives=true`, {
          method: "PATCH",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: JSON.stringify({ name: body.name.trim() }),
        });
        if (!res.ok) throw new Error("Failed to rename file in Google Drive");

        const updated = await serviceSupabase<Record<string, unknown>[]>(
          `media_items?id=eq.${item.id}&select=*`,
          {
            method: "PATCH",
            headers: { prefer: "return=representation" },
            body: JSON.stringify({ name: body.name.trim(), updated_at: new Date().toISOString() }),
          }
        );
        results.push(updated[0] ?? item);
        break;
      }

      case "star": {
        const isStarred = body.starred !== false;
        for (const item of rows) {
          const res = await fetch(`https://www.googleapis.com/drive/v3/files/${item.drive_file_id}?supportsAllDrives=true`, {
            method: "PATCH",
            headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
            body: JSON.stringify({ starred: isStarred }),
          });
          if (res.ok) {
            const updated = await serviceSupabase<Record<string, unknown>[]>(
              `media_items?id=eq.${item.id}&select=*`,
              {
                method: "PATCH",
                headers: { prefer: "return=representation" },
                body: JSON.stringify({ starred: isStarred, updated_at: new Date().toISOString() }),
              }
            );
            results.push(updated[0] ?? item);
          }
        }
        break;
      }

      case "trash": {
        const isTrashed = body.trashed !== false;
        for (const item of rows) {
          const res = await fetch(`https://www.googleapis.com/drive/v3/files/${item.drive_file_id}?supportsAllDrives=true`, {
            method: "PATCH",
            headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
            body: JSON.stringify({ trashed: isTrashed }),
          });
          if (res.ok) {
            const updated = await serviceSupabase<Record<string, unknown>[]>(
              `media_items?id=eq.${item.id}&select=*`,
              {
                method: "PATCH",
                headers: { prefer: "return=representation" },
                body: JSON.stringify({ trashed: isTrashed, updated_at: new Date().toISOString() }),
              }
            );
            results.push(updated[0] ?? item);
          }
        }
        break;
      }

      case "move": {
        if (!body.destinationFolderId) {
          return NextResponse.json({ error: "destinationFolderId is required to move files" }, { status: 400 });
        }
        for (const item of rows) {
          const fileInfoRes = await fetch(
            `https://www.googleapis.com/drive/v3/files/${item.drive_file_id}?fields=parents&supportsAllDrives=true`,
            { headers: { authorization: `Bearer ${token}` } }
          );
          const currentParents = fileInfoRes.ok
            ? ((await fileInfoRes.json()) as { parents?: string[] }).parents?.join(",") ?? ""
            : "";

          const moveUrl = new URL(`https://www.googleapis.com/drive/v3/files/${item.drive_file_id}`);
          moveUrl.searchParams.set("addParents", body.destinationFolderId);
          if (currentParents) moveUrl.searchParams.set("removeParents", currentParents);
          moveUrl.searchParams.set("supportsAllDrives", "true");

          const res = await fetch(moveUrl.toString(), {
            method: "PATCH",
            headers: { authorization: `Bearer ${token}` },
          });
          if (res.ok) {
            const updated = await serviceSupabase<Record<string, unknown>[]>(
              `media_items?id=eq.${item.id}&select=*`,
              {
                method: "PATCH",
                headers: { prefer: "return=representation" },
                body: JSON.stringify({
                  folder_path: body.destinationFolderId,
                  updated_at: new Date().toISOString(),
                }),
              }
            );
            results.push(updated[0] ?? item);
          }
        }
        break;
      }

      case "copy": {
        const item = rows[0];
        const copyPayload: Record<string, unknown> = {
          name: `Copy of ${item.name}`,
        };
        if (body.destinationFolderId) {
          copyPayload.parents = [body.destinationFolderId];
        }
        const res = await fetch(`https://www.googleapis.com/drive/v3/files/${item.drive_file_id}/copy?supportsAllDrives=true`, {
          method: "POST",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: JSON.stringify(copyPayload),
        });
        if (!res.ok) throw new Error("Failed to copy file in Google Drive");
        const copied = (await res.json()) as { id: string; name: string; mimeType: string; size?: string };

        const uploadText = body.copyUploadText ? item.upload_text : "";
        const created = await serviceSupabase<Record<string, unknown>[]>(
          "media_items",
          {
            method: "POST",
            headers: { prefer: "return=representation" },
            body: JSON.stringify({
              workspace_id: member.workspace_id,
              drive_file_id: copied.id,
              name: copied.name,
              mimeType: copied.mimeType ?? "video/mp4",
              size_bytes: copied.size ? Number(copied.size) : null,
              folder_path: body.destinationFolderId ?? item.folder_path,
              upload_text: uploadText,
              upload_text_revision: uploadText ? 1 : 0,
              upload_text_updated_by: uploadText ? auth.userId : null,
              upload_text_updated_at: uploadText ? new Date().toISOString() : null,
            }),
          }
        );
        results.push(created[0]);
        break;
      }

      default:
        return NextResponse.json({ error: "Invalid action" }, { status: 400 });
    }

    if (body.idempotencyKey) {
      await serviceSupabase("operation_log", {
        method: "POST",
        headers: { prefer: "resolution=ignore-duplicates" },
        body: JSON.stringify({
          workspace_id: member.workspace_id,
          actor_id: auth.userId,
          idempotency_key: body.idempotencyKey,
          operation: body.action,
          target_id: targetIds.join(","),
          detail: { count: results.length },
        }),
      });
    }

    return NextResponse.json({
      success: true,
      action: body.action,
      items: results.map(mediaDTO),
    });
  } catch (error) {
    return routeError(error);
  }
}
