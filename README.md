# BRABUS UTIL - Control Center 2.1 (beta)

Strumento locale per **Windows 10/11** (Windows PowerShell 5.1) che analizza il PC, propone tweak
compatibili e li applica **solo dopo conferma**, con backup verificato in doppia copia, rilettura di
ogni valore e ripristino selettivo. Nessuna IA, nessun servizio residente, nessuna modifica automatica.

> Beta pubblica. Leggi il codice e verifica l'hash prima di eseguirlo. Nessuna promessa di FPS:
> il valore PWU indica un impatto potenziale qualitativo, non un benchmark.

## Avvio rapido

1. Scarica `BrabusDebloater.ps1` (ed eventualmente `SHA256SUMS.txt`).
2. Verifica l'integrità del file:
   ```powershell
   (Get-FileHash .\BrabusDebloater.ps1 -Algorithm SHA256).Hash
   ```
   Il valore deve coincidere con la riga corrispondente di `SHA256SUMS.txt`.
3. Apri PowerShell nella cartella del file e avvia:
   ```powershell
   powershell.exe -NoProfile -STA -File .\BrabusDebloater.ps1
   ```
   Se Windows blocca un file scaricato, verificane prima l'hash; solo se attendibile usa
   `Unblock-File -LiteralPath .\BrabusDebloater.ps1`, oppure `-ExecutionPolicy RemoteSigned` per il solo
   processo. Non modificare la policy di sistema e rispetta le policy aziendali.

Per i tweak dei **driver di rete** e delle **chiavi criteri** (`HKCU\Software\Policies`) serve una
PowerShell avviata come amministratore: l'elevazione non viene mai richiesta automaticamente e le
voci che la richiedono sono marcate `RICHIEDE ADMIN`.

## Funzionalita

| Area | Cosa fa |
| --- | --- |
| **Catalogo tweak** | 124 definizioni per utente (debloat, privacy, Explorer, visual, input, notifiche, taskbar, 18 permessi app), 24 criteri ADMX locali, 37 criteri browser (Edge/Chrome solo se installati), 12 launcher in avvio automatico, notifiche per app. Compaiono solo le voci compatibili con build, edizione e stato attuale del PC. |
| **Energia / CPU** | 9 indici AC del piano attivo, **solo desktop senza batteria**. Mai sui portatili. |
| **Network Center** | Speed test HTTPS (2 flussi, ~30 s, max 1 GB + 300 MB), ping a riposo e sotto carico, jitter, perdita, cronologia locale; 16 proprieta avanzate in whitelist delle schede fisiche. |
| **Backup e ripristino** | Journal write-ahead in doppia copia con SHA-256, snapshot per sessione, rilettura dopo ogni scrittura, ripristino selettivo che non sovrascrive valori cambiati da altri. |
| **Verifica tweak** | Rilegge i valori attuali contro originale/obiettivo e segnala conflitti e riavvii necessari. |
| **Profili portabili** | Esporta solo identificatori opachi dei tweak attivi (nessun valore, percorso o GUID di scheda); l'import seleziona soltanto le voci compatibili. |
| **Strumenti** | Inventari in sola lettura (app, servizi, funzionalita, Windows Update, dischi, GPU), rimozione app Store consentite, preferenza GPU per gioco, Software Center WinGet con verifica dell'ID. |

Mai toccati automaticamente: Defender, firewall, UAC, Windows Update, servizi.

## Opzioni da riga di comando

| Parametro | Effetto |
| --- | --- |
| *(nessuno)* | Avvia la GUI. |
| `-SelfTest` | Test integrato su una chiave HKCU di prova isolata: scrittura reale, journal, verifica, rollback. |
| `-UiTest` | Test automatico della GUI su finestra nascosta con dati sintetici. |
| `-Scan` | Salva un report JSON in sola lettura nella cartella di stato. |
| `-ReleaseCheck` | Stampa un riepilogo JSON (catalogo, audit, profilo). Nessuna scrittura. |
| `-ExportCurrentProfile <file>` | Esporta il profilo dei tweak attivi in un file **nuovo** (mai sovrascritto). |
| `-Undo` | Ripristina tutte le modifiche utente/energia del journal. Per i driver usa la GUI. |

## Come funziona il backup

```
selezione -> snapshot del batch (file immutabile, verificato)
          -> journal primario + mirror (SHA-256, proprietario = SID utente, riletti e confrontati)
          -> ricontrollo del valore live -> scrittura -> rilettura obbligatoria
```

* Una copia danneggiata viene sostituita dall'altra (con avviso); due copie danneggiate bloccano ogni scrittura.
* Il ripristino procede dal piu recente al piu vecchio e conserva il record se il valore e stato cambiato da altri.
* Stato in `%LOCALAPPDATA%\BrabusPC-Debloater-State` (`backup-v2\`, `changes.jsonl`, `speed-history.json`).
  Formato e nomi dei file sono **identici alla v2.0**: i backup esistenti restano leggibili e ripristinabili,
  e la v2.0 legge quelli scritti dalla 2.1 (downgrade sicuro). Non sono immagini di sistema: tienili privati.

## Sviluppo e test

```powershell
# Requisiti una tantum
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser

# Tutta la suite (sugli altri sistemi i test Windows vengono saltati)
powershell.exe -NoProfile -File .\tests\Invoke-Tests.ps1
```

| Suite | Contenuto | Piattaforma |
| --- | --- | --- |
| `Backup.Tests.ps1` | envelope, validazione, apply/restore, conflitti, corruzione, migrazione v1, journal rete | tutte (registro simulato) |
| `Catalog.Tests.ps1` | regole del catalogo, ADMX, PWU, schede di rete | tutte |
| `Compatibility.Tests.ps1` | backup scritti dal codice originale v2.0 letti/ripristinati, e viceversa | tutte |
| `Profile.Tests.ps1`, `SpeedHistory.Tests.ps1` | profili portabili, cronologia, file atomici | tutte |
| `Static.Tests.ps1` | parsing, solo ASCII, CRLF, verbi approvati, controlli XAML usati dal codice, ogni comando esistente in PowerShell 5.1, PSScriptAnalyzer | tutte |
| `Windows.Integration.Tests.ps1` | registro reale, clone del piano energetico, `-SelfTest`, `-ReleaseCheck`, `-UiTest` | solo Windows |

La CI (`.github/workflows/ci.yml`) esegue tutto su Windows PowerShell 5.1, PowerShell 7 e Linux,
e verifica che `SHA256SUMS.txt` corrisponda ai file. Dopo ogni modifica rigenera i checksum con
`.\tools\Update-Checksums.ps1`.

### Struttura

```
BrabusDebloater.ps1          distribuzione in un solo file (dot-source = solo funzioni, per i test)
PSScriptAnalyzerSettings.psd1 regole di analisi, incluse compatibilita sintassi/comandi/tipi 5.1
tests/                       suite Pester 5
tools/Update-Checksums.ps1   rigenera SHA256SUMS.txt
archive/                     versioni pubblicate 1.4 - 2.0, invariate, con i loro checksum
```

Per aggiungere un tweak basta una riga in `Get-StaticTweakDefinition` (campi documentati nel codice):
i test verificano unicita, categorie, tipi e percorsi ammessi dal validatore dei backup.

## Limiti noti

* Registry/power readback non prova l'effetto a runtime; alcune voci sono preferenze, non ottimizzazioni.
* Le modifiche ai driver richiedono un riavvio manuale; nessun riavvio automatico.
* Rimozione app e installer WinGet sono azioni separate e confermate; il recupero dei dati delle app non e garantito.
* Testato dall'autore su un PC Windows 11; compatibilita su altri PC, driver e build non certificata.

Vedi [CHANGELOG.md](CHANGELOG.md) per le modifiche di ogni versione.
