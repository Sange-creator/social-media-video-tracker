"use client";

import { useMemo, useRef, useState } from "react";
import {
  Check,
  ChevronRight,
  Cloud,
  Copy,
  Download,
  FileImage,
  Film,
  Folder,
  FolderPlus,
  Grid2X2,
  List,
  MoreHorizontal,
  Search,
  Star,
  Trash2,
  Upload,
  Users,
  Edit2,
  ArrowRight,
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
  DialogTrigger,
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
  useFolders,
  useCreateFolder,
  useMediaLibrary,
  useMediaOperations,
  useSaveUploadText,
  useUploadMedia,
  useAssignments,
} from "@/lib/media";
import type { MediaItem } from "@/lib/types";
import { signIn, signInAdmin, signOut, useSession } from "@/lib/supabase";

function BrandMark({ className = "h-9 w-9" }: { className?: string }) {
  return (
    <svg viewBox="0 0 48 48" className={className} aria-hidden="true">
      <rect x="5" y="7" width="30" height="34" rx="7" fill="currentColor" />
      <path d="M18 17.5v13l10.5-6.5L18 17.5Z" fill="white" />
      <path
        d="M32 19h7a4 4 0 0 1 4 4v12a4 4 0 0 1-4 4H27l5-5V19Z"
        fill="#2563EB"
        stroke="white"
        strokeWidth="2"
      />
      <path d="M35 25h4M35 29h4" stroke="white" strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
}

export default function Home() {
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedFolderId, setSelectedFolderId] = useState<string | null>(null);
  const [selectedFolderName, setSelectedFolderName] = useState<string>("All files");
  const [viewFilter, setViewFilter] = useState<"all" | "starred" | "trash">("all");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [uploadOpen, setUploadOpen] = useState(false);
  const [newFolderOpen, setNewFolderOpen] = useState(false);
  const [teamOpen, setTeamOpen] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [loginOpen, setLoginOpen] = useState(false);

  const session = useSession();
  const library = useMediaLibrary();
  const foldersQuery = useFolders();
  const mediaOps = useMediaOperations();
  const assignmentsQuery = useAssignments();

  // Filter media items
  const items = useMemo(() => {
    let list = library.data ?? [];
    if (viewFilter === "starred") {
      list = list.filter((i) => i.starred && !i.trashed);
    } else if (viewFilter === "trash") {
      list = list.filter((i) => i.trashed);
    } else {
      list = list.filter((i) => !i.trashed);
      if (selectedFolderId && selectedFolderId !== "root") {
        list = list.filter((i) => i.folder.includes(selectedFolderId) || i.folder.includes(selectedFolderName));
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
  }, [library.data, viewFilter, selectedFolderId, selectedFolderName, query]);

  const selected = items.find((item) => item.id === selectedId) ?? items[0] ?? null;

  // Toggle multiselect
  const toggleSelect = (id: string, event: React.MouseEvent) => {
    event.stopPropagation();
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const clearSelection = () => setSelectedIds(new Set());

  return (
    <main className="workspace-shell">
      {/* Top Header */}
      <header className="topbar">
        <div className="brand">
          <BrandMark />
          <div>
            <strong>Social Media Video Tracker</strong>
            <span>Content workspace</span>
          </div>
        </div>

        <div className="search-wrap">
          <Search />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search media, text, or folders…"
            aria-label="Search media"
          />
        </div>

        <div className="top-actions">
          <span className="sync-state">
            <Cloud /> {session ? "Synced" : "Preview mode"}
          </span>
          {session ? (
            <>
              <UploadDialog
                open={uploadOpen}
                onOpenChange={setUploadOpen}
                defaultFolderId={selectedFolderId ?? "root"}
                defaultFolderName={selectedFolderName}
              />
              <button
                className="avatar"
                onClick={() => signOut()}
                aria-label="Sign out"
                title={`Signed in as ${session.user.email ?? "Admin"} (Click to sign out)`}
              >
                {session.user.email?.slice(0, 2).toUpperCase() ?? "AD"}
              </button>
            </>
          ) : (
            <>
              <Button onClick={() => setLoginOpen(true)}>Sign in</Button>
              <button
                className="avatar"
                onClick={() => setLoginOpen(true)}
                aria-label="Sign in"
                title="Click to sign in"
              >
                ST
              </button>
            </>
          )}
        </div>
      </header>

      {/* Sidebar */}
      <aside className="sidebar">
        <nav aria-label="Workspace navigation">
          <NavItem
            icon={<Folder />}
            label="All files"
            active={viewFilter === "all" && !selectedFolderId}
            count={String((library.data ?? []).filter((i) => !i.trashed).length)}
            onClick={() => {
              setViewFilter("all");
              setSelectedFolderId(null);
              setSelectedFolderName("All files");
            }}
          />
          <NavItem
            icon={<Star />}
            label="Starred"
            active={viewFilter === "starred"}
            count={String((library.data ?? []).filter((i) => i.starred && !i.trashed).length)}
            onClick={() => {
              setViewFilter("starred");
              setSelectedFolderId(null);
              setSelectedFolderName("Starred");
            }}
          />
          <NavItem
            icon={<Trash2 />}
            label="Trash"
            active={viewFilter === "trash"}
            count={String((library.data ?? []).filter((i) => i.trashed).length)}
            onClick={() => {
              setViewFilter("trash");
              setSelectedFolderId(null);
              setSelectedFolderName("Trash");
            }}
          />
          <NavItem
            icon={<Users />}
            label="Team"
            count="1"
            onClick={() => setTeamOpen(true)}
          />
        </nav>

        {/* Google Drive Folders */}
        <div className="side-section">
          <div className="side-heading">
            <span>Google Drive</span>
            <button
              onClick={() => setNewFolderOpen(true)}
              aria-label="Add Drive folder"
              title="Create new subfolder"
            >
              <FolderPlus />
            </button>
          </div>
          {(foldersQuery.data?.grants ?? []).map((grant) => (
            <FolderItem
              key={grant.id}
              label={grant.name}
              count={String(
                (library.data ?? []).filter(
                  (i) => !i.trashed && (i.folder.includes(grant.name) || i.folder.includes(grant.driveFolderId))
                ).length
              )}
              active={selectedFolderId === grant.driveFolderId}
              onClick={() => {
                setViewFilter("all");
                setSelectedFolderId(grant.driveFolderId);
                setSelectedFolderName(grant.name);
              }}
            />
          ))}
        </div>

        {/* Content Accounts Section */}
        {assignmentsQuery.data?.accounts && assignmentsQuery.data.accounts.length > 0 && (
          <div className="side-section">
            <div className="side-heading">
              <span>Content accounts</span>
            </div>
            {assignmentsQuery.data.accounts.map(({ account, assignments }) => (
              <AccountItem
                key={account.id}
                color="#2563EB"
                label={account.name}
                count={`${assignments.filter((a) => a.state === "completed").length}/${account.daily_quota}`}
              />
            ))}
          </div>
        )}

        <div className="storage-card">
          <div>
            <span>Drive storage</span>
            <strong>21.4 GB / 100 GB</strong>
          </div>
          <Progress value={21.4} />
        </div>
      </aside>

      {/* Main Library Pane */}
      <section className="library-pane">
        <div className="library-heading">
          <div>
            <p>{viewFilter === "starred" ? "Favorites" : viewFilter === "trash" ? "Deleted" : selectedFolderName}</p>
            <h1>{viewFilter === "starred" ? "Starred media" : viewFilter === "trash" ? "Trash" : "All media"}</h1>
          </div>
          <div className="library-tools">
            <span>{items.length} items</span>
            <div className="view-toggle" aria-label="View style">
              <button
                className={view === "grid" ? "active" : ""}
                onClick={() => setView("grid")}
                aria-label="Grid view"
              >
                <Grid2X2 />
              </button>
              <button
                className={view === "list" ? "active" : ""}
                onClick={() => setView("list")}
                aria-label="List view"
              >
                <List />
              </button>
            </div>
          </div>
        </div>

        {/* Breadcrumbs & Batch Action Toolbar */}
        <div className="breadcrumbs">
          <span>My Drive</span>
          <ChevronRight />
          <strong>{selectedFolderName}</strong>
          {selectedIds.size > 0 && (
            <div className="flex items-center gap-2 ml-auto text-xs">
              <span className="font-semibold text-primary">{selectedIds.size} selected</span>
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  mediaOps.mutate({
                    action: "star",
                    mediaIds: Array.from(selectedIds),
                    starred: true,
                  });
                  clearSelection();
                }}
              >
                <Star className="h-3 w-3 mr-1" /> Star
              </Button>
              <Button
                size="sm"
                variant="outline"
                className="text-destructive"
                onClick={() => {
                  mediaOps.mutate({
                    action: "trash",
                    mediaIds: Array.from(selectedIds),
                    trashed: viewFilter !== "trash",
                  });
                  clearSelection();
                }}
              >
                <Trash2 className="h-3 w-3 mr-1" />
                {viewFilter === "trash" ? "Restore" : "Trash"}
              </Button>
              <Button size="sm" variant="ghost" onClick={clearSelection}>
                <X className="h-3 w-3" />
              </Button>
            </div>
          )}
        </div>

        {/* Media Items Grid / List */}
        {library.isLoading ? (
          <MediaSkeleton />
        ) : items.length === 0 ? (
          <div className="empty">
            <Search />
            <h2>No matching files</h2>
            <p>Drop a photo or video to upload, or try another search.</p>
          </div>
        ) : (
          <div className={view === "grid" ? "media-grid" : "media-list"}>
            {items.map((item) => (
              <MediaCard
                key={item.id}
                item={item}
                selected={selected?.id === item.id}
                checked={selectedIds.has(item.id)}
                onCheck={(e) => toggleSelect(item.id, e)}
                onSelect={() => setSelectedId(item.id)}
              />
            ))}
          </div>
        )}
      </section>

      {/* Inspector Pane */}
      <Inspector
        key={selected?.id ?? "none"}
        item={selected}
        folders={foldersQuery.data?.grants ?? []}
      />

      {/* New Folder Modal */}
      <NewFolderDialog
        open={newFolderOpen}
        onOpenChange={setNewFolderOpen}
        parentFolderId={selectedFolderId ?? "root"}
      />

      {/* Team Management Modal */}
      <TeamDialog open={teamOpen} onOpenChange={setTeamOpen} />

      {/* Admin Sign-In Modal */}
      <LoginDialog open={loginOpen} onOpenChange={setLoginOpen} />
    </main>
  );
}

function NavItem({
  icon,
  label,
  active,
  count,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
  count?: string;
  onClick?: () => void;
}) {
  return (
    <button className={`nav-item ${active ? "active" : ""}`} onClick={onClick}>
      {icon}
      <span>{label}</span>
      {count && <small>{count}</small>}
    </button>
  );
}

function FolderItem({
  label,
  count,
  active,
  onClick,
}: {
  label: string;
  count: string;
  active?: boolean;
  onClick?: () => void;
}) {
  return (
    <button className={`folder-item ${active ? "active" : ""}`} onClick={onClick}>
      <Folder />
      <span>{label}</span>
      <small>{count}</small>
    </button>
  );
}

function AccountItem({ color, label, count }: { color: string; label: string; count: string }) {
  return (
    <button className="folder-item">
      <i style={{ background: color }} />
      <span>{label}</span>
      <small>{count}</small>
    </button>
  );
}

function MediaCard({
  item,
  selected,
  checked,
  onCheck,
  onSelect,
}: {
  item: MediaItem;
  selected: boolean;
  checked: boolean;
  onCheck: (e: React.MouseEvent) => void;
  onSelect: () => void;
}) {
  return (
    <button className={`media-card ${selected ? "selected" : ""}`} onClick={onSelect}>
      <div className={`poster poster-${item.accent}`}>
        {item.kind === "video" ? <Film /> : <FileImage />}
        {item.duration && <span className="duration">{item.duration}</span>}
        {item.starred && <Star className="starred" fill="currentColor" />}
        <input
          type="checkbox"
          checked={checked}
          onClick={onCheck}
          onChange={() => {}}
          className="absolute top-2 right-2 h-4 w-4 rounded accent-primary cursor-pointer"
          aria-label={`Select ${item.name}`}
        />
      </div>
      <div className="media-meta">
        <strong title={item.name}>{item.name}</strong>
        <span>
          {item.size} · {item.updatedLabel}
        </span>
      </div>
    </button>
  );
}

function Inspector({
  item,
  folders,
}: {
  item: MediaItem | null;
  folders: Array<{ id: string; driveFolderId: string; name: string }>;
}) {
  const [draft, setDraft] = useState(item?.uploadText ?? "");
  const [copied, setCopied] = useState(false);
  const [renameOpen, setRenameOpen] = useState(false);
  const [moveOpen, setMoveOpen] = useState(false);
  const [renameDraft, setRenameDraft] = useState("");
  const [targetFolderId, setTargetFolderId] = useState("");

  const save = useSaveUploadText();
  const ops = useMediaOperations();

  if (!item) {
    return (
      <aside className="inspector empty-inspector">
        <FileImage />
        <p>Select a file to inspect it.</p>
      </aside>
    );
  }

  const text = draft;
  const isDirty = text !== item.uploadText;

  async function copyText() {
    if (!text) return;
    await navigator.clipboard.writeText(text);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  }

  const streamUrl = `/api/v1/media/${item.id}/stream`;
  const downloadUrl = `/api/v1/media/${item.id}/stream?download=1`;

  return (
    <aside className="inspector">
      {/* Live Preview / Poster */}
      <div className={`preview poster-${item.accent} overflow-hidden rounded-lg relative`}>
        {item.kind === "video" ? (
          <video
            key={item.id}
            src={streamUrl}
            controls
            playsInline
            preload="metadata"
            className="w-full h-full object-contain bg-black"
          />
        ) : (
          /* eslint-disable-next-line @next/next/no-img-element */
          <img
            key={item.id}
            src={streamUrl}
            alt={item.name}
            className="w-full h-full object-contain"
          />
        )}
      </div>

      <div className="inspector-title">
        <div>
          <span>{item.kind}</span>
          <h2 title={item.name}>{item.name}</h2>
        </div>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button size="icon" variant="ghost">
              <MoreHorizontal />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              onClick={() => {
                setRenameDraft(item.name);
                setRenameOpen(true);
              }}
            >
              <Edit2 className="h-4 w-4 mr-2" /> Rename
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() => {
                setTargetFolderId(folders[0]?.driveFolderId ?? "root");
                setMoveOpen(true);
              }}
            >
              <ArrowRight className="h-4 w-4 mr-2" /> Move
            </DropdownMenuItem>
            <DropdownMenuItem
              onClick={() =>
                ops.mutate({
                  action: "star",
                  mediaId: item.id,
                  starred: !item.starred,
                })
              }
            >
              <Star className="h-4 w-4 mr-2" />
              {item.starred ? "Unstar" : "Star"}
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem
              className="text-destructive"
              onClick={() =>
                ops.mutate({
                  action: "trash",
                  mediaId: item.id,
                  trashed: !item.trashed,
                })
              }
            >
              <Trash2 className="h-4 w-4 mr-2" />
              {item.trashed ? "Restore from Trash" : "Move to Trash"}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>

      <dl className="facts">
        <div>
          <dt>Folder</dt>
          <dd>{item.folder}</dd>
        </div>
        <div>
          <dt>Size</dt>
          <dd>{item.size}</dd>
        </div>
        <div>
          <dt>Modified</dt>
          <dd>{item.updatedLabel}</dd>
        </div>
      </dl>

      <div className="caption-heading">
        <div>
          <h3>Upload text</h3>
          <span>
            {save.isPending ? "Saving…" : isDirty ? "Unsaved" : save.isSuccess ? "Synced" : "Ready"}
          </span>
        </div>
        <small>Title, caption, and hashtags stay together.</small>
      </div>

      <Textarea
        key={item.id}
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        placeholder="Paste the complete upload paragraph here…"
        className="caption-box"
      />
      <div className="character-count">{draft.length.toLocaleString()} characters</div>

      <div className="inspector-actions">
        <Button
          variant="outline"
          disabled={!isDirty || save.isPending}
          onClick={() => save.mutate({ id: item.id, text: draft, revision: item.revision })}
        >
          {save.isPending ? "Saving…" : "Save"}
        </Button>
        <Button disabled={!draft} onClick={copyText}>
          {copied ? <Check /> : <Copy />}
          {copied ? "Copied" : "Copy text"}
        </Button>
      </div>

      <a href={downloadUrl} download={item.name} className="block mt-2">
        <Button variant="outline" className="w-full">
          <Download className="mr-2 h-4 w-4" /> Download original
        </Button>
      </a>

      {/* Rename Dialog */}
      <Dialog open={renameOpen} onOpenChange={setRenameOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Rename file</DialogTitle>
          </DialogHeader>
          <Input
            value={renameDraft}
            onChange={(e) => setRenameDraft(e.target.value)}
            placeholder="Enter file name"
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setRenameOpen(false)}>
              Cancel
            </Button>
            <Button
              disabled={!renameDraft.trim() || renameDraft === item.name}
              onClick={() => {
                ops.mutate(
                  { action: "rename", mediaId: item.id, name: renameDraft.trim() },
                  { onSuccess: () => setRenameOpen(false) }
                );
              }}
            >
              Rename
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Move Dialog */}
      <Dialog open={moveOpen} onOpenChange={setMoveOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Move to folder</DialogTitle>
          </DialogHeader>
          <div className="grid gap-2">
            {folders.map((f) => (
              <Button
                key={f.id}
                variant={targetFolderId === f.driveFolderId ? "default" : "outline"}
                className="justify-start"
                onClick={() => setTargetFolderId(f.driveFolderId)}
              >
                <Folder className="h-4 w-4 mr-2" />
                {f.name}
              </Button>
            ))}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setMoveOpen(false)}>
              Cancel
            </Button>
            <Button
              disabled={!targetFolderId}
              onClick={() => {
                ops.mutate(
                  {
                    action: "move",
                    mediaId: item.id,
                    destinationFolderId: targetFolderId,
                  },
                  { onSuccess: () => setMoveOpen(false) }
                );
              }}
            >
              Move
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </aside>
  );
}

function UploadDialog({
  open,
  onOpenChange,
  defaultFolderId,
  defaultFolderName,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  defaultFolderId: string;
  defaultFolderName: string;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [text, setText] = useState<string>(() => {
    if (typeof window !== "undefined") {
      return localStorage.getItem("drivetracker_draft_upload_text") ?? "";
    }
    return "";
  });
  const upload = useUploadMedia();

  const handleTextChange = (val: string) => {
    setText(val);
    if (typeof window !== "undefined") {
      localStorage.setItem("drivetracker_draft_upload_text", val);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogTrigger asChild>
        <Button>
          <Upload /> Upload media
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Upload to {defaultFolderName}</DialogTitle>
        </DialogHeader>
        <button className="drop-zone" onClick={() => input.current?.click()}>
          <Upload />
          <strong>{file ? file.name : "Choose a video or photo"}</strong>
          <span>{file ? `${Math.round(file.size / 1_048_576)} MB` : "Saved directly into Google Drive"}</span>
        </button>
        <input
          ref={input}
          hidden
          type="file"
          accept="video/*,image/*"
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />
        <label className="upload-label">
          Upload text
          <Textarea
            value={text}
            onChange={(e) => handleTextChange(e.target.value)}
            placeholder="Paste the complete title, caption, and hashtags…"
          />
        </label>
        {upload.isPending && <Progress value={upload.progress} />}
        <Button
          disabled={!file || upload.isPending}
          onClick={() =>
            file &&
            upload.mutate(
              { file, text, folderId: defaultFolderId },
              {
                onSuccess: () => {
                  setFile(null);
                  setText("");
                  onOpenChange(false);
                },
              }
            )
          }
        >
          {upload.isPending ? `Uploading ${upload.progress}%` : "Upload and attach text"}
        </Button>
      </DialogContent>
    </Dialog>
  );
}

function NewFolderDialog({
  open,
  onOpenChange,
  parentFolderId,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  parentFolderId: string;
}) {
  const [name, setName] = useState("");
  const createFolder = useCreateFolder();

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Create new subfolder</DialogTitle>
        </DialogHeader>
        <Input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Folder name (e.g. October Reels)"
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            disabled={!name.trim() || createFolder.isPending}
            onClick={() => {
              createFolder.mutate(
                { name: name.trim(), parentFolderId },
                {
                  onSuccess: () => {
                    setName("");
                    onOpenChange(false);
                  },
                }
              );
            }}
          >
            {createFolder.isPending ? "Creating…" : "Create folder"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function TeamDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<"editor" | "viewer">("editor");
  const [inviteLink, setInviteLink] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const generateInvite = async () => {
    if (!email.trim()) return;
    setLoading(true);
    try {
      const res = await fetch("/api/v1/invitations", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ email: email.trim(), role }),
      });
      const data = (await res.json()) as { inviteLink?: string };
      if (data.inviteLink) setInviteLink(data.inviteLink);
    } catch {
      // Ignored
    } finally {
      setLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Team members & invitations</DialogTitle>
        </DialogHeader>
        <div className="grid gap-3">
          <label className="text-sm font-semibold">Invite teammate by email</label>
          <Input
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="teammate@example.com"
          />
          <div className="flex gap-2">
            <Button
              size="sm"
              variant={role === "editor" ? "default" : "outline"}
              onClick={() => setRole("editor")}
            >
              Editor
            </Button>
            <Button
              size="sm"
              variant={role === "viewer" ? "default" : "outline"}
              onClick={() => setRole("viewer")}
            >
              Viewer
            </Button>
          </div>
          <Button disabled={!email.trim() || loading} onClick={generateInvite}>
            {loading ? "Generating…" : "Generate invitation link"}
          </Button>
          {inviteLink && (
            <div className="p-3 bg-secondary rounded text-xs break-all">
              <span className="font-semibold block mb-1">Send this link to teammate:</span>
              <code>{inviteLink}</code>
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}

function MediaSkeleton() {
  return (
    <div className="media-grid">
      {Array.from({ length: 8 }).map((_, i) => (
        <div className="media-card skeleton" key={i}>
          <div className="poster" />
          <div className="media-meta">
            <strong />
            <span />
          </div>
        </div>
      ))}
    </div>
  );
}

function LoginDialog({
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
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-base font-semibold">
            <BrandMark className="h-6 w-6" />
            <span>Sign in to Content Workspace</span>
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="grid gap-4 py-2">
          {error && (
            <div className="rounded-md bg-destructive/15 p-3 text-xs text-destructive font-medium">
              {error}
            </div>
          )}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Email
            </label>
            <Input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="admin@gmail.com"
              required
              autoComplete="username"
            />
          </div>
          <div className="space-y-1.5">
            <label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              Password
            </label>
            <Input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="admin123"
              required
              autoComplete="current-password"
            />
          </div>
          <div className="rounded-md bg-muted/60 p-2.5 text-xs text-muted-foreground border">
            💡 <strong>Quick Access:</strong> Sign in with email <code>admin@gmail.com</code> and password <code>admin123</code>.
          </div>
          <Button type="submit" disabled={loading} className="w-full">
            {loading ? "Signing in…" : "Sign In to Workspace"}
          </Button>
          <div className="relative my-1">
            <div className="absolute inset-0 flex items-center">
              <span className="w-full border-t" />
            </div>
            <div className="relative flex justify-center text-xs uppercase">
              <span className="bg-background px-2 text-muted-foreground">or</span>
            </div>
          </div>
          <Button
            type="button"
            variant="outline"
            className="w-full"
            onClick={async () => {
              try {
                await signIn();
              } catch (err) {
                setError(err instanceof Error ? err.message : "Google Sign-In requires Supabase credentials.");
              }
            }}
          >
            Sign in with Google Drive
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}

