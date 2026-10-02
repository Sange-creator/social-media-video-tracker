import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, routeError, serviceSupabase } from "@/lib/server";
import { scanDriveFolder } from "@/lib/driveScan";
import { affectedDriveRoots, driveStartToken, readDriveChanges } from "@/lib/driveChanges";

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
    if (!cronSecret || (authHeader !== `Bearer ${cronSecret}` && authHeader !== cronSecret)) {
      return NextResponse.json({ error: "Unauthorized worker invocation" }, { status: 401 });
    }

    await serviceSupabase("rpc/enqueue_drive_repairs", { method: "POST", body: "{}" });

    // 1. Fetch pending sync jobs bounded to 10 at a time
    const jobs = await serviceSupabase<SyncJob[]>(
      "sync_jobs?state=eq.pending&order=created_at.asc&limit=10"
    );

    let processedCount = 0;

    for (const job of jobs) {
      const claimed = await serviceSupabase<SyncJob[]>(`sync_jobs?id=eq.${job.id}&state=eq.pending&select=*`, {
        method: "PATCH",
        body: JSON.stringify({ state: "running", updated_at: new Date().toISOString() }),
      });
      if (!claimed.length) continue;

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

        const scanStartedAt = new Date().toISOString();
        const token = await googleAccessToken(connection.encrypted_refresh_token);

        // A full baseline is needed only for a new/expired cursor. Notifications
        // consume the change feed and scan only the corresponding granted trees.
        let baseline = !connection.change_cursor;
        let cursor: string;
        let changes: Awaited<ReturnType<typeof readDriveChanges>>["changes"] = [];
        if (baseline) cursor = await driveStartToken(token);
        else {
          try {
            const page = await readDriveChanges(token, connection.change_cursor!);
            changes = page.changes;
            cursor = page.cursor;
          } catch (error) {
            if (!(error instanceof Error) || !error.message.includes('(410)')) throw error;
            baseline = true;
            cursor = await driveStartToken(token);
          }
        }
        const grants = await serviceSupabase<Array<{ id: string; drive_folder_id: string; folder_name: string }>>(
          `folder_grants?connection_id=eq.${connection.id}&select=id,drive_folder_id,folder_name`
        );
        const affected = baseline ? new Set(grants.map(g => g.drive_folder_id))
          : await affectedDriveRoots(token, changes, new Set(grants.map(g => g.drive_folder_id)));
        // Include previous grants for a file moved out of a folder or removed.
        for (const change of changes) {
          if (!change.fileId) continue;
          const folders = await serviceSupabase<Array<{ grant_id: string }>>(
            `drive_folder_memberships?drive_folder_id=eq.${encodeURIComponent(change.fileId)}&select=grant_id`
          );
          for (const grant of grants) if (folders.some(p => p.grant_id === grant.id)) affected.add(grant.drive_folder_id);
          const paths = await serviceSupabase<Array<{ grant_id: string }>>(
            `media_access_paths?select=grant_id,media_items!inner(drive_file_id)&media_items.drive_file_id=eq.${encodeURIComponent(change.fileId)}`
          );
          for (const grant of grants) if (paths.some(p => p.grant_id === grant.id)) affected.add(grant.drive_folder_id);
        }
        for (const grant of grants) {
          if (!affected.has(grant.drive_folder_id)) continue;
          const folderIDs = new Set<string>();
          const files = await scanDriveFolder(token, grant.drive_folder_id, grant.folder_name, folderIDs);
          // The database atomically reconciles paths and metadata, preserving
          // independently edited upload text and avoiding unchanged writes.
          await serviceSupabase("rpc/reconcile_drive_grant", {
            method: "POST",
            body: JSON.stringify({ p_workspace_id: connection.workspace_id, p_grant_id: grant.id, p_files: files }),
          });
          await serviceSupabase("rpc/replace_drive_folder_memberships", {
            method: "POST", body: JSON.stringify({ p_grant_id: grant.id, p_folder_ids: [...folderIDs] }),
          });
        }
        await serviceSupabase(`drive_connections?id=eq.${connection.id}`, {
          method: "PATCH", body: JSON.stringify({ change_cursor: cursor, last_sync_at: scanStartedAt, updated_at: new Date().toISOString() }),
        });

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
