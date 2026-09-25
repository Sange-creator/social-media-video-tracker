import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, routeError, serviceSupabase } from "@/lib/server";

type SyncJob = {
  id: string;
  connection_id: string;
  reason: string;
  state: string;
  attempts: number;
};

type Connection = {
  id: string;
  workspace_id: string;
  google_email: string;
  encrypted_refresh_token: string;
  change_cursor: string | null;
  watch_channel_id: string | null;
  watch_resource_id: string | null;
  watch_token: string | null;
  watch_expires_at: string | null;
};

export async function POST(request: NextRequest) {
  try {
    const cronSecret = process.env.CRON_SECRET;
    const authHeader = request.headers.get("authorization") || request.headers.get("x-cron-secret");
    if (cronSecret && authHeader !== `Bearer ${cronSecret}` && authHeader !== cronSecret) {
      return NextResponse.json({ error: "Unauthorized worker invocation" }, { status: 401 });
    }

    // 1. Fetch pending sync jobs bounded to 10 at a time
    const jobs = await serviceSupabase<SyncJob[]>(
      "sync_jobs?state=eq.pending&order=created_at.asc&limit=10"
    );

    let processedCount = 0;

    for (const job of jobs) {
      await serviceSupabase(`sync_jobs?id=eq.${job.id}`, {
        method: "PATCH",
        body: JSON.stringify({ state: "running", updated_at: new Date().toISOString() }),
      });

      try {
        const connections = await serviceSupabase<Connection[]>(
          `drive_connections?id=eq.${job.connection_id}&select=*&limit=1`
        );
        const connection = connections[0];
        if (!connection) {
          await serviceSupabase(`sync_jobs?id=eq.${job.id}`, {
            method: "PATCH",
            body: JSON.stringify({ state: "failed", last_error: "Connection not found" }),
          });
          continue;
        }

        const token = await googleAccessToken(connection.encrypted_refresh_token);

        // Fetch or initialize change cursor
        let cursor = connection.change_cursor;
        if (!cursor) {
          const startRes = await fetch(
            "https://www.googleapis.com/drive/v3/changes/startPageToken?supportsAllDrives=true",
            { headers: { authorization: `Bearer ${token}` } }
          );
          if (startRes.ok) {
            const startData = (await startRes.json()) as { startPageToken: string };
            cursor = startData.startPageToken;
          }
        }

        if (cursor) {
          const changesUrl = new URL("https://www.googleapis.com/drive/v3/changes");
          changesUrl.searchParams.set("pageToken", cursor);
          changesUrl.searchParams.set("supportsAllDrives", "true");
          changesUrl.searchParams.set("includeItemsFromAllDrives", "true");
          changesUrl.searchParams.set("pageSize", "100");
          changesUrl.searchParams.set(
            "fields",
            "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,size,parents,trashed,starred,modifiedTime))"
          );

          const changesRes = await fetch(changesUrl.toString(), {
            headers: { authorization: `Bearer ${token}` },
          });

          if (changesRes.ok) {
            const changesData = (await changesRes.json()) as {
              nextPageToken?: string;
              newStartPageToken?: string;
              changes?: Array<{
                fileId: string;
                removed?: boolean;
                file?: {
                  id: string;
                  name: string;
                  mimeType: string;
                  size?: string;
                  parents?: string[];
                  trashed?: boolean;
                  starred?: boolean;
                  modifiedTime?: string;
                };
              }>;
            };

            for (const change of changesData.changes ?? []) {
              if (change.removed || change.file?.trashed) {
                await serviceSupabase(
                  `media_items?workspace_id=eq.${connection.workspace_id}&drive_file_id=eq.${change.fileId}`,
                  {
                    method: "PATCH",
                    body: JSON.stringify({ trashed: true, updated_at: new Date().toISOString() }),
                  }
                );
              } else if (change.file) {
                const f = change.file;
                const isMedia = f.mimeType.startsWith("video/") || f.mimeType.startsWith("image/");
                if (isMedia) {
                  // Upsert media item preserving upload_text
                  const existing = await serviceSupabase<Array<{ id: string; upload_text: string }>>(
                    `media_items?workspace_id=eq.${connection.workspace_id}&drive_file_id=eq.${f.id}&select=id,upload_text&limit=1`
                  );

                  if (existing[0]) {
                    await serviceSupabase(`media_items?id=eq.${existing[0].id}`, {
                      method: "PATCH",
                      body: JSON.stringify({
                        name: f.name,
                        mime_type: f.mimeType,
                        size_bytes: f.size ? Number(f.size) : null,
                        folder_path: f.parents?.[0] ?? "My Drive",
                        starred: Boolean(f.starred),
                        trashed: Boolean(f.trashed),
                        drive_modified_at: f.modifiedTime ?? new Date().toISOString(),
                        updated_at: new Date().toISOString(),
                      }),
                    });
                  } else {
                    await serviceSupabase("media_items", {
                      method: "POST",
                      headers: { prefer: "resolution=ignore-duplicates" },
                      body: JSON.stringify({
                        workspace_id: connection.workspace_id,
                        drive_file_id: f.id,
                        name: f.name,
                        mime_type: f.mimeType,
                        size_bytes: f.size ? Number(f.size) : null,
                        folder_path: f.parents?.[0] ?? "My Drive",
                        starred: Boolean(f.starred),
                        trashed: false,
                        upload_text: "",
                        upload_text_revision: 0,
                        drive_modified_at: f.modifiedTime ?? new Date().toISOString(),
                      }),
                    });
                  }
                }
              }
            }

            const nextCursor = changesData.newStartPageToken || changesData.nextPageToken || cursor;
            await serviceSupabase(`drive_connections?id=eq.${connection.id}`, {
              method: "PATCH",
              body: JSON.stringify({
                change_cursor: nextCursor,
                updated_at: new Date().toISOString(),
              }),
            });
          }
        }

        // 2. Check and renew Drive watch channel if expiring within 24 hours
        const expiresAt = connection.watch_expires_at ? new Date(connection.watch_expires_at).getTime() : 0;
        const now = Date.now();
        const shouldRenew = !connection.watch_channel_id || expiresAt - now < 86_400_000;
        const appUrl = process.env.PUBLIC_APP_URL;

        if (shouldRenew && appUrl && cursor) {
          const channelId = `dt-${connection.id}-${Date.now()}`;
          const channelToken = crypto.randomUUID();
          const watchRes = await fetch(
            `https://www.googleapis.com/drive/v3/changes/watch?pageToken=${cursor}&supportsAllDrives=true`,
            {
              method: "POST",
              headers: {
                authorization: `Bearer ${token}`,
                "content-type": "application/json",
              },
              body: JSON.stringify({
                id: channelId,
                type: "web_hook",
                address: `${appUrl}/api/v1/google-drive/webhook`,
                token: channelToken,
              }),
            }
          );

          if (watchRes.ok) {
            const watchData = (await watchRes.json()) as { resourceId?: string; expiration?: string };
            const newExpiry = watchData.expiration ? new Date(Number(watchData.expiration)).toISOString() : null;
            await serviceSupabase(`drive_connections?id=eq.${connection.id}`, {
              method: "PATCH",
              body: JSON.stringify({
                watch_channel_id: channelId,
                watch_resource_id: watchData.resourceId ?? null,
                watch_token: channelToken,
                watch_expires_at: newExpiry,
                updated_at: new Date().toISOString(),
              }),
            });
          }
        }

        await serviceSupabase(`sync_jobs?id=eq.${job.id}`, {
          method: "PATCH",
          body: JSON.stringify({ state: "completed", updated_at: new Date().toISOString() }),
        });
        processedCount += 1;
      } catch (jobErr) {
        const errorMsg = jobErr instanceof Error ? jobErr.message : "Sync job error";
        await serviceSupabase(`sync_jobs?id=eq.${job.id}`, {
          method: "PATCH",
          body: JSON.stringify({
            state: job.attempts >= 3 ? "failed" : "pending",
            attempts: job.attempts + 1,
            last_error: errorMsg,
            updated_at: new Date().toISOString(),
          }),
        });
      }
    }

    return NextResponse.json({
      success: true,
      processedJobs: processedCount,
    });
  } catch (error) {
    return routeError(error);
  }
}
