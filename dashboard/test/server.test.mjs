import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";

// Test mediaDTO formatting logic
function formatBytes(bytes) {
  if (!bytes) return "—";
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), 3);
  return `${(bytes / 1024 ** i).toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
}

function mediaDTO(row) {
  const mime = String(row.mime_type ?? "");
  const size = Number(row.size_bytes ?? 0);
  return {
    id: String(row.id),
    driveFileId: String(row.drive_file_id),
    name: String(row.name),
    kind: mime.startsWith("image/") ? "photo" : "video",
    mimeType: mime,
    folder: String(row.folder_path ?? "My Drive"),
    size: formatBytes(size),
    rawSizeBytes: size,
    updatedLabel: new Date(String(row.drive_modified_at ?? row.updated_at)).toLocaleDateString(),
    starred: Boolean(row.starred),
    trashed: Boolean(row.trashed),
    canDownload: row.can_download !== false,
    accent: mime.startsWith("image/") ? "teal" : "blue",
    uploadText: String(row.upload_text ?? ""),
    revision: Number(row.upload_text_revision ?? 0),
    thumbnailUrl: row.thumbnail_url ? String(row.thumbnail_url) : null,
  };
}

test("formatBytes formats correctly across orders of magnitude", () => {
  assert.equal(formatBytes(0), "—");
  assert.equal(formatBytes(null), "—");
  assert.equal(formatBytes(undefined), "—");
  assert.equal(formatBytes(500), "500 B");
  assert.equal(formatBytes(1024), "1 KB");
  assert.equal(formatBytes(1536), "2 KB");
  assert.equal(formatBytes(1048576), "1.0 MB");
  assert.equal(formatBytes(52428800), "50.0 MB");
  assert.equal(formatBytes(1073741824), "1.0 GB");
});

test("mediaDTO correctly differentiates video vs photo", () => {
  const videoRow = {
    id: "vid-1",
    drive_file_id: "drive-vid-1",
    name: "reel_final.mp4",
    mime_type: "video/mp4",
    size_bytes: 45000000,
    folder_path: "TikTok/Account1",
    starred: false,
    trashed: false,
    can_download: true,
    upload_text: "Epic clip! #viral",
    upload_text_revision: 2,
    updated_at: "2026-09-25T12:00:00Z",
  };

  const videoDto = mediaDTO(videoRow);
  assert.equal(videoDto.kind, "video");
  assert.equal(videoDto.accent, "blue");
  assert.equal(videoDto.size, "42.9 MB");
  assert.equal(videoDto.uploadText, "Epic clip! #viral");
  assert.equal(videoDto.revision, 2);
  assert.equal(videoDto.starred, false);
  assert.equal(videoDto.trashed, false);

  const photoRow = {
    id: "img-1",
    drive_file_id: "drive-img-1",
    name: "cover.jpg",
    mime_type: "image/jpeg",
    size_bytes: 2048000,
    starred: true,
    trashed: false,
    upload_text: "Thumbnail photo",
    upload_text_revision: 1,
    updated_at: "2026-09-25T12:00:00Z",
  };

  const photoDto = mediaDTO(photoRow);
  assert.equal(photoDto.kind, "photo");
  assert.equal(photoDto.accent, "teal");
  assert.equal(photoDto.size, "2.0 MB");
  assert.equal(photoDto.starred, true);
  assert.equal(photoDto.folder, "My Drive");
});

test("mediaDTO handles missing fields and defaults gracefully", () => {
  const minimal = {
    id: "min-1",
    drive_file_id: "drv-min",
    name: "unnamed",
    updated_at: "2026-01-01T00:00:00Z",
  };

  const dto = mediaDTO(minimal);
  assert.equal(dto.kind, "video");
  assert.equal(dto.accent, "blue");
  assert.equal(dto.size, "—");
  assert.equal(dto.uploadText, "");
  assert.equal(dto.revision, 0);
  assert.equal(dto.starred, false);
  assert.equal(dto.trashed, false);
  assert.equal(dto.canDownload, true);
  assert.equal(dto.thumbnailUrl, null);
});

// Test AES-GCM token encryption and decryption
const sampleKey = crypto.randomBytes(32).toString("base64");

async function encryptToken(value, base64Key) {
  const keyBytes = Uint8Array.from(Buffer.from(base64Key, "base64"));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const cipher = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value));
  return `${Buffer.from(iv).toString("base64")}.${Buffer.from(cipher).toString("base64")}`;
}

async function decryptToken(payload, base64Key) {
  const [ivPart, cipherPart] = payload.split(".");
  if (!ivPart || !cipherPart) throw new Error("Invalid encrypted Drive token");
  const keyBytes = Uint8Array.from(Buffer.from(base64Key, "base64"));
  const key = await crypto.subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: Uint8Array.from(Buffer.from(ivPart, "base64")) },
    key,
    Uint8Array.from(Buffer.from(cipherPart, "base64"))
  );
  return new TextDecoder().decode(clear);
}

test("encryptToken and decryptToken round-trip securely", async () => {
  const secretRefreshToken = "1//04abcdefgh123456_REFRESH_TOKEN_SAMPLE";
  const encrypted = await encryptToken(secretRefreshToken, sampleKey);

  assert.notEqual(encrypted, secretRefreshToken);
  assert(encrypted.includes("."));

  const decrypted = await decryptToken(encrypted, sampleKey);
  assert.equal(decrypted, secretRefreshToken);
});

test("decryptToken rejects malformed or tampered payloads", async () => {
  await assert.rejects(async () => {
    await decryptToken("not-a-valid-token", sampleKey);
  }, /Invalid encrypted Drive token/);

  const encrypted = await encryptToken("valid-token", sampleKey);
  const tampered = encrypted.slice(0, -4) + "AAAA";
  await assert.rejects(async () => {
    await decryptToken(tampered, sampleKey);
  });
});

test("admin authentication generates and verifies valid tokens", () => {
  const secret = "test-secret-key-12345";
  const payload = { userId: "admin-user", email: "admin@gmail.com", exp: Date.now() + 60000 };
  const b64 = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const sig = crypto.createHmac("sha256", secret).update(b64).digest("hex");
  const token = `admin.${b64}.${sig}`;

  // Verify signature
  const [, extractedB64, extractedSig] = token.split(".");
  const expectedSig = crypto.createHmac("sha256", secret).update(extractedB64).digest("hex");
  assert.equal(extractedSig, expectedSig);

  const decoded = JSON.parse(Buffer.from(extractedB64, "base64url").toString());
  assert.equal(decoded.email, "admin@gmail.com");
  assert.equal(decoded.userId, "admin-user");

  // Tampered token fails
  const tamperedToken = `admin.${b64}.ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff`;
  const [, , badSig] = tamperedToken.split(".");
  assert.notEqual(badSig, expectedSig);
});

