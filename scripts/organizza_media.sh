#!/bin/zsh

# Controlla se exiftool è installato
if ! command -v exiftool &> /dev/null; then
    echo "Errore: 'exiftool' non è installato. Installalo con 'brew install exiftool'."
    exit 1
fi

# Argomenti: [origine] [destinazione]
if [ -z "$1" ]; then
    echo -n "Inserisci il percorso della cartella di origine: "
    read SOURCE_DIR
else
    SOURCE_DIR="$1"
fi

SOURCE_DIR="${SOURCE_DIR%/}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Errore: La cartella '$SOURCE_DIR' non esiste."
    exit 1
fi

DEFAULT_DEST="$(dirname "$SOURCE_DIR")/$(basename "$SOURCE_DIR")_Organizzate"
if [ -n "$2" ]; then
    DEST_DIR="$2"
elif [ -z "$1" ]; then
    echo -n "Inserisci il percorso di destinazione [$DEFAULT_DEST]: "
    read DEST_INPUT
    if [ -n "$DEST_INPUT" ]; then
        DEST_DIR="$DEST_INPUT"
    else
        DEST_DIR="$DEFAULT_DEST"
    fi
else
    DEST_DIR="$DEFAULT_DEST"
fi

DEST_DIR="${DEST_DIR%/}"
FOTO_DIR="${DEST_DIR}/foto"
VIDEO_DIR="${DEST_DIR}/video"
OTHER_DIR="${DEST_DIR}/others"
REPORT_FILE="${DEST_DIR}/report_organizzazione.md"

mkdir -p "$FOTO_DIR" "$VIDEO_DIR"

SCRIPT_DIR="${0:A:h}"
TROVA_SCRIPT="${SCRIPT_DIR}/trova_altri_file.sh"

TOTAL_PROCESSED=0
TOTAL_FOTO=0
TOTAL_VIDEO=0
TOTAL_BY_DATE=0
TOTAL_WITHOUT_META=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
TOTAL_TO_PROCESS=0
PROGRESS_UI=0
[[ -t 1 && -t 2 ]] && PROGRESS_UI=1

typeset -A FOLDER_COUNTS
ERRORS_LIST=()
SKIPPED_LIST=()

pct_of() {
    local cur=$1 tot=$2
    (( tot > 0 )) && echo $(( cur * 100 / tot )) || echo 0
}

progress_teardown() {
    if (( PROGRESS_UI )); then
        printf '\e[r\e[?25h' >/dev/tty
    fi
}
trap progress_teardown EXIT INT TERM

progress_draw_header() {
    (( PROGRESS_UI )) || return
    local cur=$1
    local pct bar_w filled empty bar
    pct=$(pct_of "$cur" "$TOTAL_TO_PROCESS")
    bar_w=28
    filled=$(( pct * bar_w / 100 ))
    empty=$(( bar_w - filled ))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf '\e7\e[1;1H\e[2K' >/dev/tty
    printf 'Avanzamento: %3d%%  [%s]  %d/%d' "$pct" "$bar" "$cur" "$TOTAL_TO_PROCESS" >/dev/tty
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
    progress_draw_header 0
    printf '\e[3;1H' >/dev/tty
}

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

log_msg() {
    local color="$C_RESET"
    case "$1" in
        ok) color="$C_GREEN"; shift ;;
        skip) color="$C_ORANGE"; shift ;;
        err) color="$C_RED"; shift ;;
    esac
    if (( PROGRESS_UI )); then
        printf '%s%s%s\n' "$color" "$*" "$C_RESET" >/dev/tty
        progress_draw_header "$TOTAL_PROCESSED"
    else
        printf '%s[%3d%%] %s%s\n' "$color" "$(pct_of "$TOTAL_PROCESSED" "$TOTAL_TO_PROCESS")" "$*" "$C_RESET"
    fi
}

PHOTO_EXTS=(jpg jpeg png heic gif webp cr2 nef arw)
VIDEO_EXTS=(mp4 mov avi m4v mkv 3gp mts m2ts wmv)

is_valid_date_parts() {
    [[ "$1" =~ ^(19[7-9][0-9]|20[0-3][0-9])$ ]] && [[ "$2" =~ ^(0[1-9]|1[0-2])$ ]]
}

# Sidecar Google Takeout (non elaborare come file a sé)
is_sidecar_json() {
    local base="$1"
    [[ "$base" == *.supplemental-metadata.json ]] && return 0
    [[ "$base" == *.json ]] || return 1
    local dir="$2"
    local media="${base%.json}"
    # es. foto.jpg.json → foto.jpg esiste nella stessa cartella
    [[ -f "${dir}/${media}" ]]
}

find_sidecar_json() {
    local file="$1"
    if [[ -f "${file}.supplemental-metadata.json" ]]; then
        echo "${file}.supplemental-metadata.json"
        return 0
    fi
    if [[ -f "${file}.json" ]]; then
        echo "${file}.json"
        return 0
    fi
    return 1
}

# Legge photoTakenTime (poi creationTime) dal JSON Takeout → unix timestamp
extract_takeout_timestamp() {
    local json="$1"
    python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
for key in ("photoTakenTime", "creationTime"):
    t = (d.get(key) or {}).get("timestamp")
    if t not in (None, "", 0, "0"):
        print(str(t).strip())
        break
' "$json" 2>/dev/null
}

apply_date_from_timestamp() {
    local ts="$1"
    [[ -n "$ts" && "$ts" =~ ^[0-9]+$ ]] || return 1
    YEAR=$(date -r "$ts" +%Y 2>/dev/null)
    MONTH=$(date -r "$ts" +%m 2>/dev/null)
    local day
    day=$(date -r "$ts" +%d 2>/dev/null)
    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        return 1
    fi
    CLEAN_DATE="${YEAR}${MONTH}${day}"
    META_DATETIME=$(date -r "$ts" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
    return 0
}

extract_year_month() {
    local file="$1"
    shift
    local tag raw_y raw_m
    YEAR=""
    MONTH=""
    for tag in "$@"; do
        raw_y=$(exiftool -s3 -d "%Y" -"$tag" "$file" 2>/dev/null)
        raw_m=$(exiftool -s3 -d "%m" -"$tag" "$file" 2>/dev/null)
        if is_valid_date_parts "$raw_y" "$raw_m"; then
            YEAR="$raw_y"
            MONTH="$raw_m"
            return 0
        fi
    done
    return 1
}

media_kind() {
    local ext="$1"
    local e
    for e in "${PHOTO_EXTS[@]}"; do
        [[ "$ext" == "$e" ]] && { echo "foto"; return; }
    done
    for e in "${VIDEO_EXTS[@]}"; do
        [[ "$ext" == "$e" ]] && { echo "video"; return; }
    done
    echo "other"
}

apply_foto_metadata() {
    local src="$1"
    local dst="$2"
    local year="$3"
    local month="$4"
    local clean_date="$5"
    local meta_datetime="$6"

    exiftool -overwrite_original -TagsFromFile "$src" "-all:all" "$dst" &> /dev/null

    if ! is_valid_date_parts "$year" "$month"; then
        return
    fi

    local existing_dto existing_create day meta_date
    existing_dto=$(exiftool -s3 -d "%Y" -DateTimeOriginal "$dst" 2>/dev/null)
    existing_create=$(exiftool -s3 -d "%Y" -CreateDate "$dst" 2>/dev/null)
    if ! is_valid_date_parts "$existing_dto" "01" && ! is_valid_date_parts "$existing_create" "01"; then
        if [[ -n "$meta_datetime" ]]; then
            meta_date="$meta_datetime"
        else
            day="01"
            if [ -n "$clean_date" ] && [ ${#clean_date} -ge 8 ]; then
                day=${clean_date:6:2}
                [[ "$day" =~ ^(0[1-9]|[12][0-9]|3[01])$ ]] || day="01"
            fi
            meta_date="${year}:${month}:${day} 12:00:00"
        fi
        exiftool -overwrite_original \
            -DateTimeOriginal="$meta_date" \
            -CreateDate="$meta_date" \
            -ModifyDate="$meta_date" \
            "$dst" &> /dev/null
    fi

    exiftool -overwrite_original \
        "-FileModifyDate<CreateDate" \
        "-FileCreateDate<CreateDate" \
        "-FileModifyDate<DateTimeOriginal" \
        "-FileCreateDate<DateTimeOriginal" \
        "-ModifyDate<DateTimeOriginal" \
        "-ModifyDate<CreateDate" \
        "$dst" &> /dev/null
}

apply_video_metadata() {
    local src="$1"
    local dst="$2"
    local year="$3"
    local month="$4"
    local clean_date="$5"
    local meta_datetime="$6"

    exiftool -overwrite_original -TagsFromFile "$src" "-all:all" "$dst" &> /dev/null

    if ! is_valid_date_parts "$year" "$month"; then
        return
    fi

    local existing_create day meta_date
    existing_create=$(exiftool -s3 -d "%Y" -CreateDate "$dst" 2>/dev/null)
    if ! is_valid_date_parts "$existing_create" "01"; then
        if [[ -n "$meta_datetime" ]]; then
            meta_date="$meta_datetime"
        else
            day="01"
            if [ -n "$clean_date" ] && [ ${#clean_date} -ge 8 ]; then
                day=${clean_date:6:2}
                [[ "$day" =~ ^(0[1-9]|[12][0-9]|3[01])$ ]] || day="01"
            fi
            meta_date="${year}:${month}:${day} 12:00:00"
        fi
        exiftool -overwrite_original \
            -CreateDate="$meta_date" \
            -ModifyDate="$meta_date" \
            -TrackCreateDate="$meta_date" \
            -TrackModifyDate="$meta_date" \
            -MediaCreateDate="$meta_date" \
            -MediaModifyDate="$meta_date" \
            "$dst" &> /dev/null
    fi

    exiftool -overwrite_original \
        "-FileModifyDate<CreationDate" \
        "-FileCreateDate<CreationDate" \
        "-FileModifyDate<ContentCreateDate" \
        "-FileCreateDate<ContentCreateDate" \
        "-FileModifyDate<TrackCreateDate" \
        "-FileCreateDate<TrackCreateDate" \
        "-FileModifyDate<MediaCreateDate" \
        "-FileCreateDate<MediaCreateDate" \
        "-FileModifyDate<CreateDate" \
        "-FileCreateDate<CreateDate" \
        "-FileModifyDate<DateTimeOriginal" \
        "-FileCreateDate<DateTimeOriginal" \
        "-ModifyDate<DateTimeOriginal" \
        "-ModifyDate<CreateDate" \
        "$dst" &> /dev/null
}

resolve_date() {
    local file="$1"
    local kind="$2"
    YEAR=""
    MONTH=""
    CLEAN_DATE=""
    META_DATETIME=""

    if [[ "$kind" == "foto" ]]; then
        extract_year_month "$file" \
            DateTimeOriginal CreateDate MediaCreateDate TrackCreateDate ContentCreateDate
    else
        extract_year_month "$file" \
            MediaCreateDate CreateDate CreationDate DateTimeOriginal TrackCreateDate ContentCreateDate
    fi

    # Fallback: data nel nome file
    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        local match
        match=$(echo "$(basename "$file")" | grep -oE '(19[7-9][0-9]|20[0-3][0-9])[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12][0-9]|3[01])' | head -n1)
        if [ -n "$match" ]; then
            CLEAN_DATE=$(echo "$match" | tr -d '_-')
            YEAR=${CLEAN_DATE:0:4}
            MONTH=${CLEAN_DATE:4:2}
        fi
    fi

    # Ultima spiaggia: JSON Google Takeout (photoTakenTime / creationTime)
    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        local sidecar ts
        sidecar=$(find_sidecar_json "$file") || sidecar=""
        if [[ -n "$sidecar" ]]; then
            ts=$(extract_takeout_timestamp "$sidecar")
            apply_date_from_timestamp "$ts" || true
        fi
    fi

    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        CLEAN_DATE=""
        META_DATETIME=""
        return 1
    fi
    return 0
}

# Conteggio file da elaborare (stessi filtri del loop)
echo "Conteggio file in corso..."
while IFS= read -r -d '' FILE; do
    case "$FILE" in
        "$DEST_DIR"/*) continue ;;
    esac
    FILENAME="$(basename "$FILE")"
    FILE_DIR="$(dirname "$FILE")"
    [[ "$FILENAME" == .DS_Store || "$FILENAME" == Thumbs.db || "$FILENAME" == ._* ]] && continue
    is_sidecar_json "$FILENAME" "$FILE_DIR" && continue
    [[ "$(media_kind "${FILENAME:e:l}")" == "other" ]] && continue
    ((TOTAL_TO_PROCESS++))
done < <(find "$SOURCE_DIR" -type f -print0)

progress_setup
log_msg "Origine:      $SOURCE_DIR"
log_msg "Destinazione: $DEST_DIR"
log_msg "  foto/          $FOTO_DIR"
log_msg "  video/         $VIDEO_DIR"
log_msg "  others/        $OTHER_DIR"
log_msg "File da elaborare: $TOTAL_TO_PROCESS"
log_msg "------------------------------------------------"

# process substitution evita la subshell della pipe (contatori/report corretti)
while IFS= read -r -d '' FILE; do
    # non rielaborare la cartella di destinazione se rientra sotto SOURCE
    case "$FILE" in
        "$DEST_DIR"/*) continue ;;
    esac

    FILENAME="$(basename "$FILE")"
    FILE_DIR="$(dirname "$FILE")"
    # ignora file di sistema e sidecar JSON Google Takeout
    [[ "$FILENAME" == .DS_Store || "$FILENAME" == Thumbs.db || "$FILENAME" == ._* ]] && continue
    if is_sidecar_json "$FILENAME" "$FILE_DIR"; then
        continue
    fi

    EXT_LOWER="${FILENAME:e:l}"
    KIND="$(media_kind "$EXT_LOWER")"
    [[ "$KIND" == "other" ]] && continue

    ((TOTAL_PROCESSED++))

    if resolve_date "$FILE" "$KIND"; then
        REL_FOLDER="${YEAR}/${MONTH}"
    else
        REL_FOLDER="not_elaborate"
    fi

    if [[ "$KIND" == "foto" ]]; then
        BASE_MEDIA_DIR="$FOTO_DIR"
    else
        BASE_MEDIA_DIR="$VIDEO_DIR"
    fi

    TARGET_FOLDER="${BASE_MEDIA_DIR}/${REL_FOLDER}"
    TARGET_FILE="${TARGET_FOLDER}/${FILENAME}"
    REPORT_REL="${KIND}/${REL_FOLDER}"

    if [ -e "$TARGET_FILE" ]; then
        log_msg skip "Skip: $FILENAME già presente in ${REPORT_REL}"
        ((TOTAL_SKIPPED++))
        SKIPPED_LIST+=("$FILE -> ${REPORT_REL}/${FILENAME}")
        continue
    fi

    mkdir -p "$TARGET_FOLDER"

    if cp -p "$FILE" "$TARGET_FILE" 2>/dev/null; then
        if [[ "$KIND" == "foto" ]]; then
            apply_foto_metadata "$FILE" "$TARGET_FILE" "$YEAR" "$MONTH" "$CLEAN_DATE" "$META_DATETIME"
            ((TOTAL_FOTO++))
        else
            apply_video_metadata "$FILE" "$TARGET_FILE" "$YEAR" "$MONTH" "$CLEAN_DATE" "$META_DATETIME"
            ((TOTAL_VIDEO++))
        fi
        if [[ "$REL_FOLDER" == "not_elaborate" ]]; then
            ((TOTAL_WITHOUT_META++))
        else
            ((TOTAL_BY_DATE++))
        fi
        log_msg ok "Copiata: $FILENAME -> ${REPORT_REL}"
        FOLDER_COUNTS[$REPORT_REL]=$(( ${FOLDER_COUNTS[$REPORT_REL]:-0} + 1 ))
    else
        log_msg err "ERRORE nella copia di: $FILE"
        ((TOTAL_ERRORS++))
        ERRORS_LIST+=("$FILE")
    fi

done < <(find "$SOURCE_DIR" -type f -print0)

progress_teardown
PROGRESS_UI=0
trap - EXIT INT TERM

echo "------------------------------------------------"
echo "Spostamento altri file..."
echo "------------------------------------------------"
if [ -f "$TROVA_SCRIPT" ]; then
    zsh "$TROVA_SCRIPT" "$SOURCE_DIR" "$DEST_DIR"
else
    echo "Avviso: '$TROVA_SCRIPT' non trovato, altri file non spostati."
fi

DATE_NOW=$(date "+%Y-%m-%d %H:%M:%S")

{
    echo "# Report Organizzazione Media"
    echo ""
    echo "**Data esecuzione:** \`$DATE_NOW\`  "
    echo "**Cartella Origine:** \`$SOURCE_DIR\`  "
    echo "**Cartella Destinazione:** \`$DEST_DIR\`  "
    echo ""
    echo "---"
    echo ""
    echo "## Riepilogo Generale"
    echo ""
    echo "| Metric | Conteggio |"
    echo "| :--- | :--- |"
    echo "| **Totale file elaborati** | $TOTAL_PROCESSED |"
    echo "| **Foto** | $TOTAL_FOTO |"
    echo "| **Video** | $TOTAL_VIDEO |"
    echo "| **Organizzati per data (Anno/Mese)** | $TOTAL_BY_DATE |"
    echo "| **Senza metadati (\`not_elaborate\`)** | $TOTAL_WITHOUT_META |"
    echo "| **File già presenti (skippati)** | $TOTAL_SKIPPED |"
    echo "| **File con errori** | $TOTAL_ERRORS |"
    echo ""
    echo "---"
    echo ""
    echo "## Dettaglio Cartelle"
    echo ""
    if [ ${#FOLDER_COUNTS[@]} -gt 0 ]; then
        echo "| Sottocartella | Numero file |"
        echo "| :--- | :--- |"
        for FOLDER in ${(k)FOLDER_COUNTS}; do
            echo "| \`$FOLDER\` | ${FOLDER_COUNTS[$FOLDER]} |"
        done | sort
    else
        echo "_Nessun file organizzato._"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## File già presenti (skippati)"
    echo ""
    if [ ${#SKIPPED_LIST[@]} -gt 0 ]; then
        echo "Sono stati skippati **$TOTAL_SKIPPED** file già presenti in destinazione:"
        echo ""
        for SKIP_FILE in "${SKIPPED_LIST[@]}"; do
            echo "- \`$SKIP_FILE\`"
        done
    else
        echo "Nessun file skippato: in destinazione non c'erano omonimi."
    fi
    echo ""
    echo "---"
    echo ""
    echo "## File in Errore"
    echo ""
    if [ ${#ERRORS_LIST[@]} -gt 0 ]; then
        echo "Sono stati riscontrati **$TOTAL_ERRORS** errori durante la copia dei seguenti file:"
        echo ""
        for ERR_FILE in "${ERRORS_LIST[@]}"; do
            echo "- \`$ERR_FILE\`"
        done
    else
        echo "Nessun errore riscontrato durante la lavorazione."
    fi
    echo ""
} > "$REPORT_FILE"

echo "------------------------------------------------"
echo "Completato!"
echo "Media organizzati in: $DEST_DIR"
echo "Report salvato in:    $REPORT_FILE"
echo "Report altri file:    ${DEST_DIR}/report_altri_file.md"
echo "------------------------------------------------"
