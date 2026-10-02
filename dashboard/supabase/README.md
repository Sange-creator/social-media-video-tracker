# Supabase setup

1. Create a project and run migrations in order with the Supabase CLI or SQL editor.
2. Enable Google in Authentication and add the dashboard callback URL.
3. Add `http://localhost:3000` and the Cloudflare Pages URL to allowed redirect URLs.
4. Put public keys in the dashboard environment and keep the service-role key server-only.
5. Add the owner to `workspaces` and `workspace_members`; invitations should create memberships only after the invited email signs in.

The database stores metadata and upload text only. Original media remains in Google Drive.

Apply `migrations/002_sync_reliability.sql` after the initial schema before deploying the updated sync API. It adds assignment change timestamps and the missing member access policies.

Apply `migrations/003_folder_scoped_sync.sql` after migration 002 to store nested folder membership and reduce missed notification checks to twice daily.
