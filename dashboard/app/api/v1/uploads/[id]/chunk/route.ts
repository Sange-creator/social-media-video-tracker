import { NextRequest, NextResponse } from "next/server";
import { requireAuth, routeError, serviceSupabase } from "@/lib/server";
type Job={id:string;created_by:string;google_session_url:string;mime_type:string;size_bytes:number};
export async function PUT(request:NextRequest,{params}:{params:Promise<{id:string}>}){try{
  const auth=await requireAuth(request); const{id}=await params; const jobs=await serviceSupabase<Job[]>(`upload_jobs?id=eq.${id}&select=*&limit=1`); const job=jobs[0];
  if(!job||job.created_by!==auth.userId)return NextResponse.json({error:"Upload not found"},{status:404});
  const google=await fetch(job.google_session_url,{method:"PUT",headers:{"content-type":request.headers.get("content-type")??job.mime_type,"content-length":request.headers.get("content-length")??String(job.size_bytes),...(request.headers.get("content-range")?{"content-range":request.headers.get("content-range")!}:{})},body:request.body,duplex:"half"} as RequestInit & {duplex:string});
  if(google.status===308)return new NextResponse(null,{status:308,headers:{range:google.headers.get("range")??""}});
  if(!google.ok)return NextResponse.json({error:"Google Drive rejected the upload"},{status:google.status});
  const file=await google.json() as {id:string}; await serviceSupabase(`upload_jobs?id=eq.${id}`,{method:"PATCH",body:JSON.stringify({drive_file_id:file.id,state:"uploaded",updated_at:new Date().toISOString()})});
  return NextResponse.json({driveFileId:file.id});
}catch(error){return routeError(error)}}
