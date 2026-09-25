import { NextRequest, NextResponse } from "next/server";
import { mediaDTO, requireAuth, routeError, serviceSupabase } from "@/lib/server";
type Job={id:string;workspace_id:string;created_by:string;folder_id:string;file_name:string;mime_type:string;size_bytes:number;upload_text:string;drive_file_id:string;connection_id:string};
export async function POST(request:NextRequest,{params}:{params:Promise<{id:string}>}){try{
  const auth=await requireAuth(request); const{id}=await params; const jobs=await serviceSupabase<Job[]>(`upload_jobs?id=eq.${id}&select=*&limit=1`); const job=jobs[0];
  if(!job||job.created_by!==auth.userId||!job.drive_file_id)return NextResponse.json({error:"Upload is not ready to finalize"},{status:409});
  const rows=await serviceSupabase<Record<string,unknown>[]>("media_items?on_conflict=workspace_id,drive_file_id",{method:"POST",headers:{prefer:"resolution=merge-duplicates,return=representation"},body:JSON.stringify({workspace_id:job.workspace_id,drive_file_id:job.drive_file_id,name:job.file_name,mime_type:job.mime_type,size_bytes:job.size_bytes,folder_path:job.folder_id,upload_text:job.upload_text,upload_text_revision:job.upload_text?1:0,upload_text_updated_by:auth.userId,upload_text_updated_at:job.upload_text?new Date().toISOString():null})});
  const grants=await serviceSupabase<{id:string}[]>(`folder_grants?workspace_id=eq.${job.workspace_id}&drive_folder_id=eq.${job.folder_id}&select=id&limit=1`); if(grants[0])await serviceSupabase("media_access_paths?on_conflict=media_id,grant_id",{method:"POST",headers:{prefer:"resolution=ignore-duplicates"},body:JSON.stringify({media_id:rows[0].id,grant_id:grants[0].id,relative_path:""})});
  await serviceSupabase(`upload_jobs?id=eq.${id}`,{method:"PATCH",body:JSON.stringify({state:"finalized",updated_at:new Date().toISOString()})}); return NextResponse.json(mediaDTO(rows[0]));
}catch(error){return routeError(error)}}
