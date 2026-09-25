import { NextRequest, NextResponse } from "next/server";
import { requireAuth, routeError } from "@/lib/server";

export async function GET(request: NextRequest) {
  try {
    const auth = await requireAuth(request);
    return NextResponse.json({
      ok: true,
      user: {
        id: auth.userId,
        email: auth.email,
        role: auth.userId === "admin-user" ? "admin" : "member",
      },
    });
  } catch (error) {
    return routeError(error);
  }
}
