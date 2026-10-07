import { pb } from "./pb"

function text(name: string, required = false) {
  return { name, type: "text", required, options: { min: null, max: null, pattern: "" } }
}
function num(name: string) {
  return { name, type: "number", required: false, options: { min: null, max: null, noDecimal: false } }
}
function bool(name: string) {
  return { name, type: "bool", required: false, options: {} }
}
function json(name: string) {
  return { name, type: "json", required: false, options: { maxSize: 2000000 } }
}

async function createCollection(name: string, schema: unknown[]) {
  try {
    await pb.collections.getOne(name)
    return
  } catch {
    // create
  }
  try {
    await pb.collections.create({
      name,
      type: "base",
      listRule: "",
      viewRule: "",
      createRule: "",
      updateRule: "",
      deleteRule: "",
      schema,
    })
  } catch (err: unknown) {
    const e = err as { response?: unknown }
    console.error("Errore collection", name, JSON.stringify(e.response, null, 2))
    throw err
  }
}

export async function ensureSchema() {
  await createCollection("jobs", [
    text("source_dir", true),
    text("dest_dir", true),
    text("flat_dir"),
    text("org_dir"),
    text("media_type", true),
    text("status", true),
    bool("dry_run"),
    num("file_limit"),
    num("files_found"),
    num("files_unique"),
    num("files_duplicates"),
    num("files_produced"),
    num("files_without_meta"),
    num("files_errors"),
    num("files_other"),
    json("other_exts"),
    json("other_files"),
    json("report_md"),
    json("log_flat"),
    json("log_organize"),
    json("log_others"),
    json("timings"),
    text("script_name"),
    text("error_message"),
  ])

  await ensureJobFields()

  await createCollection("file_hashes", [
    text("path", true),
    num("size"),
    num("mtime"),
    text("sha256", true),
  ])

  await createCollection("unique_media", [
    text("sha256", true),
    num("size"),
    text("kept_path"),
    text("kept_name"),
    text("first_source"),
  ])

  const jobs = await pb.collections.getOne("jobs")
  await createCollection("job_uniques", [
    {
      name: "job",
      type: "relation",
      required: true,
      options: { collectionId: jobs.id, cascadeDelete: true, maxSelect: 1, minSelect: 0, displayFields: [] },
    },
    text("sha256", true),
    text("kept_name"),
    text("kept_source"),
    text("dest_path"),
    num("size"),
    num("duplicate_count"),
    json("duplicate_paths"),
  ])
}

async function ensureJobFields() {
  const col = await pb.collections.getOne("jobs")
  const schema = (col.schema || []) as { name: string }[]
  const names = new Set(schema.map((f) => f.name))
  const extra = [
    num("files_other"),
    json("other_exts"),
    json("other_files"),
    json("report_md"),
    text("org_dir"),
    json("log_flat"),
    json("log_organize"),
    json("log_others"),
  ]
  let changed = false
  for (const field of extra) {
    if (!names.has(field.name)) {
      schema.push(field as { name: string })
      changed = true
    }
  }
  if (changed) {
    await pb.collections.update(col.id, { schema })
  }
}
