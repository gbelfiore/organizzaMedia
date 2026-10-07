#!/bin/zsh

PHOTO_EXTS=(jpg jpeg png heic heif gif webp tif tiff dng cr2 cr3 nef arw raf orf rw2)
VIDEO_EXTS=(mp4 mov avi m4v mkv 3gp mts m2ts wmv mpg mpeg webm)

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
OTHER_DIR="${DEST_DIR}/others"
STATS_ONLY=${STATS_ONLY:-0}
LIMIT=${LIMIT:-0}
REPORT_FILE="${REPORT_FILE:-}"
REPORT_JSON="${REPORT_JSON:-}"

if (( ! STATS_ONLY )); then
    mkdir -p "$OTHER_DIR"
fi

if [[ -t 1 ]]; then
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

is_valid_date_parts() {
    [[ "$1" =~ ^(19[7-9][0-9]|20[0-3][0-9])$ ]] && [[ "$2" =~ ^(0[1-9]|1[0-2])$ ]]
}

is_sidecar_json() {
    local base="$1"
    [[ "$base" == *.supplemental-metadata.json ]] && return 0
    [[ "$base" == *.json ]] || return 1
    local dir="$2"
    local media="${base%.json}"
    [[ -f "${dir}/${media}" ]]
}

is_photo_or_video() {
    local ext="$1"
    local e
    for e in "${PHOTO_EXTS[@]}"; do
        [[ "$ext" == "$e" ]] && return 0
    done
    for e in "${VIDEO_EXTS[@]}"; do
        [[ "$ext" == "$e" ]] && return 0
    done
    return 1
}

resolve_date() {
    local file="$1"
    YEAR=""
    MONTH=""

    local match
    match=$(echo "$(basename "$file")" | grep -oE '(19[7-9][0-9]|20[0-3][0-9])[-_]?(0[1-9]|1[0-2])[-_]?(0[1-9]|[12][0-9]|3[01])' | head -n1)
    if [ -n "$match" ]; then
        local clean
        clean=$(echo "$match" | tr -d '_-')
        YEAR=${clean:0:4}
        MONTH=${clean:4:2}
        if is_valid_date_parts "$YEAR" "$MONTH"; then
            return 0
        fi
    fi

    YEAR=""
    MONTH=""
    return 1
}

TOTAL_OTHER=0
TOTAL_MOVED=0
TOTAL_BY_DATE=0
TOTAL_WITHOUT_META=0
TOTAL_SKIPPED=0
TOTAL_ERRORS=0
OTHER_FILES=()
SKIPPED_LIST=()
ERRORS_LIST=()
typeset -A EXT_COUNTS
typeset -A FOLDER_COUNTS

echo "Origine:      $SOURCE_DIR"
if (( STATS_ONLY )); then
    echo "Modalità:     solo statistiche (nessuno spostamento)"
else
    echo "Destinazione: $OTHER_DIR"
fi
if (( LIMIT > 0 )); then
    echo "Limite:       primi $LIMIT file media (stesso del backup)"
else
    echo "Limite:       nessuno"
fi
echo "------------------------------------------------"

MEDIA_SEEN=0
while IFS= read -r -d '' FILE; do
    case "$FILE" in
        "$DEST_DIR"/*) continue ;;
    esac

    FILENAME="$(basename "$FILE")"
    FILE_DIR="$(dirname "$FILE")"
    [[ "$FILENAME" == .DS_Store || "$FILENAME" == Thumbs.db || "$FILENAME" == ._* ]] && continue
    is_sidecar_json "$FILENAME" "$FILE_DIR" && continue

    EXT_LOWER="${FILENAME:e:l}"
    if is_photo_or_video "$EXT_LOWER"; then
        ((MEDIA_SEEN++))
        if (( LIMIT > 0 && MEDIA_SEEN >= LIMIT )); then
            echo "Raggiunto il limite di $LIMIT file media, stop."
            break
        fi
        continue
    fi

    ((TOTAL_OTHER++))
    OTHER_FILES+=("$FILE")

    EXT="$EXT_LOWER"
    [ -z "$EXT" ] && EXT="Senza Estensione"
    EXT_COUNTS[$EXT]=$(( ${EXT_COUNTS[$EXT]:-0} + 1 ))

    if (( STATS_ONLY )); then
        echo "Trovato: $FILENAME (.$EXT)"
        continue
    fi

    if resolve_date "$FILE"; then
        REL_FOLDER="${YEAR}/${MONTH}"
    else
        REL_FOLDER="without_metadata"
    fi

    TARGET_FOLDER="${OTHER_DIR}/${REL_FOLDER}"
    TARGET_FILE="${TARGET_FOLDER}/${FILENAME}"

    if [ -e "$TARGET_FILE" ]; then
        echo "${C_ORANGE}Skip: $FILENAME già presente in others/${REL_FOLDER}${C_RESET}"
        ((TOTAL_SKIPPED++))
        SKIPPED_LIST+=("$FILE -> others/${REL_FOLDER}/${FILENAME}")
        continue
    fi

    mkdir -p "$TARGET_FOLDER"

    if mv "$FILE" "$TARGET_FILE" 2>/dev/null; then
        ((TOTAL_MOVED++))
        if [[ "$REL_FOLDER" == "without_metadata" ]]; then
            ((TOTAL_WITHOUT_META++))
        else
            ((TOTAL_BY_DATE++))
        fi
        FOLDER_COUNTS[$REL_FOLDER]=$(( ${FOLDER_COUNTS[$REL_FOLDER]:-0} + 1 ))
        echo "${C_GREEN}Spostato: $FILENAME -> others/${REL_FOLDER}${C_RESET}"
    else
        echo "${C_RED}ERRORE nello spostamento di: $FILE${C_RESET}"
        ((TOTAL_ERRORS++))
        ERRORS_LIST+=("$FILE")
    fi
done < <(find "$SOURCE_DIR" -type f -print0 | sort -z)

DATE_NOW=$(date "+%Y-%m-%d %H:%M:%S")

{
    echo "# Report File Non Riconosciuti (Altri File)"
    echo ""
    echo "**Data esecuzione:** \`$DATE_NOW\`  "
    echo "**Cartella Origine:** \`$SOURCE_DIR\`  "
    echo "**Cartella Destinazione:** \`$OTHER_DIR\`  "
    echo ""
    echo "---"
    echo ""
    echo "## Riepilogo"
    echo ""
    echo "| Metric | Conteggio |"
    echo "| :--- | :--- |"
    echo "| **Totale file non foto/video** | $TOTAL_OTHER |"
    if (( ! STATS_ONLY )); then
    echo "| **File spostati** | $TOTAL_MOVED |"
    echo "| **Organizzati per data (Anno/Mese)** | $TOTAL_BY_DATE |"
    echo "| **Senza data nel nome (\`without_metadata\`)** | $TOTAL_WITHOUT_META |"
    echo "| **File già presenti (skippati)** | $TOTAL_SKIPPED |"
    echo "| **File con errori** | $TOTAL_ERRORS |"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## Riepilogo Tipologie File"
    echo ""
    if [ ${#EXT_COUNTS[@]} -gt 0 ]; then
        echo "| Estensione / Tipo | Quantità File |"
        echo "| :--- | :--- |"
        for EXT in ${(k)EXT_COUNTS}; do
            echo "| \`.${EXT}\` | ${EXT_COUNTS[$EXT]} |"
        done | sort
    else
        echo "_Nessun file extra trovato._"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## Dettaglio Cartelle"
    echo ""
    if [ ${#FOLDER_COUNTS[@]} -gt 0 ]; then
        echo "| Sottocartella | Numero file |"
        echo "| :--- | :--- |"
        for FOLDER in ${(k)FOLDER_COUNTS}; do
            echo "| \`others/${FOLDER}\` | ${FOLDER_COUNTS[$FOLDER]} |"
        done | sort
    else
        echo "_Nessun file spostato._"
    fi
    echo ""
    echo "---"
    echo ""
    echo "## Elenco File Trovati"
    echo ""
    if [ ${#OTHER_FILES[@]} -gt 0 ]; then
        for FILE_PATH in "${OTHER_FILES[@]}"; do
            echo "- \`$FILE_PATH\`"
        done
    else
        echo "Nessun file extra trovato. La cartella contiene esclusivamente foto e video supportati."
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
        echo "Sono stati riscontrati **$TOTAL_ERRORS** errori durante lo spostamento dei seguenti file:"
        echo ""
        for ERR_FILE in "${ERRORS_LIST[@]}"; do
            echo "- \`$ERR_FILE\`"
        done
    else
        echo "Nessun errore riscontrato durante la lavorazione."
    fi
    echo ""
} | if [[ -n "$REPORT_FILE" ]]; then
    mkdir -p "$(dirname "$REPORT_FILE")"
    tee "$REPORT_FILE"
else
    cat
fi

if [[ -n "$REPORT_JSON" ]]; then
    LIST_TMP="$(mktemp)"
    for FILE_PATH in "${OTHER_FILES[@]}"; do
        FN="$(basename "$FILE_PATH")"
        EX="${FN:e:l}"
        [ -z "$EX" ] && EX="Senza Estensione"
        printf '%s\t%s\n' "$FILE_PATH" "$EX" >> "$LIST_TMP"
    done
    python3 -c '
import json, sys
from collections import Counter
rows = open(sys.argv[1], encoding="utf-8").read().splitlines()
files, exts = [], Counter()
for row in rows:
    if "\t" not in row:
        continue
    p, e = row.split("\t", 1)
    files.append(p)
    exts[e] += 1
json.dump({"total": len(files), "exts": dict(exts), "files": files}, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
' "$LIST_TMP" "$REPORT_JSON"
    rm -f "$LIST_TMP"
fi

echo "------------------------------------------------"
echo "Analisi completata!"
if (( STATS_ONLY )); then
    echo "Nessun file spostato (solo statistiche)."
else
    echo "File spostati in: $OTHER_DIR"
fi
[[ -n "$REPORT_FILE" ]] && echo "Report salvato in: $REPORT_FILE"
echo "------------------------------------------------"
