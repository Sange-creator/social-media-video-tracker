import crypto from "node:crypto";

const SECRET = process.env.ADMIN_SESSION_SECRET || "social-media-tracker-admin-auth-secret-key-2026";
const ADMIN_EMAIL = "admin@gmail.com";
const ADMIN_PASSWORD = "admin123";

export interface AdminPayload {
  userId: string;
  email: string;
  role: "admin";
  exp: number;
}

export function validateAdminCredentials(email?: string, pass?: string): boolean {
  if (!email || !pass) return false;
  return email.trim().toLowerCase() === ADMIN_EMAIL && pass.trim() === ADMIN_PASSWORD;
}

export function createAdminToken(userId = "admin-user", email = ADMIN_EMAIL): string {
  const payload: AdminPayload = {
    userId,
    email,
    role: "admin",
    exp: Date.now() + 30 * 24 * 60 * 60 * 1000, // 30 days
  };
  const json = JSON.stringify(payload);
  const b64 = Buffer.from(json, "utf-8").toString("base64url");
  const signature = crypto.createHmac("sha256", SECRET).update(b64).digest("hex");
  return `admin.${b64}.${signature}`;
}

export function verifyAdminToken(token: string): AdminPayload | null {
  if (!token.startsWith("admin.")) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [, b64, signature] = parts;
  if (!b64 || !signature) return null;

  const expectedSig = crypto.createHmac("sha256", SECRET).update(b64).digest("hex");
  try {
    const sigBuf = Buffer.from(signature, "hex");
    const expBuf = Buffer.from(expectedSig, "hex");
    if (sigBuf.length !== expBuf.length || !crypto.timingSafeEqual(sigBuf, expBuf)) {
      return null;
    }
    const decoded = JSON.parse(Buffer.from(b64, "base64url").toString("utf-8")) as AdminPayload;
    if (typeof decoded.exp === "number" && decoded.exp < Date.now()) {
      return null;
    }
    return decoded;
  } catch {
    return null;
  }
}
