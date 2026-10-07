import { Link } from "react-router-dom"
import { CameraLogo } from "@/components/CameraLogo"
import { Button } from "@/components/ui/button"

export function SiteHeader() {
  return (
    <header className="border-b bg-card/80 backdrop-blur">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-6 py-4">
        <Link to="/" className="flex items-center gap-3">
          <span className="inline-flex h-12 w-12 items-center justify-center rounded-2xl bg-primary/30 shadow-sm">
            <CameraLogo size={40} />
          </span>
          <span>
            <span className="block text-lg font-semibold leading-tight">Organizza foto</span>
            <span className="block text-xs text-muted-foreground">click click</span>
          </span>
        </Link>
        <nav className="flex items-center gap-2">
          <Button asChild size="sm">
            <Link to="/">Nuova</Link>
          </Button>
          <Button asChild size="sm" variant="secondary">
            <Link to="/esecuzioni">Esecuzioni</Link>
          </Button>
        </nav>
      </div>
    </header>
  )
}
