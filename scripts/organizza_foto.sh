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
REPORT_FILE="${DEST_DIR}/report_organizzazione.md"

mkdir -p "$DEST_DIR"

TOTAL_PROCESSED=0
TOTAL_BY_DATE=0
TOTAL_WITHOUT_META=0
TOTAL_ERRORS=0
TOTAL_TO_PROCESS=0
PROGRESS_UI=0
[[ -t 1 && -t 2 ]] && PROGRESS_UI=1

typeset -A FOLDER_COUNTS
ERRORS_LIST=()

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

log_msg() {
    if (( PROGRESS_UI )); then
        printf '%s\n' "$*" >/dev/tty
        progress_draw_header "$TOTAL_PROCESSED"
    else
        printf '[%3d%%] %s\n' "$(pct_of "$TOTAL_PROCESSED" "$TOTAL_TO_PROCESS")" "$*"
    fi
}

is_valid_date_parts() {
    [[ "$1" =~ ^(19[7-9][0-9]|20[0-3][0-9])$ ]] && [[ "$2" =~ ^(0[1-9]|1[0-2])$ ]]
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

FIND_OPTS=(
    "$SOURCE_DIR" -type f
    \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic"
    -o -iname "*.gif" -o -iname "*.webp"
    -o -iname "*.cr2" -o -iname "*.nef" -o -iname "*.arw" \)
)

echo "Conteggio file in corso..."
while IFS= read -r -d '' FILE; do
    case "$FILE" in
        "$DEST_DIR"/*) continue ;;
    esac
    ((TOTAL_TO_PROCESS++))
done < <(find "${FIND_OPTS[@]}" -print0)

progress_setup
log_msg "Origine:      $SOURCE_DIR"
log_msg "Destinazione: $DEST_DIR"
log_msg "File da elaborare: $TOTAL_TO_PROCESS"
log_msg "------------------------------------------------"

while IFS= read -r -d '' FILE; do
    case "$FILE" in
        "$DEST_DIR"/*) continue ;;
    esac

    ((TOTAL_PROCESSED++))
    YEAR=""
    MONTH=""
    CLEAN_DATE=""
    META_DATETIME=""

    extract_year_month "$FILE" \
        DateTimeOriginal CreateDate MediaCreateDate TrackCreateDate ContentCreateDate

    FILENAME="$(basename "$FILE")"
    EXT_LOWER="${FILENAME:e:l}"

    # Fallback: data nel nome file
    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        MATCH=$(echo "$FILENAME" | grep -oE '(19[7-9][0-9]|20[0-3][0-9])[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12][0-9]|3[01])' | head -n1)
        if [ -n "$MATCH" ]; then
            CLEAN_DATE=$(echo "$MATCH" | tr -d '_-')
            YEAR=${CLEAN_DATE:0:4}
            MONTH=${CLEAN_DATE:4:2}
        fi
    fi

    # Ultima spiaggia: JSON Google Takeout
    if ! is_valid_date_parts "$YEAR" "$MONTH"; then
        YEAR=""
        MONTH=""
        SIDECAR=$(find_sidecar_json "$FILE") || SIDECAR=""
        if [[ -n "$SIDECAR" ]]; then
            TS=$(extract_takeout_timestamp "$SIDECAR")
            apply_date_from_timestamp "$TS" || true
        fi
    fi

    if is_valid_date_parts "$YEAR" "$MONTH"; then
        REL_FOLDER="${YEAR}/${MONTH}"
        ((TOTAL_BY_DATE++))
    else
        YEAR=""
        MONTH=""
        CLEAN_DATE=""
        META_DATETIME=""
        REL_FOLDER="without_metadata"
        ((TOTAL_WITHOUT_META++))
    fi

    TARGET_FOLDER="${DEST_DIR}/${REL_FOLDER}"
    TARGET_FILE="${TARGET_FOLDER}/${FILENAME}"
    mkdir -p "$TARGET_FOLDER"

    if cp -p "$FILE" "$TARGET_FILE" 2>/dev/null; then
        exiftool -overwrite_original -TagsFromFile "$FILE" "-all:all" "$TARGET_FILE" &> /dev/null

        if is_valid_date_parts "$YEAR" "$MONTH"; then
            EXISTING_DTO=$(exiftool -s3 -d "%Y" -DateTimeOriginal "$TARGET_FILE" 2>/dev/null)
            EXISTING_CREATE=$(exiftool -s3 -d "%Y" -CreateDate "$TARGET_FILE" 2>/dev/null)
            if ! is_valid_date_parts "$EXISTING_DTO" "01" && ! is_valid_date_parts "$EXISTING_CREATE" "01"; then
                if [[ -n "$META_DATETIME" ]]; then
                    META_DATE="$META_DATETIME"
                else
                    DAY="01"
                    if [ -n "${CLEAN_DATE:-}" ] && [ ${#CLEAN_DATE} -ge 8 ]; then
                        DAY=${CLEAN_DATE:6:2}
                        [[ "$DAY" =~ ^(0[1-9]|[12][0-9]|3[01])$ ]] || DAY="01"
                    fi
                    META_DATE="${YEAR}:${MONTH}:${DAY} 12:00:00"
                fi
                exiftool -overwrite_original \
                    -DateTimeOriginal="$META_DATE" \
                    -CreateDate="$META_DATE" \
                    -ModifyDate="$META_DATE" \
                    "$TARGET_FILE" &> /dev/null
            fi

            exiftool -overwrite_original \
                "-FileModifyDate<CreateDate" \
                "-FileCreateDate<CreateDate" \
                "-FileModifyDate<DateTimeOriginal" \
                "-FileCreateDate<DateTimeOriginal" \
                "-ModifyDate<DateTimeOriginal" \
                "-ModifyDate<CreateDate" \
                "$TARGET_FILE" &> /dev/null
        fi

        log_msg "Copiata: $FILENAME -> ${REL_FOLDER}"
        FOLDER_COUNTS[$REL_FOLDER]=$(( ${FOLDER_COUNTS[$REL_FOLDER]:-0} + 1 ))
    else
        log_msg "ERRORE nella copia di: $FILE"
        ((TOTAL_ERRORS++))
        ERRORS_LIST+=("$FILE")
    fi

done < <(find "${FIND_OPTS[@]}" -print0)

progress_teardown
PROGRESS_UI=0
trap - EXIT INT TERM

DATE_NOW=$(date "+%Y-%m-%d %H:%M:%S")

{
    echo "# Report Organizzazione Foto"
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
    echo "| **Totale immagini elaborate** | $TOTAL_PROCESSED |"
    echo "| **Organizzate per data (Anno/Mese)** | $TOTAL_BY_DATE |"
    echo "| **Senza metadati (\`without_metadata\`)** | $TOTAL_WITHOUT_META |"
    echo "| **File con errori** | $TOTAL_ERRORS |"
    echo ""
    echo "---"
    echo ""
    echo "## Dettaglio Cartelle"
    echo ""
    if [ ${#FOLDER_COUNTS[@]} -gt 0 ]; then
        echo "| Sottocartella | Numero di Foto |"
        echo "| :--- | :--- |"
        for FOLDER in ${(k)FOLDER_COUNTS}; do
            echo "| \`$FOLDER\` | ${FOLDER_COUNTS[$FOLDER]} |"
        done | sort
    else
        echo "_Nessuna foto organizzata._"
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
echo "Foto organizzate in: $DEST_DIR"
echo "Report salvato in:   $REPORT_FILE"
echo "------------------------------------------------"
