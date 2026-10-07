import express from "express"
import cors from "cors"
import { authAdmin, waitForPocketBase } from "./pb"
import { ensureSchema } from "./schema"
import { browseDir } from "./fsBrowse"
import { closeStaleJobs, continueOrganize, deleteJob, getJob, listJobs, listUniques, openFlatFolder, recoverReadyJobUniques, resumeOtherStats, startJob, subscribe } from "./jobRunner"
import { MediaType } from "./types"

const PORT = Number(process.env.API_PORT || 3001)
const app = express()
app.use(cors())
app.use(express.json())

app.get("/api/health", (_req, res) => {
  res.json({ ok: true })
})

app.get("/api/fs", (req, res) => {
  try {
    res.json(browseDir(String(req.query.path || "")))
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.get("/api/jobs", async (_req, res) => {
  try {
    res.json(await listJobs())
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.get("/api/jobs/:id", async (req, res) => {
  try {
    res.json(await getJob(req.params.id))
  } catch (err) {
    res.status(404).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.get("/api/jobs/:id/uniques", async (req, res) => {
  try {
    res.json(await listUniques(req.params.id))
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.get("/api/jobs/:id/stream", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream")
  res.setHeader("Cache-Control", "no-cache")
  res.setHeader("Connection", "keep-alive")
  res.flushHeaders()
  const off = subscribe(req.params.id, (ev) => {
    res.write(`data: ${JSON.stringify(ev)}\n\n`)
  })
  req.on("close", off)
})

app.post("/api/jobs/:id/organize", async (req, res) => {
  try {
    res.json(await continueOrganize(req.params.id))
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.post("/api/jobs/:id/open-flat", async (req, res) => {
  try {
    const job = await getJob(req.params.id)
    openFlatFolder(job.flat_dir)
    res.json({ ok: true, path: job.flat_dir })
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.delete("/api/jobs/:id", async (req, res) => {
  try {
    await deleteJob(req.params.id)
    res.json({ ok: true })
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

app.post("/api/jobs", async (req, res) => {
  try {
    const media = (req.body.media_type || "foto") as MediaType
    if (!["foto", "video", "media"].includes(media)) {
      res.status(400).json({ error: "media_type non valido" })
      return
    }
    const job = await startJob({
      source_dir: String(req.body.source_dir || ""),
      dest_dir: String(req.body.dest_dir || ""),
      media_type: media,
      dry_run: !!req.body.dry_run,
      file_limit: Number(req.body.file_limit || 0),
    })
    res.json(job)
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) })
  }
})

async function main() {
  console.log("Attendo PocketBase...")
  await waitForPocketBase()
  await authAdmin()
  await ensureSchema()
  await closeStaleJobs()
  await recoverReadyJobUniques()
  await resumeOtherStats()
  app.listen(PORT, () => {
    console.log("API su http://127.0.0.1:" + PORT)
  })
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
