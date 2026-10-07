# Backup e organizzazione di foto e video

Due script zsh per macOS che, partendo da una cartella qualsiasi (anche con sottocartelle, ad es. un export di Google Takeout):

1. **Backup flat**: copiano tutte le foto (o i video) in un'unica cartella senza sottocartelle, **saltando i duplicati** (stesso contenuto = stessa dimensione + stesso hash SHA-256, a prescindere dal nome).
2. **Organizzazione per data**: copiano il backup flat in `<cartella_organizzata>/AAAA/MM` in base alla data di scatto/ripresa; i file senza data finiscono in `without_metadata/`.
3. **Report**: scrivono un report dettagliato in Markdown e un TSV con il dettaglio file per file.

| Script | File gestiti |
| :--- | :--- |
| `backup_organizza_foto.sh` | jpg, jpeg, png, heic, heif, gif, webp, tif, tiff, dng, cr2, cr3, nef, arw, raf, orf, rw2 |
| `backup_organizza_video.sh` | mp4, mov, m4v, 3gp, mts, m2ts, avi, mkv, wmv, mpg, mpeg, webm |

La cartella di origine viene **solo letta**: non viene mai modificata.

## Requisiti

```sh
brew install exiftool        # obbligatorio
xcode-select --install       # opzionale: fornisce SetFile, serve a preservare la data di creazione dei file
```

Se serve, rendi eseguibili gli script:

```sh
chmod +x scripts/backup_organizza_foto.sh scripts/backup_organizza_video.sh
```

## Uso

```sh
./scripts/backup_organizza_foto.sh  [opzioni] [origine] [cartella_bk_flat] [cartella_organizzata]
./scripts/backup_organizza_video.sh [opzioni] [origine] [cartella_bk_flat] [cartella_organizzata]
```

Tutti gli argomenti sono facoltativi:

- **nessun argomento**: lo script chiede la cartella di origine e propone le due cartelle di destinazione (basta premere Invio per accettarle);
- **solo `origine`**: le destinazioni vengono create accanto all'origine con i nomi predefiniti;
- **tutti e tre**: usa esattamente le cartelle indicate.

Nomi predefiniti delle destinazioni (per un'origine `/Volumes/Disco/Foto`):

| | Foto | Video |
| :--- | :--- | :--- |
| Backup flat | `/Volumes/Disco/Foto_BK_Foto_Flat` | `/Volumes/Disco/Foto_BK_Video_Flat` |
| Organizzata | `/Volumes/Disco/Foto_Foto_Organizzate` | `/Volumes/Disco/Foto_Video_Organizzati` |

Origine, backup flat e cartella organizzata devono essere tre cartelle diverse, e le destinazioni non possono stare dentro l'origine.

### Opzioni

| Opzione | Variabile d'ambiente | Descrizione |
| :--- | :--- | :--- |
| `-n N`, `--limit N`, `--limit=N` | `LIMIT=N` | Elabora solo i **primi N** file dell'origine (in ordine alfabetico di percorso). `0` = nessun limite (predefinito). |
| `--dry-run` | `DRY_RUN=1` | Simulazione: non copia nulla, mostra cosa verrebbe copiato e quali duplicati verrebbero saltati. La fase 2 non viene eseguita. |
| `-h`, `--help` | | Mostra l'aiuto. |

Le opzioni si possono mettere prima o dopo i percorsi.

## Esempi

```sh
# Modalità interattiva (chiede le cartelle)
./scripts/backup_organizza_foto.sh

# Origine con destinazioni predefinite
./scripts/backup_organizza_foto.sh "/Volumes/Disco/Takeout/Google Foto"

# Origine e destinazioni esplicite
./scripts/backup_organizza_foto.sh ~/Takeout ~/Backup/Foto_Flat ~/Backup/Foto_Organizzate
./scripts/backup_organizza_video.sh ~/Takeout ~/Backup/Video_Flat ~/Backup/Video_Organizzati

# Prova su 50 file prima di lanciare tutto
./scripts/backup_organizza_foto.sh --limit 50 ~/Takeout ~/Backup/Foto_Flat ~/Backup/Foto_Organizzate
./scripts/backup_organizza_foto.sh ~/Takeout ~/Backup/Foto_Flat ~/Backup/Foto_Organizzate -n 50

# Simulazione completa senza copiare nulla
./scripts/backup_organizza_foto.sh --dry-run ~/Takeout
DRY_RUN=1 ./scripts/backup_organizza_video.sh ~/Takeout

# Simulazione sui primi 100 file
DRY_RUN=1 LIMIT=100 ./scripts/backup_organizza_foto.sh ~/Takeout

# Aggiungere al backup esistente una seconda origine (i file già presenti vengono saltati)
./scripts/backup_organizza_foto.sh /Volumes/VecchioDisco/Foto ~/Backup/Foto_Flat ~/Backup/Foto_Organizzate
```

## Come funziona

### Fase 1: backup flat

- Indicizza il backup flat esistente, così il backup è **incrementale**: rilanciando lo script, anche con un'altra origine, i file già presenti vengono riconosciuti come duplicati e saltati.
- Legge ricorsivamente l'origine e ordina i file alfabeticamente: tra file identici si tiene il primo in ordine alfabetico.
- **Duplicati**: l'hash SHA-256 viene calcolato solo quando due file hanno la stessa dimensione, quindi i file di dimensione unica non vengono letti per intero.
- **Conflitti di nome** (file diversi con lo stesso nome, ad es. `IMG_0001.jpg` in due cartelle): il secondo viene rinominato `IMG_0001_1.jpg`, `IMG_0001_2.jpg`, … Il confronto ignora maiuscole e minuscole, come il filesystem di macOS.
- **JSON di Google Takeout**: il file `.json` associato (anche nelle varianti con nome troncato, ad es. `foto.jpg.supplemental-me.json`, `foto.jpg(1).json`) viene copiato accanto al file come `<nome>.json`. Se un duplicato ha il JSON e il file tenuto no, il JSON viene recuperato dal duplicato.
- Nel backup flat viene aggiornato `indice_origine.tsv`, con il percorso di origine di ogni file copiato.
- I file non foto/video (txt, `.DS_Store`, AppleDouble `._*`, …) vengono ignorati ed elencati nel report.

### Fase 2: organizzazione per data

La data viene presa, in ordine di priorità, da:

1. i **metadati** del file. Foto: `DateTimeOriginal`, `CreateDate`, `MediaCreateDate`, `TrackCreateDate`, `ContentCreateDate`. Video: `CreationDate`, `MediaCreateDate`, `CreateDate`, `DateTimeOriginal`, `TrackCreateDate`, `ContentCreateDate`;
2. il **nome del file**, se contiene una data (`20210315`, `2021-03-15`, `2021_03_15`, …);
3. il **JSON di Google Takeout** (`photoTakenTime` / `creationTime`).

Se non trova nessuna data, il file va in `without_metadata/`.

Se la data è stata ricavata dal nome del file o dal JSON, viene **scritta nei metadati** della copia organizzata. Lo stesso vale per il **GPS** presente nel JSON e assente nel file. Exiftool aggiunge solo i dati mancanti e non sovrascrive mai quelli validi. Infine la data di modifica e di creazione del file vengono allineate alla data di scatto/ripresa.

> Nota video: AVI, MKV, WMV e WEBM non sono scrivibili da exiftool. Vengono organizzati comunque, ma senza aggiunta di metadati (nel report risultano in "Scrittura metadati fallita").

### Preservazione dei metadati

Le copie sono identiche byte per byte: EXIF, XMP e GPS non vengono toccati. Mantengono anche permessi, attributi estesi, data di modifica e, se `SetFile` è disponibile, data di creazione. Ogni copia viene fatta prima su un file temporaneo nascosto e poi verificata sulla dimensione, così un'interruzione non lascia mai file troncati.

### Limite `-n` / `--limit`

- Prende i primi N file media dell'origine **dopo l'ordinamento alfabetico**: lanciando di nuovo con lo stesso N vengono rielaborati gli stessi file, che risulteranno duplicati già presenti. Per andare avanti, aumenta N, ad es. `-n 50` e poi `-n 200`.
- Con il limite attivo, la fase 2 organizza **solo i file copiati in questa esecuzione** e non tutto il backup flat.
- Nel conteggio entrano solo i file foto/video: i file ignorati e i JSON non contano.

### Interruzione (Ctrl-C)

Si può interrompere in qualsiasi momento: lo script scrive comunque un **report parziale**, segnalato come "Interrotto". Rilanciando, riparte dai file mancanti grazie al backup incrementale.

## Report

A ogni esecuzione vengono creati due file nella **cartella organizzata**, con data e ora nel nome, così i report precedenti non vengono sovrascritti:

| File | Contenuto |
| :--- | :--- |
| `report_backup_<foto\|video>_AAAAMMGG_HHMMSS.md` | Report leggibile in Markdown |
| `report_backup_<foto\|video>_AAAAMMGG_HHMMSS_dettaglio.tsv` | Una riga per ogni file: `fase`, `esito`, `file`, `destinazione`, `byte`, `note` (apribile con Numbers/Excel) |

Il report Markdown contiene:

- **Riepilogo**: esito (completato / con errori / interrotto), inizio, fine, durata totale e per fase, cartelle, limite, versione di exiftool, disponibilità di SetFile, spazio libero sul disco.
- **Numeri principali**: trovati, elaborati, non elaborati per il limite, copiati, duplicati saltati (con percentuale e spazio risparmiato), organizzati, senza metadati, ignorati, errori.
- **Fase 1**: file già presenti nel backup, duplicati divisi in "già nel backup" e "ripetuti dentro l'origine", rinominati, JSON Takeout (associati, copiati, recuperati), hash calcolati, velocità di copia, errori.
  - Tabella **per estensione** (trovati / copiati / duplicati / dimensione).
  - **File ignorati** raggruppati per tipo, con l'elenco completo.
- **Fase 2**: elaborati, organizzati, senza metadati, già organizzati, date e GPS aggiunti, scritture di metadati fallite, errori.
  - Da dove è stata presa la data (quale tag, nome file o JSON), con percentuali.
  - Conteggi per anno e per cartella `AAAA/MM`.
  - Elenchi dei file senza data, con data aggiunta, con GPS aggiunto e con scrittura dei metadati fallita.
- **Duplicati**: raggruppati per file tenuto (quante copie saltate e da dove veniva l'originale), più l'elenco completo duplicato → file tenuto.
- **Rinominati** per conflitto di nome e **file in errore**.
- **Stato finale**: numero di file e dimensione di backup flat e cartella organizzata, con un controllo che siano allineati.

Gli elenchi lunghi sono in sezioni richiudibili (`<details>`): conviene aprire il report in un visualizzatore Markdown, ad es. l'anteprima di VS Code (`Cmd+Shift+V`).

Esempi di esiti nel TSV: `ignorato`, `copiato`, `copierebbe (dry run)`, `duplicato`, `organizzato`, `senza metadati`, `già organizzato`, `errore`.

## Altri script in `scripts/`

`organizza_foto.sh`, `organizza_video.sh`, `organizza_media.sh` e `trova_altri_file.sh` sono gli script precedenti e indipendenti: la logica di organizzazione di `organizza_foto.sh` / `organizza_video.sh` è già inclusa nei due script di backup.

## Webapp (PocketBase + React)

Questo repository è la webapp. Gli script zsh stanno in `scripts/`. PocketBase memorizza gli hash SHA-256 così i confronti sui run successivi sono più veloci.

```sh
npm run setup
npm run dev
```

Poi apri http://127.0.0.1:5173

- **Origine / destinazione**: scegli le cartelle (o sfoglia dal disco)
- Dopo l'esecuzione: immagini di partenza, uniche, doppioni, file prodotti, tempi per step
- Per ogni foto unica: quanti doppioni ha e i percorsi

La destinazione organizzata è quella che inserisci; il backup flat delle uniche va in `destinazione_flat`. PocketBase resta su http://127.0.0.1:8090, l'API su http://127.0.0.1:3001.
