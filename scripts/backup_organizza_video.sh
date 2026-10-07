#!/bin/zsh
#
# Backup flat + deduplica + organizzazione per data dei VIDEO.
#
#   1. Legge ricorsivamente la cartella di origine e copia tutti i video, in
#      modo flat (senza sottocartelle), nella cartella di backup.
#   2. Durante la copia salta i duplicati: due file sono duplicati se hanno
#      contenuto identico (stessa dimensione + stesso hash SHA-256). L'hash
#      viene calcolato solo quando due file hanno la stessa dimensione.
#   3. Organizza la cartella flat in <organizzate>/AAAA/MM (logica di
#      organizza_video.sh, inglobata qui).
#
# I metadati non vengono mai persi: le copie sono identiche byte per byte
# (EXIF/XMP/GPS inclusi), conservano permessi, attributi estesi, data di
# modifica e data di creazione. Exiftool AGGIUNGE solo dati mancanti (data
# di scatto, GPS dal JSON di Google Takeout), non sovrascrive mai quelli validi.
#
# Uso:
#   ./backup_organizza_video.sh [opzioni] [origine] [cartella_bk_flat] [cartella_organizzate]
#
# Opzioni:
#   -n, --limit N   elabora solo i primi N file dell'origine (ordine alfabetico)
#   --dry-run       simula senza copiare nulla (equivale a DRY_RUN=1)
#   -h, --help      mostra l'aiuto
#
#   DRY_RUN=1 ./backup_organizza_video.sh ...   # simula senza copiare nulla
#   LIMIT=50  ./backup_organizza_video.sh ...   # come --limit 50
#
# Il backup flat è incrementale: rilanciandolo (anche con un'altra origine)
# i file già presenti nel backup vengono riconosciuti e saltati.

# ---------------------------------------------------------------- config ---
MEDIA_LABEL="video"
MEDIA_EXTS=(mp4 mov m4v 3gp mts m2ts avi mkv wmv mpg mpeg webm)
# Tag letti (in ordine di priorità) per ricavare la data di ripresa.
# CreationDate (Apple) è in ora locale con fuso, gli altri QuickTime sono UTC.
DATE_TAGS=(CreationDate MediaCreateDate CreateDate DateTimeOriginal TrackCreateDate ContentCreateDate)
# Le date QuickTime sono in UTC per specifica: convertile da/verso l'ora locale
EXIF_OPTS=(-api QuickTimeUTC)
DEFAULT_BK_SUFFIX="_BK_Video_Flat"
DEFAULT_ORG_SUFFIX="_Video_Organizzati"

# Argomenti exiftool per scrivere la data quando manca (tutti i tag scritti
# sono tra quelli di DATE_TAGS, quindi sono assenti o non validi).
# Nota: AVI/MKV/WMV/WEBM non sono scrivibili da exiftool, restano intatti.
missing_date_args() {
    local d="$1"
    print -rl -- "-CreateDate=$d" "-MediaCreateDate=$d" "-TrackCreateDate=$d"
}

# Argomenti exiftool per scrivere il GPS quando manca (formato Apple + standard)
missing_gps_args() {
    local lat="$1" lon="$2" alt="$3" coords="$1, $2"
    [[ -n "$alt" ]] && coords+=", $alt"
    print -rl -- "-Keys:GPSCoordinates=$coords" "-UserData:GPSCoordinates=$coords"
}

# Argomenti exiftool per allineare le date del filesystem alla data di ripresa
# (l'ultima assegnazione valida vince)
file_date_args() {
    print -rl -- \
        "-FileModifyDate<TrackCreateDate" "-FileCreateDate<TrackCreateDate" \
        "-FileModifyDate<MediaCreateDate" "-FileCreateDate<MediaCreateDate" \
        "-FileModifyDate<CreateDate" "-FileCreateDate<CreateDate" \
        "-FileModifyDate<DateTimeOriginal" "-FileCreateDate<DateTimeOriginal" \
        "-FileModifyDate<CreationDate" "-FileCreateDate<CreationDate"
}
# ------------------------------------------------------------------------ ---

zmodload -F zsh/stat b:zstat
zmodload zsh/datetime
START_EPOCH=$EPOCHSECONDS
DATE_START=$(date "+%Y-%m-%d %H:%M:%S")
RUN_STAMP=$(date "+%Y%m%d_%H%M%S")

if ! command -v exiftool &> /dev/null; then
    echo "Errore: 'exiftool' non è installato. Installalo con 'brew install exiftool'."
    exit 1
fi
HAS_SETFILE=0
command -v SetFile &> /dev/null && HAS_SETFILE=1

DRY_RUN=${DRY_RUN:-0}
LIMIT=${LIMIT:-0}
SCRIPT_NAME="${0:t}"

usage() {
    echo "Uso: $SCRIPT_NAME [opzioni] [origine] [cartella_bk_flat] [cartella_organizzate]"
    echo ""
    echo "Opzioni:"
    echo "  -n, --limit N   elabora solo i primi N file $MEDIA_LABEL dell'origine (ordine alfabetico)"
    echo "  --dry-run       simula senza copiare nulla"
    echo "  -h, --help      mostra questo aiuto"
}

# le opzioni possono stare prima o dopo i percorsi
POSITIONAL=()
while (( $# )); do
    case "$1" in
        -n|--limit)
            [[ -n "$2" ]] || { echo "Errore: $1 richiede un numero."; exit 1; }
            LIMIT="$2"; shift 2 ;;
        --limit=*) LIMIT="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        -*) echo "Errore: opzione sconosciuta '$1'."; usage; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]}"
if [[ "$LIMIT" != <-> ]]; then
    echo "Errore: il limite deve essere un numero intero >= 0 (ricevuto '$LIMIT')."
    exit 1
fi
LIMIT=$(( 10#$LIMIT ))

# Argomenti: [origine] [bk_flat] [organizzate]
if [ -z "$1" ]; then
    echo -n "Inserisci il percorso della cartella di origine ($MEDIA_LABEL): "
    read SOURCE_DIR
else
    SOURCE_DIR="$1"
fi
SOURCE_DIR="${SOURCE_DIR%/}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Errore: La cartella '$SOURCE_DIR' non esiste."
    exit 1
fi
SOURCE_DIR="${SOURCE_DIR:A}"

ask_dir() {
    local prompt="$1" default="$2" answer
    echo -n "$prompt [$default]: " >/dev/tty
    read answer
    print -r -- "${answer:-$default}"
}

DEFAULT_BK="$(dirname "$SOURCE_DIR")/$(basename "$SOURCE_DIR")${DEFAULT_BK_SUFFIX}"
DEFAULT_ORG="$(dirname "$SOURCE_DIR")/$(basename "$SOURCE_DIR")${DEFAULT_ORG_SUFFIX}"
if [ -n "$2" ]; then
    BK_DIR="$2"
elif [ -z "$1" ]; then
    BK_DIR=$(ask_dir "Cartella di backup flat" "$DEFAULT_BK")
else
    BK_DIR="$DEFAULT_BK"
fi
if [ -n "$3" ]; then
    ORG_DIR="$3"
elif [ -z "$1" ]; then
    ORG_DIR=$(ask_dir "Cartella organizzata per data" "$DEFAULT_ORG")
else
    ORG_DIR="$DEFAULT_ORG"
fi

BK_DIR="${BK_DIR%/}"; BK_DIR="${BK_DIR:A}"
ORG_DIR="${ORG_DIR%/}"; ORG_DIR="${ORG_DIR:A}"

if [[ "$BK_DIR" == "$SOURCE_DIR" || "$ORG_DIR" == "$SOURCE_DIR" || "$BK_DIR" == "$ORG_DIR" ]]; then
    echo "Errore: origine, backup flat e cartella organizzata devono essere cartelle diverse."
    exit 1
fi
# la cartella di origine viene solo letta: niente destinazioni al suo interno
if [[ "$BK_DIR" == "$SOURCE_DIR"/* || "$ORG_DIR" == "$SOURCE_DIR"/* ]]; then
    echo "Errore: le cartelle di destinazione non possono stare dentro l'origine '$SOURCE_DIR'."
    exit 1
fi

mkdir -p "$BK_DIR" "$ORG_DIR" || exit 1

# report e dettaglio restano fuori dalle cartelle dest (solo console / tmp)
REPORT_FILE="${TMPDIR:-/tmp}/report_backup_${MEDIA_LABEL}_${RUN_STAMP}.md"
DETAIL_FILE="${TMPDIR:-/tmp}/report_backup_${MEDIA_LABEL}_${RUN_STAMP}_dettaglio.tsv"
INDEX_FILE="${BK_DIR}/indice_origine.tsv"
printf 'fase\tesito\tfile\tdestinazione\tbyte\tnote\n' > "$DETAIL_FILE"

# ------------------------------------------------------------ progress UI ---
PROGRESS_UI=0
[[ -t 1 && -t 2 ]] && PROGRESS_UI=1
PHASE_LABEL=""
CUR=0
TOT=0

if [[ -t 1 || -t 2 ]]; then
    C_GREEN=$'\e[32m'
    C_ORANGE=$'\e[38;5;208m'
    C_RED=$'\e[31m'
    C_RESET=$'\e[0m'
else
    C_GREEN=""
    C_ORANGE=""
    C_RED=""
    C_RESET=""
fi

pct_of() {
    local cur=$1 tot=$2
    (( tot > 0 )) && echo $(( cur * 100 / tot )) || echo 0
}

progress_teardown() {
    if (( PROGRESS_UI )); then
        printf '\e[r\e[?25h' >/dev/tty
    fi
}
trap progress_teardown EXIT
# in caso di interruzione scrive comunque il report parziale
trap 'progress_teardown; PROGRESS_UI=0; INTERRUPTED=1; (( $+functions[write_report] )) && write_report && echo "\nInterrotto: report parziale in $REPORT_FILE"; exit 130' INT TERM
INTERRUPTED=0

progress_draw_header() {
    (( PROGRESS_UI )) || return
    local pct bar_w filled empty bar
    pct=$(pct_of "$CUR" "$TOT")
    bar_w=28
    filled=$(( pct * bar_w / 100 ))
    empty=$(( bar_w - filled ))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf '\e7\e[1;1H\e[2K' >/dev/tty
    printf '%s %3d%%  [%s]  %d/%d' "$PHASE_LABEL" "$pct" "$bar" "$CUR" "$TOT" >/dev/tty
    printf '\e[2;1H\e[2K%s' "------------------------------------------------" >/dev/tty
    printf '\e8' >/dev/tty
}

progress_setup() {
    (( PROGRESS_UI )) || return
    local lines
    lines=${LINES:-$(tput lines 2>/dev/null || echo 40)}
    (( lines < 5 )) && lines=40
    printf '\e[?25l\e[2J\e[H' >/dev/tty
    printf '\e[3;%dr' "$lines" >/dev/tty
    progress_draw_header
    printf '\e[3;1H' >/dev/tty
}

start_phase() {
    PHASE_LABEL="$1"
    TOT="$2"
    CUR=0
    progress_draw_header
}

log_msg() {
    local color="$C_RESET"
    case "$1" in
        ok) color="$C_GREEN"; shift ;;
        skip) color="$C_ORANGE"; shift ;;
        err) color="$C_RED"; shift ;;
    esac
    if (( PROGRESS_UI )); then
        printf '%s%s%s\n' "$color" "$*" "$C_RESET" >/dev/tty
        progress_draw_header
    else
        printf '%s[%3d%%] %s%s\n' "$color" "$(pct_of "$CUR" "$TOT")" "$*" "$C_RESET"
    fi
}

# ---------------------------------------------------------------- helpers ---
is_media_file() {
    local name="$1"
    [[ "$name" == ._* ]] && return 1   # AppleDouble di macOS
    (( ${MEDIA_EXTS[(Ie)${name:e:l}]} ))
}

file_size() {
    zstat +size -- "$1"
}

file_hash() {
    local out
    out=$(openssl dgst -sha256 < "$1") || return 1
    print -r -- "${out##* }"
}

# Dimensione leggibile (B, KB, MB, GB, TB)
human_size() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i] }'
}

# Durata leggibile (hh:mm:ss) da secondi
human_duration() {
    local s=${1:-0}
    printf '%02d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
}

# Riga del report dettagliato (TSV): fase, esito, file, destinazione, byte, note
detail_row() {
    local IFS=$'\t'
    print -r -- "$*" >> "$DETAIL_FILE"
}

# Estensione minuscola per le statistiche
ext_of() {
    local e="${1:t:e:l}"
    print -r -- "${e:-(nessuna)}"
}

# Conta file media e byte (ricorsivo se $2 = 1): imposta CNT_FILES, CNT_BYTES
count_media() {
    local dir="$1" recursive="$2" f
    local -a files sz
    CNT_FILES=0; CNT_BYTES=0
    if (( recursive )); then files=("$dir"/**/*(N.)); else files=("$dir"/*(N.)); fi
    for f in "${files[@]}"; do
        is_media_file "${f:t}" || continue
        zstat -A sz +size -- "$f" || continue
        (( CNT_FILES++ ))
        (( CNT_BYTES += sz[1] ))
    done
}

# Copia preservando contenuto (metadati interni), permessi, attributi estesi,
# data di modifica e data di creazione; verifica la dimensione finale.
# Copia su un file temporaneo nascosto: un'interruzione non lascia file troncati.
copy_preserving() {
    local src="$1" dst="$2" birth
    local tmp="${dst:h}/.${dst:t}.partial"
    [[ -e "$dst" ]] && return 1
    if ! cp -p "$src" "$tmp" 2>/dev/null \
        || [[ "$(file_size "$src")" != "$(file_size "$tmp")" ]] \
        || ! mv -n "$tmp" "$dst"; then
        rm -f "$tmp"
        return 1
    fi
    if (( HAS_SETFILE )); then
        birth=$(stat -f %SB -t "%m/%d/%Y %H:%M:%S" "$src" 2>/dev/null)
        [[ -n "$birth" ]] && SetFile -d "$birth" "$dst" 2>/dev/null
    fi
    return 0
}

# Sidecar JSON di Google Takeout per un file (anche con nomi troncati)
find_sidecar_json() {
    local file="$1" c
    local -a cands
    for c in "${file}.supplemental-metadata.json" "${file}.json"; do
        [[ -f "$c" ]] && { print -r -- "$c"; return 0; }
    done
    # Takeout tronca i nomi lunghi: foto.jpg.supplemental-me.json, foto.jpg.su.json
    cands=( "${file}".s*.json(N) )
    (( ${#cands} )) && { print -r -- "${cands[1]}"; return 0; }
    # Takeout sposta il contatore: foto(1).jpg -> foto.jpg(1).json
    local dir="${file:h}" base="${file:t}"
    if [[ "$base" =~ '^(.*)(\([0-9]+\))(\.[^.]+)$' ]]; then
        for c in "${dir}/${match[1]}${match[3]}.supplemental-metadata${match[2]}.json" \
                 "${dir}/${match[1]}${match[3]}${match[2]}.json"; do
            [[ -f "$c" ]] && { print -r -- "$c"; return 0; }
        done
    fi
    return 1
}

# Legge dal JSON Takeout: timestamp|lat|lon|alt (campi vuoti se assenti)
read_takeout_json() {
    python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
ts = ""
for key in ("photoTakenTime", "creationTime"):
    t = (d.get(key) or {}).get("timestamp")
    if t not in (None, "", 0, "0"):
        ts = str(t).strip()
        break
lat = lon = alt = ""
for key in ("geoData", "geoDataExif"):
    g = d.get(key) or {}
    if g.get("latitude") or g.get("longitude"):
        lat, lon = str(g.get("latitude")), str(g.get("longitude"))
        alt = str(g.get("altitude", "")) if g.get("altitude") else ""
        break
print("|".join((ts, lat, lon, alt)))
' "$1" 2>/dev/null
}

is_valid_date_parts() {
    [[ "$1" =~ ^(19[7-9][0-9]|20[0-3][0-9])$ ]] && [[ "$2" =~ ^(0[1-9]|1[0-2])$ ]]
}

# ----------------------------------------------------------------- report ---
# Definito prima delle fasi così che, in caso di interruzione (Ctrl-C), il trap
# possa scrivere un report parziale con i dati raccolti fino a quel momento.

# Percentuale con un decimale
pct1() {
    awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { if (b > 0) printf "%.1f%%", a * 100 / b; else printf "0%%" }'
}

# Velocità media (byte/secondo leggibile)
throughput() {
    local bytes="${1:-0}" secs="${2:-0}"
    (( secs > 0 )) && print -r -- "$(human_size $(( bytes / secs )))/s" || print -r -- "-"
}

# Escape del carattere | nelle celle delle tabelle markdown
md_esc() {
    print -r -- "${1//|/\\|}"
}

write_list() {
    local empty_msg="$1"
    shift
    if (( $# )); then
        local item
        for item in "$@"; do
            echo "- \`$item\`"
        done
    else
        echo "$empty_msg"
    fi
}

# Lista richiudibile: titolo, messaggio se vuota, elementi
write_details() {
    local title="$1" empty_msg="$2"
    shift 2
    if (( $# )); then
        echo "<details>"
        echo "<summary>$title ($#)</summary>"
        echo ""
        write_list "" "$@"
        echo ""
        echo "</details>"
    else
        echo "$empty_msg"
    fi
}

write_report() {
    local end_epoch=$EPOCHSECONDS key n run_status tot_errors
    local date_end=$(date "+%Y-%m-%d %H:%M:%S")
    local p1_secs=$(( ${PHASE1_END:-$end_epoch} - ${PHASE1_START:-$end_epoch} ))
    local p2_secs=$(( ${PHASE2_END:-$end_epoch} - ${PHASE2_START:-$end_epoch} ))
    local title pl shot
    if [[ "$MEDIA_LABEL" == "foto" ]]; then
        title="Foto"; pl="e"; shot="scatto"
    else
        title="Video"; pl="i"; shot="ripresa"
    fi
    tot_errors=$(( ${FLAT_ERRORS:-0} + ${ORG_ERRORS:-0} ))
    if (( INTERRUPTED )); then
        run_status="⛔ Interrotto dall'utente (report parziale)"
    elif (( tot_errors )); then
        run_status="⚠️ Completato con $tot_errors errori"
    else
        run_status="✅ Completato senza errori"
    fi

    # stato finale delle cartelle
    local bk_files bk_bytes org_files org_bytes disk_free
    local -a bk_json
    count_media "$BK_DIR" 0; bk_files=$CNT_FILES; bk_bytes=$CNT_BYTES
    count_media "$ORG_DIR" 1; org_files=$CNT_FILES; org_bytes=$CNT_BYTES
    bk_json=("$BK_DIR"/*.json(N.))
    disk_free=$(df -h "$BK_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')

    {
        echo "# Report Backup e Organizzazione $title"
        echo ""
        (( DRY_RUN )) && { echo "> **DRY RUN** — nessun file è stato copiato: i numeri indicano cosa *verrebbe* fatto."; echo ""; }
        (( INTERRUPTED )) && { echo "> **ESECUZIONE INTERROTTA** — i dati si riferiscono solo ai file elaborati prima dell'interruzione."; echo ""; }
        echo "## Riepilogo"
        echo ""
        echo "| | |"
        echo "| :--- | :--- |"
        echo "| **Esito** | $run_status |"
        echo "| **Inizio** | \`$DATE_START\` |"
        echo "| **Fine** | \`$date_end\` |"
        echo "| **Durata totale** | $(human_duration $(( end_epoch - START_EPOCH ))) |"
        echo "| **Durata fase 1 (backup flat)** | $(human_duration $p1_secs) |"
        (( DRY_RUN )) || echo "| **Durata fase 2 (organizzazione)** | $(human_duration $p2_secs) |"
        echo "| **Cartella Origine** | \`$(md_esc "$SOURCE_DIR")\` |"
        echo "| **Backup flat** | \`$(md_esc "$BK_DIR")\` |"
        echo "| **Cartella Organizzata** | \`$(md_esc "$ORG_DIR")\` |"
        echo "| **Report dettagliato (TSV, file per file)** | \`$(md_esc "${DETAIL_FILE:t}")\` |"
        echo "| **Utente / Computer** | $USER @ ${HOST} |"
        echo "| **Versione exiftool** | $(exiftool -ver 2>/dev/null) |"
        echo "| **SetFile (data di creazione)** | $( (( HAS_SETFILE )) && echo "disponibile" || echo "non disponibile: data di creazione non preservata" ) |"
        echo "| **Spazio libero sul disco del backup** | ${disk_free:-?} |"
        if (( LIMIT > 0 )); then
            echo "| **Limite** | primi $LIMIT file dell'origine ($SRC_SKIPPED_LIMIT esclusi); fase 2 solo sui file copiati in questa esecuzione |"
        else
            echo "| **Limite** | nessuno (tutti i file) |"
        fi
        echo ""
        echo "### Numeri principali"
        echo ""
        echo "| Metric | Conteggio | Dimensione |"
        echo "| :--- | ---: | ---: |"
        echo "| **$title trovat${pl} nell'origine** | $SRC_TOTAL | |"
        echo "| **$title elaborat${pl}** | $FLAT_SCANNED | $(human_size $FLAT_SCANNED_BYTES) |"
        (( SRC_SKIPPED_LIMIT )) && echo "| **Non elaborat${pl} (oltre il limite di $LIMIT)** | $SRC_SKIPPED_LIMIT | |"
        echo "| **Nuov${pl} copiat${pl} nel backup** | $FLAT_COPIED | $(human_size $FLAT_COPIED_BYTES) |"
        echo "| **Duplicati saltati** | $FLAT_DUPLICATES ($(pct1 $FLAT_DUPLICATES $FLAT_SCANNED)) | $(human_size $FLAT_DUP_BYTES) risparmiati |"
        if (( ! DRY_RUN )); then
            echo "| **Organizzat${pl} per data** | ${ORG_BY_DATE:-0} | |"
            echo "| **Senza metadati** | ${ORG_WITHOUT_META:-0} | |"
        fi
        echo "| **File non $MEDIA_LABEL ignorati nell'origine** | $SRC_IGNORED | |"
        echo "| **Errori totali** | $tot_errors | |"
        echo ""
        echo "---"
        echo ""
        echo "## Fase 1 — Backup flat"
        echo ""
        echo "| Metric | Conteggio | Dimensione |"
        echo "| :--- | ---: | ---: |"
        echo "| **Già presenti nel backup prima dell'esecuzione** | $FLAT_EXISTING | $(human_size $FLAT_EXISTING_BYTES) |"
        echo "| **Duplicati già presenti dentro il backup flat** | $FLAT_EXISTING_DUPS | |"
        echo "| **File trovati nell'origine** | $SRC_TOTAL | |"
        echo "| **Elaborati** | $FLAT_SCANNED | $(human_size $FLAT_SCANNED_BYTES) |"
        echo "| **Non elaborati per il limite** | $SRC_SKIPPED_LIMIT | |"
        echo "| **Copiat${pl} nel backup** | $FLAT_COPIED | $(human_size $FLAT_COPIED_BYTES) |"
        echo "| **Duplicati saltati (totale)** | $FLAT_DUPLICATES | $(human_size $FLAT_DUP_BYTES) |"
        echo "| &nbsp;&nbsp;↳ già presenti nel backup prima dell'esecuzione | $FLAT_DUP_VS_BACKUP | |"
        echo "| &nbsp;&nbsp;↳ ripetuti più volte dentro l'origine | $FLAT_DUP_INTERNAL | |"
        echo "| **Rinominat${pl} per conflitto di nome** | $FLAT_RENAMED | |"
        echo "| **Con JSON Google Takeout associato** | $FLAT_WITH_SIDECAR | |"
        echo "| **JSON Google Takeout copiati** | $FLAT_SIDECARS | |"
        echo "| &nbsp;&nbsp;↳ recuperati da un duplicato | $FLAT_SIDECARS_RECOVERED | |"
        echo "| **File JSON trovati nell'origine** | $SRC_JSON | |"
        echo "| **File non $MEDIA_LABEL ignorati** | $SRC_IGNORED | |"
        echo "| **Hash SHA-256 calcolati** | $HASHES_COMPUTED | |"
        echo "| **Velocità media di copia** | $(throughput $FLAT_COPIED_BYTES $p1_secs) | |"
        echo "| **Errori** | $FLAT_ERRORS | |"
        echo ""
        echo "### Per estensione"
        echo ""
        if (( ${#EXT_FOUND} )); then
            echo "| Estensione | Trovati | Copiati | Duplicati | Dimensione trovati |"
            echo "| :--- | ---: | ---: | ---: | ---: |"
            for key in ${(ko)EXT_FOUND}; do
                echo "| \`.$key\` | ${EXT_FOUND[$key]} | ${EXT_COPIED[$key]:-0} | ${EXT_DUP[$key]:-0} | $(human_size ${EXT_BYTES[$key]}) |"
            done
        else
            echo "_Nessun file $MEDIA_LABEL trovato nell'origine._"
        fi
        echo ""
        echo "### File ignorati nell'origine (non $MEDIA_LABEL, non JSON)"
        echo ""
        if (( ${#IGNORED_EXT} )); then
            echo "| Tipo | Numero file |"
            echo "| :--- | ---: |"
            for key in ${(ko)IGNORED_EXT}; do
                echo "| \`$(md_esc "$key")\` | ${IGNORED_EXT[$key]} |"
            done
            echo ""
            write_details "Elenco file ignorati" "" "${IGNORED_LIST[@]}"
        else
            echo "_Nessun file ignorato._"
        fi
        echo ""
        if (( ! DRY_RUN )); then
            echo "---"
            echo ""
            echo "## Fase 2 — Organizzazione per data"
            echo ""
            echo "| Metric | Conteggio |"
            echo "| :--- | ---: |"
            echo "| **File elaborati** | ${ORG_PROCESSED:-0} |"
            echo "| **Organizzati per data (Anno/Mese)** | ${ORG_BY_DATE:-0} |"
            echo "| **Senza metadati (\`without_metadata\`)** | ${ORG_WITHOUT_META:-0} |"
            echo "| **Già organizzati (saltati)** | ${ORG_ALREADY:-0} |"
            echo "| **Dimensione organizzata in questa esecuzione** | $(human_size ${ORG_BYTES:-0}) |"
            echo "| **Data di $shot aggiunta (da nome file / JSON)** | ${ORG_DATE_WRITTEN:-0} |"
            echo "| **GPS già presente nel file** | ${ORG_HAD_GPS:-0} |"
            echo "| **GPS aggiunto (da JSON Takeout)** | ${ORG_GPS_WRITTEN:-0} |"
            echo "| **Scrittura metadati fallita (file copiato intatto)** | ${ORG_META_FAILED:-0} |"
            echo "| **Errori** | ${ORG_ERRORS:-0} |"
            echo ""
            echo "### Da dove è stata presa la data (file organizzati in questa esecuzione)"
            echo ""
            if (( ${#DATE_SRC_COUNTS} )); then
                echo "| Origine della data | Numero file | % |"
                echo "| :--- | ---: | ---: |"
                for key in ${(k)DATE_SRC_COUNTS}; do
                    print -r -- "${DATE_SRC_COUNTS[$key]}"$'\t'"$key"
                done | sort -rn | while IFS=$'\t' read -r n key; do
                    echo "| $key | $n | $(pct1 $n $(( ORG_BY_DATE + ORG_WITHOUT_META ))) |"
                done
            else
                echo "_Nessun nuovo file organizzato._"
            fi
            echo ""
            echo "### Per anno (questa esecuzione)"
            echo ""
            if (( ${#YEAR_COUNTS} )); then
                echo "| Anno | Numero file |"
                echo "| :--- | ---: |"
                for key in ${(ko)YEAR_COUNTS}; do
                    echo "| $key | ${YEAR_COUNTS[$key]} |"
                done
            else
                echo "_Nessun file organizzato per data._"
            fi
            echo ""
            echo "### Dettaglio Cartelle (questa esecuzione)"
            echo ""
            if (( ${#FOLDER_COUNTS} )); then
                echo "| Sottocartella | Numero file |"
                echo "| :--- | ---: |"
                for key in ${(ko)FOLDER_COUNTS}; do
                    echo "| \`$key\` | ${FOLDER_COUNTS[$key]} |"
                done
            else
                echo "_Nessun nuovo file organizzato._"
            fi
            echo ""
            echo "### File senza metadati (finiti in \`without_metadata\`)"
            echo ""
            write_details "Elenco file senza data" "_Nessuno._" "${WITHOUT_META_LIST[@]}"
            echo ""
            echo "### Data di $shot aggiunta"
            echo ""
            write_details "Elenco file con data aggiunta" "_Nessuna._" "${DATE_WRITTEN_LIST[@]}"
            echo ""
            echo "### GPS aggiunto"
            echo ""
            write_details "Elenco file con GPS aggiunto" "_Nessuno._" "${GPS_WRITTEN_LIST[@]}"
            echo ""
            echo "### Scrittura metadati fallita"
            echo ""
            write_details "Elenco file" "_Nessuna._" "${META_FAILED_LIST[@]}"
            echo ""
        fi
        echo "---"
        echo ""
        echo "## Duplicati saltati"
        echo ""
        if (( FLAT_DUPLICATES )); then
            echo "$FLAT_DUPLICATES file saltati perché identici (stessa dimensione + stesso SHA-256) a un file tenuto nel backup."
            echo ""
            echo "### Raggruppati per file tenuto"
            echo ""
            echo "| File tenuto nel backup | Copie saltate | Origine del file tenuto |"
            echo "| :--- | ---: | :--- |"
            for key in ${(k)DUP_GROUPS}; do
                print -r -- "${DUP_GROUPS[$key]}"$'\t'"$key"
            done | sort -t $'\t' -k1,1rn -k2 | while IFS=$'\t' read -r n key; do
                if (( ${+PREEXISTING[$key]} )); then
                    echo "| \`$(md_esc "$key")\` | $n | _già nel backup_ |"
                else
                    echo "| \`$(md_esc "$key")\` | $n | \`$(md_esc "${KEPT_SRC[$key]#$SOURCE_DIR/}")\` |"
                fi
            done
            echo ""
            write_details "Elenco completo (file saltato -> file tenuto)" "" "${DUP_LIST[@]}"
        else
            echo "_Nessun duplicato._"
        fi
        echo ""
        if (( FLAT_EXISTING_DUPS )); then
            echo "### Duplicati già presenti dentro il backup flat"
            echo ""
            echo "File del backup flat con contenuto identico a un altro file del backup (non toccati, ma organizzati entrambi):"
            echo ""
            write_details "Elenco" "" "${EXISTING_DUP_LIST[@]}"
            echo ""
        fi
        echo "## Rinominati per conflitto di nome"
        echo ""
        write_details "Elenco (origine -> nome nel backup)" "_Nessuno._" "${RENAMED_LIST[@]}"
        echo ""
        echo "## File in errore"
        echo ""
        write_list "Nessun errore riscontrato." "${FLAT_ERRORS_LIST[@]}" "${ORG_ERRORS_LIST[@]}"
        echo ""
        echo "---"
        echo ""
        echo "## Stato finale delle cartelle"
        echo ""
        echo "| Cartella | File $MEDIA_LABEL | Dimensione |"
        echo "| :--- | ---: | ---: |"
        echo "| **Backup flat** | $bk_files (+ ${#bk_json} JSON) | $(human_size $bk_bytes) |"
        echo "| **Cartella organizzata** | $org_files | $(human_size $org_bytes) |"
        echo ""
        if (( ! DRY_RUN && ! INTERRUPTED )); then
            if (( bk_files == org_files )); then
                echo "✅ Ogni file del backup flat è presente nella cartella organizzata."
            else
                echo "⚠️ Il backup flat contiene $bk_files file e la cartella organizzata $org_files: differenza di $(( bk_files - org_files )) (errori, file aggiunti/rimossi a mano o file presenti solo in una delle due)."
            fi
            echo ""
        fi
        echo "_Il dettaglio file per file (esito, destinazione, dimensione, origine della data) è in \`${DETAIL_FILE:t}\`._"
        echo ""
    } > "$REPORT_FILE"
}

# =================================================== FASE 1: backup flat ===
typeset -A SIZE_SEEN      # dimensione -> 1
typeset -A PENDING_READ   # dimensione -> file da leggere per l'hash (non ancora calcolato)
typeset -A PENDING_NAME   # dimensione -> nome nel backup flat del file in attesa
typeset -A HASH_MAP       # sha256 -> nome nel backup flat
typeset -A USED_NAMES     # nome minuscolo -> 1 (il filesystem macOS ignora maiuscole)

# Registra un file per la deduplica. L'hash si calcola solo alla prima
# collisione di dimensione, così i file di dimensione unica non vengono letti.
# Ritorna 0 e imposta DUP_OF se è un duplicato; altrimenti imposta NEW_HASH.
check_duplicate() {
    local read_path="$1" size="$2"
    DUP_OF=""
    NEW_HASH=""
    (( ${+SIZE_SEEN[$size]} )) || return 1

    if (( ${+PENDING_READ[$size]} )); then
        local ph
        ph=$(file_hash "${PENDING_READ[$size]}")
        (( HASHES_COMPUTED++ ))
        [[ -n "$ph" ]] && HASH_MAP[$ph]="${HASH_MAP[$ph]:-${PENDING_NAME[$size]}}"
        unset "PENDING_READ[$size]" "PENDING_NAME[$size]"
    fi

    NEW_HASH=$(file_hash "$read_path")
    (( HASHES_COMPUTED++ ))
    if [[ -n "$NEW_HASH" && -n "${HASH_MAP[$NEW_HASH]}" ]]; then
        DUP_OF="${HASH_MAP[$NEW_HASH]}"
        return 0
    fi
    return 1
}

register_file() {
    local read_path="$1" size="$2" name="$3" hash="$4"
    USED_NAMES[${name:l}]=1
    if [[ -n "$hash" ]]; then
        HASH_MAP[$hash]="${HASH_MAP[$hash]:-$name}"
    elif (( ! ${+SIZE_SEEN[$size]} )); then
        PENDING_READ[$size]="$read_path"
        PENDING_NAME[$size]="$name"
    fi
    SIZE_SEEN[$size]=1
}

unique_flat_name() {
    local name="$1" stem ext candidate i=1
    if [[ "$name" == *.* ]]; then
        stem="${name%.*}"
        ext=".${name##*.}"
    else
        stem="$name"
        ext=""
    fi
    candidate="$name"
    while (( ${+USED_NAMES[${candidate:l}]} )) || [[ -e "${BK_DIR}/${candidate}" ]]; do
        candidate="${stem}_${i}${ext}"
        (( i++ ))
    done
    print -r -- "$candidate"
}

FLAT_EXISTING=0
FLAT_SCANNED=0
FLAT_COPIED=0
FLAT_DUPLICATES=0
FLAT_RENAMED=0
FLAT_SIDECARS=0
FLAT_ERRORS=0
DUP_LIST=()
FLAT_ERRORS_LIST=()
# statistiche aggiuntive per il report
HASHES_COMPUTED=0
FLAT_EXISTING_BYTES=0
FLAT_EXISTING_DUPS=0
FLAT_SCANNED_BYTES=0
FLAT_COPIED_BYTES=0
FLAT_DUP_BYTES=0
FLAT_DUP_VS_BACKUP=0      # contenuto già presente nel backup prima dell'esecuzione
FLAT_DUP_INTERNAL=0       # contenuto ripetuto più volte dentro l'origine
FLAT_WITH_SIDECAR=0
FLAT_SIDECARS_RECOVERED=0
SRC_JSON=0
SRC_IGNORED=0
EXISTING_DUP_LIST=()
COPIED_THIS_RUN=()        # file copiati nel backup flat in questa esecuzione
SRC_TOTAL=0
SRC_SKIPPED_LIMIT=0
RENAMED_LIST=()
IGNORED_LIST=()
typeset -A PREEXISTING    # nome nel backup flat -> 1 (presente prima dell'esecuzione)
typeset -A KEPT_SRC       # nome nel backup flat -> file di origine copiato in questa esecuzione
typeset -A DUP_GROUPS     # nome nel backup flat -> numero di duplicati saltati
typeset -A EXT_FOUND EXT_COPIED EXT_DUP EXT_BYTES IGNORED_EXT

PHASE1_START=$EPOCHSECONDS
echo "Indicizzazione backup flat esistente..."
for FILE in "$BK_DIR"/*(N.); do
    is_media_file "${FILE:t}" || continue
    SIZE=$(file_size "$FILE")
    if check_duplicate "$FILE" "$SIZE"; then
        (( FLAT_EXISTING_DUPS++ ))
        EXISTING_DUP_LIST+=("${FILE:t} = $DUP_OF")
        continue
    fi
    register_file "$FILE" "$SIZE" "${FILE:t}" "$NEW_HASH"
    PREEXISTING[${FILE:t}]=1
    (( FLAT_EXISTING++ ))
    (( FLAT_EXISTING_BYTES += SIZE ))
done
# anche i sidecar JSON già presenti occupano un nome
for FILE in "$BK_DIR"/*.json(N.); do
    USED_NAMES[${FILE:t:l}]=1
done

echo "Scansione origine..."
SOURCE_FILES=()
while IFS= read -r -d '' FILE; do
    if is_media_file "${FILE:t}"; then
        SOURCE_FILES+=("$FILE")
    elif [[ "${FILE:t:l}" == *.json ]]; then
        (( SRC_JSON++ ))
    else
        # file non media: non copiati, elencati nel report
        if [[ "${FILE:t}" == ._* ]]; then
            IEXT="._* (AppleDouble macOS)"
        elif [[ "${FILE:t}" == .* ]]; then
            IEXT="${FILE:t} (file nascosto)"
        else
            IEXT=$(ext_of "$FILE"); [[ "$IEXT" != "(nessuna)" ]] && IEXT=".$IEXT"
        fi
        IGNORED_EXT[$IEXT]=$(( ${IGNORED_EXT[$IEXT]:-0} + 1 ))
        (( SRC_IGNORED++ ))
        IGNORED_LIST+=("$FILE")
        detail_row "scansione" "ignorato" "$FILE" "" "$(file_size "$FILE")" "estensione non $MEDIA_LABEL: $IEXT"
    fi
done < <(find "$SOURCE_DIR" \( -path "$BK_DIR" -o -path "$ORG_DIR" \) -prune -o -type f -print0)
# ordine stabile: a parità di contenuto si tiene il primo in ordine alfabetico
SOURCE_FILES=("${(@o)SOURCE_FILES}")
SRC_TOTAL=${#SOURCE_FILES}
SRC_SKIPPED_LIMIT=0
if (( LIMIT > 0 && SRC_TOTAL > LIMIT )); then
    SRC_SKIPPED_LIMIT=$(( SRC_TOTAL - LIMIT ))
    SOURCE_FILES=("${(@)SOURCE_FILES[1,$LIMIT]}")
fi

progress_setup
(( DRY_RUN )) && log_msg skip "*** DRY RUN: nessun file verrà copiato ***"
log_msg "Origine:       $SOURCE_DIR"
log_msg "Backup flat:   $BK_DIR ($FLAT_EXISTING $MEDIA_LABEL già presenti)"
log_msg "Organizzate:   $ORG_DIR"
log_msg "File $MEDIA_LABEL trovati nell'origine: $SRC_TOTAL"
(( LIMIT > 0 )) && log_msg skip "Limite attivo: elaboro i primi ${#SOURCE_FILES} file ($SRC_SKIPPED_LIMIT esclusi dal limite)"
(( HAS_SETFILE )) || log_msg skip "Avviso: 'SetFile' non trovato (xcode-select --install): la data di creazione del file non verrà preservata."
log_msg "------------------------------------------------"

if (( ! DRY_RUN )) && [[ ! -f "$INDEX_FILE" ]]; then
    printf 'nome_flat\torigine\n' > "$INDEX_FILE"
fi

start_phase "Fase 1/2 backup flat:" ${#SOURCE_FILES}
for FILE in "${SOURCE_FILES[@]}"; do
    (( CUR++ ))
    (( FLAT_SCANNED++ ))
    SIZE=$(file_size "$FILE")
    SIDECAR=$(find_sidecar_json "$FILE") || SIDECAR=""
    EXT=$(ext_of "$FILE")
    EXT_FOUND[$EXT]=$(( ${EXT_FOUND[$EXT]:-0} + 1 ))
    EXT_BYTES[$EXT]=$(( ${EXT_BYTES[$EXT]:-0} + SIZE ))
    (( FLAT_SCANNED_BYTES += SIZE ))
    [[ -n "$SIDECAR" ]] && (( FLAT_WITH_SIDECAR++ ))

    if check_duplicate "$FILE" "$SIZE"; then
        (( FLAT_DUPLICATES++ ))
        (( FLAT_DUP_BYTES += SIZE ))
        EXT_DUP[$EXT]=$(( ${EXT_DUP[$EXT]:-0} + 1 ))
        DUP_GROUPS[$DUP_OF]=$(( ${DUP_GROUPS[$DUP_OF]:-0} + 1 ))
        if (( ${+PREEXISTING[$DUP_OF]} )); then
            (( FLAT_DUP_VS_BACKUP++ ))
            DUP_KIND="già nel backup prima dell'esecuzione"
        else
            (( FLAT_DUP_INTERNAL++ ))
            DUP_KIND="duplicato dentro l'origine di ${KEPT_SRC[$DUP_OF]:-?}"
        fi
        DUP_LIST+=("$FILE -> $DUP_OF ($DUP_KIND)")
        DUP_NOTE="$DUP_KIND"
        # se la copia tenuta non ha il JSON Takeout e questa sì, lo recupera
        if (( ! DRY_RUN )) && [[ -n "$SIDECAR" && ! -e "${BK_DIR}/${DUP_OF}.json" ]]; then
            if copy_preserving "$SIDECAR" "${BK_DIR}/${DUP_OF}.json"; then
                (( FLAT_SIDECARS++ ))
                (( FLAT_SIDECARS_RECOVERED++ ))
                DUP_NOTE+="; JSON Takeout recuperato"
            fi
            USED_NAMES[${DUP_OF:l}.json]=1
        fi
        detail_row "1-backup" "duplicato" "$FILE" "$DUP_OF" "$SIZE" "$DUP_NOTE"
        log_msg skip "Duplicato: ${FILE#$SOURCE_DIR/} = $DUP_OF"
        continue
    fi

    NAME=$(unique_flat_name "${FILE:t}")
    COPY_NOTE=""
    if [[ "$NAME" != "${FILE:t}" ]]; then
        (( FLAT_RENAMED++ ))
        RENAMED_LIST+=("${FILE#$SOURCE_DIR/} -> $NAME")
        COPY_NOTE="rinominato (conflitto di nome)"
    fi
    [[ -n "$SIDECAR" ]] && COPY_NOTE+="${COPY_NOTE:+; }con JSON Takeout"

    if (( DRY_RUN )); then
        register_file "$FILE" "$SIZE" "$NAME" "$NEW_HASH"
        KEPT_SRC[$NAME]="$FILE"
        (( FLAT_COPIED++ ))
        (( FLAT_COPIED_BYTES += SIZE ))
        EXT_COPIED[$EXT]=$(( ${EXT_COPIED[$EXT]:-0} + 1 ))
        detail_row "1-backup" "copierebbe (dry run)" "$FILE" "$NAME" "$SIZE" "$COPY_NOTE"
        log_msg ok "[dry] Copierei: ${FILE#$SOURCE_DIR/} -> $NAME"
        continue
    fi

    if copy_preserving "$FILE" "${BK_DIR}/${NAME}"; then
        register_file "${BK_DIR}/${NAME}" "$SIZE" "$NAME" "$NEW_HASH"
        KEPT_SRC[$NAME]="$FILE"
        printf '%s\t%s\n' "$NAME" "$FILE" >> "$INDEX_FILE"
        if [[ -n "$SIDECAR" ]]; then
            copy_preserving "$SIDECAR" "${BK_DIR}/${NAME}.json" && (( FLAT_SIDECARS++ ))
            USED_NAMES[${NAME:l}.json]=1
        fi
        (( FLAT_COPIED++ ))
        (( FLAT_COPIED_BYTES += SIZE ))
        COPIED_THIS_RUN+=("${BK_DIR}/${NAME}")
        EXT_COPIED[$EXT]=$(( ${EXT_COPIED[$EXT]:-0} + 1 ))
        detail_row "1-backup" "copiato" "$FILE" "$NAME" "$SIZE" "$COPY_NOTE"
        log_msg ok "Copiato: ${FILE#$SOURCE_DIR/} -> $NAME"
    else
        (( FLAT_ERRORS++ ))
        FLAT_ERRORS_LIST+=("$FILE")
        detail_row "1-backup" "errore" "$FILE" "$NAME" "$SIZE" "copia fallita"
        log_msg err "ERRORE nella copia di: $FILE"
    fi
done
PHASE1_END=$EPOCHSECONDS

# ============================================ FASE 2: organizza per data ===
# (logica di organizza_video.sh applicata alla cartella flat)
ORG_PROCESSED=0
ORG_BY_DATE=0
ORG_WITHOUT_META=0
ORG_ALREADY=0
ORG_DATE_WRITTEN=0
ORG_GPS_WRITTEN=0
ORG_ERRORS=0
ORG_ERRORS_LIST=()
typeset -A FOLDER_COUNTS
ORG_BYTES=0
ORG_HAD_GPS=0
ORG_META_FAILED=0
WITHOUT_META_LIST=()
DATE_WRITTEN_LIST=()
GPS_WRITTEN_LIST=()
META_FAILED_LIST=()
typeset -A DATE_SRC_COUNTS   # origine della data (tag EXIF, nome file, JSON) -> numero file
typeset -A YEAR_COUNTS       # anno -> numero file organizzati in questa esecuzione

# Imposta YEAR, MONTH, META_DATE (data da scrivere se mancante), DATE_FROM_TAGS,
# HAS_GPS, JSON_LAT/LON/ALT
resolve_date() {
    local file="$1" line tag_date sidecar info ts match_name
    local -a lines
    local i=0
    YEAR=""; MONTH=""; META_DATE=""; DATE_FROM_TAGS=0; HAS_GPS=0
    JSON_LAT=""; JSON_LON=""; JSON_ALT=""; DATE_SOURCE="nessuna"

    # una sola chiamata exiftool: una riga per tag data + una riga GPS
    lines=("${(@f)$(exiftool "${EXIF_OPTS[@]}" -f -s3 -d "%Y%m" "${DATE_TAGS[@]/#/-}" "-GPSLatitude#" "$file" 2>/dev/null)}")
    [[ "${lines[-1]}" != "-" && -n "${lines[-1]}" ]] && HAS_GPS=1
    for line in "${lines[@]:0:${#DATE_TAGS}}"; do
        (( i++ ))
        if is_valid_date_parts "${line:0:4}" "${line:4:2}" && [[ ${#line} == 6 ]]; then
            YEAR="${line:0:4}"; MONTH="${line:4:2}"; DATE_FROM_TAGS=1
            DATE_SOURCE="metadato ${DATE_TAGS[$i]}"
            break
        fi
    done

    sidecar=$(find_sidecar_json "$file") || sidecar=""
    if [[ -n "$sidecar" ]]; then
        info=$(read_takeout_json "$sidecar")
        IFS='|' read -r ts JSON_LAT JSON_LON JSON_ALT <<< "$info"
    fi
    (( DATE_FROM_TAGS )) && return 0

    # Fallback: data nel nome file
    match_name=$(print -r -- "${file:t}" | grep -oE '(19[7-9][0-9]|20[0-3][0-9])[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12][0-9]|3[01])' | head -n1)
    if [[ -n "$match_name" ]]; then
        match_name="${match_name//[-_]/}"
        if is_valid_date_parts "${match_name:0:4}" "${match_name:4:2}"; then
            YEAR="${match_name:0:4}"; MONTH="${match_name:4:2}"
            META_DATE="${YEAR}:${MONTH}:${match_name:6:2} 12:00:00"
            DATE_SOURCE="nome file"
            return 0
        fi
    fi

    # Ultima spiaggia: JSON Google Takeout (photoTakenTime / creationTime)
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        YEAR=$(date -r "$ts" +%Y 2>/dev/null)
        MONTH=$(date -r "$ts" +%m 2>/dev/null)
        if is_valid_date_parts "$YEAR" "$MONTH"; then
            META_DATE=$(date -r "$ts" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
            DATE_SOURCE="JSON Google Takeout"
            return 0
        fi
    fi

    YEAR=""; MONTH=""; META_DATE=""
    return 1
}

# Aggiunge i metadati mancanti e allinea le date del filesystem.
# -overwrite_original_in_place mantiene attributi estesi/ACL, -P le date file.
apply_metadata() {
    local dst="$1" has_date="$2"
    local -a args
    META_NOTE=""

    if [[ -n "$META_DATE" ]]; then
        args+=("${(@f)$(missing_date_args "$META_DATE")}")
    fi
    if (( ! HAS_GPS )) && [[ -n "$JSON_LAT" && -n "$JSON_LON" ]]; then
        args+=("${(@f)$(missing_gps_args "$JSON_LAT" "$JSON_LON" "$JSON_ALT")}")
    fi
    if (( ${#args} )); then
        if exiftool "${EXIF_OPTS[@]}" -q -q -overwrite_original_in_place -P "${args[@]}" "$dst" &> /dev/null; then
            if [[ -n "$META_DATE" ]]; then
                (( ORG_DATE_WRITTEN++ ))
                DATE_WRITTEN_LIST+=("${dst#$ORG_DIR/} = $META_DATE ($DATE_SOURCE)")
                META_NOTE+="; data scritta $META_DATE"
            fi
            if (( ! HAS_GPS )) && [[ -n "$JSON_LAT" ]]; then
                (( ORG_GPS_WRITTEN++ ))
                GPS_WRITTEN_LIST+=("${dst#$ORG_DIR/} = $JSON_LAT, $JSON_LON${JSON_ALT:+, $JSON_ALT}")
                META_NOTE+="; GPS scritto $JSON_LAT,$JSON_LON"
            fi
        else
            (( ORG_META_FAILED++ ))
            META_FAILED_LIST+=("${dst#$ORG_DIR/}")
            META_NOTE+="; scrittura metadati fallita"
            log_msg err "  Avviso: impossibile aggiungere metadati a ${dst:t} (file copiato intatto)"
        fi
    fi

    if (( has_date )); then
        exiftool "${EXIF_OPTS[@]}" -q -q "${(@f)$(file_date_args)}" "$dst" &> /dev/null
    fi
}

PHASE2_START=$EPOCHSECONDS
if (( ! DRY_RUN )); then
    FLAT_FILES=()
    if (( LIMIT > 0 )); then
        # con il limite si organizzano solo i file copiati in questa esecuzione
        FLAT_FILES=("${COPIED_THIS_RUN[@]}")
    else
        for FILE in "$BK_DIR"/*(N.); do
            is_media_file "${FILE:t}" && FLAT_FILES+=("$FILE")
        done
    fi

    log_msg "------------------------------------------------"
    start_phase "Fase 2/2 organizzazione:" ${#FLAT_FILES}
    for FILE in "${FLAT_FILES[@]}"; do
        (( CUR++ ))
        (( ORG_PROCESSED++ ))
        FILENAME="${FILE:t}"

        if resolve_date "$FILE"; then
            REL_FOLDER="${YEAR}/${MONTH}"
            HAS_DATE=1
        else
            REL_FOLDER="without_metadata"
            HAS_DATE=0
        fi

        TARGET_FOLDER="${ORG_DIR}/${REL_FOLDER}"
        TARGET_FILE="${TARGET_FOLDER}/${FILENAME}"

        # i nomi nel backup flat sono univoci: se esiste è già stato organizzato
        if [[ -e "$TARGET_FILE" ]]; then
            (( ORG_ALREADY++ ))
            detail_row "2-organizzazione" "già organizzato" "$FILE" "$TARGET_FILE" "$(file_size "$FILE")" "data da: $DATE_SOURCE"
            log_msg skip "Già organizzato: $FILENAME (${REL_FOLDER})"
            continue
        fi

        mkdir -p "$TARGET_FOLDER"
        if copy_preserving "$FILE" "$TARGET_FILE"; then
            apply_metadata "$TARGET_FILE" "$HAS_DATE"
            SIZE=$(file_size "$FILE")
            (( ORG_BYTES += SIZE ))
            (( HAS_GPS )) && (( ORG_HAD_GPS++ ))
            DATE_SRC_COUNTS[$DATE_SOURCE]=$(( ${DATE_SRC_COUNTS[$DATE_SOURCE]:-0} + 1 ))
            if (( HAS_DATE )); then
                (( ORG_BY_DATE++ ))
                YEAR_COUNTS[$YEAR]=$(( ${YEAR_COUNTS[$YEAR]:-0} + 1 ))
                detail_row "2-organizzazione" "organizzato" "$FILE" "$TARGET_FILE" "$SIZE" "data da: $DATE_SOURCE$META_NOTE"
            else
                (( ORG_WITHOUT_META++ ))
                WITHOUT_META_LIST+=("$FILENAME")
                detail_row "2-organizzazione" "senza metadati" "$FILE" "$TARGET_FILE" "$SIZE" "nessuna data trovata$META_NOTE"
            fi
            FOLDER_COUNTS[$REL_FOLDER]=$(( ${FOLDER_COUNTS[$REL_FOLDER]:-0} + 1 ))
            log_msg ok "Organizzato: $FILENAME -> ${REL_FOLDER}"
        else
            (( ORG_ERRORS++ ))
            ORG_ERRORS_LIST+=("$FILE")
            detail_row "2-organizzazione" "errore" "$FILE" "$TARGET_FILE" "$(file_size "$FILE")" "copia fallita"
            log_msg err "ERRORE nella copia di: $FILE"
        fi
    done
fi
PHASE2_END=$EPOCHSECONDS

progress_teardown
PROGRESS_UI=0
trap - EXIT INT TERM

# ----------------------------------------------------------- report finale ---
write_report

echo "------------------------------------------------"
echo "Completato!"
echo "Elaborati:     $FLAT_SCANNED di $SRC_TOTAL $MEDIA_LABEL nell'origine ($(human_size $FLAT_SCANNED_BYTES))"
(( SRC_SKIPPED_LIMIT )) && echo "Limite:        primi $LIMIT, $SRC_SKIPPED_LIMIT non elaborati"
echo "Backup flat:   $BK_DIR  (+$FLAT_COPIED, $FLAT_DUPLICATES duplicati saltati, $FLAT_ERRORS errori)"
(( DRY_RUN )) || echo "Organizzate:   $ORG_DIR  ($ORG_BY_DATE per data, $ORG_WITHOUT_META senza metadati, $ORG_ALREADY già presenti, $ORG_ERRORS errori)"
(( SRC_IGNORED )) && echo "Ignorati:      $SRC_IGNORED file non $MEDIA_LABEL nell'origine"
echo "Durata:        $(human_duration $(( EPOCHSECONDS - START_EPOCH )))"
echo "Report:        $REPORT_FILE"
echo "Dettaglio:     $DETAIL_FILE"
echo "------------------------------------------------"
