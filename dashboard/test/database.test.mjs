import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
const owner='00000000-0000-4000-8000-000000000001', viewer='00000000-0000-4000-8000-000000000002', stranger='00000000-0000-4000-8000-000000000003';
const workspace='00000000-0000-4000-8000-000000000011', connection='00000000-0000-4000-8000-000000000021', grant='00000000-0000-4000-8000-000000000031', account='00000000-0000-4000-8000-000000000041';
let db;
test.before(async()=>{
  db=new PGlite({extensions:{pgcrypto}});
  await db.exec(`create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    create role anon; create role authenticated; create role service_role bypassrls; create publication supabase_realtime;`);
  for(const migration of ['001_connected_workspace.sql','002_sync_reliability.sql'])
    await db.exec(await readFile(new URL(`../supabase/migrations/${migration}`,import.meta.url),'utf8'));
  await db.exec(`grant usage on schema public,auth to authenticated; grant select,insert,update,delete on all tables in schema public to authenticated;
    grant usage,select on all sequences in schema public to authenticated;
    insert into auth.users values('${owner}'),('${viewer}'),('${stranger}');
    insert into public.workspaces(id,name,created_by) values('${workspace}','QA','${owner}');
    insert into public.workspace_members(workspace_id,user_id,role) values('${workspace}','${owner}','owner'),('${workspace}','${viewer}','viewer');
    insert into public.drive_connections(id,workspace_id,google_user_id,google_email,encrypted_refresh_token,created_by) values('${connection}','${workspace}','test','qa@example.test','test-token','${owner}');
    insert into public.folder_grants(id,workspace_id,connection_id,drive_folder_id,folder_name) values('${grant}','${workspace}','${connection}','test-folder','QA');
    insert into public.content_accounts(id,workspace_id,grant_id,name) values('${account}','${workspace}','${grant}','QA Account');`);
});
test.after(async()=>{await db?.close()});
test.afterEach(async()=>{await db.exec('reset role; reset request.jwt.claim.sub;')});
async function scan(files){await db.query('select public.reconcile_drive_grant($1,$2,$3::jsonb)',[workspace,grant,JSON.stringify(files)])}
async function asUser(user){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);await db.exec('set role authenticated')}
const file={id:'drive-video',name:'Video.mp4',mimeType:'video/mp4',size:'1024',folderPath:'QA',description:'Original caption'};
test('Complete scans create access paths, preserve edited text, and avoid unchanged writes',async()=>{
  await scan([file]);
  let row=(await db.query('select * from public.media_items')).rows[0];
  assert.equal(row.upload_text,'Original caption');
  assert.equal((await db.query('select count(*)::int as n from public.media_access_paths')).rows[0].n,1);
  await db.query("update public.media_items set upload_text='Workspace edit',upload_text_revision=4 where id=$1",[row.id]);
  row=(await db.query('select * from public.media_items')).rows[0];
  await scan([file]);
  const unchanged=(await db.query('select * from public.media_items')).rows[0];
  assert.equal(unchanged.upload_text,'Workspace edit');assert.equal(unchanged.upload_text_revision,4);
  assert.equal(unchanged.updated_at.getTime(),row.updated_at.getTime());
  await db.query('insert into public.assignments(account_id,media_id,day_key,slot) values($1,$2,current_date,1)',[account,row.id]);
});
test('Owner caption RPC works with member policies; viewer writes are denied',async()=>{
  const mediaID=(await db.query('select id from public.media_items')).rows[0].id;
  await asUser(owner);
  const result=await db.query('select * from public.update_media_upload_text($1,$2,$3)',[mediaID,'Saved\n#caption',4]);
  assert.equal(result.rows[0].upload_text_revision,5);assert.equal(result.rows[0].upload_text,'Saved\n#caption');
  await db.exec('reset role');await asUser(viewer);
  await assert.rejects(db.query('select * from public.update_media_upload_text($1,$2,$3)',[mediaID,'Unauthorized',5]));
});
test('Assignment updates have fresh timestamps and foreign users cannot see or edit them',async()=>{
  const before=(await db.query('select * from public.assignments')).rows[0];await asUser(owner);
  await db.query("update public.assignments set state='completed',completed_at=clock_timestamp() where id=$1",[before.id]);
  assert.ok((await db.query('select * from public.assignments')).rows[0].updated_at>before.updated_at);
  await db.exec('reset role');await asUser(stranger);
  assert.equal((await db.query('select * from public.assignments')).rows.length,0);
  assert.equal((await db.query("update public.assignments set state='assigned' returning id")).rows.length,0);
  assert.equal((await db.query("select has_function_privilege('authenticated','public.reconcile_drive_grant(uuid,uuid,jsonb)','execute') as allowed")).rows[0].allowed,false);
});
test('Assignments cannot be moved to another accessible grant',async()=>{
  const otherGrant='00000000-0000-4000-8000-000000000032';
  await db.query('insert into public.folder_grants(id,workspace_id,connection_id,drive_folder_id,folder_name) values($1,$2,$3,$4,$5)',[otherGrant,workspace,connection,'other-folder','Other']);
  await db.query('select public.reconcile_drive_grant($1,$2,$3::jsonb)',[workspace,otherGrant,JSON.stringify([{...file,id:'other-video'}])]);
  const mediaID=(await db.query("select id from public.media_items where drive_file_id='other-video'")).rows[0].id;
  await asUser(owner);
  await assert.rejects(db.query('update public.assignments set media_id=$1',[mediaID]));
  await db.exec('reset role');
  await db.query('select public.reconcile_drive_grant($1,$2,$3::jsonb)',[workspace,otherGrant,'[]']);
  await db.query("delete from public.media_items where drive_file_id='other-video'");
});
test('Repair queue coalesces jobs and remembers notifications during a running scan',async()=>{
  await db.query('select public.enqueue_drive_sync($1)',[connection]);await db.query('select public.enqueue_drive_sync($1)',[connection]);
  assert.equal((await db.query('select count(*)::int as n from public.sync_jobs')).rows[0].n,1);
  await db.exec("update public.sync_jobs set state='running';update public.drive_connections set last_sync_at=clock_timestamp()-interval '1 minute';");
  await db.query('select public.enqueue_drive_sync($1)',[connection]);
  await db.exec("update public.sync_jobs set state='completed';select public.enqueue_drive_repairs();");
  assert.equal((await db.query("select count(*)::int as n from public.sync_jobs where state='pending'")).rows[0].n,1);
});
test('Missing files lose live access paths while metadata and history remain',async()=>{
  await scan([]);
  assert.equal((await db.query('select count(*)::int as n from public.media_access_paths')).rows[0].n,0);
  assert.equal((await db.query('select count(*)::int as n from public.media_items')).rows[0].n,1);
  assert.equal((await db.query('select count(*)::int as n from public.assignments')).rows[0].n,1);
});
