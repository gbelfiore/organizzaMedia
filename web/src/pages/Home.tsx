import { FormEvent, useEffect, useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { api, Job, MediaType } from "@/lib/api"
import { FolderPicker } from "@/components/FolderPicker"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Badge } from "@/components/ui/badge"
import { useDialogs } from "@/components/AppDialogs"

function statusBadge(s: Job["status"]) {
  if (s === "done") return <Badge variant="ok">completato</Badge>
  if (s === "error") return <Badge variant="err">errore</Badge>
  if (s === "running" || s === "organizing") return <Badge variant="run">in corso</Badge>
  if (s === "awaiting_organize") return <Badge variant="run">flat pronto</Badge>
  return <Badge variant="secondary">in coda</Badge>
}

export function Home() {
  const nav = useNavigate()
  const dialogs = useDialogs()
  const [source, setSource] = useState("")
  const [dest, setDest] = useState("")
  const [media, setMedia] = useState<MediaType>("foto")
  const [limit, setLimit] = useState(0)
  const [dry, setDry] = useState(false)
  const [jobs, setJobs] = useState<Job[]>([])
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const [listErr, setListErr] = useState("")

  const reload = () =>
    api.jobs()
      .then((items) => {
        setJobs(items)
        setListErr("")
      })
      .catch((e) => setListErr(e.message))

  useEffect(() => {
    reload()
    const t = setInterval(reload, 4000)
    return () => clearInterval(t)
  }, [])

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setErr("")
    try {
      const job = await api.createJob({
        source_dir: source,
        dest_dir: dest,
        media_type: media,
        dry_run: dry,
        file_limit: limit,
      })
      nav(`/jobs/${job.id}`)
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Errore"
      setErr(msg)
      dialogs.alert(msg, "API non raggiungibile")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="mx-auto max-w-5xl space-y-8 p-6">
      <p className="text-muted-foreground">
        Lancia lo script da origine e destinazione. PocketBase tiene gli hash per confrontare più velocemente i duplicati.
      </p>

      <Card>
        <CardHeader>
          <CardTitle>Nuova elaborazione</CardTitle>
          <CardDescription>Dentro la destinazione vengono create <code>flat/</code> (uniche) e <code>organizzate/</code> (per data).</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-5" onSubmit={submit}>
            <div className="space-y-2">
              <Label>Cartella di origine</Label>
              <FolderPicker value={source} onChange={setSource} />
            </div>
            <div className="space-y-2">
              <Label>Cartella di destinazione</Label>
              <FolderPicker value={dest} onChange={setDest} />
            </div>
            <div className="grid gap-4 sm:grid-cols-3">
              <div className="space-y-2">
                <Label>Tipo</Label>
                <select
                  className="flex h-10 w-full rounded-md border border-input bg-background px-3 text-sm"
                  value={media}
                  onChange={(e) => setMedia(e.target.value as MediaType)}
                >
                  <option value="foto">Foto</option>
                  <option value="video">Video</option>
                  <option value="media">Foto + video</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label>Limite file (0 = tutti)</Label>
                <Input type="number" min={0} value={limit} onChange={(e) => setLimit(Number(e.target.value))} />
              </div>
              <label className="flex items-end gap-2 pb-2 text-sm">
                <input type="checkbox" checked={dry} onChange={(e) => setDry(e.target.checked)} />
                Dry run (non copia)
              </label>
            </div>
            {err && <p className="text-sm text-destructive">{err}</p>}
            <Button type="submit" disabled={busy || !source || !dest}>
              {busy ? "Avvio..." : "Lancia elaborazione"}
            </Button>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle>Ultime esecuzioni</CardTitle>
          <Button asChild size="sm" variant="secondary">
            <Link to="/esecuzioni">Vedi storico</Link>
          </Button>
        </CardHeader>
        <CardContent className="space-y-3">
          {listErr && <p className="text-sm text-destructive">{listErr}</p>}
          {jobs.length === 0 && !listErr && <p className="text-sm text-muted-foreground">Nessuna esecuzione ancora.</p>}
          {jobs.slice(0, 3).map((j) => (
            <div key={j.id} className="flex items-center gap-2 rounded-lg border p-3 hover:bg-accent">
              <Link to={`/jobs/${j.id}`} className="min-w-0 flex-1">
                <div className="truncate font-medium">{j.source_dir}</div>
                <div className="truncate text-xs text-muted-foreground">→ {j.dest_dir}</div>
              </Link>
              <div className="flex shrink-0 items-center gap-2">
                {statusBadge(j.status)}
                <span className="text-xs text-muted-foreground">{j.files_found} → {j.files_produced}</span>
                <Button
                  type="button"
                  size="sm"
                  variant="destructive"
                  onClick={async (e) => {
                    e.preventDefault()
                    const ok = await dialogs.confirm({
                      title: "Elimina esecuzione",
                      description: "Cancellare questa esecuzione dallo storico?",
                      action: "Elimina",
                      destructive: true,
                    })
                    if (!ok) return
                    api.deleteJob(j.id).then(reload).catch((err) => {
                      setListErr(err.message)
                      dialogs.alert(err.message, "Errore")
                    })
                  }}
                >
                  Elimina
                </Button>
              </div>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  )
}
