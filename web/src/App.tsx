import { Navigate, Route, Routes } from "react-router-dom"
import { DialogsProvider } from "@/components/AppDialogs"
import { SiteHeader } from "@/components/SiteHeader"
import { Esecuzioni } from "@/pages/Esecuzioni"
import { Home } from "@/pages/Home"
import { JobDetail } from "@/pages/JobDetail"

export function App() {
  return (
    <DialogsProvider>
      <div className="min-h-screen">
        <SiteHeader />
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/esecuzioni" element={<Esecuzioni />} />
          <Route path="/jobs/:id" element={<JobDetail />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </div>
    </DialogsProvider>
  )
}
