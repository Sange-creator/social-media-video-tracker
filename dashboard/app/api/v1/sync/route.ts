import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, supabase } from "@/lib/server";

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const since = request.nextUrl.searchParams.get("since") ?? "1970-01-01T00:00:00Z";
    const nextCursor = new Date().toISOString();

    const mediaRows = await supabase<Record<string, unknown>[]>(
      auth,
      `accessible_media?select=*&updated_at=gt.${encodeURIComponent(since)}&order=updated_at.asc&limit=1000`
    );

    const assignments = await supabase<Record<string, unknown>[]>(
      auth,
      `assignments?assigned_at=gt.${encodeURIComponent(since)}&order=assigned_at.asc&limit=500`
    ).catch(() => []);

    return NextResponse.json({
      cursor: nextCursor,
      changes: mediaRows.map(mediaDTO),
      assignments,
    });
  } catch (error) {
    return routeError(error);
  }
}
