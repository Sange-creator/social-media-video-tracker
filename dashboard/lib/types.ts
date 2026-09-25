export type MediaItem = {
  id: string;
  driveFileId: string;
  name: string;
  kind: "video" | "photo";
  mimeType?: string;
  folder: string;
  size: string;
  rawSizeBytes?: number;
  updatedLabel: string;
  duration?: string;
  starred: boolean;
  trashed?: boolean;
  canDownload?: boolean;
  accent: "blue" | "amber" | "teal" | "slate" | "rose";
  uploadText: string;
  revision: number;
  thumbnailUrl?: string | null;
};

export type FolderGrant = {
  id: string;
  driveFolderId: string;
  name: string;
};

export type FolderChild = {
  id: string;
  name: string;
  modifiedAt: string;
};

export type ContentAccount = {
  id: string;
  workspace_id: string;
  grant_id: string;
  name: string;
  daily_quota: number;
  time_zone: string;
  paused: boolean;
};

export type AssignmentItem = {
  id: string;
  account_id: string;
  media_id: string;
  day_key: string;
  slot: number;
  state: "assigned" | "completed";
  assigned_at: string;
  completed_at: string | null;
  media?: MediaItem | null;
};

export type WorkspaceMember = {
  workspace_id: string;
  user_id: string;
  role: "owner" | "editor" | "viewer";
  created_at: string;
};
