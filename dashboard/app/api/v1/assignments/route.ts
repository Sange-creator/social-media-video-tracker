import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, serviceSupabase } from "@/lib/server";

type Membership = { workspace_id: string; role: string };
type ContentAccountRow = {
  id: string;
  workspace_id: string;
  grant_id: string;
  name: string;
  daily_quota: number;
  time_zone: string;
  paused: boolean;
};

type AssignmentRow = {
  id: string;
  account_id: string;
  media_id: string;
  day_key: string;
  slot: number;
  state: string;
  assigned_at: string;
  completed_at: string | null;
};

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const memberships = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&select=workspace_id,role&limit=1`
    );
    const member = memberships[0];
    if (!member) return NextResponse.json({ error: "Access denied" }, { status: 403 });

    const accountId = request.nextUrl.searchParams.get("accountId");
    const today = new Date().toISOString().split("T")[0];
    const dayKey = request.nextUrl.searchParams.get("dayKey") || today;

    const accountQuery = accountId
      ? `content_accounts?workspace_id=eq.${member.workspace_id}&id=eq.${accountId}&select=*`
      : `content_accounts?workspace_id=eq.${member.workspace_id}&paused=eq.false&select=*`;
    const accounts = await serviceSupabase<ContentAccountRow[]>(accountQuery);

    const results: Array<{
      account: ContentAccountRow;
      assignments: Array<AssignmentRow & { media: ReturnType<typeof mediaDTO> | null }>;
    }> = [];

    for (const acc of accounts) {
      let assignments = await serviceSupabase<AssignmentRow[]>(
        `assignments?account_id=eq.${acc.id}&day_key=eq.${dayKey}&order=slot.asc&select=*`
      );

      // If no assignments for today, transactionally generate them from available videos in this account's grant
      if (assignments.length === 0 && !acc.paused) {
        const availableMedia = await serviceSupabase<Record<string, unknown>[]>(
          `accessible_media?select=*&mime_type=like.video%25&order=updated_at.desc&limit=50`
        );

        // Filter out media already completed in previous days for this account
        const previousAssignments = await serviceSupabase<{ media_id: string }[]>(
          `assignments?account_id=eq.${acc.id}&state=eq.completed&select=media_id`
        );
        const usedMediaIds = new Set(previousAssignments.map((p) => p.media_id));
        const eligible = availableMedia.filter((m) => !usedMediaIds.has(String(m.id))).slice(0, acc.daily_quota);

        const newRows = eligible.map((m, idx) => ({
          account_id: acc.id,
          media_id: m.id,
          day_key: dayKey,
          slot: idx + 1,
          state: "assigned",
        }));

        if (newRows.length > 0) {
          assignments = await serviceSupabase<AssignmentRow[]>("assignments", {
            method: "POST",
            headers: { prefer: "return=representation" },
            body: JSON.stringify(newRows),
          });
        }
      }

      // Attach media details
      const mediaIds = assignments.map((a) => `"${a.media_id}"`).join(",");
      const mediaMap = new Map<string, ReturnType<typeof mediaDTO>>();
      if (mediaIds.length > 0) {
        const mediaItems = await serviceSupabase<Record<string, unknown>[]>(
          `media_items?id=in.(${mediaIds})&select=*`
        );
        for (const item of mediaItems) {
          mediaMap.set(String(item.id), mediaDTO(item));
        }
      }

      results.push({
        account: acc,
        assignments: assignments.map((a) => ({
          ...a,
          media: mediaMap.get(a.media_id) ?? null,
        })),
      });
    }

    return NextResponse.json({ dayKey, accounts: results });
  } catch (error) {
    return routeError(error);
  }
}

export async function POST(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const body = (await request.json()) as {
      assignmentId?: string;
      accountId?: string;
      mediaId?: string;
      completed?: boolean;
      action?: "complete" | "replace";
    };

    const members = await serviceSupabase<Membership[]>(
      `workspace_members?user_id=eq.${auth.userId}&select=workspace_id,role&limit=1`
    );
    const member = members[0];
    if (!member) return NextResponse.json({ error: "Access denied" }, { status: 403 });

    if (body.action === "replace" && body.assignmentId) {
      const existing = await serviceSupabase<AssignmentRow[]>(
        `assignments?id=eq.${body.assignmentId}&select=*&limit=1`
      );
      if (!existing[0]) return NextResponse.json({ error: "Assignment not found" }, { status: 404 });
      const current = existing[0];

      // Find an unused replacement candidate
      const assignedMedia = await serviceSupabase<{ media_id: string }[]>(
        `assignments?account_id=eq.${current.account_id}&select=media_id`
      );
      const assignedIds = new Set(assignedMedia.map((a) => a.media_id));

      const candidates = await serviceSupabase<Record<string, unknown>[]>(
        `accessible_media?select=*&mime_type=like.video%25&order=updated_at.desc&limit=50`
      );
      const replacement = candidates.find((c) => !assignedIds.has(String(c.id)));
      if (!replacement) return NextResponse.json({ error: "No available replacement video found" }, { status: 409 });

      const updated = await serviceSupabase<AssignmentRow[]>(
        `assignments?id=eq.${current.id}&select=*`,
        {
          method: "PATCH",
          headers: { prefer: "return=representation" },
          body: JSON.stringify({
            media_id: replacement.id,
            state: "assigned",
            assigned_at: new Date().toISOString(),
          }),
        }
      );

      return NextResponse.json({
        success: true,
        assignment: updated[0],
        media: mediaDTO(replacement),
      });
    }

    // Default action: toggle completion
    const isCompleted = body.completed !== false;
    let assignment: AssignmentRow | null = null;

    if (body.assignmentId) {
      const updated = await serviceSupabase<AssignmentRow[]>(
        `assignments?id=eq.${body.assignmentId}&select=*`,
        {
          method: "PATCH",
          headers: { prefer: "return=representation" },
          body: JSON.stringify({
            state: isCompleted ? "completed" : "assigned",
            completed_at: isCompleted ? new Date().toISOString() : null,
          }),
        }
      );
      assignment = updated[0] ?? null;
    } else if (body.accountId && body.mediaId) {
      const today = new Date().toISOString().split("T")[0];
      const updated = await serviceSupabase<AssignmentRow[]>(
        `assignments?account_id=eq.${body.accountId}&media_id=eq.${body.mediaId}&day_key=eq.${today}&select=*`,
        {
          method: "PATCH",
          headers: { prefer: "return=representation" },
          body: JSON.stringify({
            state: isCompleted ? "completed" : "assigned",
            completed_at: isCompleted ? new Date().toISOString() : null,
          }),
        }
      );
      assignment = updated[0] ?? null;
    }

    if (!assignment) {
      return NextResponse.json({ error: "Assignment not found to update" }, { status: 404 });
    }

    return NextResponse.json({ success: true, assignment });
  } catch (error) {
    return routeError(error);
  }
}
