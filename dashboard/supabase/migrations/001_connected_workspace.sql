create extension if not exists pgcrypto;

create type public.workspace_role as enum ('owner','editor','viewer');
create type public.upload_state as enum ('draft','uploading','uploaded','finalized','failed','cancelled');

create table public.workspaces (
  id uuid primary key default gen_random_uuid(), name text not null,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.workspace_role not null, created_at timestamptz not null default now(),
  primary key(workspace_id,user_id)
);
create table public.drive_connections (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  google_user_id text not null, google_email text not null, encrypted_refresh_token text not null,
  change_cursor text, watch_channel_id text, watch_resource_id text, watch_token text, watch_expires_at timestamptz,
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(workspace_id,google_user_id)
);
create table public.folder_grants (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  connection_id uuid not null references public.drive_connections(id) on delete cascade,
  drive_folder_id text not null, folder_name text not null, member_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(), unique(workspace_id,drive_folder_id,member_id)
);
create table public.media_items (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  drive_file_id text not null, name text not null, mime_type text not null, size_bytes bigint,
  folder_path text, drive_modified_at timestamptz, thumbnail_url text, resource_key text,
  starred boolean not null default false, trashed boolean not null default false, can_download boolean not null default true,
  upload_text text not null default '', upload_text_revision integer not null default 0,
  upload_text_updated_by uuid references auth.users(id), upload_text_updated_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(workspace_id,drive_file_id)
);
create table public.media_access_paths (
  media_id uuid not null references public.media_items(id) on delete cascade,
  grant_id uuid not null references public.folder_grants(id) on delete cascade,
  relative_path text not null default '', primary key(media_id,grant_id)
);
create table public.upload_text_revisions (
  id bigint generated always as identity primary key, media_id uuid not null references public.media_items(id) on delete cascade,
  revision integer not null, text text not null, edited_by uuid not null references auth.users(id), created_at timestamptz not null default now(),
  unique(media_id,revision)
);
create table public.content_accounts (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  grant_id uuid not null references public.folder_grants(id), name text not null, daily_quota integer not null default 3 check(daily_quota between 1 and 30),
  time_zone text not null default 'America/New_York', paused boolean not null default false, created_at timestamptz not null default now()
);
create table public.assignments (
  id uuid primary key default gen_random_uuid(), account_id uuid not null references public.content_accounts(id) on delete cascade,
  media_id uuid not null references public.media_items(id) on delete cascade, day_key date not null, slot integer not null,
  state text not null default 'assigned', assigned_at timestamptz not null default now(), completed_at timestamptz,
  unique(account_id,media_id,day_key)
);
create table public.upload_jobs (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  connection_id uuid not null references public.drive_connections(id), created_by uuid not null references auth.users(id),
  folder_id text not null, file_name text not null, mime_type text not null, size_bytes bigint not null,
  upload_text text not null default '', google_session_url text, drive_file_id text, state public.upload_state not null default 'draft',
  error_message text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.operation_log (
  id bigint generated always as identity primary key, workspace_id uuid not null references public.workspaces(id) on delete cascade,
  actor_id uuid references auth.users(id), idempotency_key text, operation text not null, target_id text, detail jsonb not null default '{}', created_at timestamptz not null default now(),
  unique(workspace_id,idempotency_key)
);
create table public.sync_jobs (
  id uuid primary key default gen_random_uuid(), connection_id uuid not null references public.drive_connections(id) on delete cascade,
  reason text not null, state text not null default 'pending', attempts integer not null default 0,
  run_after timestamptz not null default now(), last_error text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create unique index one_pending_sync_per_connection on public.sync_jobs(connection_id) where state in ('pending','running');
create table public.device_preferences (
  id uuid primary key default gen_random_uuid(), workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id), device_id text not null, visible_grant_ids uuid[] not null default '{}', sync_cursor timestamptz,
  updated_at timestamptz not null default now(), unique(workspace_id,user_id,device_id)
);

create or replace function public.can_read_workspace(target uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.workspace_members where workspace_id=target and user_id=auth.uid());
$$;
create or replace function public.can_edit_workspace(target uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.workspace_members where workspace_id=target and user_id=auth.uid() and role in ('owner','editor'));
$$;
create or replace view public.accessible_media with (security_invoker=true) as
  select distinct m.* from public.media_items m join public.media_access_paths p on p.media_id=m.id join public.folder_grants g on g.id=p.grant_id
  where public.can_read_workspace(m.workspace_id) and (g.member_id is null or g.member_id=auth.uid()) and not m.trashed;

create or replace function public.update_media_upload_text(p_media_id uuid,p_text text,p_expected_revision integer)
returns setof public.media_items language plpgsql security invoker as $$
declare current_row public.media_items; next_revision integer;
begin
  select * into current_row from public.media_items where id=p_media_id for update;
  if not found or not public.can_edit_workspace(current_row.workspace_id) then raise exception 'not authorized' using errcode='42501'; end if;
  if current_row.upload_text_revision<>p_expected_revision then raise exception 'revision conflict' using errcode='40001'; end if;
  next_revision:=current_row.upload_text_revision+1;
  insert into public.upload_text_revisions(media_id,revision,text,edited_by) values(p_media_id,next_revision,p_text,auth.uid());
  update public.media_items set upload_text=p_text,upload_text_revision=next_revision,upload_text_updated_by=auth.uid(),upload_text_updated_at=now(),updated_at=now() where id=p_media_id returning * into current_row;
  return next current_row;
end $$;

alter table public.workspaces enable row level security; alter table public.workspace_members enable row level security;
alter table public.drive_connections enable row level security; alter table public.folder_grants enable row level security;
alter table public.media_items enable row level security; alter table public.media_access_paths enable row level security;
alter table public.upload_text_revisions enable row level security; alter table public.content_accounts enable row level security;
alter table public.assignments enable row level security; alter table public.upload_jobs enable row level security;
alter table public.operation_log enable row level security; alter table public.device_preferences enable row level security;
alter table public.sync_jobs enable row level security;
create policy workspace_read on public.workspaces for select using(public.can_read_workspace(id));
create policy member_read on public.workspace_members for select using(public.can_read_workspace(workspace_id));
create policy media_read on public.media_items for select using(public.can_read_workspace(workspace_id));
create policy path_read on public.media_access_paths for select using(exists(select 1 from public.media_items m where m.id=media_id and public.can_read_workspace(m.workspace_id)));
create policy grant_read on public.folder_grants for select using(public.can_read_workspace(workspace_id) and (member_id is null or member_id=auth.uid()));
create policy revisions_read on public.upload_text_revisions for select using(exists(select 1 from public.media_items m where m.id=media_id and public.can_read_workspace(m.workspace_id)));
create policy device_own on public.device_preferences for all using(user_id=auth.uid()) with check(user_id=auth.uid());
alter publication supabase_realtime add table public.media_items,public.assignments,public.folder_grants;
