-- Missed notifications need a change-feed check, not a full scan every five minutes.
create or replace function public.enqueue_drive_repairs()
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.sync_jobs set state='pending',updated_at=clock_timestamp(),attempts=attempts+1
    where state='running' and updated_at<clock_timestamp()-interval '15 minutes';
  insert into public.sync_jobs(connection_id,reason)
    select id,case when sync_requested_at>last_sync_at then 'drive-change' else 'periodic-change-check' end
    from public.drive_connections
    where last_sync_at is null or sync_requested_at>last_sync_at
      or last_sync_at<clock_timestamp()-interval '12 hours'
    on conflict do nothing;
end $$;

-- Remember nested folders, including empty ones, to route removals and moves.
create table public.drive_folder_memberships (
  grant_id uuid not null references public.folder_grants(id) on delete cascade,
  drive_folder_id text not null,
  primary key(grant_id,drive_folder_id)
);
alter table public.drive_folder_memberships enable row level security;
create function public.replace_drive_folder_memberships(p_grant_id uuid,p_folder_ids text[])
returns void language plpgsql security definer set search_path=public as $$
begin
  delete from public.drive_folder_memberships where grant_id=p_grant_id;
  insert into public.drive_folder_memberships(grant_id,drive_folder_id)
    select p_grant_id,unnest(p_folder_ids) on conflict do nothing;
end $$;
revoke all on function public.replace_drive_folder_memberships(uuid,text[]) from public,anon,authenticated;
grant execute on function public.replace_drive_folder_memberships(uuid,text[]) to service_role;
