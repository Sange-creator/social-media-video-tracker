"use client";

import { createClient, type Session } from "@supabase/supabase-js";
import { useEffect, useState } from "react";

const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

export const supabaseClient = url && key ? createClient(url, key) : null;

export type AppUser = {
  id: string;
  email?: string;
  role?: string;
  name?: string;
};

export type AppSession = {
  user: AppUser;
  access_token: string;
};

async function registerDrive(session: Session) {
  if (!session.provider_token || !session.provider_refresh_token) return;
  try {
    await fetch("/api/v1/drive-connections", {
      method: "POST",
      headers: {
        authorization: `Bearer ${session.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        providerToken: session.provider_token,
        providerRefreshToken: session.provider_refresh_token,
      }),
    });
  } catch {
    // Ignore drive registration error in local/preview
  }
}

function getStoredAdminSession(): AppSession | null {
  if (typeof window === "undefined") return null;
  const token = localStorage.getItem("admin_session_token");
  if (!token) return null;
  let user: AppUser = {
    id: "admin-user",
    email: "admin@gmail.com",
    role: "admin",
    name: "Workspace Admin",
  };
  const storedUser = localStorage.getItem("admin_session_user");
  if (storedUser) {
    try {
      user = JSON.parse(storedUser);
    } catch {}
  }
  return { user, access_token: token };
}

export function useSession() {
  const [session, setSession] = useState<AppSession | null>(() => getStoredAdminSession());

  useEffect(() => {
    // 1. Initial check for Supabase session or stored admin session
    if (supabaseClient) {
      supabaseClient.auth.getSession().then(({ data }) => {
        if (data.session) {
          setSession({
            user: {
              id: data.session.user.id,
              email: data.session.user.email ?? "",
            },
            access_token: data.session.access_token,
          });
          void registerDrive(data.session);
        } else {
          setSession(getStoredAdminSession());
        }
      });

      const { data: sub } = supabaseClient.auth.onAuthStateChange((_event, next) => {
        if (next) {
          setSession({
            user: { id: next.user.id, email: next.user.email ?? "" },
            access_token: next.access_token,
          });
          void registerDrive(next);
        } else {
          setSession(getStoredAdminSession());
        }
      });

      const handleCustomAuth = () => {
        setSession(getStoredAdminSession());
      };
      window.addEventListener("auth-state-change", handleCustomAuth);

      return () => {
        sub.subscription.unsubscribe();
        window.removeEventListener("auth-state-change", handleCustomAuth);
      };
    } else {
      setSession(getStoredAdminSession());
      const handleCustomAuth = () => {
        setSession(getStoredAdminSession());
      };
      window.addEventListener("auth-state-change", handleCustomAuth);
      return () => {
        window.removeEventListener("auth-state-change", handleCustomAuth);
      };
    }
  }, []);

  return session;
}

export async function signInAdmin(email: string, pass: string): Promise<AppSession> {
  const res = await fetch("/api/v1/auth/login", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password: pass }),
  });
  const data = (await res.json().catch(() => ({}))) as {
    ok?: boolean;
    token?: string;
    user?: AppUser;
    error?: string;
  };
  if (!res.ok || !data.ok || !data.token) {
    throw new Error(data.error || "Login failed");
  }

  const newSession: AppSession = {
    user: data.user || {
      id: "admin-user",
      email: email.trim().toLowerCase(),
      role: "admin",
      name: "Workspace Admin",
    },
    access_token: data.token,
  };

  if (typeof window !== "undefined") {
    localStorage.setItem("admin_session_token", data.token);
    localStorage.setItem("admin_session_user", JSON.stringify(newSession.user));
    window.dispatchEvent(new Event("auth-state-change"));
  }
  return newSession;
}

export async function signIn() {
  if (!supabaseClient) {
    throw new Error("Supabase is not configured yet. Sign in with admin@gmail.com / admin123 instead.");
  }
  await supabaseClient.auth.signInWithOAuth({
    provider: "google",
    options: {
      scopes: "https://www.googleapis.com/auth/drive",
      redirectTo: window.location.origin,
      queryParams: { access_type: "offline", prompt: "consent" },
    },
  });
}

export async function signOut() {
  if (typeof window !== "undefined") {
    localStorage.removeItem("admin_session_token");
    localStorage.removeItem("admin_session_user");
    window.dispatchEvent(new Event("auth-state-change"));
  }
  if (supabaseClient) {
    await supabaseClient.auth.signOut();
  }
}
