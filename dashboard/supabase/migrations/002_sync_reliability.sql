-- Assignment edits must be discoverable after the original assignment date.
alter table public.assignments add column updated_at timestamptz not null default clock_timestamp();
create index assignments_sync_order on public.assignments(updated_at,id);
create index media_sync_order on public.media_items(updated_at,id);

create function public.set_sync_updated_at() returns trigger language plpgsql set search_path=public as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;
create trigger assignments_sync_updated before update on public.assignments
  for each row execute function public.set_sync_updated_at();
create trigger media_sync_updated before update on public.media_items
  for each row execute function public.set_sync_updated_at();

-- These tables had RLS enabled without policies, silently hiding assignment
-- changes and preventing the caption RPC from saving under a member's JWT.
create policy accounts_read on public.content_accounts for select using(
  public.can_read_workspace(workspace_id) and exists(
    select 1 from public.folder_grants g where g.id=grant_id
  )
);
create policy assignments_read on public.assignments for select using(
  exists(select 1 from public.content_accounts a where a.id=account_id)
);
create policy assignments_edit on public.assignments for update using(
  exists(select 1 from public.content_accounts a where a.id=account_id and public.can_edit_workspace(a.workspace_id))
) with check(
  exists(select 1 from public.content_accounts a
    join public.media_access_paths p on p.grant_id=a.grant_id
    join public.media_items m on m.id=p.media_id and m.workspace_id=a.workspace_id
    where a.id=assignments.account_id and p.media_id=assignments.media_id
      and public.can_edit_workspace(a.workspace_id))
);
create policy assignments_insert on public.assignments for insert with check(
  exists(select 1 from public.content_accounts a
    join public.media_access_paths p on p.grant_id=a.grant_id
    join public.media_items m on m.id=p.media_id and m.workspace_id=a.workspace_id
    where a.id=assignments.account_id and p.media_id=assignments.media_id
      and public.can_edit_workspace(a.workspace_id))
);
create policy media_edit on public.media_items for update using(public.can_edit_workspace(workspace_id))
  with check(public.can_edit_workspace(workspace_id));
create policy revisions_insert on public.upload_text_revisions for insert with check(
  edited_by=auth.uid() and exists(
    select 1 from public.media_items m where m.id=media_id and public.can_edit_workspace(m.workspace_id)
  )
);

-- A worker sees only explicitly granted folder trees. Reconcile each complete
-- scan in one transaction; upload text changes are preserved on conflict.
create function public.reconcile_drive_grant(p_workspace_id uuid,p_grant_id uuid,p_files jsonb)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.folder_grants where id=p_grant_id and workspace_id=p_workspace_id) then
    raise exception 'invalid folder grant';
  end if;
  insert into public.media_items(workspace_id,drive_file_id,name,mime_type,size_bytes,folder_path,drive_modified_at,
    thumbnail_url,resource_key,starred,trashed,can_download,upload_text,upload_text_revision)
  select p_workspace_id,f->>'id',f->>'name',f->>'mimeType',nullif(f->>'size','')::bigint,f->>'folderPath',
    nullif(f->>'modifiedTime','')::timestamptz,f->>'thumbnailLink',f->>'resourceKey',
    coalesce((f->>'starred')::boolean,false),false,coalesce((f->'capabilities'->>'canDownload')::boolean,true),
    coalesce(f->>'description',''),case when coalesce(f->>'description','')='' then 0 else 1 end
  from jsonb_array_elements(p_files) f
  on conflict(workspace_id,drive_file_id) do update set
    name=excluded.name,mime_type=excluded.mime_type,size_bytes=excluded.size_bytes,folder_path=excluded.folder_path,
    drive_modified_at=excluded.drive_modified_at,thumbnail_url=excluded.thumbnail_url,resource_key=excluded.resource_key,
    starred=excluded.starred,trashed=false,can_download=excluded.can_download
  where (media_items.name,media_items.mime_type,media_items.size_bytes,media_items.folder_path,media_items.drive_modified_at,
    media_items.thumbnail_url,media_items.resource_key,media_items.starred,media_items.trashed,media_items.can_download)
    is distinct from (excluded.name,excluded.mime_type,excluded.size_bytes,excluded.folder_path,excluded.drive_modified_at,
    excluded.thumbnail_url,excluded.resource_key,excluded.starred,false,excluded.can_download);

  delete from public.media_access_paths p where p.grant_id=p_grant_id and not exists(
    select 1 from public.media_items m,jsonb_array_elements(p_files) f where m.id=p.media_id and m.drive_file_id=f->>'id'
  );
  insert into public.media_access_paths(media_id,grant_id,relative_path)
  select m.id,p_grant_id,f->>'folderPath' from jsonb_array_elements(p_files) f
    join public.media_items m on m.workspace_id=p_workspace_id and m.drive_file_id=f->>'id'
  on conflict(media_id,grant_id) do update set relative_path=excluded.relative_path
    where media_access_paths.relative_path is distinct from excluded.relative_path;
end $$;
revoke all on function public.reconcile_drive_grant(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.reconcile_drive_grant(uuid,uuid,jsonb) to service_role;

alter table public.drive_connections add column last_sync_at timestamptz;
alter table public.drive_connections add column sync_requested_at timestamptz;
create function public.enqueue_drive_sync(p_connection_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  update public.drive_connections set sync_requested_at=clock_timestamp() where id=p_connection_id;
  insert into public.sync_jobs(connection_id,reason) values(p_connection_id,'drive-change') on conflict do nothing;
end $$;
create function public.enqueue_drive_repairs()
returns void language plpgsql security definer set search_path=public as $$
begin
  -- Recover workers interrupted before completing a job.
  update public.sync_jobs set state='pending',updated_at=clock_timestamp(),attempts=attempts+1
    where state='running' and updated_at<clock_timestamp()-interval '15 minutes';
  insert into public.sync_jobs(connection_id,reason)
    select id,'periodic-repair' from public.drive_connections
    where last_sync_at is null or sync_requested_at>last_sync_at or last_sync_at<clock_timestamp()-interval '5 minutes'
    on conflict do nothing;
end $$;
revoke all on function public.enqueue_drive_sync(uuid) from public,anon,authenticated;
revoke all on function public.enqueue_drive_repairs() from public,anon,authenticated;
grant execute on function public.enqueue_drive_sync(uuid) to service_role;
grant execute on function public.enqueue_drive_repairs() to service_role;
