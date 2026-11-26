# Changelog

## 2.1.0 beta - refactoring completo e correzioni

Stesse funzioni e stesso catalogo della 2.0 (verificato con un test di parita automatico: 0 differenze
su 342 righe x 13 campi in tre scenari), codice riscritto per essere leggibile, testabile e piu veloce.
I backup esistenti restano compatibili in entrambe le direzioni.

### Correzioni
- **Preset SAFE / GAMING / ULTIMATE**: dopo la selezione il pulsante *Applica* restava disabilitato
  (il pie di pagina non veniva aggiornato). Ora si abilita subito.
- **Chiavi criteri protette** (`HKCU\Software\Policies`, criteri browser e ADMX): per un utente
  standard erano proposte come applicabili e fallivano in scrittura. Ora vengono verificati i permessi
  senza scrivere nulla e le voci sono marcate `RICHIEDE ADMIN`.
- **Scansione robusta**: un errore di `powercfg` o la lettura negata di una singola chiave
  interrompeva l'intero catalogo (e quindi l'avvio). Ora la voce viene saltata e il resto prosegue.
- **`-ExportCurrentProfile` con percorso relativo**: il file temporaneo veniva risolto rispetto alla
  cartella di PowerShell e lo spostamento rispetto a quella del processo .NET. Ora i percorsi sono risolti
  una sola volta.
- **Comandi esterni** (`powercfg`, `winget show`): con `ErrorActionPreference=Stop` qualsiasi riga su
  stderr diventava un errore fatale in Windows PowerShell 5.1. Ora conta solo il codice di uscita.
- **Migrazione backup v1** (`undo.json`): gestisce correttamente anche un file con un solo record.
- **Raggruppamento delle sessioni**: ogni voce applicata riceveva un proprio `BatchId` (la variabile del
  batch non veniva mai impostata); ora un'applicazione condivide un solo snapshot e un solo `BatchId`.
- **Ripristino multiplo**: un solo file `restore-*.json` per journal invece di uno per voce, ordine dal
  piu recente.
- La GUI richiede un thread STA e lo segnala con un messaggio chiaro invece di un errore WPF.
- Rimossi gli stub del test UI che usavano variabili non definite (`$preserve`, `$choices`).

### Prestazioni (misurate su scansione + 2 aggiornamenti, ambiente simulato)
- Query CIM: 21 -> 3. Parsing dei modelli ADMX: 72 -> 8. Chiamate `powercfg`: 6 -> 3.
- Speed test: l'impronta della configurazione di rete usa i valori gia letti dalla scansione invece di
  interrogare ogni proprieta della scheda una per una (decine di chiamate CIM all'avvio e alla fine).
- Lo stato batteria non viene piu interrogato per ogni proprieta di rete.

### Qualita del codice
- 161 funzioni con nomi Verb-Noun approvati, commenti e sezioni (`#region`); nessuna riga
  "a catena" con `;`. Rimossi 7 componenti morti (~140 righe mai chiamate: vecchi dialoghi Software,
  Funzionalita, Servizi, Recovery, Rimozione app, Diagnostica).
- Catalogo dichiarativo: aggiungere un tweak significa aggiungere una riga di dati.
- Journal espliciti (`$script:UserJournal`, `$script:NetworkJournal`) al posto dello scoping dinamico
  che sostituiva le variabili `$journal`/`$mirror` di nascosto.
- XAML formattato (equivalenza verificata in forma canonica) e controlli indicizzati in `$script:Ui`.
- PSScriptAnalyzer: 194 avvisi -> 0, incluse le regole di compatibilita con Windows PowerShell 5.1
  (sintassi, comandi, tipi .NET).
- Il file si puo caricare con dot-source senza avviare nulla: base della suite Pester (100 test).

### Repository
- Versione corrente nella radice; versioni 1.4 - 2.0 spostate invariate in `archive/`.
  (La radice mostrava ancora la 1.4 e `SHA256SUMS.txt` elencava file inesistenti.)
- README in Markdown, CHANGELOG, CI GitHub Actions (Windows PowerShell 5.1, PowerShell 7, Linux),
  verifica automatica dei checksum, `.gitattributes` per fine riga stabili.

## 2.0 beta
Control Center: catalogo per dispositivo, PWU, filtri combinati, Network Center con speed test
multistream e cronologia, pagina Integrity, profili portabili v2. Vedi `archive/v2.0/README.txt`.

## 1.4 - 1.7 beta
Debloater one-shot, motore di backup v2 in doppia copia, Recovery Center, tweak energia AC, prime
voci di rete. Vedi i README in `archive/`.
