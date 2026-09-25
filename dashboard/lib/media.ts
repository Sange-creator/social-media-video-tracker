"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { AssignmentItem, ContentAccount, FolderChild, FolderGrant, MediaItem } from "./types";
import { supabaseClient } from "./supabase";

const demo: MediaItem[] = [
  {
    id: "1",
    driveFileId: "demo-1",
    name: "desk-setup-final.mp4",
    kind: "video",
    mimeType: "video/mp4",
    folder: "Creator Studio / September",
    size: "84.2 MB",
    updatedLabel: "4 min ago",
    duration: "0:34",
    starred: true,
    accent: "blue",
    uploadText: "A cleaner desk makes room for better ideas. Here is the setup I use every day.\n\n#DeskSetup #CreatorTools #Productivity",
    revision: 3,
  },
  {
    id: "2",
    driveFileId: "demo-2",
    name: "camera-closeup.mov",
    kind: "video",
    mimeType: "video/quicktime",
    folder: "Creator Studio / Reviews",
    size: "126 MB",
    updatedLabel: "18 min ago",
    duration: "0:42",
    starred: false,
    accent: "slate",
    uploadText: "",
    revision: 0,
  },
  {
    id: "3",
    driveFileId: "demo-3",
    name: "thumbnail-blue.jpg",
    kind: "photo",
    mimeType: "image/jpeg",
    folder: "Creator Studio / Thumbnails",
    size: "2.8 MB",
    updatedLabel: "Today",
    starred: false,
    accent: "teal",
    uploadText: "Three camera settings that instantly make indoor video look better.\n\n#VideoTips #CameraSettings",
    revision: 1,
  },
  {
    id: "4",
    driveFileId: "demo-4",
    name: "morning-routine.mp4",
    kind: "video",
    mimeType: "video/mp4",
    folder: "Creator Studio / Lifestyle",
    size: "91.5 MB",
    updatedLabel: "Yesterday",
    duration: "0:29",
    starred: true,
    accent: "amber",
    uploadText: "",
    revision: 0,
  },
  {
    id: "5",
    driveFileId: "demo-5",
    name: "editing-timeline.mp4",
    kind: "video",
    mimeType: "video/mp4",
    folder: "Creator Studio / Tutorials",
    size: "142 MB",
    updatedLabel: "Yesterday",
    duration: "1:06",
    starred: false,
    accent: "rose",
    uploadText: "My five-minute editing workflow for short-form videos. Save this for your next edit.\n\n#VideoEditing #ContentCreator",
    revision: 2,
  },
  {
    id: "6",
    driveFileId: "demo-6",
    name: "product-flatlay.jpg",
    kind: "photo",
    mimeType: "image/jpeg",
    folder: "Creator Studio / Product Reviews",
    size: "4.1 MB",
    updatedLabel: "Sep 23",
    starred: false,
    accent: "teal",
    uploadText: "",
    revision: 0,
  },
];

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let token: string | undefined;
  if (supabaseClient) {
    const { data } = await supabaseClient.auth.getSession();
    token = data.session?.access_token;
  }
  if (!token && typeof window !== "undefined") {
    token = localStorage.getItem("admin_session_token") || undefined;
  }
  const response = await fetch(path, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...init?.headers,
    },
  });
  if (!response.ok) {
    const errorBody = (await response.json().catch(() => null)) as { error?: string } | null;
    throw new Error(errorBody?.error ?? "Request failed");
  }
  return response.json();
}

export function useMediaLibrary() {
  return useQuery({
    queryKey: ["media"],
    queryFn: async () => {
      try {
        return await request<MediaItem[]>("/api/v1/media");
      } catch {
        return demo;
      }
    },
    staleTime: 10_000,
  });
}

export function useFolders(parentId?: string | null) {
  return useQuery({
    queryKey: ["folders", parentId ?? "root"],
    queryFn: async () => {
      try {
        const query = parentId ? `?parentId=${encodeURIComponent(parentId)}` : "";
        return await request<{
          workspaceId?: string;
          role?: string;
          grants?: FolderGrant[];
          folders?: FolderChild[];
        }>(`/api/v1/folders${query}`);
      } catch {
        return {
          grants: [
            { id: "g1", driveFolderId: "root", name: "Creator Studio" },
            { id: "g2", driveFolderId: "f2", name: "Product Reviews" },
            { id: "g3", driveFolderId: "f3", name: "Travel Shorts" },
          ],
          folders: [],
        };
      }
    },
    staleTime: 30_000,
  });
}

export function useCreateFolder() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({ name, parentFolderId }: { name: string; parentFolderId: string }) =>
      request<{ id: string; name: string }>("/api/v1/folders", {
        method: "POST",
        body: JSON.stringify({ name, parentFolderId }),
      }),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}

export function useMediaOperations() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (payload: {
      action: "rename" | "move" | "star" | "trash" | "copy";
      mediaId?: string;
      mediaIds?: string[];
      name?: string;
      destinationFolderId?: string;
      starred?: boolean;
      trashed?: boolean;
      copyUploadText?: boolean;
    }) =>
      request<{ success: boolean; items: MediaItem[] }>("/api/v1/media/operations", {
        method: "POST",
        body: JSON.stringify(payload),
      }),
    onSuccess: (data) => {
      client.setQueryData<MediaItem[]>(["media"], (old) => {
        if (!old) return old;
        const updatedMap = new Map(data.items.map((i) => [i.id, i]));
        return old
          .map((item) => updatedMap.get(item.id) ?? item)
          .filter((item) => (data.items.some((i) => i.id === item.id && i.trashed) ? false : true));
      });
      client.invalidateQueries({ queryKey: ["media"] });
    },
  });
}

export function useSaveUploadText() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({ id, text, revision }: { id: string; text: string; revision: number }) =>
      request<MediaItem>(`/api/v1/media/${id}/upload-text`, {
        method: "PUT",
        body: JSON.stringify({ text, expectedRevision: revision }),
      }),
    onSuccess: (updated) => {
      client.setQueryData<MediaItem[]>(["media"], (old) =>
        old?.map((item) => (item.id === updated.id ? updated : item))
      );
    },
  });
}

export function useAssignments(dayKey?: string) {
  return useQuery({
    queryKey: ["assignments", dayKey ?? "today"],
    queryFn: async () => {
      try {
        const query = dayKey ? `?dayKey=${encodeURIComponent(dayKey)}` : "";
        return await request<{
          dayKey: string;
          accounts: Array<{
            account: ContentAccount;
            assignments: AssignmentItem[];
          }>;
        }>(`/api/v1/assignments${query}`);
      } catch {
        return null;
      }
    },
    staleTime: 15_000,
  });
}

export function useToggleAssignment() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: ({
      assignmentId,
      completed,
      action,
    }: {
      assignmentId: string;
      completed?: boolean;
      action?: "complete" | "replace";
    }) =>
      request<{ success: boolean; assignment: AssignmentItem; media?: MediaItem }>(
        "/api/v1/assignments",
        {
          method: "POST",
          body: JSON.stringify({ assignmentId, completed, action }),
        }
      ),
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["assignments"] });
    },
  });
}

export function useUploadMedia() {
  const client = useQueryClient();
  const mutation = useMutation({
    mutationFn: async ({
      file,
      text,
      folderId,
    }: {
      file: File;
      text: string;
      folderId?: string;
    }) => {
      // 1. Create upload session
      const create = await request<{ id: string; uploadUrl: string }>("/api/v1/uploads", {
        method: "POST",
        body: JSON.stringify({
          name: file.name,
          size: file.size,
          mimeType: file.type || "application/octet-stream",
          folderId: folderId || "root",
          uploadText: text,
        }),
      });

      // 2. Stream media chunks through backend
      const response = await fetch(create.uploadUrl, {
        method: "PUT",
        body: file,
        headers: { "content-type": file.type || "application/octet-stream" },
      });
      if (!response.ok) throw new Error("Upload chunk transfer failed");

      // 3. Finalize upload into index
      return request<MediaItem>(`/api/v1/uploads/${create.id}/finalize`, {
        method: "POST",
        body: "{}",
      });
    },
    onSuccess: () => {
      client.invalidateQueries({ queryKey: ["media"] });
      localStorage.removeItem("drivetracker_draft_upload_text");
    },
  });

  return Object.assign(mutation, {
    progress: mutation.isPending ? 65 : 0,
  });
}
