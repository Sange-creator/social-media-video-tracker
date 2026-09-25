import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, supabase } from "@/lib/server";

export async function PUT(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  try {
    const auth = await requireAuth(request); const { id } = await params;
    const body = await request.json() as { text?: string; expectedRevision?: number };
    if (typeof body.text !== "string" || body.text.length > 50_000) return NextResponse.json({error:"Upload text must be 50,000 characters or fewer."},{status:400});
    const rows = await supabase<Record<string, unknown>[]>(auth, "rpc/update_media_upload_text", { method:"POST", body:JSON.stringify({p_media_id:id,p_text:body.text,p_expected_revision:body.expectedRevision??0}) });
    return NextResponse.json(mediaDTO(rows[0]));
  } catch (error) { return routeError(error); }
}
