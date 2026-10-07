import { useEffect, useState } from "react"
import { Folder, Home, ChevronUp } from "lucide-react"
import { api, FsListing } from "@/lib/api"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"

type Props = {
  value: string
  onChange: (path: string) => void
}

export function FolderPicker({ value, onChange }: Props) {
  const [open, setOpen] = useState(false)
  const [listing, setListing] = useState<FsListing | null>(null)
  const [err, setErr] = useState("")

  const load = async (p: string) => {
    setErr("")
    try {
      const data = await api.fs(p)
      setListing(data)
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Errore")
    }
  }

  useEffect(() => {
    if (open) load(value || "")
  }, [open])

  return (
    <div className="space-y-2">
      <div className="flex gap-2">
        <Input value={value} onChange={(e) => onChange(e.target.value)} placeholder="/percorso/cartella" />
        <Button type="button" variant="outline" onClick={() => setOpen(true)}>
          <Folder className="mr-2 h-4 w-4" />
          Sfoglia
        </Button>
      </div>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-xl">
          <DialogHeader>
            <DialogTitle>Scegli cartella</DialogTitle>
          </DialogHeader>
          {listing && (
            <div className="space-y-3">
              <div className="flex items-center justify-between gap-2 text-xs text-muted-foreground">
                <span className="truncate font-mono">{listing.path}</span>
                <div className="flex gap-1">
                  <Button type="button" size="sm" variant="ghost" onClick={() => load(listing.home)}>
                    <Home className="h-4 w-4" />
                  </Button>
                  {listing.parent && (
                    <Button type="button" size="sm" variant="ghost" onClick={() => load(listing.parent)}>
                      <ChevronUp className="h-4 w-4" />
                    </Button>
                  )}
                </div>
              </div>
              {err && <p className="text-sm text-destructive">{err}</p>}
              <div className="max-h-64 overflow-auto rounded-md border">
                {listing.dirs.map((d) => (
                  <button
                    key={d.path}
                    type="button"
                    className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-accent"
                    onClick={() => load(d.path)}
                  >
                    <Folder className="h-4 w-4 text-primary" />
                    {d.name}
                  </button>
                ))}
                {listing.dirs.length === 0 && <p className="px-3 py-2 text-sm text-muted-foreground">Nessuna sottocartella</p>}
              </div>
            </div>
          )}
          {!listing && err && <p className="text-sm text-destructive">{err}</p>}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>Annulla</Button>
            <Button
              type="button"
              disabled={!listing}
              onClick={() => {
                if (!listing) return
                onChange(listing.path)
                setOpen(false)
              }}
            >
              Usa questa
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
