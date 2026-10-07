export type MediaType = "foto" | "video" | "media"
export type JobStatus = "queued" | "running" | "awaiting_organize" | "organizing" | "done" | "error"

export type JobTimings = {
  scan_ms: number
  compare_ms: number
  copy_ms: number
  organize_ms: number
  others_ms: number
  total_ms: number
}

export type Job = {
  id: string
  source_dir: string
  dest_dir: string
  flat_dir: string
  org_dir: string
  media_type: MediaType
  status: JobStatus
  dry_run: boolean
  file_limit: number
  files_found: number
  files_unique: number
  files_duplicates: number
  files_produced: number
  files_without_meta: number
  files_errors: number
  files_other: number
  other_exts: Record<string, number>
  other_files: string[]
  report_md: string
  log_flat: string
  log_organize: string
  log_others: string
  timings: JobTimings
  script_name: string
  error_message: string
  created: string
}

export type UniquePhoto = {
  id: string
  sha256: string
  kept_name: string
  kept_source: string
  dest_path: string
  size: number
  duplicate_count: number
  duplicate_paths: string[]
}

export type FsListing = {
  path: string
  parent: string
  home: string
  dirs: { name: string; path: string }[]
}

async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, init)
  const text = await res.text()
  if (!text.trim()) {
    throw new Error("API non raggiungibile. Riavvia npm run dev e ricarica la pagina.")
  }
  let data: { error?: string }
  try {
    data = JSON.parse(text)
  } catch {
    throw new Error("Risposta API non valida. Riavvia npm run dev.")
  }
  if (!res.ok) throw new Error(data.error || "Errore API")
  return data as T
}

export const api = {
  jobs: () => json<Job[]>("/api/jobs"),
  job: (id: string) => json<Job>(`/api/jobs/${id}`),
  uniques: (id: string) => json<UniquePhoto[]>(`/api/jobs/${id}/uniques`),
  fs: (path: string) => json<FsListing>(`/api/fs?path=${encodeURIComponent(path)}`),
  createJob: (body: { source_dir: string; dest_dir: string; media_type: MediaType; dry_run?: boolean; file_limit?: number }) =>
    json<Job>("/api/jobs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
  organize: (id: string) =>
    json<Job>(`/api/jobs/${id}/organize`, { method: "POST" }),
  openFlat: (id: string) =>
    json<{ ok: boolean; path: string }>(`/api/jobs/${id}/open-flat`, { method: "POST" }),
  deleteJob: (id: string) =>
    json<{ ok: boolean }>(`/api/jobs/${id}`, { method: "DELETE" }),
}
