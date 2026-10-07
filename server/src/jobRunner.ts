import { createHash } from "crypto"
import { spawn } from "child_process"
import fs from "fs"
import os from "os"
import path from "path"
import { pb } from "./pb"
import { organizeFlatDir } from "./organize"
import { JobRecord, JobTimings, LogPhase, MediaType, ProgressEvent, UniqueRecord } from "./types"

const PHOTO_EXTS = new Set(["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"])
const VIDEO_EXTS = new Set(["mp4", "mov", "avi", "m4v", "mkv", "3gp", "mts", "m2ts", "wmv", "mpg", "mpeg", "webm"])
const SCRIPTS_DIR = path.resolve(__dirname, "../../scripts")

type Emitter = (ev: ProgressEvent) => void

type Group = {
  sha256: string
  size: number
  keptSource: string
  keptName: string
  destPath: string
  duplicates: string[]
}

const listeners = new Map<string, Set<Emitter>>()

export function subscribe(jobId: string, fn: Emitter) {
  let set = listeners.get(jobId)
  if (!set) {
    set = new Set()
    listeners.set(jobId, set)
  }
  set.add(fn)
  return () => {
    set!.delete(fn)
  }
}

function emit(jobId: string, ev: ProgressEvent) {
  const set = listeners.get(jobId)
  if (!set) return
  set.forEach((fn) => fn(ev))
}

const logsMem = new Map<string, { flat: string[]; organize: string[]; others: string[] }>()

function bufFor(jobId: string) {
  let b = logsMem.get(jobId)
  if (!b) {
    b = { flat: [], organize: [], others: [] }
    logsMem.set(jobId, b)
  }
  if (!b.others) b.others = []
  return b
}

const reportBusy = new Set<string>()

function logLine(jobId: string, phase: LogPhase, line: string) {
  const msg = String(line || "").replace(/\s+$/, "")
  if (!msg) return
  const b = bufFor(jobId)
  b[phase].push(msg)
  emit(jobId, { type: "log", phase, message: msg })
  if (b[phase].length % 10 === 0) {
    persistLogs(jobId, phase).catch(() => undefined)
    if (phase === "others" || phase === "organize") scheduleReport(jobId)
  } else if (b[phase].length % 25 === 0) {
    persistLogs(jobId, phase).catch(() => undefined)
  }
}

function scheduleReport(jobId: string) {
  if (reportBusy.has(jobId)) return
  reportBusy.add(jobId)
  refreshReport(jobId).catch(() => undefined).finally(() => reportBusy.delete(jobId))
}

function organizeLiveFromLogs(lines: string[]) {
  let copied = 0
  let pct = 0
  let last = ""
  for (const line of lines) {
    const m = line.match(/\[\s*(\d+)%\]/)
    if (m) pct = Number(m[1])
    if (/Copiata:|Spostato:|Organizzat/i.test(line)) copied += 1
    last = line
  }
  return { copied, pct, last }
}

async function persistLogs(jobId: string, phase?: LogPhase) {
  const b = bufFor(jobId)
  const patch: Record<string, string> = {}
  if (!phase || phase === "flat") patch.log_flat = b.flat.join("\n")
  if (!phase || phase === "organize") patch.log_organize = b.organize.join("\n")
  if (!phase || phase === "others") patch.log_others = b.others.join("\n")
  await pb.collection("jobs").update(jobId, patch)
}

function extOf(file: string) {
  return path.extname(file).slice(1).toLowerCase()
}

function isMedia(file: string, kind: MediaType) {
  const ext = extOf(file)
  const photo = PHOTO_EXTS.has(ext)
  const video = VIDEO_EXTS.has(ext)
  if (kind === "foto") return photo
  if (kind === "video") return video
  return photo || video
}

function isSidecar(name: string) {
  return name.endsWith(".supplemental-metadata.json") || name.endsWith(".json")
}

function scanFiles(root: string, kind: MediaType, destDir: string, flatDir: string, orgDir?: string) {
  const out: string[] = []
  const walk = (dir: string) => {
    let entries: fs.Dirent[]
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      const full = path.join(dir, e.name)
      if (e.isDirectory()) {
        if (full === destDir || full === flatDir || (orgDir && full === orgDir)) continue
        if (full.startsWith(destDir + path.sep) || full.startsWith(flatDir + path.sep) || (orgDir && full.startsWith(orgDir + path.sep))) continue
        walk(full)
        continue
      }
      if (!e.isFile()) continue
      if (e.name === ".DS_Store" || e.name === "Thumbs.db" || e.name.startsWith("._")) continue
      if (isSidecar(e.name)) continue
      if (isMedia(full, kind)) out.push(full)
    }
  }
  walk(root)
  out.sort((a, b) => a.localeCompare(b))
  return out
}

function sha256File(file: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256")
    const stream = fs.createReadStream(file)
    stream.on("data", (d) => hash.update(d))
    stream.on("end", () => resolve(hash.digest("hex")))
    stream.on("error", reject)
  })
}

async function cachedHash(file: string, size: number, mtime: number): Promise<{ hash: string; fromDb: boolean }> {
  try {
    const rec = await pb.collection("file_hashes").getFirstListItem(`path="${escapeFilter(file)}" && size=${size} && mtime=${mtime}`)
    return { hash: rec.sha256 as string, fromDb: true }
  } catch {
    // miss
  }
  const hash = await sha256File(file)
  try {
    await pb.collection("file_hashes").create({ path: file, size, mtime, sha256: hash })
  } catch {
    // ignore duplicate insert
  }
  return { hash, fromDb: false }
}

function escapeFilter(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

async function findUniqueByHash(hash: string) {
  try {
    return await pb.collection("unique_media").getFirstListItem(`sha256="${hash}"`)
  } catch {
    return null
  }
}

function uniqueTarget(dir: string, filename: string) {
  const dest = path.join(dir, filename)
  if (!fs.existsSync(dest)) return dest
  const parsed = path.parse(filename)
  let n = 1
  while (fs.existsSync(path.join(dir, `${parsed.name}_${n}${parsed.ext}`))) n += 1
  return path.join(dir, `${parsed.name}_${n}${parsed.ext}`)
}

function findSidecar(file: string) {
  const a = file + ".supplemental-metadata.json"
  const b = file + ".json"
  if (fs.existsSync(a)) return a
  if (fs.existsSync(b)) return b
  return ""
}

function copyFileKeepTimes(src: string, dest: string) {
  fs.copyFileSync(src, dest)
  const st = fs.statSync(src)
  fs.utimesSync(dest, st.atime, st.mtime)
}

function runScript(script: string, args: string[], onLine: (line: string) => void, env?: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const child = spawn("zsh", [script, ...args], { cwd: SCRIPTS_DIR, env: { ...process.env, ...env } })
    let buf = ""
    const handle = (chunk: Buffer) => {
      buf += chunk.toString()
      const lines = buf.split(/\r?\n/)
      buf = lines.pop() || ""
      lines.forEach((line) => line && onLine(line))
    }
    child.stdout.on("data", handle)
    child.stderr.on("data", handle)
    child.on("error", reject)
    child.on("close", (code) => resolve(code ?? 1))
  })
}

export async function startJob(input: {
  source_dir: string
  dest_dir: string
  media_type: MediaType
  dry_run?: boolean
  file_limit?: number
}) {
  const source = path.resolve(input.source_dir)
  const dest = path.resolve(input.dest_dir)
  const flat = path.join(dest, "flat")
  const org = path.join(dest, "organizzate")
  if (!fs.existsSync(source) || !fs.statSync(source).isDirectory()) {
    throw new Error("Cartella di origine non trovata")
  }
  if (dest === source) {
    throw new Error("Origine e destinazione devono essere cartelle diverse")
  }
  if (dest.startsWith(source + path.sep)) {
    throw new Error("La destinazione non può stare dentro l'origine")
  }

  const scriptName =
    input.media_type === "foto"
      ? "organizza_foto.sh"
      : input.media_type === "video"
        ? "organizza_video.sh"
        : "organizza_media.sh"

  const created = await pb.collection("jobs").create({
    source_dir: source,
    dest_dir: dest,
    flat_dir: flat,
    org_dir: org,
    media_type: input.media_type,
    status: "queued",
    dry_run: !!input.dry_run,
    file_limit: input.file_limit || 0,
    files_found: 0,
    files_unique: 0,
    files_duplicates: 0,
    files_produced: 0,
    files_without_meta: 0,
    files_errors: 0,
    files_other: 0,
    other_exts: {},
    other_files: [],
    report_md: "",
    log_flat: "",
    log_organize: "",
    log_others: "",
    timings: { scan_ms: 0, compare_ms: 0, copy_ms: 0, organize_ms: 0, others_ms: 0, total_ms: 0 },
    script_name: scriptName + " + trova_altri_file.sh",
    error_message: "",
  })

  setImmediate(() => {
    runPipeline(created.id, {
      source,
      dest,
      flat,
      org,
      mediaType: input.media_type,
      dryRun: !!input.dry_run,
      limit: input.file_limit || 0,
      scriptName,
    }).catch((err) => {
      const msg = err instanceof Error ? err.message : String(err)
      logLine(created.id, "flat", msg)
      emit(created.id, { type: "error", phase: "flat", message: msg })
      persistLogs(created.id, "flat").catch(() => undefined)
      pb.collection("jobs").update(created.id, { status: "error", error_message: msg }).catch(() => undefined)
    })
  })

  return created as unknown as JobRecord
}

async function runPipeline(
  jobId: string,
  opts: {
    source: string
    dest: string
    flat: string
    org: string
    mediaType: MediaType
    dryRun: boolean
    limit: number
    scriptName: string
  }
) {
  const t0 = Date.now()
  const timings: JobTimings = { scan_ms: 0, compare_ms: 0, copy_ms: 0, organize_ms: 0, others_ms: 0, total_ms: 0 }
  await pb.collection("jobs").update(jobId, { status: "running" })
  logLine(jobId, "flat", "Scansione origine...")
  emit(jobId, { type: "step", step: "scan", phase: "flat", message: "Scansione origine..." })

  const tScan = Date.now()
  let files = scanFiles(opts.source, opts.mediaType, opts.dest, opts.flat, opts.org)
  if (opts.limit > 0) files = files.slice(0, opts.limit)
  timings.scan_ms = Date.now() - tScan
  await pb.collection("jobs").update(jobId, { files_found: files.length })
  logLine(jobId, "flat", `Trovati ${files.length} file`)
  emit(jobId, { type: "progress", step: "scan", phase: "flat", current: files.length, total: files.length, message: `Trovati ${files.length} file` })

  if (!opts.dryRun) {
    fs.mkdirSync(opts.dest, { recursive: true })
    fs.mkdirSync(opts.flat, { recursive: true })
    fs.mkdirSync(opts.org, { recursive: true })
  }

  const groups = new Map<string, Group>()
  const tCmp = Date.now()
  let i = 0
  for (const file of files) {
    i += 1
    const st = fs.statSync(file)
    const { hash, fromDb } = await cachedHash(file, st.size, Math.floor(st.mtimeMs))
    let g = groups.get(hash)
    if (!g) {
      const existing = await findUniqueByHash(hash)
      g = {
        sha256: hash,
        size: st.size,
        keptSource: (existing?.first_source as string) || file,
        keptName: path.basename(file),
        destPath: existing?.kept_path as string || "",
        duplicates: [],
      }
      if (existing && existing.kept_path && fs.existsSync(existing.kept_path as string)) {
        g.destPath = existing.kept_path as string
        g.keptName = path.basename(existing.kept_path as string)
        g.duplicates.push(file)
      }
      groups.set(hash, g)
    } else {
      g.duplicates.push(file)
    }
    if (i % 5 === 0 || i === files.length) {
      const cmpMsg = `${fromDb ? "indice DB" : "hash"} ${path.basename(file)}`
      logLine(jobId, "flat", cmpMsg)
      emit(jobId, {
        type: "progress",
        step: "compare",
        phase: "flat",
        current: i,
        total: files.length,
        message: cmpMsg,
      })
    }
  }
  timings.compare_ms = Date.now() - tCmp

  const tCopy = Date.now()
  let copied = 0
  let dups = 0
  let errors = 0
  for (const g of groups.values()) {
    dups += g.duplicates.length
    const already = g.destPath && fs.existsSync(g.destPath)
    if (already) continue
    const destFile = uniqueTarget(opts.flat, g.keptName)
    g.destPath = destFile
    g.keptName = path.basename(destFile)
    if (opts.dryRun) {
      copied += 1
      continue
    }
    try {
      copyFileKeepTimes(g.keptSource, destFile)
      const side = findSidecar(g.keptSource)
      if (side) {
        const sideDest = side.endsWith(".supplemental-metadata.json")
          ? destFile + ".supplemental-metadata.json"
          : destFile + ".json"
        copyFileKeepTimes(side, sideDest)
      }
      copied += 1
      const existing = await findUniqueByHash(g.sha256)
      if (existing) {
        await pb.collection("unique_media").update(existing.id, { kept_path: destFile, kept_name: g.keptName })
      } else {
        await pb.collection("unique_media").create({
          sha256: g.sha256,
          size: g.size,
          kept_path: destFile,
          kept_name: g.keptName,
          first_source: g.keptSource,
        })
      }
    } catch (err) {
      errors += 1
      logLine(jobId, "flat", "Errore copia " + g.keptSource + " " + String(err))
    }
  }
  timings.copy_ms = Date.now() - tCopy
  logLine(jobId, "flat", `Copiate ${copied} foto uniche`)
  emit(jobId, { type: "progress", step: "copy", phase: "flat", current: copied, total: groups.size, message: `Copiate ${copied} foto uniche` })

  const pauseMsg = `Backup flat finito in ${opts.flat}. Puoi eliminare o rinominare i file lì. Quando sei pronto, avvia l'organizzazione.`
  timings.total_ms = Date.now() - t0
  await persistLogs(jobId, "flat").catch(() => undefined)
  const readyStatus = errors && copied === 0 ? "error" : "awaiting_organize"
  const updated = await pb.collection("jobs").update(jobId, {
    status: readyStatus,
    files_found: files.length,
    files_unique: groups.size,
    files_duplicates: dups,
    files_produced: copied,
    files_without_meta: 0,
    files_errors: errors,
    log_flat: bufFor(jobId).flat.join("\n"),
    timings,
    error_message: readyStatus === "error" ? "Nessun file copiato" : pauseMsg,
  })
  emit(jobId, { type: "step", step: "awaiting_organize", job: updated as unknown as JobRecord, message: pauseMsg })
  refreshReport(jobId).catch(() => undefined)

  if (readyStatus === "error") return

  for (const g of groups.values()) {
    try {
      await pb.collection("job_uniques").create({
        job: jobId,
        sha256: g.sha256,
        kept_name: g.keptName,
        kept_source: g.keptSource,
        dest_path: g.destPath,
        size: g.size,
        duplicate_count: g.duplicates.length,
        duplicate_paths: g.duplicates,
      })
    } catch {
      // già presenti o PB occupato: non bloccare l'organizzazione
    }
  }

  collectOtherStats(jobId, opts.source, opts.dest, opts.limit).catch((err) => {
    logLine(jobId, "others", "Statistiche altri file non riuscite: " + String(err))
  })
}

async function collectOtherStats(jobId: string, source: string, dest: string, limit: number) {
  logLine(jobId, "others", "Statistiche altri file (trova_altri_file.sh)...")
  if (limit > 0) logLine(jobId, "others", `Limite: primi ${limit} file media (stesso del backup)`)
  emit(jobId, { type: "step", step: "others", phase: "others", message: "Statistiche altri file (trova_altri_file.sh)..." })
  const tOth = Date.now()
  const reportMdPath = path.join(os.tmpdir(), `foto_altri_${jobId}.md`)
  const reportJsonPath = path.join(os.tmpdir(), `foto_altri_${jobId}.json`)
  let otherTotal = 0
  let otherExts: Record<string, number> = {}
  let otherFiles: string[] = []
  let reportMd = ""
  const othersScript = path.join(SCRIPTS_DIR, "trova_altri_file.sh")
  try {
    await runScript(othersScript, [source, dest], (line) => {
      logLine(jobId, "others", line)
    }, {
      STATS_ONLY: "1",
      LIMIT: String(limit || 0),
      REPORT_FILE: reportMdPath,
      REPORT_JSON: reportJsonPath,
    })
    if (fs.existsSync(reportJsonPath)) {
      const parsed = JSON.parse(fs.readFileSync(reportJsonPath, "utf8")) as { total?: number; exts?: Record<string, number>; files?: string[] }
      otherTotal = parsed.total || 0
      otherExts = parsed.exts || {}
      otherFiles = (parsed.files || []).slice(0, 2000)
    }
    if (fs.existsSync(reportMdPath)) reportMd = fs.readFileSync(reportMdPath, "utf8")
  } catch (err) {
    logLine(jobId, "others", "Statistiche altri file non riuscite: " + String(err))
  }
  await persistLogs(jobId, "others").catch(() => undefined)
  const current = await pb.collection("jobs").getOne(jobId)
  const timings = { ...((current.timings as JobTimings) || {}) }
  timings.others_ms = Date.now() - tOth
  timings.total_ms = (timings.scan_ms || 0) + (timings.compare_ms || 0) + (timings.copy_ms || 0) + (timings.organize_ms || 0) + timings.others_ms
  const patch: Record<string, unknown> = {
    files_other: otherTotal,
    other_exts: otherExts,
    other_files: otherFiles,
    log_others: bufFor(jobId).others.join("\n"),
    timings,
  }
  await pb.collection("jobs").update(jobId, patch).catch(() => undefined)
  await refreshReport(jobId, { altriMd: reportMd }).catch(() => undefined)
}

export async function continueOrganize(jobId: string) {
  const job = await pb.collection("jobs").getOne(jobId)
  if (String(job.status) !== "awaiting_organize") {
    throw new Error("Questa esecuzione non è in attesa di organizzazione")
  }
  try {
    return await runOrganize(jobId, job)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    logLine(jobId, "organize", msg)
    emit(jobId, { type: "error", phase: "organize", message: msg })
    await persistLogs(jobId, "organize")
    await pb.collection("jobs").update(jobId, { status: "error", error_message: msg })
    throw err
  }
}

function logText(v: unknown): string {
  if (typeof v === "string") return v
  if (Array.isArray(v)) return v.map(String).join("\n")
  return ""
}

function hydrateLogs(jobId: string, job: Record<string, unknown>) {
  if (logsMem.has(jobId)) return
  const b = bufFor(jobId)
  const flat = logText(job.log_flat)
  const org = logText(job.log_organize)
  const others = logText(job.log_others)
  if (flat) b.flat = flat.split("\n").filter(Boolean)
  if (org) b.organize = org.split("\n").filter(Boolean)
  if (others) b.others = others.split("\n").filter(Boolean)
}

async function runOrganize(jobId: string, job: Record<string, unknown>) {
  hydrateLogs(jobId, job)
  const mediaType = job.media_type as MediaType
  const scriptName =
    mediaType === "foto" ? "organizza_foto.sh" : mediaType === "video" ? "organizza_video.sh" : "organizza_media.sh"
  const timings = { ...(job.timings as JobTimings) }
  let errors = Number(job.files_errors || 0)
  await pb.collection("jobs").update(jobId, { status: "organizing", error_message: "" })
  logLine(jobId, "organize", "Avvio organizzazione...")
  emit(jobId, { type: "step", step: "organize", phase: "organize", message: "Avvio organizzazione..." })
  refreshReport(jobId).catch(() => undefined)

  const tOrg = Date.now()
  const org = (job.org_dir as string) || path.join(job.dest_dir as string, "organizzate")
  const flat = job.flat_dir as string
  fs.mkdirSync(org, { recursive: true })
  const files = scanFiles(flat, mediaType, org, org + "__never")
  logLine(jobId, "organize", `File da organizzare: ${files.length}`)
  const orgRes = await organizeFlatDir(flat, org, mediaType, files, !!job.dry_run, (line, current, total) => {
    logLine(jobId, "organize", line)
    emit(jobId, { type: "progress", step: "organize", phase: "organize", current, total, message: line })
  })
  let produced = orgRes.produced
  let withoutMeta = orgRes.withoutMeta
  errors += orgRes.errors
  if (orgRes.skipped) logLine(jobId, "organize", `Saltati ${orgRes.skipped} già in indice DB`)
  timings.organize_ms = Date.now() - tOrg
  const latest = await pb.collection("jobs").getOne(jobId)
  const latestTimings = { ...((latest.timings as JobTimings) || {}) }
  timings.others_ms = latestTimings.others_ms || timings.others_ms || 0
  timings.total_ms = (timings.scan_ms || 0) + (timings.compare_ms || 0) + (timings.copy_ms || 0) + timings.organize_ms + timings.others_ms

  const reportMd = buildFullReport({
    source: job.source_dir as string,
    dest: job.dest_dir as string,
    flat: job.flat_dir as string,
    scriptName,
    status: errors && produced === 0 ? "error" : "done",
    filesFound: Number(job.files_found || 0),
    unique: Number(job.files_unique || 0),
    dups: Number(job.files_duplicates || 0),
    produced,
    withoutMeta,
    errors,
    otherTotal: Number(latest.files_other || job.files_other || 0),
    otherExts: (latest.other_exts as Record<string, number>) || (job.other_exts as Record<string, number>) || {},
    otherFiles: (latest.other_files as string[]) || (job.other_files as string[]) || [],
    timings,
    altriMd: "",
    organizeTail: bufFor(jobId).organize.slice(-12),
    othersTail: bufFor(jobId).others.slice(-8),
  })

  logLine(jobId, "organize", "Organizzazione completata")
  await persistLogs(jobId, "organize")
  const updated = await pb.collection("jobs").update(jobId, {
    status: errors && produced === 0 ? "error" : "done",
    files_produced: produced,
    files_without_meta: withoutMeta,
    files_errors: errors,
    report_md: reportMd,
    log_organize: bufFor(jobId).organize.join("\n"),
    timings,
    error_message: "",
  })
  emit(jobId, { type: "done", job: updated as unknown as JobRecord, message: "Organizzazione completata" })
  return updated as unknown as JobRecord
}

function countMedia(root: string, kind: MediaType) {
  if (!fs.existsSync(root)) return 0
  return scanFiles(root, kind, root + "__never", root + "__never2").length
}

function countWithoutMeta(root: string) {
  const dirs = [
    path.join(root, "without_metadata"),
    path.join(root, "foto", "without_metadata"),
    path.join(root, "video", "without_metadata"),
  ]
  let n = 0
  for (const d of dirs) {
    if (!fs.existsSync(d)) continue
    n += fs.readdirSync(d).filter((f) => !f.startsWith(".") && !f.endsWith(".json")).length
  }
  return n
}

export function openFlatFolder(flatDir: string) {
  if (!fs.existsSync(flatDir)) throw new Error("Cartella flat non trovata")
  spawn("open", [flatDir])
}

export async function getJob(id: string) {
  return (await pb.collection("jobs").getOne(id)) as unknown as JobRecord
}

export async function listJobs() {
  const jobs = (await pb.collection("jobs").getFullList({ sort: "-created" })) as unknown as JobRecord[]
  return jobs.map((j) => ({ ...j, log_flat: "", log_organize: "", log_others: "" }))
}

export async function deleteJob(id: string) {
  try {
    const uniques = await pb.collection("job_uniques").getFullList({ filter: `job="${id}"` })
    for (const u of uniques) {
      await pb.collection("job_uniques").delete(u.id)
    }
  } catch {
    // collection vuota o già cancellata
  }
  logsMem.delete(id)
  await pb.collection("jobs").delete(id)
}

async function recoverUniquesFromFlat(jobId: string, flatDir: string, mediaType: string) {
  if (!flatDir || !fs.existsSync(flatDir)) return
  try {
    const existing = await pb.collection("job_uniques").getList(1, 1, { filter: `job="${jobId}"` })
    if ((existing.items || []).length > 0) return
  } catch {
    // collection vuota o filtro: si tenta comunque il recupero
  }
  const kind = (mediaType === "video" || mediaType === "media" ? mediaType : "foto") as MediaType
  const files = scanFiles(flatDir, kind, path.join(flatDir, "__never"), path.join(flatDir, "__never2"))
  for (const file of files) {
    try {
      const st = fs.statSync(file)
      await pb.collection("job_uniques").create({
        job: jobId,
        sha256: "recovered:" + path.basename(file),
        kept_name: path.basename(file),
        kept_source: file,
        dest_path: file,
        size: st.size,
        duplicate_count: 0,
        duplicate_paths: [],
      })
    } catch {
      // ignore
    }
  }
}

function flatHasFiles(flatDir: string) {
  if (!flatDir || !fs.existsSync(flatDir)) return 0
  try {
    return fs.readdirSync(flatDir).filter((f) => {
      if (f.startsWith(".") || f.endsWith(".json")) return false
      return isMedia(path.join(flatDir, f), "media")
    }).length
  } catch {
    return 0
  }
}

export async function closeStaleJobs() {
  const stale = await pb.collection("jobs").getFullList({
    filter: 'status="running" || status="organizing" || status="queued"',
  })
  for (const job of stale) {
    await persistLogs(job.id).catch(() => undefined)
    const copied = Number(job.files_produced || 0) || Number(job.files_unique || 0) || flatHasFiles(String(job.flat_dir || ""))
    if (copied > 0 && String(job.status) !== "queued") {
      await recoverUniquesFromFlat(job.id, String(job.flat_dir || ""), String(job.media_type || "foto"))
      await pb.collection("jobs").update(job.id, {
        status: "awaiting_organize",
        files_produced: Number(job.files_produced || 0) || copied,
        files_unique: Number(job.files_unique || 0) || copied,
        error_message: "Backup flat pronto. Puoi avviare l'organizzazione.",
      })
      continue
    }
    await pb.collection("jobs").update(job.id, {
      status: "error",
      error_message: "Interrotto: il server è stato riavviato prima della fine.",
    })
  }
  if (stale.length) console.log("Chiuse esecuzioni bloccate:", stale.length)
}

export async function recoverReadyJobUniques() {
  const ready = await pb.collection("jobs").getFullList({
    filter: 'status="awaiting_organize"',
  })
  for (const job of ready) {
    await recoverUniquesFromFlat(job.id, String(job.flat_dir || ""), String(job.media_type || "foto"))
  }
}

export async function resumeOtherStats() {
  const jobs = await pb.collection("jobs").getFullList({
    filter: 'status="awaiting_organize" || status="organizing"',
  })
  for (const job of jobs) {
    const already = logText(job.log_others)
    const timings = (job.timings || {}) as JobTimings
    if (already || Number(timings.others_ms || 0) > 0) continue
    collectOtherStats(job.id, String(job.source_dir), String(job.dest_dir), Number(job.file_limit || 0)).catch((err) => {
      logLine(job.id, "others", "Statistiche altri file non riuscite: " + String(err))
    })
  }
}

async function refreshReport(jobId: string, extra?: { altriMd?: string }) {
  const job = await pb.collection("jobs").getOne(jobId)
  const timings = { ...((job.timings as JobTimings) || {}) }
  const live = organizeLiveFromLogs(bufFor(jobId).organize)
  const produced = live.copied || Number(job.files_produced || 0)
  const scriptName = String(job.script_name || "organizza_foto.sh")
  const reportMd = buildFullReport({
    source: String(job.source_dir || ""),
    dest: String(job.dest_dir || ""),
    flat: String(job.flat_dir || ""),
    scriptName: scriptName.replace(/ \+ .*$/, ""),
    status: String(job.status || ""),
    filesFound: Number(job.files_found || 0),
    unique: Number(job.files_unique || 0),
    dups: Number(job.files_duplicates || 0),
    produced,
    withoutMeta: Number(job.files_without_meta || 0),
    errors: Number(job.files_errors || 0),
    otherTotal: Number(job.files_other || 0),
    otherExts: (job.other_exts as Record<string, number>) || {},
    otherFiles: (job.other_files as string[]) || [],
    timings,
    altriMd: extra?.altriMd || "",
    organizeTail: bufFor(jobId).organize.slice(-12),
    othersTail: bufFor(jobId).others.slice(-8),
    organizePct: live.pct,
  })
  const updated = await pb.collection("jobs").update(jobId, {
    report_md: reportMd,
    files_produced: job.status === "organizing" ? produced : job.files_produced,
  })
  emit(jobId, { type: "progress", job: updated as unknown as JobRecord, message: live.last || "Report aggiornato" })
}

function buildFullReport(p: {
  source: string
  dest: string
  flat: string
  scriptName: string
  status?: string
  filesFound: number
  unique: number
  dups: number
  produced: number
  withoutMeta: number
  errors: number
  otherTotal: number
  otherExts: Record<string, number>
  otherFiles: string[]
  timings: JobTimings
  altriMd: string
  organizeTail?: string[]
  othersTail?: string[]
  organizePct?: number
}) {
  const stato =
    p.status === "done" ? "completato" :
    p.status === "organizing" ? `organizzazione in corso${p.organizePct ? ` (${p.organizePct}%)` : ""}` :
    p.status === "awaiting_organize" ? "backup flat finito" :
    p.status === "running" ? "backup flat in corso" :
    p.status || "in corso"
  const lines = [
    "# Report esecuzione",
    "",
    `**Stato:** ${stato}`,
    `**Origine:** \`${p.source}\``,
    `**Destinazione:** \`${p.dest}\``,
    `**Flat:** \`${p.flat}\``,
    `**Script:** \`${p.scriptName} + trova_altri_file.sh\``,
    "",
    "## Numeri",
    "",
    "| Metric | Conteggio |",
    "| :--- | :--- |",
    `| Partito da | ${p.filesFound} |`,
    `| Foto uniche | ${p.unique} |`,
    `| Doppioni | ${p.dups} |`,
    `| Prodotti | ${p.produced} |`,
    `| Senza metadati | ${p.withoutMeta} |`,
    `| Altri file | ${p.otherTotal} |`,
    `| Errori | ${p.errors} |`,
    "",
    "## Tempi",
    "",
    `| Step | Durata |`,
    "| :--- | :--- |",
    `| Scansione | ${p.timings.scan_ms} ms |`,
    `| Confronti | ${p.timings.compare_ms} ms |`,
    `| Copia | ${p.timings.copy_ms} ms |`,
    `| Organizzazione | ${p.timings.organize_ms} ms |`,
    `| Altri file | ${p.timings.others_ms} ms |`,
    `| Totale | ${p.timings.total_ms} ms |`,
    "",
    "## Altri file (trova_altri_file.sh, solo statistiche)",
    "",
  ]
  const exts = Object.keys(p.otherExts)
  if (exts.length) {
    lines.push("| Estensione | Quantità |", "| :--- | :--- |")
    exts.sort().forEach((e) => lines.push(`| \`.${e}\` | ${p.otherExts[e]} |`))
  } else {
    lines.push("_Nessun file extra._")
  }
  if (p.othersTail && p.othersTail.length) {
    lines.push("", "## Log altri file (ultime righe)", "", "```", ...p.othersTail, "```")
  }
  if (p.organizeTail && p.organizeTail.length) {
    lines.push("", "## Log organizzazione (ultime righe)", "", "```", ...p.organizeTail, "```")
  }
  if (p.altriMd && !p.altriMd.startsWith("# Report esecuzione")) {
    lines.push("", p.altriMd)
  }
  return lines.join("\n")
}

export async function listUniques(jobId: string) {
  const res = await pb.collection("job_uniques").getFullList({
    filter: `job="${jobId}"`,
    sort: "-duplicate_count,kept_name",
  })
  return res.map((r) => ({
    id: r.id,
    job: r.job,
    sha256: r.sha256,
    kept_name: r.kept_name,
    kept_source: r.kept_source,
    dest_path: r.dest_path,
    size: r.size,
    duplicate_count: r.duplicate_count || 0,
    duplicate_paths: (r.duplicate_paths as string[]) || [],
  })) as UniqueRecord[]
}
