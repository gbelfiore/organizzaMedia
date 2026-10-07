import { execFile } from "child_process"
import fs from "fs"
import path from "path"
import { pb } from "./pb"
import { MediaType } from "./types"

const DATE_TAGS = [
  "DateTimeOriginal",
  "CreateDate",
  "CreationDate",
  "MediaCreateDate",
  "TrackCreateDate",
  "ContentCreateDate",
]

export type OrganizeResult = {
  produced: number
  withoutMeta: number
  errors: number
  skipped: number
}

function escapeFilter(value: string) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function execFileP(cmd: string, args: string[]): Promise<{ ok: boolean; stdout: string }> {
  return new Promise((resolve) => {
    execFile(cmd, args, { maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      resolve({ ok: !err, stdout: String(stdout || "") })
    })
  })
}

function validYearMonth(y: string, m: string) {
  return /^(19[7-9]\d|20[0-3]\d)$/.test(y) && /^(0[1-9]|1[0-2])$/.test(m)
}

function parseDateTime(raw: unknown): { year: string; month: string; day: string; meta: string } | null {
  const s = String(raw || "").trim()
  const m = s.match(/^(19[7-9]\d|20[0-3]\d):([01]\d):([0-3]\d)(?:[ T](\d{2}:\d{2}:\d{2}))?/)
  if (!m || !validYearMonth(m[1], m[2])) return null
  const day = /^(0[1-9]|[12]\d|3[01])$/.test(m[3]) ? m[3] : "01"
  const time = m[4] || "12:00:00"
  return { year: m[1], month: m[2], day, meta: `${m[1]}:${m[2]}:${day} ${time}` }
}

function dateFromName(filename: string) {
  const match = filename.match(/(19[7-9]\d|20[0-3]\d)[-_]?((0[1-9]|1[0-2]))[-_]?((0[1-9]|[12]\d|3[01]))/)
  if (!match) return null
  const year = match[1]
  const month = match[2]
  const day = match[4]
  if (!validYearMonth(year, month)) return null
  return { year, month, day, meta: `${year}:${month}:${day} 12:00:00` }
}

function dateFromSidecar(file: string) {
  const a = file + ".supplemental-metadata.json"
  const b = file + ".json"
  const side = fs.existsSync(a) ? a : fs.existsSync(b) ? b : ""
  if (!side) return null
  try {
    const d = JSON.parse(fs.readFileSync(side, "utf8")) as { photoTakenTime?: { timestamp?: string }; creationTime?: { timestamp?: string } }
    const ts = Number((d.photoTakenTime || {}).timestamp || (d.creationTime || {}).timestamp || 0)
    if (!ts) return null
    const dt = new Date(ts * 1000)
    if (Number.isNaN(dt.getTime())) return null
    const pad = (n: number) => String(n).padStart(2, "0")
    const year = String(dt.getFullYear())
    const month = pad(dt.getMonth() + 1)
    const day = pad(dt.getDate())
    if (!validYearMonth(year, month)) return null
    const meta = `${year}:${month}:${day} ${pad(dt.getHours())}:${pad(dt.getMinutes())}:${pad(dt.getSeconds())}`
    return { year, month, day, meta, fromJson: true as const }
  } catch {
    return null
  }
}

async function readExifOnce(file: string) {
  const args = ["-j", "-d", "%Y:%m:%d %H:%M:%S", ...DATE_TAGS.map((t) => "-" + t), file]
  const { stdout } = await execFileP("exiftool", args)
  let parsed: Record<string, unknown> = {}
  try {
    const arr = JSON.parse(stdout) as Record<string, unknown>[]
    parsed = arr[0] || {}
  } catch {
    parsed = {}
  }
  let date: { year: string; month: string; day: string; meta: string } | null = null
  let hasDto = false
  let hasCreate = false
  for (const tag of DATE_TAGS) {
    const got = parseDateTime(parsed[tag])
    if (!got) continue
    if (tag === "DateTimeOriginal") hasDto = true
    if (tag === "CreateDate" || tag === "CreationDate" || tag === "MediaCreateDate") hasCreate = true
    if (!date) date = got
  }
  return { date, hasDto, hasCreate }
}

async function writeExifOnce(dest: string, meta: string, addMissing: boolean, video: boolean) {
  const args = ["-overwrite_original", "-P"]
  if (addMissing) {
    args.push(`-DateTimeOriginal=${meta}`, `-CreateDate=${meta}`, `-ModifyDate=${meta}`)
    if (video) {
      args.push(`-TrackCreateDate=${meta}`, `-TrackModifyDate=${meta}`, `-MediaCreateDate=${meta}`, `-MediaModifyDate=${meta}`)
    }
  }
  args.push(`-FileModifyDate=${meta}`, `-FileCreateDate=${meta}`, dest)
  await execFileP("exiftool", args)
}

function uniqueTarget(dir: string, filename: string) {
  const dest = path.join(dir, filename)
  if (!fs.existsSync(dest)) return dest
  const parsed = path.parse(filename)
  let n = 1
  while (fs.existsSync(path.join(dir, `${parsed.name}_${n}${parsed.ext}`))) n += 1
  return path.join(dir, `${parsed.name}_${n}${parsed.ext}`)
}

function copyFileKeepTimes(src: string, dest: string) {
  fs.copyFileSync(src, dest)
  const st = fs.statSync(src)
  fs.utimesSync(dest, st.atime, st.mtime)
}

function copySidecar(src: string, dest: string) {
  const a = src + ".supplemental-metadata.json"
  const b = src + ".json"
  if (fs.existsSync(a)) copyFileKeepTimes(a, dest + ".supplemental-metadata.json")
  else if (fs.existsSync(b)) copyFileKeepTimes(b, dest + ".json")
}

async function findOrganized(sourcePath: string) {
  try {
    return await pb.collection("organized_media").getFirstListItem(`source_path="${escapeFilter(sourcePath)}"`)
  } catch {
    return null
  }
}

async function saveOrganized(sourcePath: string, destPath: string, size: number, mtime: number, folder: string) {
  const row = { source_path: sourcePath, dest_path: destPath, size, mtime, folder }
  const existing = await findOrganized(sourcePath)
  if (existing) await pb.collection("organized_media").update(existing.id, row)
  else await pb.collection("organized_media").create(row)
}

export async function organizeFlatDir(
  flatDir: string,
  orgDir: string,
  kind: MediaType,
  files: string[],
  dryRun: boolean,
  onLine: (line: string, current: number, total: number) => void
): Promise<OrganizeResult> {
  let produced = 0
  let withoutMeta = 0
  let errors = 0
  let skipped = 0
  const total = files.length
  let i = 0
  for (const file of files) {
    i += 1
    const name = path.basename(file)
    try {
      const st = fs.statSync(file)
      const mtime = Math.floor(st.mtimeMs)
      const existing = await findOrganized(file)
      if (existing && Number(existing.size) === st.size && Number(existing.mtime) === mtime && existing.dest_path && fs.existsSync(existing.dest_path as string)) {
        skipped += 1
        produced += 1
        const folder = String(existing.folder || "")
        if (folder === "without_metadata") withoutMeta += 1
        onLine(`indice DB già organizzato ${name}`, i, total)
        continue
      }

      const exif = await readExifOnce(file)
      let date = exif.date || dateFromName(name) || dateFromSidecar(file)
      const folder = date ? `${date.year}/${date.month}` : "without_metadata"
      if (!date) withoutMeta += 1
      if (dryRun) {
        produced += 1
        onLine(`copierebbe ${name} -> ${folder}`, i, total)
        continue
      }

      const destFolder = path.join(orgDir, folder)
      fs.mkdirSync(destFolder, { recursive: true })
      const destSameName = path.join(destFolder, name)
      if (fs.existsSync(destSameName) && fs.statSync(destSameName).size === st.size) {
        await saveOrganized(file, destSameName, st.size, mtime, folder)
        produced += 1
        skipped += 1
        onLine(`già organizzato ${name} -> ${folder}`, i, total)
        continue
      }
      const dest = uniqueTarget(destFolder, name)
      copyFileKeepTimes(file, dest)
      copySidecar(file, dest)
      if (date) {
        const addMissing = !exif.hasDto && !exif.hasCreate
        await writeExifOnce(dest, date.meta, addMissing, kind === "video" || kind === "media")
      }
      await saveOrganized(file, dest, st.size, mtime, folder)
      produced += 1
      onLine(`Copiata: ${name} -> ${folder}`, i, total)
    } catch (err) {
      errors += 1
      onLine("Errore " + name + " " + String(err), i, total)
    }
  }
  return { produced, withoutMeta, errors, skipped }
}
