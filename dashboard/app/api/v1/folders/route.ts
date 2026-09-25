import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, requireAuth, routeError, serviceSupabase } from "@/lib/server";

type Membership = { workspace_id: string; role: string };
type Connection = { id: string; encrypted_refresh_token: string };
type Grant = { id: string; drive_folder_id: string; folder_name: string; member_id: string | null };

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const memberships = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&select=workspace_id,role&limit=1`
    );
    const member = memberships[0];
    if (!member) return NextResponse.json({ error: "No workspace membership" }, { status: 404 });

    const grants = await serviceSupabase<Grant[]>(
      `folder_grants?workspace_id=eq.${member.workspace_id}&select=id,drive_folder_id,folder_name,member_id`
    );

    const parentId = request.nextUrl.searchParams.get("parentId");
    if (!parentId) {
      return NextResponse.json({
        workspaceId: member.workspace_id,
        role: member.role,
        grants: grants.map((g) => ({
          id: g.id,
          driveFolderId: g.drive_folder_id,
          name: g.folder_name,
        })),
      });
    }

    const connections = await serviceSupabase<Connection[]>(
      `drive_connections?workspace_id=eq.${member.workspace_id}&select=id,encrypted_refresh_token&limit=1`
    );
    const connection = connections[0];
    if (!connection) throw new Error("Drive connection is unavailable");

    const token = await googleAccessToken(connection.encrypted_refresh_token);
    const q = `'${parentId.replace(/'/g, "\\'")}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false`;
    const driveUrl = new URL("https://www.googleapis.com/drive/v3/files");
    driveUrl.searchParams.set("q", q);
    driveUrl.searchParams.set("fields", "files(id, name, mimeType, parents, modifiedTime)");
    driveUrl.searchParams.set("pageSize", "100");
    driveUrl.searchParams.set("supportsAllDrives", "true");
    driveUrl.searchParams.set("includeItemsFromAllDrives", "true");

    const driveRes = await fetch(driveUrl.toString(), {
      headers: { authorization: `Bearer ${token}` },
    });
    if (!driveRes.ok) throw new Error("Failed to list folders from Google Drive");
    const data = (await driveRes.json()) as { files: Array<{ id: string; name: string; modifiedTime: string }> };

    return NextResponse.json({
      parentId,
      folders: data.files.map((f) => ({
        id: f.id,
        name: f.name,
        modifiedAt: f.modifiedTime,
      })),
    });
  } catch (error) {
    return routeError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const body = (await request.json()) as { name?: string; parentFolderId?: string };
    if (!body.name || !body.name.trim() || !body.parentFolderId) {
      return NextResponse.json({ error: "Folder name and parentFolderId are required" }, { status: 400 });
    }

    const members = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&role=in.(owner,editor)&select=workspace_id,role&limit=1`
    );
    const member = members[0];
    if (!member) return NextResponse.json({ error: "Editor or owner role required to create folders" }, { status: 403 });

    const connections = await serviceSupabase<Connection[]>(
      `drive_connections?workspace_id=eq.${member.workspace_id}&select=id,encrypted_refresh_token&limit=1`
    );
    const connection = connections[0];
    if (!connection) throw new Error("Drive connection is unavailable");

    const token = await googleAccessToken(connection.encrypted_refresh_token);
    const driveRes = await fetch("https://www.googleapis.com/drive/v3/files?supportsAllDrives=true", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        name: body.name.trim(),
        mimeType: "application/vnd.google-apps.folder",
        parents: [body.parentFolderId],
      }),
    });

    if (!driveRes.ok) {
      const err = await driveRes.text();
      throw new Error(`Google Drive folder creation failed: ${err}`);
    }
    const created = (await driveRes.json()) as { id: string; name: string };

    await serviceSupabase("folder_grants", {
      method: "POST",
      headers: { prefer: "resolution=ignore-duplicates" },
      body: JSON.stringify({
        workspace_id: member.workspace_id,
        connection_id: connection.id,
        drive_folder_id: created.id,
        folder_name: created.name,
        member_id: null,
      }),
    });

    return NextResponse.json({ id: created.id, name: created.name }, { status: 201 });
  } catch (error) {
    return routeError(error);
  }
}
