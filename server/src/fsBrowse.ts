import fs from "fs"
import os from "os"
import path from "path"

export function browseDir(raw?: string) {
  const home = os.homedir()
  let target = raw && raw.trim() ? raw : home
  if (target === "~") target = home
  if (target.startsWith("~/")) target = path.join(home, target.slice(2))
  target = path.resolve(target)

  if (!fs.existsSync(target) || !fs.statSync(target).isDirectory()) {
    throw new Error("Cartella non trovata: " + target)
  }

  const entries = fs.readdirSync(target, { withFileTypes: true })
  const dirs = entries
    .filter((e) => e.isDirectory() && !e.name.startsWith("."))
    .map((e) => ({ name: e.name, path: path.join(target, e.name) }))
    .sort((a, b) => a.name.localeCompare(b.name))

  const parent = path.dirname(target)

  return {
    path: target,
    parent: parent !== target ? parent : "",
    home,
    dirs,
  }
}
