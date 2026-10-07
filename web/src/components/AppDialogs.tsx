import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

type ConfirmOpts = { title?: string; description: string; action?: string; destructive?: boolean }

type Dialogs = {
  alert: (description: string, title?: string) => Promise<void>
  confirm: (opts: ConfirmOpts | string) => Promise<boolean>
}

const DialogsContext = createContext<Dialogs | null>(null)

export function useDialogs() {
  const ctx = useContext(DialogsContext)
  if (!ctx) throw new Error("useDialogs va usato dentro DialogsProvider")
  return ctx
}

export function DialogsProvider({ children }: { children: ReactNode }) {
  const [info, setInfo] = useState({ open: false, title: "Avviso", description: "" })
  const [ask, setAsk] = useState({ open: false, title: "Conferma", description: "", action: "Continua", destructive: false })
  const infoDone = useRef<(() => void) | null>(null)
  const askDone = useRef<((ok: boolean) => void) | null>(null)

  const alert = useCallback((description: string, title = "Avviso") => {
    return new Promise<void>((resolve) => {
      infoDone.current = resolve
      setInfo({ open: true, title, description })
    })
  }, [])

  const confirm = useCallback((opts: ConfirmOpts | string) => {
    const o = typeof opts === "string" ? { description: opts } : opts
    return new Promise<boolean>((resolve) => {
      askDone.current = resolve
      setAsk({
        open: true,
        title: o.title || "Conferma",
        description: o.description,
        action: o.action || "Continua",
        destructive: !!o.destructive,
      })
    })
  }, [])

  const value = useMemo(() => ({ alert, confirm }), [alert, confirm])

  return (
    <DialogsContext.Provider value={value}>
      {children}
      <Dialog
        open={info.open}
        onOpenChange={(open) => {
          setInfo((s) => ({ ...s, open }))
          if (!open) {
            infoDone.current?.()
            infoDone.current = null
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{info.title}</DialogTitle>
            <DialogDescription>{info.description}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button type="button" onClick={() => setInfo((s) => ({ ...s, open: false }))}>Ok</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <AlertDialog
        open={ask.open}
        onOpenChange={(open) => {
          setAsk((s) => ({ ...s, open }))
          if (!open && askDone.current) {
            askDone.current(false)
            askDone.current = null
          }
        }}
      >
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{ask.title}</AlertDialogTitle>
            <AlertDialogDescription>{ask.description}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Annulla</AlertDialogCancel>
            <AlertDialogAction
              className={ask.destructive ? "bg-destructive text-destructive-foreground hover:bg-destructive/85" : undefined}
              onClick={() => {
                askDone.current?.(true)
                askDone.current = null
              }}
            >
              {ask.action}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </DialogsContext.Provider>
  )
}
