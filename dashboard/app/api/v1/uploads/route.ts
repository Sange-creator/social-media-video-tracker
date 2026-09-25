import { NextRequest, NextResponse } from "next/server";
import { googleAccessToken, requireAuth, routeError, serviceSupabase } from "@/lib/server";

type Membership={workspace_id:string}; type Grant={id:string;drive_folder_id:string;connection_id:string}; type Connection={id:string;encrypted_refresh_token:string};
export async function POST(request:NextRequest){try{
  const auth=await requireAuth(request); const body=await request.json() as {name:string;size:number;mimeType:string;folderId?:string;uploadText?:string};
  if(!body.name||!body.mimeType||!Number.isFinite(body.size)||body.size<=0)return NextResponse.json({error:"Invalid upload metadata"},{status:400});
  const members=await serviceSupabase<Membership[]>(`workspace_members?user_id=eq.${auth.userId}&role=in.(owner,editor)&select=workspace_id&limit=1`); if(!members[0])return NextResponse.json({error:"Editor access required"},{status:403});
  const grants=await serviceSupabase<Grant[]>(`folder_grants?workspace_id=eq.${members[0].workspace_id}&select=id,drive_folder_id,connection_id&limit=1`); if(!grants[0])return NextResponse.json({error:"Connect a destination Drive folder first"},{status:409});
  const connections=await serviceSupabase<Connection[]>(`drive_connections?id=eq.${grants[0].connection_id}&select=id,encrypted_refresh_token&limit=1`); const connection=connections[0]; if(!connection)throw new Error("Drive connection is unavailable");
  const token=await googleAccessToken(connection.encrypted_refresh_token); const metadata={name:body.name,parents:[grants[0].drive_folder_id],mimeType:body.mimeType};
  const google=await fetch("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true",{method:"POST",headers:{authorization:`Bearer ${token}`,"content-type":"application/json","x-upload-content-type":body.mimeType,"x-upload-content-length":String(body.size)},body:JSON.stringify(metadata)});
  const session=google.headers.get("location"); if(!google.ok||!session)throw new Error("Google Drive did not create an upload session");
  const rows=await serviceSupabase<{id:string}[]>("upload_jobs",{method:"POST",body:JSON.stringify({workspace_id:members[0].workspace_id,connection_id:connection.id,created_by:auth.userId,folder_id:grants[0].drive_folder_id,file_name:body.name,mime_type:body.mimeType,size_bytes:body.size,upload_text:body.uploadText??"",google_session_url:session,state:"uploading"})});
  return NextResponse.json({id:rows[0].id,uploadUrl:`/api/v1/uploads/${rows[0].id}/chunk`},{status:201});
}catch(error){return routeError(error)}}
