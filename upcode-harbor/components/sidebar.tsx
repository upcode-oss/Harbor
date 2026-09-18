"use client"

import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import {
  Server,
  Container,
  BarChart3,
  HardDrive,
  HardDriveDownload,
  Network,
  Shield,
  ShieldAlert,
  Users,
  Disc,
  FileText,
  Settings,
  Terminal,
  Store,
  GitBranch,
  ChevronDown,
  ChevronRight,
  LogOut,
  User,
  Sun,
  Moon,
  Monitor,
  Bell,
} from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { apiUrl } from "@/lib/api"
import { useTheme } from "next-themes"
import { useAuth } from "@/components/auth-provider"
import { useRouter } from "next/navigation"
import { UserSettings } from "@/components/user-settings"
import { Progress } from "@/components/ui/progress"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuPortal,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

interface SidebarProps {
  activeSection: string
  onSectionChange: (section: string) => void
}

interface SidebarItem {
  id: string
  label: string
  icon: React.ComponentType<{ className?: string }>
  requires: "admin" | "containers" | "vms" | "storage" | "shell" | "logs" | null
  subItems?: { id: string; label: string }[]
}

interface BackupJob {
  id: number
  name: string
}

interface BackupJobProgress {
  job_id?: number
  status: "idle" | "running" | "completed" | "failed"
  progress: number
  message: string
  job_name?: string
  updated_at?: string | null
}

interface Replication {
  id: string
  name: string
}

interface ReplicationProgress {
  replication_id?: string
  status: "idle" | "running" | "completed" | "failed"
  progress: number
  message: string
  name?: string
  updated_at?: string | null
}

type RecentStatusEntry = {
  id: string
  type: "backup" | "replication"
  name: string
  status: "running" | "completed" | "failed"
  progress: number
  message: string
  updatedAt: string
}

const NOTIFICATION_EVENT_KEYS = new Set([
  "container_create",
  "container_start",
  "container_stop",
  "container_crash",
  "container_delete",
  "vm_create",
  "vm_start",
  "vm_stop",
  "vm_delete",
  "backup_started",
  "backup_success",
  "backup_failure",
  "replication_started",
  "replication_success",
  "replication_failure",
  "system_alert",
])

export function Sidebar({ activeSection, onSectionChange }: SidebarProps) {
  const [hostname, setHostname] = useState("")
  const { theme, setTheme, resolvedTheme } = useTheme()
  const [storageExpanded, setStorageExpanded] = useState(false)
  const [userSettingsOpen, setUserSettingsOpen] = useState(false)
  const { setToken, username, permissions } = useAuth()
  const router = useRouter()
  const [hasCustomLogo, setHasCustomLogo] = useState(false)
  const [logoTimestamp, setLogoTimestamp] = useState(Date.now())
  const [activityLines, setActivityLines] = useState<string[]>([])
  const [lastSeenActivity, setLastSeenActivity] = useState("")
  const [activityOpen, setActivityOpen] = useState(false)
  const [recentStatusChanges, setRecentStatusChanges] = useState<RecentStatusEntry[]>([])
  const finalizedProgressIdsRef = useRef<Set<string>>(new Set())

  const handleLogout = () => {
    setToken(null)
    router.push("/login")
  }

  useEffect(() => {
    const loadHostname = async () => {
      try {
        const res = await fetch(apiUrl("/info"))
        if (res.ok) {
          const data = await res.json()
          setHostname(data.hostname)
        }
      } catch (err) {
        console.error(err)
      }
    }
    const loadCustomization = async () => {
      try {
        const res = await fetch(apiUrl("/settings/customization"))
        if (res.ok) {
          const data = await res.json()
          setHasCustomLogo(data.has_logo === true)
          setLogoTimestamp(Date.now())
        }
      } catch {
        // silently fall back to default
      }
    }
    loadHostname()
    loadCustomization()
  }, [])

  useEffect(() => {
    const extractNotificationEvent = (line: string) => {
      const match = line.match(/event=([a-z_]+)/)
      if (!match) return null
      return match[1]
    }

    const loadActivity = async () => {
      try {
        const res = await fetch(apiUrl("/logs/activity?lines=25"))
        if (!res.ok) return
        const text = await res.text()
        const lines = text
          .split("\n")
          .map((line) => line.trim())
          .filter(Boolean)
          .filter((line) => {
            const event = extractNotificationEvent(line)
            return !!event && NOTIFICATION_EVENT_KEYS.has(event)
          })
          .reverse()
        setActivityLines(lines)
      } catch {
        // Keep last known activity list if fetch fails.
      }
    }

    const loadRunningProgress = async () => {
      try {
        const backupJobsRes = await fetch(apiUrl("/backup/jobs"))
        if (backupJobsRes.ok) {
          const backupJobs = (await backupJobsRes.json()) as BackupJob[]
          const backupEntries = await Promise.all(
            backupJobs
              .filter((job) => !finalizedProgressIdsRef.current.has(`backup-${job.id}`))
              .map(async (job) => {
              try {
                const progressRes = await fetch(apiUrl(`/backup/jobs/${job.id}/progress`))
                if (!progressRes.ok) return null
                const progress = (await progressRes.json()) as BackupJobProgress
                // Only include non-idle status
                if (progress.status === "idle") return null
                const entry: RecentStatusEntry = {
                  id: `backup-${job.id}`,
                  type: "backup" as const,
                  name: progress.job_name || job.name || `Job #${job.id}`,
                  status: progress.status as "running" | "completed" | "failed",
                  progress: progress.progress,
                  message: progress.message,
                  updatedAt: progress.updated_at || new Date().toISOString(),
                }
                if (entry.status === "completed" || entry.status === "failed") {
                  finalizedProgressIdsRef.current.add(entry.id)
                }
                return entry
              } catch {
                return null
              }
            })
          )
          const validBackups = backupEntries.filter((entry): entry is RecentStatusEntry => !!entry)

          const replicationsRes = await fetch(apiUrl("/cluster/replications"))
          let validReplications: typeof validBackups = []
          if (replicationsRes.ok) {
            const replications = (await replicationsRes.json()) as Replication[]
            const replicationEntries = await Promise.all(
              replications
                .filter((replication) => !finalizedProgressIdsRef.current.has(`replication-${replication.id}`))
                .map(async (replication) => {
                try {
                  const progressRes = await fetch(apiUrl(`/cluster/replications/${replication.id}/progress`))
                  if (!progressRes.ok) return null
                  const progress = (await progressRes.json()) as ReplicationProgress
                  // Only include non-idle status
                  if (progress.status === "idle") return null
                  const entry: RecentStatusEntry = {
                    id: `replication-${replication.id}`,
                    type: "replication" as const,
                    name: progress.name || replication.name || replication.id,
                    status: progress.status as "running" | "completed" | "failed",
                    progress: progress.progress,
                    message: progress.message,
                    updatedAt: progress.updated_at || new Date().toISOString(),
                  }
                  if (entry.status === "completed" || entry.status === "failed") {
                    finalizedProgressIdsRef.current.add(entry.id)
                  }
                  return entry
                } catch {
                  return null
                }
              })
            )
            validReplications = replicationEntries.filter((entry): entry is RecentStatusEntry => !!entry)
          }

          // Merge fetched updates into existing cache, keep most recent 10.
          setRecentStatusChanges((previous) => {
            const byId = new Map<string, RecentStatusEntry>(previous.map((entry) => [entry.id, entry]))
            for (const entry of [...validBackups, ...validReplications]) {
              byId.set(entry.id, entry)
            }
            return Array.from(byId.values())
              .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime())
              .slice(0, 10)
          })
        }
        // On error or non-OK response, keep the previous list
      } catch {
        // On error, keep the previous list
      }
    }

    loadActivity()
    loadRunningProgress()
    const activityInterval = window.setInterval(loadActivity, 10000)
    const progressInterval = window.setInterval(loadRunningProgress, 10000)
    return () => {
      window.clearInterval(activityInterval)
      window.clearInterval(progressInterval)
    }
  }, [])

  useEffect(() => {
    if (activityOpen && activityLines.length > 0) {
      setLastSeenActivity(activityLines[0])
    }
  }, [activityOpen, activityLines])

  const unreadActivities = (() => {
    if (!activityLines.length) return 0
    if (!lastSeenActivity) return 0
    const seenIndex = activityLines.indexOf(lastSeenActivity)
    if (seenIndex === -1) return Math.min(activityLines.length, 25)
    return seenIndex
  })()

  const formatActivityLine = (line: string) => {
    const eventMatch = line.match(/event=([a-z_]+)/)
    if (eventMatch) {
      const prettyEvent = eventMatch[1].replace(/_/g, " ")
      const splitMarker = " – "
      const markerIndex = line.indexOf(splitMarker)
      const message = markerIndex >= 0 ? line.slice(markerIndex + splitMarker.length) : line
      const prefixMatch = line.match(/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+\[[^\]]+\])/)
      const prefix = prefixMatch ? `${prefixMatch[1]} ` : ""
      return `${prefix}${prettyEvent.toUpperCase()} ${message}`.trim()
    }

    try {
      const parsed = JSON.parse(line)
      const timestamp = parsed.timestamp || parsed.time || ""
      const level = parsed.level || parsed.severity || "info"
      const message = parsed.message || parsed.msg || line
      return `${timestamp} [${String(level).toUpperCase()}] ${message}`.trim()
    } catch {
      return line
    }
  }

  const categories: { title: string; items: SidebarItem[] }[] = [
    {
      title: "System",
      items: [
        { id: "dashboard", label: "Dashboard", icon: BarChart3, requires: null },
        { id: "shell",     label: "Shell",     icon: Terminal,  requires: "shell" as const },
        { id: "cluster",  label: "Cluster",   icon: GitBranch, requires: null },
      ],
    },
    {
      title: "Compute",
      items: [
        { id: "vms",        label: "Virtual Machines", icon: Server,    requires: "vms" as const },
        { id: "containers", label: "Container",        icon: Container, requires: "containers" as const },
        { id: "compose",    label: "Compose Builder",  icon: FileText,  requires: "containers" as const },
      ],
    },
    {
      title: "Resources",
      items: [
        { id: "images", label: "Images & ISOs", icon: Disc, requires: null },
        {
          id: "storage",
          label: "Storage",
          icon: HardDrive,
          requires: "storage" as const,
          subItems: [
            { id: "storage",           label: "Physical Storage" },
            { id: "container-storage", label: "Container Storage" },
          ]
        },
      ],
    },
    {
      title: "Administration",
      items: [
        { id: "app-store", label: "App Store", icon: Store,      requires: "containers" as const },
        { id: "settings",  label: "Settings",  icon: Settings,  requires: "admin" as const },
        { id: "users",     label: "Users",     icon: Users,     requires: "admin" as const },
        { id: "backup",    label: "Backup",    icon: HardDriveDownload,    requires: "admin" as const },
        { id: "security",  label: "Security",  icon: ShieldAlert, requires: "admin" as const },
        { id: "network",   label: "Network",   icon: Network,   requires: "admin" as const },
        { id: "firewall",  label: "Firewall",  icon: Shield,    requires: "admin" as const },
        { id: "logs",      label: "Logs",      icon: FileText,  requires: "logs" as const },
      ],
    },
  ]

  // Filter items the current user has no access to
  const hasPermission = (requires: "admin" | "containers" | "vms" | "storage" | "shell" | "logs" | null) => {
    if (!requires) return true
    return permissions[requires] === true
  }

  return (
    <div className="w-64 upcode-harbor-sidebar flex flex-col">
      <div className="p-6 border-b border-sidebar-border/30">
        <div className="flex items-center justify-center mb-4">
          <img
            src={
              hasCustomLogo
                ? `${apiUrl("/settings/customization/logo/file")}?t=${logoTimestamp}`
                : theme === "dark"
                ? "/logo_light.png"
                : "/logo.png"
            }
            alt="Upcode Harbor Logo"
            className="h-32 w-auto max-w-full object-contain"
          />
        </div>
        <div className="space-y-1">
          <div className="flex items-center space-x-2">
            <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
            <p className="text-sm text-muted-foreground font-medium">{hostname || "Local Server"}</p>
          </div>
          <p className="text-xs text-muted-foreground/60 font-mono pl-4">v0.7.0</p>
        </div>
      </div>
      <nav className="flex-1 p-4 space-y-6">
        {categories.map((category) => {
          const visibleItems = category.items.filter((item) => hasPermission(item.requires ?? null))
          if (visibleItems.length === 0) return null
          return (
          <div key={category.title} className="space-y-3">
            <div className="px-3 text-xs font-bold text-muted-foreground uppercase tracking-wide">
              {category.title}
            </div>
            <div className="space-y-1">
              {visibleItems.map((item) => {
                const Icon = item.icon
                const isActive = activeSection === item.id
                const hasSubItems = item.subItems && item.subItems.length > 0
                const isExpanded = item.id === "storage" ? storageExpanded : false

                return (
                  <div key={item.id}>
                    <Button
                      variant="ghost"
                      className={cn(
                        "w-full justify-start h-11 font-medium transition-all duration-200 rounded-none",
                        isActive 
                          ? "bg-primary/70 text-white shadow-sm" 
                          : "hover:bg-primary/50 hover:border-l-4 hover:border-primary hover:text-white"
                      )}
                      onClick={() => {
                        if (hasSubItems) {
                          if (item.id === "storage") {
                            setStorageExpanded(!storageExpanded)
                          }
                        } else {
                          onSectionChange(item.id)
                        }
                      }}
                    >
                      <Icon className={cn(
                        "mr-3 h-4 w-4 transition-colors",
                        isActive ? "text-white" : "text-muted-foreground"
                      )} />
                      {item.label}
                      {hasSubItems && (
                        <div className="ml-auto">
                          {isExpanded ? (
                            <ChevronDown className="h-4 w-4" />
                          ) : (
                            <ChevronRight className="h-4 w-4" />
                          )}
                        </div>
                      )}

                    </Button>
                    {hasSubItems && isExpanded && (
                      <div className="ml-6 space-y-1 mt-1">
                        {item.subItems?.map((subItem) => {
                          const subIsActive = activeSection === subItem.id
                          return (
                            <Button
                              key={subItem.id}
                              variant="ghost"
                              className={cn(
                                "w-full justify-start h-9 font-normal text-sm transition-all duration-200 rounded-none",
                                subIsActive 
                                  ? "bg-primary/50 text-white" 
                                  : "hover:bg-primary/30 hover:text-white"
                              )}
                              onClick={() => onSectionChange(subItem.id)}
                            >
                              {subItem.label}

                            </Button>
                          )
                        })}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          </div>
          )
        })}
      </nav>
      <div className="p-4 border-t border-sidebar-border/30">
        <DropdownMenu open={activityOpen} onOpenChange={setActivityOpen}>
          <DropdownMenuTrigger asChild>
            <button
              className="w-full flex items-center justify-between px-3 py-2 mb-2 rounded-md text-sm text-muted-foreground hover:text-foreground hover:bg-primary/10 transition-colors"
              aria-label="Show recent activity"
            >
              <span className="flex items-center gap-2">
                <Bell className="h-4 w-4" />
                <span>Activity</span>
              </span>
              {unreadActivities > 0 ? (
                <span className="min-w-5 h-5 px-1.5 rounded-full bg-primary text-primary-foreground text-xs leading-5 font-semibold">
                  {unreadActivities > 9 ? "9+" : unreadActivities}
                </span>
              ) : (
                <span className="text-xs text-muted-foreground/70">0</span>
              )}
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuPortal>
            <DropdownMenuContent align="end" sideOffset={8} className="w-[36rem] max-w-[calc(100vw-2rem)] p-0 z-[10000]">
              <div className="px-4 py-3 text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                Recent Activity
              </div>

              {recentStatusChanges.length > 0 && (
                <>
                  <DropdownMenuSeparator />
                  <div className="px-3 py-3 space-y-3 bg-muted/20">
                    {recentStatusChanges.filter((entry) => entry.type === "backup").length > 0 && (
                      <div className="space-y-2">
                        <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">Recent Backups</div>
                        <div className="space-y-2">
                          {recentStatusChanges
                            .filter((entry) => entry.type === "backup")
                            .map((entry) => (
                              <div key={entry.id} className="rounded-md border bg-background/70 px-2.5 py-2">
                                <div className="flex items-center justify-between gap-2 text-xs mb-1">
                                  <span className="font-medium truncate">{entry.name}</span>
                                  <div className="flex items-center gap-2">
                                    <span className="text-[10px] font-medium px-1.5 py-0.5 rounded-full bg-muted text-muted-foreground capitalize">
                                      {entry.status}
                                    </span>
                                    {entry.status === "running" && (
                                      <span className="text-muted-foreground">{entry.progress}%</span>
                                    )}
                                  </div>
                                </div>
                                {entry.status === "running" && <Progress value={entry.progress} className="h-1.5 mb-1" />}
                                <div className="text-[11px] text-muted-foreground truncate">{entry.message}</div>
                              </div>
                            ))}
                        </div>
                      </div>
                    )}

                    {recentStatusChanges.filter((entry) => entry.type === "replication").length > 0 && (
                      <div className="space-y-2">
                        <div className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">Recent Replications</div>
                        <div className="space-y-2">
                          {recentStatusChanges
                            .filter((entry) => entry.type === "replication")
                            .map((entry) => (
                              <div key={entry.id} className="rounded-md border bg-background/70 px-2.5 py-2">
                                <div className="flex items-center justify-between gap-2 text-xs mb-1">
                                  <span className="font-medium truncate">{entry.name}</span>
                                  <div className="flex items-center gap-2">
                                    <span className="text-[10px] font-medium px-1.5 py-0.5 rounded-full bg-muted text-muted-foreground capitalize">
                                      {entry.status}
                                    </span>
                                    {entry.status === "running" && (
                                      <span className="text-muted-foreground">{entry.progress}%</span>
                                    )}
                                  </div>
                                </div>
                                {entry.status === "running" && <Progress value={entry.progress} className="h-1.5 mb-1" />}
                                <div className="text-[11px] text-muted-foreground truncate">{entry.message}</div>
                              </div>
                            ))}
                        </div>
                      </div>
                    )}
                  </div>
                </>
              )}

              <DropdownMenuSeparator />
              <div className="max-h-[28rem] overflow-y-auto p-3 space-y-1.5">
                {activityLines.length === 0 ? (
                  <div className="px-2 py-3 text-sm text-muted-foreground">No recent activity available.</div>
                ) : (
                  activityLines.slice(0, 20).map((line, index) => (
                    <div
                      key={`${line}-${index}`}
                      className="px-2.5 py-2 text-xs rounded-sm bg-muted/40 text-foreground break-words"
                    >
                      {formatActivityLine(line)}
                    </div>
                  ))
                )}
              </div>
              {hasPermission("logs") && (
                <>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onSelect={() => onSectionChange("logs")}>
                    Open Logs
                  </DropdownMenuItem>
                </>
              )}
            </DropdownMenuContent>
          </DropdownMenuPortal>
        </DropdownMenu>

        <div className="flex items-center gap-2 px-3 py-2 mb-1">
          <div className="flex items-center gap-1.5 flex-1">
            <Sun className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
            <button
              onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
              className={cn(
                "relative w-8 h-4 rounded-full transition-colors shrink-0",
                resolvedTheme === "dark" ? "bg-primary" : "bg-muted-foreground/40"
              )}
              aria-label="Toggle light/dark mode"
            >
              <span
                className={cn(
                  "absolute top-0.5 left-0.5 w-3 h-3 rounded-full bg-white transition-transform duration-200",
                  resolvedTheme === "dark" ? "translate-x-0" : "translate-x-4"
                )}
              />
            </button>
            <Moon className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
          </div>
          <button
            onClick={() => setTheme("system")}
            className={cn(
              "flex items-center gap-1 px-2 py-0.5 rounded text-xs transition-colors",
              theme === "system"
                ? "bg-primary/20 text-primary font-medium"
                : "text-muted-foreground hover:text-foreground hover:bg-muted/30"
            )}
            aria-label="Use system theme"
          >
            <Monitor className="h-3 w-3" />
            <span>System</span>
          </button>
        </div>
        <div className="flex items-center gap-1">
          <div
            onClick={() => setUserSettingsOpen(true)}
            className="flex items-center gap-2 px-3 py-2 flex-1 min-w-0 rounded-md transition-colors hover:bg-primary/10 cursor-pointer group"
            role="button"
            aria-label="Open user settings"
          >
            <div className="flex items-center justify-center w-7 h-7 rounded-full bg-primary/20 shrink-0 group-hover:bg-primary/30 transition-colors">
              <User className="h-3.5 w-3.5 text-primary" />
            </div>
            <span className="text-sm font-medium text-muted-foreground truncate">{username || "User"}</span>
          </div>
          <div className="w-px h-6 bg-sidebar-border/40 shrink-0" />
          <button
            onClick={handleLogout}
            className="flex items-center gap-1.5 px-2.5 py-2 rounded-md text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors shrink-0"
            aria-label="Logout"
          >
            <LogOut className="h-4 w-4" />
          </button>
        </div>
        <UserSettings open={userSettingsOpen} onOpenChange={setUserSettingsOpen} />
      </div>
    </div>
  )
}
