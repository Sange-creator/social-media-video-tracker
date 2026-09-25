import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, supabase } from "@/lib/server";

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    const rows = await supabase<Record<string, unknown>[]>(auth, "accessible_media?select=*&order=updated_at.desc&limit=100");
    return NextResponse.json(rows.map(mediaDTO));
  } catch (error) { return routeError(error); }
}
