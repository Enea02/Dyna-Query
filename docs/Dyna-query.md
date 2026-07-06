# DYNA QUERY STUDIO — Revisione Tecnica v1.1

**Integrazione allo Studio di Fattibilità v1.0**
Motore di query dinamiche per Business Central Online

**DSC Group Srl** · Data: 5 Luglio 2026
Destinatari: Sviluppatori AL senior, Team Tecnico DSC, Product Owner DynaSupport
Obiettivo: consolidare le scelte tecniche della v1.0 alla luce delle best practice ufficiali Microsoft (Microsoft Learn) e rendere concreti i meccanismi AL che la v1.0 descrive solo a livello concettuale.

---

## 0. Come leggere questo documento

Questa revisione **non sostituisce** lo Studio di Fattibilità v1.0: lo integra. Ogni punto è agganciato alla sezione originale che aggiorna. Il verdetto complessivo resta **GO**: l'architettura proposta è allineata alle raccomandazioni Microsoft. Gli interventi qui descritti riducono i rischi residui (locking, sicurezza, integrità audit) e rendono il progetto direttamente implementabile senza scelte tecniche lasciate aperte.

Legenda:
- ✅ **Confermato** — la scelta v1.0 è già best practice, nessuna modifica.
- 🔧 **Da integrare** — la scelta v1.0 è corretta ma va resa concreta con un meccanismo AL specifico.
- ⚠️ **Attenzione** — vincolo non affrontato nella v1.0 che impatta il design.

---

## 1. Ciò che la v1.0 ha già centrato (confermato dalle fonti ufficiali)

| Scelta v1.0 | Stato | Riferimento Microsoft Learn |
| --- | --- | --- |
| Equi-join con push-down della chiave come `SetRange` sul record interno | ✅ Confermato | *Table Keys and Performance* — definire la chiave corretta e specificarla nel codice è la leva primaria di performance |
| `SetLoadFields` sui soli campi proiettati/usati nel join | ✅ Confermato | *Using partial records* — carica solo i campi necessari; guadagni fino a 9× su loop, si moltiplicano sulle righe |
| Join sempre read-only; scrittura solo su sorgente singola per chiave | ✅ Confermato | Coerente con la separazione read/write raccomandata; abilita esecuzione async (§3) |
| Buffer risultato materializzato, separato dall'iterazione | ✅ Confermato | Consente ordinamento/raggruppamento in un secondo passaggio senza tenere aperti i RecordRef |
| Sottoinsieme SQL con errori espliciti sui costrutti non supportati | ✅ Confermato | *AL error handling* — errori chiari e azionabili sono raccomandati |
| Risoluzione tabelle/campi via metadati AL, non nomi fisici | ✅ Confermato | I nomi fisici SQL non sono stabili tra versioni; l'accesso diretto a SQL non è supportato |

**Conclusione della sezione:** nessuna delle scelte fondanti va rivista. Le modifiche seguenti sono additive.

---

## 2. Sicurezza: dal concetto al meccanismo (aggiorna §8 e §5.2)

La v1.0 afferma correttamente "esecuzione sotto i permessi utente" ma non nomina il meccanismo AL. Senza il meccanismo esplicito, il motore **non filtra** per sicurezza e, peggio, **va in runtime error** quando incontra un record fuori dal security filter dell'utente.

🔧 **Da integrare — tre primitive obbligatorie prima di ogni lettura:**

1. **`RecordRef.ReadPermission()`** — verifica preventiva che l'utente possa leggere la tabella. Se `false`, la sorgente è rifiutata dal Validator con errore chiaro, *prima* di iniziare l'iterazione.
2. **`RecordRef.SetPermissionFilter()`** — applica il security filter dell'utente al RecordRef, combinandolo con i filtri WHERE. Impedisce sia la lettura di righe fuori ambito, sia il runtime error che altrimenti si verifica leggendo un record fuori dal range di sicurezza.
3. **`RecordRef.SecurityFiltering(SecurityFilter::Filtered)`** — governa *come* i security filter vengono applicati; da impostare esplicitamente per non dipendere dal default.

```al
// Pattern: apertura sicura di una sorgente (Join Engine / Validator)
procedure OpenSourceSecure(TableNo: Integer; var SourceRef: RecordRef)
begin
    SourceRef.Open(TableNo);
    if not SourceRef.ReadPermission() then
        Error(NoReadPermissionErr, SourceRef.Caption);   // rifiuto esplicito
    SourceRef.SecurityFiltering(SecurityFilter::Filtered);
    SourceRef.SetPermissionFilter();                      // no runtime error, righe fuori ambito escluse
end;
```

⚠️ **Attenzione — scope Cloud vs OnPrem.** Un'estensione con target `Cloud` **non può** usare RecordRef su tabelle con scope `OnPrem`. Il Validator (Codeunit 50102) deve quindi rifiutare una sorgente per **due** motivi distinti — permesso mancante *e* scope incompatibile — con messaggi differenti. La v1.0 considera solo il primo.

---

## 3. Modello di esecuzione: sincrono vs asincrono (nuova sezione, impatta §4, §7.1, §11)

La v1.0 non specifica **dove gira** il motore. È la decisione architetturale mancante più importante, perché determina se l'UI si blocca durante una query pesante e se la query è cancellabile.

### 3.1 Il vincolo del Page Background Task (PBT)

Il PBT è il candidato naturale per l'esecuzione read-only, ma ha tre vincoli che ne definiscono l'uso:

- È **sola lettura**: non può scrivere né lockare il database.
- Ha **timeout massimo di 10 minuti** (default inferiore, configurabile lato server).
- Restituisce risultati **solo come `Dictionary<Text,Text>`** e gira in sessione figlia isolata: **non condivide le tabelle temporanee** con la sessione padre.
- Viene **cancellato automaticamente** se la pagina si chiude o cambia il record corrente — ottimo per la sicurezza, ma da gestire.
- Soggetto a **limiti operativi** su BC Online (numero di sessioni figlie concorrenti).

### 3.2 Conseguenza sul Result Buffer (aggiorna §6.5)

⚠️ Poiché il PBT è read-only e le tabelle temporanee sono *per-sessione*, **un PBT non può popolare un buffer temporaneo che la pagina padre poi legge**. Questo obbliga a scegliere il modello di buffer in funzione del modello di esecuzione:

| Modello di esecuzione | Buffer risultato | Pro | Contro |
| --- | --- | --- | --- |
| **Foreground** (sessione utente) | Temporanea (come v1.0) | Semplice, isolato, nessun cleanup | Blocca l'UI; soggetto ai limiti di durata query |
| **Page Background Task** | Solo `Dictionary` di ritorno | UI reattiva, cancellabile, auto-pulito | Adatto solo a risultati piccoli o a stime/conteggi |
| **`StartSession` background** | **Persistente**, taggata per `Run ID` + `User ID` | Può scrivere, gestisce set grandi | Va pulita a fine consumo; consuma limiti operativi; non auto-cancellata |

### 3.3 Design raccomandato: modello ibrido

🔧 **Da integrare:**

- **Pre-flight (stima righe + avviso cartesiano)** → **Page Background Task**. È esattamente lo scenario read-only, leggero e cancellabile descritto in §7.1 della v1.0. La stima gira in background mentre l'utente resta libero, e il risultato (conteggio + flag rischio) torna nel `Dictionary`.
- **Materializzazione del set completo** → **foreground** per i set entro il row cap prudente, oppure **`StartSession`** con **buffer persistente run-scoped** per i set grandi con export. In questo caso il Result Buffer (§6.5) **non è più `Temporary`**: diventa una tabella reale con chiave `Run ID, Row No.` e pulizia a fine sessione/consumo.
- **Write-back** → **sempre foreground**: il PBT non può scrivere (coerente con §5.6, che già isola la scrittura).

```al
// Pre-flight: stima e avviso cartesiano in Page Background Task (read-only, cancellabile)
CurrPage.EnqueueBackgroundTask(EstimateTaskId, Codeunit::"DSC QS Estimate Task", Params, 60000,
                               PageBackgroundTaskErrorLevel::Warning);
// ... OnPageBackgroundTaskCompleted riceve {"rowEstimate":"...", "cartesianRisk":"true|false"}
```

---

## 4. Motore di join: raffinamenti al pattern (aggiorna §5.2 e §5.3)

✅ Il nested-loop equi-join della v1.0 è corretto. Tre raffinamenti:

🔧 **4.1 `SetCurrentKey` esplicito sulla chiave di join.** Il push-down `SetRange` sfrutta l'indice solo se la chiave interna è allineata. Il motore deve chiamare `SetCurrentKey` sui campi di join prima dell'iterazione interna; il Validator, che già (correttamente, §5.3) avvisa se la condizione non è coperta da indice, deve suggerire la chiave da usare.

🔧 **4.2 Read isolation per non impattare la produzione.** Trattandosi di letture diagnostiche read-only su tabelle vive, impostare un livello di isolamento basso riduce lock e blocchi reciproci con l'operatività:

```al
OuterRef.ReadIsolation(IsolationLevel::ReadUncommitted); // o ReadCommitted se serve coerenza
```

🔧 **4.3 `FieldIndex` invece di `Field` in `EmitRow`.** In un loop che proietta molte colonne per molte righe, `RecordRef.FieldIndex(...)` è più performante di `RecordRef.Field(...)` per l'accesso ripetuto ai FieldRef. Microstruttura, ma su set grandi conta.

---

## 5. Aggregazioni: GROUP BY con Dictionary (aggiorna §5.4)

La v1.0 descrive il GROUP BY come "ordina il buffer e collassa le righe con stessa chiave". Funziona, ma è un ordinamento O(n log n) più una scansione.

🔧 **Da integrare — accumulo O(1) con `Dictionary`.** Microsoft raccomanda esplicitamente il tipo `Dictionary` quando serve una struttura chiave-valore ottimizzata per lookup veloci, al posto di una tabella temporanea. Per il GROUP BY:

- Chiave del dizionario = concatenazione ordinata delle colonne di raggruppamento.
- Valore = accumulatori per gruppo (Sum, Count, Min, Max, e coppia sum/count per l'Avg).
- L'`ORDER BY` finale si applica una sola volta sul set aggregato, molto più piccolo dell'input.

Questo elimina l'ordinamento dell'intero buffer grezzo: si ordina solo il risultato aggregato.

---

## 6. Scrittura e partial records: il caveat mancante (aggiorna §5.6)

✅ Il drill-through a tabella singola per chiave primaria è la scelta giusta.

⚠️ **Attenzione — non applicare partial records al percorso di scrittura.** Microsoft avverte che i partial records **non** vanno usati su record destinati a insert, delete, rename, transfer di campi o copia su temporanea: tutte queste operazioni richiedono il caricamento di *tutti* i campi, quindi il runtime emette un JIT load il cui costo supera il guadagno.

Regola operativa per il motore:
- **Percorso di lettura (join, proiezione)** → `SetLoadFields` aggressivo. ✅
- **Percorso di write-back (drill-through modify/delete)** → caricare il record **completo** (nessun `SetLoadFields`, o `SetLoadFields()` senza argomenti per il reset). 🔧

---

## 7. Audit e telemetria: integrità sotto rollback (aggiorna §6.6 e §8)

✅ L'audit log su tabella immutabile è corretto per la tracciabilità di business.

⚠️ **Attenzione — l'audit non deve condividere la transazione della scrittura.** Se un write-back fallisce e fa rollback, un'entry di audit scritta nella stessa transazione **rotola indietro con esso**: si perde la traccia proprio dell'operazione andata male. Microsoft indica due strade per loggare dentro una transazione che può fare rollback: **una nuova sessione** (`StartSession`) oppure la **telemetria**.

🔧 **Da integrare:**

- **Audit di business (chi/cosa/quando/chiave)** → scrittura su tabella `DSC QS Audit Log` tramite `StartSession` dedicata, così l'entry sopravvive al rollback dell'operazione di dati. Campo `Entry No.` come `AutoIncrement` per evitare contese sul progressivo.
- **Diagnostica tecnica (durata, errori, SQL lento)** → emissione in **telemetria** con `Session.LogMessage` / `Telemetry.LogError` verso Application Insights. Questo abilita anche il punto §8 seguente.

---

## 8. Validazione delle prestazioni come test di prima classe (aggiorna §9 e §11)

La v1.0 raccomanda giustamente il benchmark del join dalla Fase 3. Microsoft offre segnali di telemetria pronti da usare come criterio oggettivo, senza strumentazione custom:

🔧 **Da integrare nel piano di test:**
- **Long running AL method telemetry** — durata dei metodi AL, con breakdown per subscriber; individua il codice lento.
- **Long running SQL query telemetry** — l'`sqlStatement` effettivo e il suo `executionTime`; verifica che il push-down produca davvero un seek e non una scansione.

Criterio di accettazione Fase 3 (proposto): sulla relazione testata→righe di riferimento, l'`executionTime` del join interno resta sotto la soglia di long-running e non compaiono scansioni complete sulla tabella interna in telemetria.

---

## 9. Query object come fast-path opzionale (aggiorna §3, nota di prodotto)

La v1.0 esclude correttamente i Query object come motore, perché sono compilati a design-time e non consentono join arbitrari a runtime. Resta però vero che, dove la forma del join è nota e la query è read-heavy, un Query object è nettamente più veloce: bypassa l'API record (il server non legge tutti i campi) e, con un covering index, dà letture rapide anche su tabelle con molti campi — al prezzo di nessuna scrittura e nessuna struttura dinamica.

💡 **Ottimizzazione futura (non MVP):** per le **query salvate più usate** (Fase 7), il sistema potrebbe generare/mappare un Query object compilato come percorso rapido, mantenendo il motore nested-loop come default dinamico. Da valutare solo dopo che motore e IR sono stabili.

---

## 10. Checklist di modifiche al documento v1.0

| # | Sezione v1.0 | Modifica | Priorità |
| --- | --- | --- | --- |
| 1 | §8, §5.2 | Nominare `ReadPermission` + `SetPermissionFilter` + `SecurityFiltering` come meccanismo di sicurezza | Alta |
| 2 | §5.2 (Validator) | Rifiuto sorgente anche per scope Cloud/OnPrem incompatibile | Alta |
| 3 | §4, §7.1, §6.5 | Definire il modello di esecuzione (ibrido: PBT per stima, foreground/StartSession per materializzazione) e adeguare il Result Buffer (temp vs persistente run-scoped) | Alta |
| 4 | §6.6, §8 | Audit via `StartSession` + telemetria, per sopravvivere al rollback | Alta |
| 5 | §5.6 | Caveat: nessun partial record sul percorso di write-back | Media |
| 6 | §5.4 | GROUP BY con `Dictionary` invece di ordina-e-collassa | Media |
| 7 | §5.2/§5.3 | `SetCurrentKey` sulla chiave di join, `ReadIsolation` basso, `FieldIndex` in EmitRow | Media |
| 8 | §9, §11 | Criteri di accettazione performance basati su telemetria long-running AL/SQL | Media |
| 9 | §3 | Query object come fast-path opzionale per query salvate (post-MVP) | Bassa |

---

## 11. Impatto sulle stime (aggiorna §9)

Gli interventi ad alta priorità sono per lo più **precisazioni di design**, non nuove funzionalità: incidono sulle ore in modo contenuto perché sostituiscono decisioni che andavano comunque prese.

- Sicurezza concreta (§2) e audit resiliente (§7): assorbiti dentro Fase 6, +0,5–1 giorno.
- Modello di esecuzione ibrido (§3): incide su Fase 2 e Fase 3; il buffer persistente run-scoped aggiunge ~1–2 giorni rispetto al solo buffer temporaneo.
- GROUP BY con Dictionary, read isolation, FieldIndex (§4–§5): dentro le rispettive fasi, impatto trascurabile.

**Stima aggiornata Fasi 1–6:** da 19–27 a **21–30 giorni** lavorativi, con il delta concentrato sul modello di esecuzione e sul buffer persistente. Il resto è riduzione di rischio a costo quasi nullo.

---

## 12. Raccomandazione finale

**GO confermato.** La v1.0 era già solida; questa revisione ne chiude le tre aree lasciate implicite — sicurezza, modello di esecuzione, integrità dell'audit — con meccanismi AL ufficiali e verificati. Nessun elemento emerso dalle fonti Microsoft mette in discussione la fattibilità: al contrario, gli strumenti citati (partial records, security filter, page background task, telemetria) esistono proprio per casi d'uso come questo. Procedere con l'MVP stretto raccomandato in §12.2 della v1.0, incorporando le modifiche ad alta priorità della checklist §10.

---

### Appendice — Riferimenti Microsoft Learn consultati

- Using partial records — `dev-itpro/developer/devenv-partial-records`
- RecordRef.SetLoadFields / AddLoadFields / LoadFields — `methods-auto/recordref/*`
- RecordRef.SetPermissionFilter / SecurityFiltering / ReadPermission / ReadIsolation — `methods-auto/recordref/*`
- Using Security Filters in Business Central — `security/security-filters`
- Performance articles for developers — `performance/performance-developer`
- Table Keys and Performance — `administration/optimize-sql-table-keys-and-performance`
- Page Background Tasks — `developer/devenv-page-background-tasks`
- Asynchronous processing overview / Operational Limits Online — `developer/devenv-async-overview`
- AL error handling — `developer/devenv-al-error-handling`
- Analyzing long running AL methods / SQL query telemetry — `administration/telemetry-*`
- Query Objects and Performance — `administration/optimize-sql-query-objects-and-performance`

---

## Allegato A — Spike di validazione performance (Fase 0)

**Obiettivo.** Sciogliere il rischio esistenziale del §1 (il tetto del nested-loop su `RecordRef`) **prima** di impegnare le 21–30 giornate. Si misura la *stessa* relazione con tre strategie di join, su Sandbox con dati a dimensioni di produzione, leggendo la telemetria *Long running SQL query* / *Long running AL method* in Application Insights.

Relazione di test: **Customer** (outer) ⨝ **Cust. Ledger Entry** (inner) su `Customer No.`, con finestra su `Posting Date`.

| Variante | Strategia | Costo atteso | Cosa dimostra |
| --- | --- | --- | --- |
| **A** | nested-loop RecordRef **senza** `SetCurrentKey` | O(N·M) scan interno | baseline peggiore |
| **B** | nested-loop RecordRef **con** chiave coprente + `SetLoadFields` | N seek | il dinamico è viabile entro un row-cap? |
| **C** | **Query object** (join SQL nativo) | 1 statement server-side | il fast-path §9 |

Oggetti (dentro il range 50100–50149):

### A.1 Chiave coprente — pattern quando manca (tableextension)

```al
tableextension 50120 "DQ Cust. Ledger Entry Ext" extends "Cust. Ledger Entry"
{
    keys
    {
        key(DQ_CustomerPostingDate; "Customer No.", "Posting Date")
        {
            IncludedFields = Amount; // covering index: il seek restituisce Amount senza key-lookup
        }
    }
}
```

> ⚠️ In BC standard `Cust. Ledger Entry` ha **già** una chiave `Customer No.,Posting Date`: se esiste, questa tableextension darà errore di duplicato — usala solo come *pattern* per tabelle dove la chiave manca. Per la CLE, la variante B fa direttamente `SetCurrentKey` sulla chiave esistente. È esattamente il messaggio del §4.1: **sfrutta prima le chiavi esistenti**, aggiungi solo quelle mancanti.

### A.2 Query object (variante C)

```al
query 50131 "DQ Perf Join"
{
    QueryType = Normal;

    elements
    {
        dataitem(Cust; Customer)
        {
            column(Customer_No; "No.") { }

            dataitem(CLE; "Cust. Ledger Entry")
            {
                DataItemLink = "Customer No." = Cust."No.";
                SqlJoinType = InnerJoin;

                column(Posting_Date; "Posting Date") { }
                column(Amount; Amount) { } // niente Method=Sum: confronto sui detail row, come A/B
            }
        }
    }
}
```

### A.3 Runner + misura in telemetria (variante A, B, C)

```al
codeunit 50130 "DQ Perf Spike"
{
    // Esegui su Sandbox (es. via action temporanea, vedi A.4) e confronta dq_ms in App Insights.
    trigger OnRun()
    begin
        FromDate := CalcDate('<-1Y>', Today()); // finestra di test
        ToDate := Today();
        VariantA_NoKey();
        VariantB_CoveringKey();
        VariantC_Query();
    end;

    var
        FromDate: Date;
        ToDate: Date;

    // --- A: nested-loop SENZA SetCurrentKey (scan interno) ---
    local procedure VariantA_NoKey()
    var
        Customer: Record Customer;
        CLE: Record "Cust. Ledger Entry";
        StartAt: DateTime;
        Rows: Integer;
        Total: Decimal;
    begin
        StartAt := CurrentDateTime();
        if Customer.FindSet() then
            repeat
                CLE.Reset();
                CLE.SetRange("Customer No.", Customer."No.");
                CLE.SetRange("Posting Date", FromDate, ToDate);
                if CLE.FindSet() then
                    repeat
                        Rows += 1;
                        Total += CLE.Amount;
                    until CLE.Next() = 0;
            until Customer.Next() = 0;
        LogResult('A-nokey', Rows, StartAt);
    end;

    // --- B: nested-loop CON chiave coprente + SetLoadFields (index seek) ---
    local procedure VariantB_CoveringKey()
    var
        Customer: Record Customer;
        CLE: Record "Cust. Ledger Entry";
        StartAt: DateTime;
        Rows: Integer;
        Total: Decimal;
    begin
        StartAt := CurrentDateTime();
        Customer.SetLoadFields("No.");
        if Customer.FindSet() then
            repeat
                CLE.Reset();
                CLE.SetCurrentKey("Customer No.", "Posting Date"); // chiave esistente o DQ (A.1)
                CLE.SetLoadFields(Amount);                          // covering: niente key-lookup
                CLE.SetRange("Customer No.", Customer."No.");
                CLE.SetRange("Posting Date", FromDate, ToDate);
                if CLE.FindSet() then
                    repeat
                        Rows += 1;
                        Total += CLE.Amount;
                    until CLE.Next() = 0;
            until Customer.Next() = 0;
        LogResult('B-coveringkey', Rows, StartAt);
    end;

    // --- C: Query object (join SQL nativo server-side) ---
    local procedure VariantC_Query()
    var
        DQJoin: Query "DQ Perf Join";
        StartAt: DateTime;
        Rows: Integer;
        Total: Decimal;
    begin
        StartAt := CurrentDateTime();
        DQJoin.SetRange(Posting_Date, FromDate, ToDate);
        DQJoin.Open();
        while DQJoin.Read() do begin
            Rows += 1;
            Total += DQJoin.Amount;
        end;
        DQJoin.Close();
        LogResult('C-query', Rows, StartAt);
    end;

    local procedure LogResult(Variant: Text; Rows: Integer; StartAt: DateTime)
    var
        Dim: Dictionary of [Text, Text];
        Elapsed: Duration;
        Ms: Integer;
    begin
        Elapsed := CurrentDateTime() - StartAt;
        Ms := Elapsed; // Duration -> millisecondi
        Dim.Add('dq_variant', Variant);
        Dim.Add('dq_rows', Format(Rows));
        Dim.Add('dq_ms', Format(Ms));
        Session.LogMessage('DQ0001',
            StrSubstNo('DynaQuery spike %1: %2 righe in %3 ms', Variant, Rows, Ms),
            Verbosity::Normal, DataClassification::SystemMetadata,
            TelemetryScope::ExtensionPublisher, Dim);
    end;
}
```

### A.4 Come eseguire (action temporanea, solo dev)

```al
pageextension 50121 "DQ Spike Launcher" extends "Customer List"
{
    actions
    {
        addfirst(Processing)
        {
            action(DQRunSpike)
            {
                Caption = 'DQ · Run perf spike';
                ApplicationArea = All;
                Image = Sparkle;
                trigger OnAction()
                begin
                    Codeunit.Run(Codeunit::"DQ Perf Spike");
                end;
            }
        }
    }
}
```

### A.5 Cosa leggere in telemetria

- **Custom dimensions** dei messaggi `DQ0001`: confronta `dq_ms` fra `A-nokey`, `B-coveringkey`, `C-query` a parità di `dq_rows`.
- **Long running SQL query**: verifica che B/C producano un **seek** (non un table scan) sulla tabella interna, e leggi `executionTime` dell'`sqlStatement`.
- **Long running AL method**: durata di `VariantA/B/C_*` per il breakdown lato AL.

### A.6 Criteri di accettazione → decisione

- **B ≪ A** e B sotto la soglia long-running entro un row-cap ragionevole → il **motore dinamico è viabile** per l'ad-hoc coperto da chiave; la cache materializzata (Idea 1) **non serve**.
- **C ≪ B** (atteso) → conferma il **fast-path Query object** per le query salvate (§9).
- **Nemmeno B basta** sui volumi reali → anticipare il Query-object fast-path dal post-MVP all'**MVP**, e ridiscutere §3/§9.