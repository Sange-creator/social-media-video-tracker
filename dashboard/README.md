# Connected workspace dashboard

The dashboard is the computer interface for Social Media Video Tracker. It uploads original media into Google Drive and stores one complete upload-text block against the resulting Drive file ID.

## Local setup

1. Copy `.env.example` to `.env.local` and enter the Supabase, Google OAuth, and application URL values.
2. Run `supabase/migrations/001_connected_workspace.sql` in a new Supabase project.
3. Enable Google authentication in Supabase. Configure Google OAuth for offline Drive access and add the local and production callback URLs.
4. Generate a 32-byte `TOKEN_ENCRYPTION_KEY`; keep it and the service-role key server-only.
5. Run `npm install`, then `npm run dev`.

Without environment values, the dashboard opens in preview mode with local sample media. Mutations stay disabled at the API boundary.

## Cloudflare deployment

The Vinext build targets Cloudflare Workers/Pages. Run `npm run build`, configure the variables from `.env.example` in Cloudflare, and deploy the generated worker output. Set `PUBLIC_APP_URL` to the final HTTPS address before creating Drive notification channels.

For production, invoke `/api/v1/internal/sync` from a scheduled Worker and point Google Drive change channels to `/api/v1/google-drive/webhook`. Store `CRON_SECRET`, OAuth secrets, the Supabase service-role key, and the token encryption key as encrypted Cloudflare secrets.

## Security model

- Media bytes pass through resumable Drive upload sessions and are never stored in Supabase.
- Refresh tokens are encrypted before persistence.
- Database row-level security limits metadata and realtime records to workspace members and assigned folders.
- Every mutation rechecks workspace membership; Drive remains the final authority for file capabilities.
