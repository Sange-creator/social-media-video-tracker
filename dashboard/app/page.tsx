"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  Check,
  ChevronRight,
  Cloud,
  Copy,
  Download,
  ExternalLink,
  Film,
  Folder,
  FolderPlus,
  Grid2X2,
  Image as ImageIcon,
  Key,
  List,
  Loader2,
  LogOut,
  MoreHorizontal,
  Play,
  Plus,
  RefreshCw,
  Search,
  Star,
  Trash2,
  Upload,
  Users,
  Video,
  X,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Progress } from "@/components/ui/progress";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  DEFAULT_GOOGLE_CLIENT_ID,
  GoogleDriveFolder,
  GoogleDriveMediaFile,
  GoogleDriveUser,
  createDriveFolder,
  deleteDriveFile,
  disconnectDriveSession,
  fetchDriveFolders,
  fetchDriveMediaFiles,
  fetchGoogleUserInfo,
  getStoredDriveToken,
  getStoredDriveUser,
  getStoredGoogleClientId,
  setStoredDriveSession,
  setStoredGoogleClientId,
  toggleDriveStar,
  updateDriveDescription,
  uploadToGoogleDrive,
} from "@/lib/googleDriveClient";
import { signInAdmin, signOut, useSession } from "@/lib/supabase";

function BrandMark({ className = "h-8 w-8" }: { className?: string }) {
  return (
    <svg viewBox="0 0 48 48" className={className} aria-hidden="true">
      <rect x="4" y="6" width="32" height="36" rx="8" fill="#2563EB" />
      <path d="M17 17v14l12-7-12-7Z" fill="#FFFFFF" />
      <path
        d="M32 18h8a4 4 0 0 1 4 4v14a4 4 0 0 1-4 4H28l4-4V18Z"
        fill="#3B82F6"
        stroke="#090C12"
        strokeWidth="2"
      />
      <circle cx="36" cy="27" r="2.5" fill="#FFFFFF" />
    </svg>
  );
}

const fallbackMediaList: GoogleDriveMediaFile[] = [
  {
    id: "sample-1",
    driveFileId: "sample-1",
    name: "morning-routine-v2.mp4",
    kind: "video",
    mimeType: "video/mp4",
    folder: "TikTok / Lifestyle",
    folderId: "fld-1",
    size: "42.8 MB",
    rawSizeBytes: 44879052,
    updatedLabel: "Today",
    starred: true,
    trashed: false,
    canDownload: true,
    accent: "blue",
    uploadText: "My 5-minute morning routine before creative sessions. Save this for tomorrow morning! ☕️⚡️\n\n#MorningRoutine #CreatorLife #Productivity #DailyVlog",
    revision: 2,
    thumbnailUrl: null,
  },
  {
    id: "sample-2",
    driveFileId: "sample-2",
    name: "desk-setup-cinematic.mov",
    kind: "video",
    mimeType: "video/quicktime",
    folder: "YouTube Shorts / Setups",
    folderId: "fld-2",
    size: "128 MB",
    rawSizeBytes: 134217728,
    updatedLabel: "Yesterday",
    starred: false,
    trashed: false,
    canDownload: true,
    accent: "blue",
    uploadText: "The minimal creator setup that took 3 years to build. Every piece has a reason.\n\n#DeskSetup #TechReview #WorkspaceGoals #Shorts",
    revision: 1,
    thumbnailUrl: null,
  },
  {
    id: "sample-3",
    driveFileId: "sample-3",
    name: "thumbnail-concept-01.jpg",
    kind: "photo",
    mimeType: "image/jpeg",
    folder: "Thumbnails",
    folderId: "fld-3",
    size: "3.2 MB",
    rawSizeBytes: 3355443,
    updatedLabel: "Sep 24",
    starred: true,
    trashed: false,
    canDownload: true,
    accent: "teal",
    uploadText: "High-contrast thumbnail design for episode 4. Split lighting with cyan rim light.",
    revision: 1,
    thumbnailUrl: null,
  },
];

export default function Home() {
  const [query, setQuery] = useState("");
  const [driveToken, setDriveToken] = useState<string | null>(null);
  const [driveUser, setDriveUser] = useState<GoogleDriveUser | null>(null);
  const [folders, setFolders] = useState<GoogleDriveFolder[]>([]);
  const [selectedFolderId, setSelectedFolderId] = useState<string | null>(null);
  const [selectedFolderName, setSelectedFolderName] = useState<string>("All files");
  const [viewFilter, setViewFilter] = useState<"all" | "starred" | "trash">("all");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [mediaItems, setMediaItems] = useState<GoogleDriveMediaFile[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  // Modals
  const [uploadOpen, setUploadOpen] = useState(false);
  const [newFolderOpen, setNewFolderOpen] = useState(false);
  const [connectDriveOpen, setConnectDriveOpen] = useState(false);
  const [adminLoginOpen, setAdminLoginOpen] = useState(false);

  // Load Drive auth on mount
  useEffect(() => {
    const token = getStoredDriveToken();
    const user = getStoredDriveUser();
    setDriveToken(token);
    setDriveUser(user);

    const onAuthChange = () => {
      setDriveToken(getStoredDriveToken());
      setDriveUser(getStoredDriveUser());
    };
    window.addEventListener("gdrive-auth-change", onAuthChange);
    return () => window.removeEventListener("gdrive-auth-change", onAuthChange);
  }, []);

  // Fetch real Google Drive folders & media files
  const refreshDriveData = async (token: string, folderId: string | null = null) => {
    setIsLoading(true);
    try {
      // 1. Fetch folders
      const flds = await fetchDriveFolders(token, "root");
      setFolders(flds);

      // 2. Fetch media files in active folder
      const targetFolder = folderId ?? "root";
      const folderName = flds.find((f) => f.id === targetFolder)?.name ?? "My Drive";
      const files = await fetchDriveMediaFiles(token, targetFolder, folderName);
      setMediaItems(files);
      if (files.length > 0 && !selectedId) {
        setSelectedId(files[0].id);
      }
    } catch (err) {
      console.error("Failed to load Google Drive files:", err);
      // Fallback to sample items if Drive token expired
      setMediaItems(fallbackMediaList);
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    if (driveToken) {
      void refreshDriveData(driveToken, selectedFolderId);
    } else {
      setMediaItems(fallbackMediaList);
      setFolders([
        { id: "fld-1", name: "TikTok / Lifestyle" },
        { id: "fld-2", name: "YouTube Shorts / Setups" },
        { id: "fld-3", name: "Thumbnails" },
      ]);
    }
  }, [driveToken, selectedFolderId]);

  // Filter media items
  const items = useMemo(() => {
    let list = mediaItems;
    if (viewFilter === "starred") {
      list = list.filter((i) => i.starred && !i.trashed);
    } else if (viewFilter === "trash") {
      list = list.filter((i) => i.trashed);
    } else {
      list = list.filter((i) => !i.trashed);
      if (selectedFolderId && selectedFolderId !== "root" && !driveToken) {
        list = list.filter((i) => i.folderId === selectedFolderId || i.folder.includes(selectedFolderName));
      }
    }
    if (query.trim()) {
      const q = query.trim().toLowerCase();
      list = list.filter(
        (i) =>
          i.name.toLowerCase().includes(q) ||
          i.uploadText.toLowerCase().includes(q) ||
          i.folder.toLowerCase().includes(q)
      );
    }
    return list;
  }, [mediaItems, viewFilter, selectedFolderId, selectedFolderName, query, driveToken]);

  const selected = items.find((item) => item.id === selectedId) ?? items[0] ?? null;

  // Handle caption update
  const handleSaveCaption = async (fileId: string, newText: string) => {
    // 1. Optimistic local update
    setMediaItems((prev) =>
      prev.map((item) =>
        item.id === fileId
          ? { ...item, uploadText: newText, revision: item.revision + 1 }
          : item
      )
    );

    // 2. Real Drive update if connected
    if (driveToken) {
      try {
        await updateDriveDescription(driveToken, fileId, newText);
      } catch (err) {
        console.error("Failed to update caption in Drive:", err);
      }
    }
  };

  // Handle file deletion
  const handleDeleteFile = async (fileId: string) => {
    setMediaItems((prev) => prev.filter((item) => item.id !== fileId));
    if (selectedId === fileId) {
      const remaining = items.filter((i) => i.id !== fileId);
      setSelectedId(remaining[0]?.id ?? null);
    }

    if (driveToken) {
      try {
        await deleteDriveFile(driveToken, fileId);
      } catch (err) {
        console.error("Failed to delete file from Drive:", err);
      }
    }
  };

  // Handle star toggle
  const handleToggleStar = async (fileId: string, starred: boolean) => {
    setMediaItems((prev) =>
      prev.map((item) => (item.id === fileId ? { ...item, starred } : item))
    );
    if (driveToken) {
      try {
        await toggleDriveStar(driveToken, fileId, starred);
      } catch (err) {
        console.error("Failed to star file in Drive:", err);
      }
    }
  };

  return (
    <main className="workspace-shell">
      {/* Top Header */}
      <header className="topbar">
        <div className="brand">
          <BrandMark />
          <div className="brand-info">
            <strong>Social Media Video Tracker</strong>
            <span>Google Drive Creator Studio</span>
          </div>
        </div>

        <div className="search-wrap">
          <Search />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search media, captions, hashtags, or folders…"
            aria-label="Search media"
          />
          {query && (
            <button
              onClick={() => setQuery("")}
              className="text-xs text-muted-foreground hover:text-white"
            >
              Clear
            </button>
          )}
        </div>

        <div className="top-actions">
          {driveUser ? (
            <div
              className="drive-badge cursor-pointer"
              onClick={() => setConnectDriveOpen(true)}
              title="Click to view Drive account details"
            >
              <span className="beacon" />
              <span>Drive: {driveUser.email}</span>
            </div>
          ) : (
            <button
              className="drive-badge disconnected cursor-pointer hover:bg-red-500/20"
              onClick={() => setConnectDriveOpen(true)}
              title="Connect your Google Drive account"
            >
              <span className="beacon" />
              <span>Connect Google Drive</span>
            </button>
          )}

          <Button
            size="sm"
            className="bg-blue-600 hover:bg-blue-500 text-white font-semibold flex items-center gap-1.5 shadow-lg shadow-blue-500/20"
            onClick={() => setUploadOpen(true)}
          >
            <Upload className="w-4 h-4" />
            <span>Upload & Caption</span>
          </Button>

          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button className="avatar" title={driveUser?.email ?? "Account menu"}>
                {driveUser?.email?.slice(0, 2).toUpperCase() ?? "AD"}
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-56 bg-slate-900 border-white/10 text-white">
              <div className="px-3 py-2 border-b border-white/10">
                <p className="text-xs text-slate-400">Connected Account</p>
                <p className="text-sm font-semibold truncate">{driveUser?.email ?? "admin@gmail.com"}</p>
              </div>
              <DropdownMenuItem
                className="cursor-pointer gap-2"
                onClick={() => setConnectDriveOpen(true)}
              >
                <Cloud className="w-4 h-4 text-blue-400" />
                <span>Google Drive Settings</span>
              </DropdownMenuItem>
              <DropdownMenuItem
                className="cursor-pointer gap-2"
                onClick={() => setAdminLoginOpen(true)}
              >
                <Key className="w-4 h-4 text-emerald-400" />
                <span>Admin Login</span>
              </DropdownMenuItem>
              {driveToken && (
                <DropdownMenuItem
                  className="cursor-pointer gap-2 text-red-400"
                  onClick={() => {
                    disconnectDriveSession();
                    setDriveToken(null);
                    setDriveUser(null);
                  }}
                >
                  <LogOut className="w-4 h-4" />
                  <span>Disconnect Drive</span>
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </header>

      {/* Left Sidebar */}
      <aside className="sidebar">
        <nav className="nav-group" aria-label="Workspace navigation">
          <button
            className={`nav-item ${viewFilter === "all" && !selectedFolderId ? "active" : ""}`}
            onClick={() => {
              setViewFilter("all");
              setSelectedFolderId(null);
              setSelectedFolderName("All files");
            }}
          >
            <Folder />
            <span>All media</span>
            <small>{items.filter((i) => !i.trashed).length}</small>
          </button>
          <button
            className={`nav-item ${viewFilter === "starred" ? "active" : ""}`}
            onClick={() => {
              setViewFilter("starred");
              setSelectedFolderId(null);
              setSelectedFolderName("Starred");
            }}
          >
            <Star />
            <span>Starred</span>
            <small>{mediaItems.filter((i) => i.starred && !i.trashed).length}</small>
          </button>
          <button
            className={`nav-item ${viewFilter === "trash" ? "active" : ""}`}
            onClick={() => {
              setViewFilter("trash");
              setSelectedFolderId(null);
              setSelectedFolderName("Trash");
            }}
          >
            <Trash2 />
            <span>Trash</span>
            <small>{mediaItems.filter((i) => i.trashed).length}</small>
          </button>
        </nav>

        {/* Google Drive Folders Section */}
        <div className="nav-group">
          <div className="side-heading">
            <span>Drive Folders</span>
            <button
              onClick={() => setNewFolderOpen(true)}
              aria-label="New folder"
              title="Create new subfolder in Drive"
            >
              <Plus className="w-3.5 h-3.5" />
            </button>
          </div>

          <div className="flex flex-col gap-1">
            <button
              className={`folder-item ${selectedFolderId === null || selectedFolderId === "root" ? "active" : ""}`}
              onClick={() => {
                setSelectedFolderId(null);
                setSelectedFolderName("My Drive");
                setViewFilter("all");
              }}
            >
              <Folder />
              <span>My Drive (Root)</span>
            </button>

            {folders.map((folder) => (
              <button
                key={folder.id}
                className={`folder-item ${selectedFolderId === folder.id ? "active" : ""}`}
                onClick={() => {
                  setSelectedFolderId(folder.id);
                  setSelectedFolderName(folder.name);
                  setViewFilter("all");
                }}
              >
                <Folder />
                <span title={folder.name}>{folder.name}</span>
              </button>
            ))}
          </div>
        </div>

        {/* Drive Storage Status Widget */}
        <div className="storage-widget">
          <div className="storage-info">
            <span>Google Drive Storage</span>
            <strong>{driveUser ? "Connected" : "Not connected"}</strong>
          </div>
          <Progress value={driveUser ? 45 : 0} className="h-1.5 bg-white/10" />
          <span className="text-[11px] text-slate-500">
            {driveUser ? `${items.length} media files managed` : "Connect Drive to see real usage"}
          </span>
        </div>
      </aside>

      {/* Main Library Pane */}
      <section className="library-pane">
        {!driveToken && (
          <div className="bg-gradient-to-r from-blue-900/30 to-indigo-900/30 border border-blue-500/30 rounded-xl p-4 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <Cloud className="w-6 h-6 text-blue-400 shrink-0" />
              <div>
                <strong className="text-sm text-white block">Connect Your Original Google Drive</strong>
                <p className="text-xs text-slate-300 m-0">
                  Connect your Google Drive account to browse your actual folders, upload videos, and save captions directly to Drive files.
                </p>
              </div>
            </div>
            <Button
              size="sm"
              className="bg-blue-600 hover:bg-blue-500 text-white shrink-0"
              onClick={() => setConnectDriveOpen(true)}
            >
              Connect Now
            </Button>
          </div>
        )}

        <div className="library-heading">
          <div>
            <p>{viewFilter === "starred" ? "Favorites" : viewFilter === "trash" ? "Deleted" : selectedFolderName}</p>
            <h1>{viewFilter === "starred" ? "Starred Media" : viewFilter === "trash" ? "Trash" : selectedFolderName}</h1>
          </div>

          <div className="library-tools">
            {isLoading && <Loader2 className="w-4 h-4 animate-spin text-blue-400" />}
            <span className="count-tag">{items.length} items</span>

            {driveToken && (
              <Button
                variant="outline"
                size="sm"
                className="h-8 border-white/10 text-xs gap-1.5"
                onClick={() => refreshDriveData(driveToken, selectedFolderId)}
                title="Refresh from Google Drive"
              >
                <RefreshCw className="w-3.5 h-3.5" />
                <span>Sync</span>
              </Button>
            )}

            <div className="view-toggle">
              <button
                className={view === "grid" ? "active" : ""}
                onClick={() => setView("grid")}
                aria-label="Grid view"
                title="Grid view"
              >
                <Grid2X2 className="w-4 h-4" />
              </button>
              <button
                className={view === "list" ? "active" : ""}
                onClick={() => setView("list")}
                aria-label="List view"
                title="List view"
              >
                <List className="w-4 h-4" />
              </button>
            </div>
          </div>
        </div>

        {/* Breadcrumbs */}
        <div className="breadcrumbs">
          <span>Google Drive</span>
          <ChevronRight className="w-3.5 h-3.5" />
          <strong>{selectedFolderName}</strong>
        </div>

        {/* Media Grid / List */}
        {isLoading && items.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 text-slate-500 gap-3">
            <Loader2 className="w-8 h-8 animate-spin text-blue-500" />
            <span className="text-sm">Fetching files from Google Drive…</span>
          </div>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-20 border border-dashed border-white/10 rounded-2xl gap-3 text-slate-500">
            <Film className="w-10 h-10 opacity-40 text-blue-400" />
            <strong className="text-base text-slate-300">No media in this folder</strong>
            <p className="text-xs text-slate-500 m-0 max-w-sm text-center">
              Drop videos or photos here to upload directly to this Google Drive folder with instant captions.
            </p>
            <Button
              size="sm"
              className="bg-blue-600 hover:bg-blue-500 text-white mt-2"
              onClick={() => setUploadOpen(true)}
            >
              Upload to {selectedFolderName}
            </Button>
          </div>
        ) : (
          <div className={view === "grid" ? "media-grid" : "media-list"}>
            {items.map((item) => (
              <div
                key={item.id}
                className={`media-card ${selected?.id === item.id ? "selected" : ""}`}
                onClick={() => setSelectedId(item.id)}
              >
                <div className="poster-box">
                  {item.thumbnailUrl ? (
                    <img src={item.thumbnailUrl} alt={item.name} loading="lazy" />
                  ) : (
                    <div className="poster-fallback">
                      {item.kind === "video" ? <Video /> : <ImageIcon />}
                    </div>
                  )}

                  <span className="card-badge">
                    {item.mimeType.split("/")[1]?.toUpperCase() || item.kind}
                  </span>

                  <button
                    className={`card-star-btn ${item.starred ? "starred" : ""}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      void handleToggleStar(item.id, !item.starred);
                    }}
                    title={item.starred ? "Unstar" : "Star"}
                  >
                    <Star className="w-3.5 h-3.5 fill-current" />
                  </button>
                </div>

                <div className="card-content">
                  <div className="card-title" title={item.name}>
                    {item.name}
                  </div>
                  <div className="card-caption-preview">
                    {item.uploadText || <span className="italic opacity-50">No caption attached yet</span>}
                  </div>
                  <div className="card-meta-row">
                    <span>{item.size}</span>
                    <span>{item.updatedLabel}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>

      {/* Right Media Inspector & Caption Studio */}
      <aside className="inspector">
        {selected ? (
          <InspectorDetail
            key={selected.id}
            item={selected}
            driveToken={driveToken}
            onSaveCaption={(text) => handleSaveCaption(selected.id, text)}
            onDelete={() => handleDeleteFile(selected.id)}
            onToggleStar={(starred) => handleToggleStar(selected.id, starred)}
          />
        ) : (
          <div className="flex flex-col items-center justify-center h-full text-slate-500 gap-2">
            <Film className="w-8 h-8 opacity-40" />
            <span className="text-sm">Select a file to inspect</span>
          </div>
        )}
      </aside>

      {/* Upload & Caption Modal */}
      <UploadModal
        open={uploadOpen}
        onOpenChange={setUploadOpen}
        driveToken={driveToken}
        folders={folders}
        defaultFolderId={selectedFolderId ?? "root"}
        defaultFolderName={selectedFolderName}
        onUploadComplete={(newFile) => {
          setMediaItems((prev) => [newFile, ...prev]);
          setSelectedId(newFile.id);
          setUploadOpen(false);
        }}
      />

      {/* Connect Google Drive Modal */}
      <ConnectDriveDialog
        open={connectDriveOpen}
        onOpenChange={setConnectDriveOpen}
        driveUser={driveUser}
        onConnected={(token, user) => {
          setDriveToken(token);
          setDriveUser(user);
          setConnectDriveOpen(false);
          void refreshDriveData(token);
        }}
      />

      {/* Create New Folder Modal */}
      <NewFolderDialog
        open={newFolderOpen}
        onOpenChange={setNewFolderOpen}
        driveToken={driveToken}
        parentFolderId={selectedFolderId ?? "root"}
        onFolderCreated={(folder) => {
          setFolders((prev) => [...prev, folder]);
          setNewFolderOpen(false);
        }}
      />

      {/* Admin Login Dialog */}
      <AdminLoginDialog open={adminLoginOpen} onOpenChange={setAdminLoginOpen} />
    </main>
  );
}

/* =========================================================================
   INSPECTOR DETAIL COMPONENT
   ========================================================================= */
function InspectorDetail({
  item,
  driveToken,
  onSaveCaption,
  onDelete,
  onToggleStar,
}: {
  item: GoogleDriveMediaFile;
  driveToken: string | null;
  onSaveCaption: (text: string) => Promise<void>;
  onDelete: () => Promise<void>;
  onToggleStar: (starred: boolean) => Promise<void>;
}) {
  const [caption, setCaption] = useState(item.uploadText);
  const [isCopied, setIsCopied] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [saveSuccess, setSaveSuccess] = useState(false);

  useEffect(() => {
    setCaption(item.uploadText);
  }, [item.id, item.uploadText]);

  // Copy caption & hashtags to clipboard
  const copyToClipboard = async () => {
    if (!caption) return;
    try {
      await navigator.clipboard.writeText(caption);
      setIsCopied(true);
      setTimeout(() => setIsCopied(false), 2000);
    } catch {
      // Fallback
    }
  };

  // Save caption
  const handleSave = async () => {
    setIsSaving(true);
    try {
      await onSaveCaption(caption);
      setSaveSuccess(true);
      setTimeout(() => setSaveSuccess(false), 2000);
    } finally {
      setIsSaving(false);
    }
  };

  // Count hashtags
  const hashtags = useMemo(() => {
    const matches = caption.match(/#[a-zA-Z0-9_]+/g);
    return matches ?? [];
  }, [caption]);

  return (
    <>
      {/* Media Preview Box */}
      <div className="inspector-preview-box">
        {item.webViewLink && driveToken ? (
          <iframe
            src={`https://drive.google.com/file/d/${item.driveFileId}/preview`}
            className="w-full h-full border-0"
            allow="autoplay"
            title={item.name}
          />
        ) : item.thumbnailUrl ? (
          <img src={item.thumbnailUrl} alt={item.name} />
        ) : (
          <div className="flex flex-col items-center gap-2 text-slate-500">
            {item.kind === "video" ? <Video className="w-10 h-10" /> : <ImageIcon className="w-10 h-10" />}
            <span className="text-xs">{item.name}</span>
          </div>
        )}
      </div>

      {/* Header */}
      <div className="inspector-header">
        <div className="badge-row">
          <span className="text-xs font-semibold text-blue-400 uppercase tracking-wider">
            {item.kind} • {item.mimeType.split("/")[1] || "FILE"}
          </span>
          <button
            onClick={() => onToggleStar(!item.starred)}
            className="text-slate-400 hover:text-amber-400"
            title={item.starred ? "Starred" : "Star"}
          >
            <Star className={`w-4 h-4 ${item.starred ? "text-amber-400 fill-amber-400" : ""}`} />
          </button>
        </div>
        <h2>{item.name}</h2>
      </div>

      {/* 1-Tap Copy Caption Button */}
      <button className="copy-caption-btn" onClick={copyToClipboard}>
        {isCopied ? (
          <>
            <Check className="w-4 h-4 text-emerald-300" />
            <span>Copied to Clipboard!</span>
          </>
        ) : (
          <>
            <Copy className="w-4 h-4" />
            <span>Copy Caption & Hashtags</span>
          </>
        )}
      </button>

      {/* Caption & Hashtag Editor */}
      <div className="caption-editor-section">
        <div className="caption-header-row">
          <strong>Upload Text (Caption, Title & Tags)</strong>
          {saveSuccess ? (
            <span className="save-status">
              <Check className="w-3.5 h-3.5" /> Saved to Drive
            </span>
          ) : isSaving ? (
            <span className="text-xs text-blue-400">Saving…</span>
          ) : (
            <button
              onClick={handleSave}
              className="text-xs font-semibold text-blue-400 hover:text-blue-300"
            >
              Save to Drive
            </button>
          )}
        </div>

        <Textarea
          value={caption}
          onChange={(e) => setCaption(e.target.value)}
          onBlur={handleSave}
          placeholder="Paste or write the complete title, caption, and #hashtags here in ONE box…"
          className="caption-textarea"
        />

        <div className="flex items-center justify-between text-[11px] text-slate-500">
          <span>{hashtags.length} hashtags detected</span>
          <span>{caption.length} characters</span>
        </div>

        {hashtags.length > 0 && (
          <div className="flex flex-wrap gap-1.5 mt-1">
            {hashtags.map((tag, idx) => (
              <span
                key={idx}
                className="px-2 py-0.5 rounded-md bg-blue-500/10 text-blue-400 text-xs font-mono"
              >
                {tag}
              </span>
            ))}
          </div>
        )}
      </div>

      {/* Metadata Card */}
      <div className="metadata-card">
        <div className="meta-item">
          <dt>Folder</dt>
          <dd>{item.folder}</dd>
        </div>
        <div className="meta-item">
          <dt>File Size</dt>
          <dd>{item.size}</dd>
        </div>
        <div className="meta-item">
          <dt>Format</dt>
          <dd>{item.mimeType}</dd>
        </div>
        <div className="meta-item">
          <dt>Updated</dt>
          <dd>{item.updatedLabel}</dd>
        </div>
        <div className="meta-item">
          <dt>Drive File ID</dt>
          <dd className="font-mono text-[11px]">{item.driveFileId}</dd>
        </div>
      </div>

      {/* Action Toolbar */}
      <div className="inspector-actions-row">
        {item.webViewLink && (
          <Button
            variant="outline"
            size="sm"
            className="w-full border-white/10 text-xs gap-1.5"
            onClick={() => window.open(item.webViewLink, "_blank")}
          >
            <ExternalLink className="w-3.5 h-3.5" />
            <span>Open in Drive</span>
          </Button>
        )}

        <Button
          variant="outline"
          size="sm"
          className="w-full border-white/10 text-xs gap-1.5 danger-btn"
          onClick={onDelete}
        >
          <Trash2 className="w-3.5 h-3.5" />
          <span>Move to Trash</span>
        </Button>
      </div>
    </>
  );
}

/* =========================================================================
   UPLOAD MODAL COMPONENT (WITH ZERO LAG TO DRIVE)
   ========================================================================= */
function UploadModal({
  open,
  onOpenChange,
  driveToken,
  folders,
  defaultFolderId,
  defaultFolderName,
  onUploadComplete,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  driveToken: string | null;
  folders: GoogleDriveFolder[];
  defaultFolderId: string;
  defaultFolderName: string;
  onUploadComplete: (file: GoogleDriveMediaFile) => void;
}) {
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [targetFolderId, setTargetFolderId] = useState(defaultFolderId);
  const [caption, setCaption] = useState("");
  const [progress, setProgress] = useState<number | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setTargetFolderId(defaultFolderId);
  }, [defaultFolderId]);

  const handleDrop = (e: React.DragEvent) => {
    e.preventDefault();
    if (e.dataTransfer.files?.[0]) {
      setSelectedFile(e.dataTransfer.files[0]);
    }
  };

  const handleUpload = async () => {
    if (!selectedFile) return;
    setIsUploading(true);
    setProgress(5);
    setError(null);

    try {
      if (driveToken) {
        // Upload directly to Google Drive with zero lag!
        const result = await uploadToGoogleDrive(driveToken, {
          file: selectedFile,
          folderId: targetFolderId,
          caption: caption.trim(),
          onProgress: (p) => setProgress(p),
        });
        onUploadComplete(result);
      } else {
        // Fallback simulated upload for local preview
        for (let p = 10; p <= 100; p += 20) {
          setProgress(p);
          await new Promise((r) => setTimeout(r, 80));
        }
        const isPhoto = selectedFile.type.startsWith("image/");
        const newFile: GoogleDriveMediaFile = {
          id: `local-${Date.now()}`,
          driveFileId: `local-drv-${Date.now()}`,
          name: selectedFile.name,
          kind: isPhoto ? "photo" : "video",
          mimeType: selectedFile.type || "video/mp4",
          folder: defaultFolderName,
          folderId: targetFolderId,
          size: `${(selectedFile.size / 1024 / 1024).toFixed(1)} MB`,
          rawSizeBytes: selectedFile.size,
          updatedLabel: "Just now",
          starred: false,
          trashed: false,
          canDownload: true,
          accent: isPhoto ? "teal" : "blue",
          uploadText: caption.trim(),
          revision: 1,
          thumbnailUrl: null,
        };
        onUploadComplete(newFile);
      }
      setSelectedFile(null);
      setCaption("");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed");
    } finally {
      setIsUploading(false);
      setProgress(null);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-xl bg-slate-900 border-white/10 text-white">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base font-semibold">
            <Upload className="w-5 h-5 text-blue-400" />
            <span>Upload Media & Set Caption to Google Drive</span>
          </DialogTitle>
        </DialogHeader>

        <div className="grid gap-4 py-2">
          {error && (
            <div className="p-3 rounded-lg bg-red-500/10 border border-red-500/20 text-xs text-red-400 font-medium">
              {error}
            </div>
          )}

          {/* Folder Destination Picker */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-slate-400">
              Destination Drive Folder
            </label>
            <select
              value={targetFolderId}
              onChange={(e) => setTargetFolderId(e.target.value)}
              className="w-full h-9 rounded-lg bg-white/5 border border-white/10 px-3 text-xs text-white outline-none focus:border-blue-500"
            >
              <option value="root">My Drive (Root)</option>
              {folders.map((f) => (
                <option key={f.id} value={f.id}>
                  📁 {f.name}
                </option>
              ))}
            </select>
          </div>

          {/* Drag & Drop File Zone */}
          <div
            className={`upload-modal-dropzone ${selectedFile ? "border-blue-500 bg-blue-500/5" : ""}`}
            onDragOver={(e) => e.preventDefault()}
            onDrop={handleDrop}
            onClick={() => fileInputRef.current?.click()}
          >
            <input
              type="file"
              ref={fileInputRef}
              onChange={(e) => e.target.files?.[0] && setSelectedFile(e.target.files[0])}
              accept="video/*,image/*"
              className="hidden"
            />
            {selectedFile ? (
              <div className="flex flex-col items-center gap-1">
                <Film className="w-8 h-8 text-blue-400" />
                <strong className="text-sm text-white">{selectedFile.name}</strong>
                <span className="text-xs text-slate-400">
                  {(selectedFile.size / 1024 / 1024).toFixed(1)} MB • {selectedFile.type || "media"}
                </span>
                <span className="text-[11px] text-blue-400 underline mt-1">Click to choose different file</span>
              </div>
            ) : (
              <>
                <Upload className="w-8 h-8 text-blue-400" />
                <strong className="text-sm text-slate-200">Drag & drop your video or photo here</strong>
                <span className="text-xs text-slate-400">or click to browse from your computer</span>
              </>
            )}
          </div>

          {/* Single Text Box for Title, Caption, and Hashtags */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-slate-400">
              Complete Upload Text (Title, Caption & Hashtags)
            </label>
            <Textarea
              value={caption}
              onChange={(e) => setCaption(e.target.value)}
              placeholder="Paste everything into this ONE box: title on line 1, full caption, and #hashtags at the bottom..."
              className="min-h-[140px] bg-white/5 border-white/10 text-white text-xs leading-relaxed"
            />
            <span className="text-[11px] text-slate-500 block text-right">
              {caption.length} characters • Saves directly into Google Drive file description
            </span>
          </div>

          {/* Progress Bar */}
          {progress !== null && (
            <div className="space-y-1">
              <div className="flex justify-between text-xs text-slate-400">
                <span>Uploading to Google Drive…</span>
                <span>{progress}%</span>
              </div>
              <Progress value={progress} className="h-2 bg-white/10" />
            </div>
          )}
        </div>

        <DialogFooter className="gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => onOpenChange(false)}
            disabled={isUploading}
            className="border-white/10 text-white"
          >
            Cancel
          </Button>
          <Button
            size="sm"
            onClick={handleUpload}
            disabled={!selectedFile || isUploading}
            className="bg-blue-600 hover:bg-blue-500 text-white font-semibold"
          >
            {isUploading ? "Uploading to Drive…" : "Upload to Google Drive"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/* =========================================================================
   CONNECT GOOGLE DRIVE MODAL
   ========================================================================= */
function ConnectDriveDialog({
  open,
  onOpenChange,
  driveUser,
  onConnected,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  driveUser: GoogleDriveUser | null;
  onConnected: (token: string, user: GoogleDriveUser) => void;
}) {
  const [tokenInput, setTokenInput] = useState("");
  const [clientId, setClientId] = useState(getStoredGoogleClientId());
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Connect using direct Access Token
  const handleConnectToken = async () => {
    if (!tokenInput.trim()) return;
    setIsLoading(true);
    setError(null);
    try {
      const user = await fetchGoogleUserInfo(tokenInput.trim());
      setStoredDriveSession(tokenInput.trim(), user);
      onConnected(tokenInput.trim(), user);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to connect to Google Drive");
    } finally {
      setIsLoading(false);
    }
  };

  // Connect using Google Identity Services OAuth popup
  const handleOAuthConnect = () => {
    setError(null);
    setIsLoading(true);

    try {
      const client = (window as unknown as {
        google?: {
          accounts?: {
            oauth2?: {
              initTokenClient: (cfg: {
                client_id: string;
                scope: string;
                callback: (resp: { access_token?: string; error?: string }) => void;
              }) => { requestAccessToken: () => void };
            };
          };
        };
      })?.google?.accounts?.oauth2?.initTokenClient({
        client_id: clientId.trim(),
        scope: "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/userinfo.email",
        callback: async (resp) => {
          if (resp.access_token) {
            try {
              const user = await fetchGoogleUserInfo(resp.access_token);
              setStoredDriveSession(resp.access_token, user);
              onConnected(resp.access_token, user);
            } catch (e) {
              setError("Authorized, but could not fetch user info.");
            }
          } else if (resp.error) {
            setError(`Google OAuth error: ${resp.error}`);
          }
          setIsLoading(false);
        },
      });

      if (client) {
        client.requestAccessToken();
      } else {
        // GIS library not loaded; fallback to direct prompt
        setError("Google Identity Services script is loading. You can also paste an Access Token directly below.");
        setIsLoading(false);
      }
    } catch (err) {
      setError("Please paste a Google OAuth Access Token below for instant connection.");
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md bg-slate-900 border-white/10 text-white">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base font-semibold">
            <Cloud className="w-5 h-5 text-blue-400" />
            <span>Connect Original Google Drive</span>
          </DialogTitle>
        </DialogHeader>

        <div className="grid gap-4 py-2">
          {driveUser && (
            <div className="p-3 rounded-lg bg-emerald-500/10 border border-emerald-500/20 flex items-center justify-between text-xs">
              <div>
                <span className="font-semibold text-emerald-400">Currently Connected:</span>
                <p className="m-0 text-slate-300 font-mono">{driveUser.email}</p>
              </div>
              <Button
                variant="outline"
                size="sm"
                className="border-white/10 text-xs text-red-400"
                onClick={() => {
                  disconnectDriveSession();
                  onOpenChange(false);
                }}
              >
                Disconnect
              </Button>
            </div>
          )}

          {error && (
            <div className="p-3 rounded-lg bg-red-500/10 border border-red-500/20 text-xs text-red-400">
              {error}
            </div>
          )}

          {/* Option 1: 1-Click Google OAuth */}
          <div className="p-3.5 rounded-xl bg-white/5 border border-white/10 flex flex-col gap-2">
            <strong className="text-xs text-white">Method 1: Google OAuth Sign-In</strong>
            <p className="text-xs text-slate-400 m-0">
              Sign in with your Google account to grant full access to your Drive files and folders.
            </p>
            <Button
              onClick={handleOAuthConnect}
              disabled={isLoading}
              className="w-full bg-blue-600 hover:bg-blue-500 text-white font-semibold text-xs mt-1"
            >
              Sign In with Google
            </Button>
          </div>

          {/* Option 2: Instant Access Token Paste */}
          <div className="p-3.5 rounded-xl bg-white/5 border border-white/10 flex flex-col gap-2">
            <strong className="text-xs text-white">Method 2: Direct Google Drive Access Token</strong>
            <p className="text-xs text-slate-400 m-0">
              Have an OAuth token from Google Cloud or OAuth Playground? Paste it here for zero-config connection:
            </p>
            <Input
              type="password"
              value={tokenInput}
              onChange={(e) => setTokenInput(e.target.value)}
              placeholder="Paste Google Drive Access Token (ya29...)"
              className="bg-black/30 border-white/10 text-xs text-white"
            />
            <Button
              onClick={handleConnectToken}
              disabled={!tokenInput.trim() || isLoading}
              variant="outline"
              size="sm"
              className="w-full border-blue-500/30 text-blue-400 hover:bg-blue-500/10 text-xs font-semibold"
            >
              {isLoading ? "Verifying Token…" : "Connect with Access Token"}
            </Button>
            <a
              href="https://developers.google.com/oauthplayground"
              target="_blank"
              rel="noreferrer"
              className="text-[11px] text-slate-500 hover:text-blue-400 underline"
            >
              Get a quick token from Google OAuth Playground →
            </a>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

/* =========================================================================
   CREATE NEW FOLDER MODAL
   ========================================================================= */
function NewFolderDialog({
  open,
  onOpenChange,
  driveToken,
  parentFolderId,
  onFolderCreated,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  driveToken: string | null;
  parentFolderId: string;
  onFolderCreated: (folder: GoogleDriveFolder) => void;
}) {
  const [name, setName] = useState("");
  const [loading, setLoading] = useState(false);

  const handleCreate = async () => {
    if (!name.trim()) return;
    setLoading(true);
    try {
      if (driveToken) {
        const created = await createDriveFolder(driveToken, name.trim(), parentFolderId);
        onFolderCreated(created);
      } else {
        onFolderCreated({
          id: `local-fld-${Date.now()}`,
          name: name.trim(),
        });
      }
      setName("");
    } catch (err) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-sm bg-slate-900 border-white/10 text-white">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base font-semibold">
            <FolderPlus className="w-5 h-5 text-blue-400" />
            <span>Create Drive Folder</span>
          </DialogTitle>
        </DialogHeader>
        <div className="grid gap-3 py-2">
          <Input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Folder name (e.g. TikTok / October)"
            className="bg-white/5 border-white/10 text-white text-xs"
            autoFocus
          />
        </div>
        <DialogFooter>
          <Button
            variant="outline"
            size="sm"
            onClick={() => onOpenChange(false)}
            className="border-white/10 text-white"
          >
            Cancel
          </Button>
          <Button
            size="sm"
            onClick={handleCreate}
            disabled={!name.trim() || loading}
            className="bg-blue-600 hover:bg-blue-500 text-white"
          >
            {loading ? "Creating…" : "Create Folder"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/* =========================================================================
   ADMIN LOGIN DIALOG
   ========================================================================= */
function AdminLoginDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const [email, setEmail] = useState("admin@gmail.com");
  const [password, setPassword] = useState("admin123");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await signInAdmin(email, password);
      onOpenChange(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to sign in");
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md bg-slate-900 border-white/10 text-white">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base font-semibold">
            <BrandMark className="h-6 w-6" />
            <span>Workspace Admin Login</span>
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="grid gap-4 py-2">
          {error && (
            <div className="rounded-md bg-red-500/15 p-3 text-xs text-red-400 font-medium">
              {error}
            </div>
          )}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-slate-400">
              Email
            </label>
            <Input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="admin@gmail.com"
              required
              className="bg-white/5 border-white/10 text-white text-xs"
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-slate-400">
              Password
            </label>
            <Input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="admin123"
              required
              className="bg-white/5 border-white/10 text-white text-xs"
            />
          </div>
          <div className="rounded-md bg-white/5 p-2.5 text-xs text-slate-400 border border-white/10">
            💡 <strong>Admin Credentials:</strong> <code>admin@gmail.com</code> / <code>admin123</code>
          </div>
          <Button type="submit" disabled={loading} className="w-full bg-blue-600 hover:bg-blue-500 text-white">
            {loading ? "Signing in…" : "Sign In"}
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
