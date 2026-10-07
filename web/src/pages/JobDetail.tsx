import { Fragment, useEffect, useMemo, useState } from "react"
import { Link, useNavigate, useParams } from "react-router-dom"
import { ArrowLeft } from "lucide-react"
import { api, Job, UniquePhoto } from "@/lib/api"
import { formatBytes, formatMs } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Progress } from "@/components/ui/progress"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { useDialogs } from "@/components/AppDialogs"

export function JobDetail() {
  const { id } = useParams()
  const nav = useNavigate()
  const dialogs = useDialogs()
  const [job, setJob] = useState<Job | null>(null)
  const [uniques, setUniques] = useState<UniquePhoto[]>([])
  const [logsFlat, setLogsFlat] = useState<string[]>([])
  const [logsOrg, setLogsOrg] = useState<string[]>([])
  const [logsOthers, setLogsOthers] = useState<string[]>([])
  const [progress, setProgress] = useState({ current: 0, total: 0, message: "" })
  const [openId, setOpenId] = useState("")
  const [busyOrg, setBusyOrg] = useState(false)

  const load = async () => {
    if (!id) return
    const j = await api.job(id)
    setJob(j)
    setLogsFlat(linesFrom(j.log_flat))
    setLogsOrg(linesFrom(j.log_organize))
    setLogsOthers(linesFrom(j.log_others))
    if (j.status === "done" || j.status === "error" || j.status === "awaiting_organize" || j.status === "organizing") {
      setUniques(await api.uniques(id))
    }
  }

  useEffect(() => {
    load().catch(() => undefined)
    if (!id) return
    const t = setInterval(() => {
      load().catch(() => undefined)
    }, 2000)
    return () => clearInterval(t)
  }, [id])

  useEffect(() => {
    if (!id) return
    const es = new EventSource(`/api/jobs/${id}/stream`)
    es.onmessage = (ev) => {
      const data = JSON.parse(ev.data)
      if (data.type === "log" && data.message) {
        const add = (l: string[]) => [...l, data.message]
        if (data.phase === "organize") setLogsOrg(add)
        else if (data.phase === "others") setLogsOthers(add)
        else setLogsFlat(add)
      }
      if (data.current != null) setProgress({ current: data.current, total: data.total || 0, message: data.message || "" })
      if (data.job) setJob(data.job)
      if (data.type === "done" || data.type === "error" || data.step === "awaiting_organize") {
        load().catch(() => undefined)
      }
    }
    return () => es.close()
  }, [id])

  const pct = useMemo(() => {
    if (!progress.total) return job?.status === "done" || job?.status === "awaiting_organize" ? 100 : 0
    return Math.round((progress.current / progress.total) * 100)
  }, [progress, job])

  if (!job) return <div className="p-6">Caricamento...</div>

  const t = job.timings || { scan_ms: 0, compare_ms: 0, copy_ms: 0, organize_ms: 0, others_ms: 0, total_ms: 0 }
  const canOrganize = job.status === "awaiting_organize"

  return (
    <div className="mx-auto max-w-6xl space-y-6 p-6">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild>
          <Link to="/"><ArrowLeft className="h-4 w-4" /></Link>
        </Button>
        <div>
          <h1 className="text-2xl font-semibold">Esecuzione</h1>
          <p className="text-sm text-muted-foreground">{job.script_name}</p>
        </div>
        {job.status === "done" && <Badge variant="ok">completato</Badge>}
        {job.status === "error" && <Badge variant="err">errore</Badge>}
        {(job.status === "running" || job.status === "organizing") && <Badge variant="run">in corso</Badge>}
        {job.status === "awaiting_organize" && <Badge variant="run">flat pronto</Badge>}
        <Button
          type="button"
          size="sm"
          variant="destructive"
          className="ml-auto"
          onClick={async () => {
            if (!id) return
            const ok = await dialogs.confirm({
              title: "Elimina esecuzione",
              description: "Cancellare questa esecuzione dallo storico?",
              action: "Elimina",
              destructive: true,
            })
            if (!ok) return
            try {
              await api.deleteJob(id)
              nav("/")
            } catch (e) {
              dialogs.alert(e instanceof Error ? e.message : "Errore", "API non raggiungibile")
            }
          }}
        >
          Elimina
        </Button>
      </div>

      {(job.status === "queued" || job.status === "running" || job.status === "awaiting_organize") && (
        <Card className="border-primary bg-primary/20">
          <CardHeader>
            <CardTitle>{canOrganize ? "Backup flat finito" : "Organizzazione"}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {canOrganize ? (
              <>
                <p>
                  I file unici sono in <span className="font-mono text-sm">{job.flat_dir}</span>.
                  Puoi eliminarli o rinominarli prima di organizzarli in cartelle.
                </p>
                <p className="text-sm text-muted-foreground">
                  Se rinomini una foto, rinomina anche l&apos;eventuale JSON accanto (nome.jpg.json o nome.jpg.supplemental-metadata.json). Cancellare un file va bene: semplicemente non verrà organizzato.
                </p>
              </>
            ) : (
              <p className="text-sm text-muted-foreground">
                Il bottone si attiva quando il backup flat è finito.
              </p>
            )}
            <div className="flex flex-wrap gap-2">
              <Button type="button" variant="outline" disabled={!canOrganize} onClick={() => id && api.openFlat(id).catch(() => undefined)}>
                Apri cartella flat
              </Button>
              <Button
                type="button"
                disabled={!canOrganize || busyOrg}
                onClick={async () => {
                  if (!id || !canOrganize) return
                  setBusyOrg(true)
                  try {
                    setJob(await api.organize(id))
                  } catch (e) {
                    dialogs.alert(e instanceof Error ? e.message : "Errore", "API non raggiungibile")
                  } finally {
                    setBusyOrg(false)
                    load().catch(() => undefined)
                  }
                }}
              >
                {busyOrg ? "Organizzazione..." : canOrganize ? "Avvia organizzazione" : "In attesa del backup flat"}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 sm:grid-cols-5">
        <Stat title="Partito da" value={job.files_found} hint="immagini/video in origine" />
        <Stat title="Foto uniche" value={job.files_unique} hint="contenuti distinti" />
        <Stat title="Doppioni" value={job.files_duplicates} hint="saltati" />
        <Stat title="Prodotti" value={job.files_produced} hint="file in destinazione" />
        <Stat title="Altri file" value={job.files_other} hint="non foto/video (solo stats)" />
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Avanzamento</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <Progress value={pct} />
          <p className="text-sm text-muted-foreground">{progress.message || job.error_message || "In attesa..."} {progress.total ? `(${progress.current}/${progress.total})` : ""}</p>
          <div className="grid gap-3 sm:grid-cols-6 text-sm">
            <TimeBox label="Scansione" ms={t.scan_ms} />
            <TimeBox label="Confronti" ms={t.compare_ms} />
            <TimeBox label="Copia uniche" ms={t.copy_ms} />
            <TimeBox label="Organizzazione" ms={t.organize_ms} />
            <TimeBox label="Altri file" ms={t.others_ms} />
            <TimeBox label="Totale" ms={t.total_ms} />
          </div>
          <div className="text-xs text-muted-foreground">
            Origine: <span className="font-mono">{job.source_dir}</span><br />
            Destinazione: <span className="font-mono">{job.dest_dir}</span><br />
            Flat: <span className="font-mono">{job.flat_dir || job.dest_dir + "/flat"}</span><br />
            Organizzate: <span className="font-mono">{job.org_dir || job.dest_dir + "/organizzate"}</span>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Foto uniche e doppioni</CardTitle>
        </CardHeader>
        <CardContent>
          <Table wrapperClassName="max-h-[400px]">
            <TableHeader className="sticky top-0 z-10 bg-card">
              <TableRow>
                <TableHead>File tenuto</TableHead>
                <TableHead>Doppioni</TableHead>
                <TableHead>Dimensione</TableHead>
                <TableHead>Origine tenuta</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {uniques.map((u) => (
                <Fragment key={u.id}>
                  <TableRow className="cursor-pointer" onClick={() => setOpenId(openId === u.id ? "" : u.id)}>
                    <TableCell className="font-medium">{u.kept_name}</TableCell>
                    <TableCell>
                      <Badge variant={u.duplicate_count ? "secondary" : "outline"}>{u.duplicate_count}</Badge>
                    </TableCell>
                    <TableCell>{formatBytes(u.size)}</TableCell>
                    <TableCell className="max-w-md truncate font-mono text-xs">{u.kept_source}</TableCell>
                  </TableRow>
                  {openId === u.id && u.duplicate_paths.length > 0 && (
                    <TableRow>
                      <TableCell colSpan={4} className="bg-muted/40 font-mono text-xs">
                        {u.duplicate_paths.map((p) => <div key={p}>{p}</div>)}
                      </TableCell>
                    </TableRow>
                  )}
                </Fragment>
              ))}
              {job.status === "done" && uniques.length === 0 && (
                <TableRow><TableCell colSpan={4}>Nessuna foto unica.</TableCell></TableRow>
              )}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Altri file (trova_altri_file.sh)</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {(!job.other_exts || !Object.keys(job.other_exts).length) && <p className="text-sm text-muted-foreground">Nessun file extra, oppure esecuzione ancora in corso.</p>}
          {job.other_exts && Object.keys(job.other_exts).length > 0 && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Estensione</TableHead>
                  <TableHead>Quantità</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {Object.keys(job.other_exts).sort().map((ext) => (
                  <TableRow key={ext}>
                    <TableCell>.{ext}</TableCell>
                    <TableCell>{job.other_exts[ext]}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {job.other_files && job.other_files.length > 0 && (
            <pre className="max-h-48 overflow-auto rounded-md bg-muted p-3 font-mono text-xs">{job.other_files.join("\n")}</pre>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Report</CardTitle>
          <p className="text-sm text-muted-foreground">
            {job.status === "done" ? "Report finale." : "Si aggiorna durante l'esecuzione, non solo alla fine."}
          </p>
        </CardHeader>
        <CardContent>
          <pre className="max-h-96 overflow-auto rounded-md bg-[#2F3D14] p-3 text-xs text-[#E8F7B0] whitespace-pre-wrap">
            {typeof job.report_md === "string" && job.report_md ? job.report_md : "Il report compare appena partono gli step."}
          </pre>
        </CardContent>
      </Card>

      <div className="grid gap-4 lg:grid-cols-3">
        <LogCard title="Log backup flat" lines={logsFlat} />
        <LogCard title="Log altri file" lines={logsOthers} />
        <LogCard title="Log organizzazione" lines={logsOrg} />
      </div>
    </div>
  )
}

function linesFrom(v: unknown): string[] {
  if (typeof v === "string") return v ? v.split("\n") : []
  if (Array.isArray(v)) return v.map(String)
  return []
}

function LogCard({ title, lines }: { title: string; lines: string[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <pre className="max-h-72 overflow-auto rounded-md bg-[#2F3D14] p-3 text-xs text-[#E8F7B0] whitespace-pre-wrap">
          {lines.length ? lines.join("\n") : "Nessun log ancora."}
        </pre>
      </CardContent>
    </Card>
  )
}

function Stat({ title, value, hint }: { title: string; value: number; hint: string }) {
  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="text-3xl font-semibold">{value ?? 0}</div>
        <p className="text-xs text-muted-foreground">{hint}</p>
      </CardContent>
    </Card>
  )
}

function TimeBox({ label, ms }: { label: string; ms: number }) {
  return (
    <div className="rounded-md border p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="font-medium">{formatMs(ms)}</div>
    </div>
  )
}
