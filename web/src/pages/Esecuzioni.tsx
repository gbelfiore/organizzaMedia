import { useEffect, useState } from "react"
import { Link } from "react-router-dom"
import { api, Job } from "@/lib/api"
import { formatMs } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useDialogs } from "@/components/AppDialogs"

function statusBadge(s: Job["status"]) {
  if (s === "done") return <Badge variant="ok">completato</Badge>
  if (s === "error") return <Badge variant="err">errore</Badge>
  if (s === "running" || s === "organizing") return <Badge variant="run">in corso</Badge>
  if (s === "awaiting_organize") return <Badge variant="run">flat pronto</Badge>
  return <Badge variant="secondary">in coda</Badge>
}

function reportText(j: Job) {
  const r = j.report_md as unknown
  if (typeof r === "string") return r
  return ""
}

export function Esecuzioni() {
  const dialogs = useDialogs()
  const [jobs, setJobs] = useState<Job[]>([])
  const [open, setOpen] = useState("")
  const [err, setErr] = useState("")

  useEffect(() => {
    const load = () =>
      api.jobs()
        .then((items) => {
          setJobs(items)
          setErr("")
        })
        .catch((e) => setErr(e.message))
    load()
    const t = setInterval(load, 5000)
    return () => clearInterval(t)
  }, [])

  return (
    <div className="mx-auto max-w-6xl space-y-6 p-6">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">Esecuzioni</h1>
        <p className="mt-1 text-muted-foreground">Storico completo: ogni run resta salvato in PocketBase con il suo report.</p>
      </div>
      {err && <p className="text-sm text-destructive">{err}</p>}
      {jobs.length === 0 && <p className="text-sm text-muted-foreground">Nessuna esecuzione in archivio.</p>}
      {jobs.map((j) => {
        const t = j.timings || { scan_ms: 0, compare_ms: 0, copy_ms: 0, organize_ms: 0, others_ms: 0, total_ms: 0 }
        const report = reportText(j)
        return (
          <Card key={j.id}>
            <CardHeader className="flex flex-row items-start justify-between gap-3">
              <div className="min-w-0">
                <CardTitle className="text-base">
                  <Link to={`/jobs/${j.id}`} className="hover:underline">{new Date(j.created).toLocaleString("it-IT")}</Link>
                </CardTitle>
                <p className="mt-1 truncate font-mono text-xs text-muted-foreground">{j.source_dir}</p>
                <p className="truncate font-mono text-xs text-muted-foreground">→ {j.dest_dir}</p>
              </div>
              {statusBadge(j.status)}
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid gap-2 text-sm sm:grid-cols-6">
                <Mini label="Partiti" value={j.files_found} />
                <Mini label="Uniche" value={j.files_unique} />
                <Mini label="Doppioni" value={j.files_duplicates} />
                <Mini label="Prodotti" value={j.files_produced} />
                <Mini label="Altri file" value={j.files_other} />
                <Mini label="Totale" value={formatMs(t.total_ms)} />
              </div>
              <div className="grid gap-2 text-xs text-muted-foreground sm:grid-cols-5">
                <span>Scan {formatMs(t.scan_ms)}</span>
                <span>Confronti {formatMs(t.compare_ms)}</span>
                <span>Copia {formatMs(t.copy_ms)}</span>
                <span>Organizza {formatMs(t.organize_ms)}</span>
                <span>Altri {formatMs(t.others_ms)}</span>
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button asChild size="sm">
                  <Link to={`/jobs/${j.id}`}>Apri dettaglio</Link>
                </Button>
                {report && (
                  <Button type="button" size="sm" variant="warn" onClick={() => setOpen(j.id)}>
                    Mostra report
                  </Button>
                )}
                <Button
                  type="button"
                  size="sm"
                  variant="destructive"
                  onClick={async () => {
                    const ok = await dialogs.confirm({
                      title: "Elimina esecuzione",
                      description: "Cancellare questa esecuzione dallo storico?",
                      action: "Elimina",
                      destructive: true,
                    })
                    if (!ok) return
                    api.deleteJob(j.id)
                      .then(() => setJobs((cur) => cur.filter((x) => x.id !== j.id)))
                      .catch((e) => {
                        setErr(e.message)
                        dialogs.alert(e.message, "API non raggiungibile")
                      })
                  }}
                >
                  Elimina
                </Button>
              </div>
            </CardContent>
          </Card>
        )
      })}
      <Dialog open={!!open} onOpenChange={(v) => { if (!v) setOpen("") }}>
        <DialogContent className="max-w-3xl">
          <DialogHeader>
            <DialogTitle>Report</DialogTitle>
          </DialogHeader>
          <pre className="max-h-[70vh] overflow-auto rounded-md bg-[#2F3D14] p-3 text-xs text-[#E8F7B0] whitespace-pre-wrap">
            {jobs.find((x) => x.id === open) ? reportText(jobs.find((x) => x.id === open)!) : ""}
          </pre>
        </DialogContent>
      </Dialog>
    </div>
  )
}

function Mini({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-md border bg-card p-2">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="font-semibold">{value ?? 0}</div>
    </div>
  )
}
