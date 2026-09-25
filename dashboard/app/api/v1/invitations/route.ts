import { NextRequest, NextResponse } from "next/server";
import { requireAuth, routeError, serviceSupabase } from "@/lib/server";

type Membership = { workspace_id: string; role: string; user_id: string };

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const members = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&select=workspace_id,role&limit=1`
    );
    const member = members[0];
    if (!member) return NextResponse.json({ error: "Access denied" }, { status: 403 });

    const allMembers = await serviceSupabase<Array<{ workspace_id: string; user_id: string; role: string; created_at: string }>>(
      `workspace_members?workspace_id=eq.${member.workspace_id}&select=*`
    );

    const grants = await serviceSupabase<Array<{ id: string; drive_folder_id: string; folder_name: string; member_id: string | null }>>(
      `folder_grants?workspace_id=eq.${member.workspace_id}&select=*`
    );

    return NextResponse.json({
      workspaceId: member.workspace_id,
      currentUserRole: member.role,
      members: allMembers,
      grants,
    });
  } catch (error) {
    return routeError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const body = (await request.json()) as {
      email?: string;
      role?: "editor" | "viewer";
      folderGrants?: string[];
      acceptToken?: string;
    };

    // If accepting an invitation token
    if (body.acceptToken) {
      const [workspaceId, role] = Buffer.from(body.acceptToken, "base64url").toString("utf-8").split(":");
      if (!workspaceId || !role) {
        return NextResponse.json({ error: "Invalid invitation link" }, { status: 400 });
      }

      await serviceSupabase("workspace_members", {
        method: "POST",
        headers: { prefer: "resolution=merge-duplicates" },
        body: JSON.stringify({
          workspace_id: workspaceId,
          user_id: auth.userId,
          role: role === "editor" ? "editor" : "viewer",
        }),
      });

      return NextResponse.json({ success: true, workspaceId, role });
    }

    // Creating an invitation requires owner role
    if (!body.email || !body.role) {
      return NextResponse.json({ error: "email and role are required" }, { status: 400 });
    }

    const owners = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&role=eq.owner&select=workspace_id,role&limit=1`
    );
    const owner = owners[0];
    if (!owner) return NextResponse.json({ error: "Only workspace owners can create invitations" }, { status: 403 });

    // Generate secure invitation token
    const payload = `${owner.workspace_id}:${body.role}:${body.email.trim().toLowerCase()}`;
    const token = Buffer.from(payload).toString("base64url");
    const appUrl = process.env.PUBLIC_APP_URL || "https://drivetracker.pages.dev";
    const inviteLink = `${appUrl}/invite?token=${token}`;

    return NextResponse.json({
      success: true,
      email: body.email,
      role: body.role,
      inviteLink,
      token,
    }, { status: 201 });
  } catch (error) {
    return routeError(error);
  }
}
