import PocketBase from "pocketbase"
import fetch from "node-fetch"

const g = globalThis as typeof globalThis & { fetch?: typeof fetch }
if (!g.fetch) g.fetch = fetch as unknown as typeof g.fetch

const PB_URL = process.env.PB_URL || "http://127.0.0.1:8090"
const EMAIL = process.env.PB_ADMIN_EMAIL || "admin@foto.local"
const PASS = process.env.PB_ADMIN_PASSWORD || "fotoadmin"

export const pb = new PocketBase(PB_URL)
pb.autoCancellation(false)

export async function waitForPocketBase(timeoutMs = 60000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`${PB_URL}/api/health`)
      if (res.ok) return
    } catch {
      // still starting
    }
    await new Promise((r) => setTimeout(r, 400))
  }
  throw new Error("PocketBase non risponde su " + PB_URL)
}

export async function authAdmin() {
  await pb.admins.authWithPassword(EMAIL, PASS)
}
