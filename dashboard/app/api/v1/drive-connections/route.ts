import { NextRequest, NextResponse } from "next/server";
import { encryptToken, requireAuth, routeError, serviceSupabase } from "@/lib/server";

export async function POST(request:NextRequest){try{
  const auth=await requireAuth(request); const body=await request.json() as {providerToken?:string;providerRefreshToken?:string};
  if(!body.providerToken||!body.providerRefreshToken)return NextResponse.json({error:"Google Drive must be reconnected with offline access"},{status:400});
  const profileResponse=await fetch("https://www.googleapis.com/oauth2/v3/userinfo",{headers:{authorization:`Bearer ${body.providerToken}`}}); if(!profileResponse.ok)return NextResponse.json({error:"Google authorization is invalid"},{status:401});
  const profile=await profileResponse.json() as {sub:string;email:string};
  const rootResponse=await fetch("https://www.googleapis.com/drive/v3/files/root?fields=id,name",{headers:{authorization:`Bearer ${body.providerToken}`}}); if(!rootResponse.ok)return NextResponse.json({error:"Google Drive root is unavailable"},{status:400}); const root=await rootResponse.json() as {id:string;name:string};
  let memberships=await serviceSupabase<{workspace_id:string}[]>(`workspace_members?user_id=eq.${auth.userId}&select=workspace_id&limit=1`);
  if(!memberships[0]){const workspaces=await serviceSupabase<{id:string}[]>("workspaces",{method:"POST",body:JSON.stringify({name:"Content Workspace",created_by:auth.userId})});await serviceSupabase("workspace_members",{method:"POST",body:JSON.stringify({workspace_id:workspaces[0].id,user_id:auth.userId,role:"owner"})});memberships=[{workspace_id:workspaces[0].id}]}
  const encrypted=await encryptToken(body.providerRefreshToken); const connections=await serviceSupabase<{id:string}[]>("drive_connections?on_conflict=workspace_id,google_user_id",{method:"POST",headers:{prefer:"resolution=merge-duplicates,return=representation"},body:JSON.stringify({workspace_id:memberships[0].workspace_id,google_user_id:profile.sub,google_email:profile.email,encrypted_refresh_token:encrypted,created_by:auth.userId,updated_at:new Date().toISOString()})});
  await serviceSupabase("folder_grants?on_conflict=workspace_id,drive_folder_id,member_id",{method:"POST",headers:{prefer:"resolution=ignore-duplicates"},body:JSON.stringify({workspace_id:memberships[0].workspace_id,connection_id:connections[0].id,drive_folder_id:root.id,folder_name:"My Drive",member_id:auth.userId})});
  return NextResponse.json({workspaceId:memberships[0].workspace_id,connectionId:connections[0].id});
}catch(error){return routeError(error)}}
