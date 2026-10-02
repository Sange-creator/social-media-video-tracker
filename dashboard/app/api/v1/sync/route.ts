import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, supabase } from "@/lib/server";
import { readSyncPages } from "@/lib/syncPagination";

type SyncRow = Record<string, unknown> & { id: string; updated_at: string };

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const since = request.nextUrl.searchParams.get("since") ?? "1970-01-01T00:00:00Z";
    if (!Number.isFinite(Date.parse(since))) {
      return NextResponse.json({ error: "Invalid sync cursor" }, { status: 400 });
    }
    const nextCursor = new Date().toISOString();
    const read = (query: string) => supabase<SyncRow[]>(auth, query);
    const [mediaRows, assignments] = await Promise.all([
      readSyncPages("accessible_media", since, nextCursor, read),
      readSyncPages("assignments", since, nextCursor, read),
    ]);
    return NextResponse.json({ cursor: nextCursor, changes: mediaRows.map(mediaDTO), assignments });
  } catch (error) {
    return routeError(error);
  }
}
