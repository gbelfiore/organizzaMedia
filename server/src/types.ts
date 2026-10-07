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

export type JobRecord = {
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
  updated: string
}

export type UniqueRecord = {
  id: string
  job: string
  sha256: string
  kept_name: string
  kept_source: string
  dest_path: string
  size: number
  duplicate_count: number
  duplicate_paths: string[]
}

export type LogPhase = "flat" | "organize" | "others"

export type ProgressEvent = {
  type: "log" | "step" | "progress" | "done" | "error"
  message?: string
  step?: string
  phase?: LogPhase
  current?: number
  total?: number
  job?: JobRecord
}
