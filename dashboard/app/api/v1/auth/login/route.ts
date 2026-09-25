import { NextRequest, NextResponse } from "next/server";
import { createAdminToken, validateAdminCredentials } from "@/lib/adminAuth";

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json().catch(() => ({}))) as {
      email?: string;
      password?: string;
    };

    const email = body.email?.trim() || "";
    const password = body.password || "";

    // 1. Check for admin credentials
    if (validateAdminCredentials(email, password)) {
      const token = createAdminToken("admin-user", "admin@gmail.com");
      return NextResponse.json({
        ok: true,
        token,
        user: {
          id: "admin-user",
          email: "admin@gmail.com",
          role: "admin",
          name: "Workspace Admin",
        },
      });
    }

    // 2. Fallback to Supabase password auth if configured
    const supabaseUrl = process.env.SUPABASE_URL;
    const anonKey = process.env.SUPABASE_ANON_KEY;
    if (supabaseUrl && anonKey) {
      const res = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=password`, {
        method: "POST",
        headers: {
          apikey: anonKey,
          "content-type": "application/json",
        },
        body: JSON.stringify({ email, password }),
      });
      if (res.ok) {
        const data = (await res.json()) as { access_token: string; user: { id: string; email?: string } };
        return NextResponse.json({
          ok: true,
          token: data.access_token,
          user: {
            id: data.user.id,
            email: data.user.email ?? email,
            role: "member",
            name: data.user.email ?? "Member",
          },
        });
      }
    }

    return NextResponse.json(
      {
        error: "Invalid email or password. Sign in with admin@gmail.com / admin123",
      },
      { status: 401 }
    );
  } catch (error) {
    const msg = error instanceof Error ? error.message : "Authentication error";
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
