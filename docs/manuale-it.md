# RAYS 1.5.3

Console luci nativa SwiftUI per macOS 14+, ENTTEC ODE MK3 e Ableton Link. Interfaccia italiana, rig di riferimento già preparato, scene house/tech house, banco Club 130–138 e scene personali.

## Uso

Apri **RAYS.app**: cerca automaticamente ENTTEC, console Pro DJ Link e Xone K2. Il rig predefinito è già configurato; **Attiva luci** ricorda la tua scelta anche alla riapertura. Se l’ENTTEC si scollega, l’invio si sospende e riprende automaticamente quando lo stesso dispositivo torna disponibile. **Spegni luci** annulla anche la ripresa automatica. Il blackout resta al buio, anche alla riapertura. Le vecchie preferenze partono in anteprima finché attivi l’uscita una volta; modificare il patch o scegliere un altro nodo disattiva l’uscita.

| Luce | Posizione | Modalità | Indirizzo DMX |
|---|---|---|---|
| Varytec Retro Blinder TRI 180 | Sinistra | 08 CH, Mode DMX | 008 |
| Varytec Retro Blinder TRI 380 | Centro | 25 CH, Mode DMX | 024 |
| Varytec Retro Blinder TRI 180 | Destra | 08 CH, Mode DMX | 016 |

Universo Art-Net **1**, come le due uscite dell’ODE provato. Il display delle lampade va impostato una volta: l’ODE non rileva dispositivi RDM e non può leggere o cambiare questi valori. I vecchi indirizzi 008/015/022 del PDF sovrappongono canali quando le TRI 180 sono in modalità 8 CH: non usarli.

All’avvio il vecchio patch della sola TRI180 A008 viene esteso al rig completo, conservando una copia in `patch.before-full-rig.json`. Patch diversi e personalizzati vengono mantenuti. Le luci mancanti nel patch sono solo un’anteprima e i loro canali non vengono trasmessi.

**Intensità** regola tutta la luminosità, COB compresi. **Energia** controlla movimento, contrasto e accenti della coreografia. Entrambi hanno tooltip. I tre livelli Sinistra/Centro/Destra dosano le singole zone.

Scene nel banco **House**: **Ambra**, **Tramonto**, **Pulse**, **Chase**, **Build**, **Drop**. Il centro usa sei gruppi RGB e tre COB indipendenti, le laterali un gruppo RGB e un COB ciascuna. Nessun programma o strobo interno delle lampade viene attivato. Build e Drop sono scelte dal DJ, senza fingere di riconoscere la struttura del brano.

Il banco **Club 130–138** aggiunge sei coreografie originali per groove più veloci, tutte costruite con tracce modificabili. Si sceglie sopra i sei pulsanti: cambiare banco non avvia una scena e non modifica il BPM della sessione Link. I tasti 1–6 e i pad Xone scelgono le scene del banco visibile; il gesto Build → Drop usa la coppia dello stesso banco. Le modifiche House e Club sono indipendenti, anche sullo stesso tasto. Il banco e l’ultimo BPM interno vengono ricordati; una sessione Link esterna resta la sorgente autorevole.

**Primo beat della scena** (icona ↺ accanto ai quattro battiti, tasto **R**): riparte dal primo passo dell’intero ciclo della scena in esecuzione, anche quando dura più battute e con velocità ¼×, ½× o 2×. Riallinea anche l’indicatore al beat 1. Il BPM e la griglia condivisa Ableton Link restano invariati. La correzione rimane attiva anche con i beat successivi della console, fino a un nuovo riallineamento o alla chiusura dell’app. Non accende le luci e non rimuove il blackout.

**Editor a tutto schermo:** la matita su un preset o una scena personale apre un ambiente dedicato nella stessa finestra. La finestra si allarga; il pulsante Schermo intero entra nella modalità macOS. Salva e Annulla ripristinano le dimensioni precedenti. L’anteprima delle tre luci resta visibile e permette di includere/escludere le destinazioni della traccia.

La **griglia ritmica condivisa** mostra fino a otto tracce su un asse comune. Ogni traccia mantiene passo (1/4, 1/8, 1/16) e ciclo propri; i cicli corti si ripetono e modificare una ripetizione cambia lo stesso passo. “Vista” regola l’intervallo mostrato, “Passo” e “Ciclo” il disegno della traccia selezionata. Clic alterna forte/debole/spento; trascinare dipinge anche le caselle attraversate. Segui mantiene visibile il cursore; sfogliare o disegnare disattiva il seguito automatico.

L’ispettore ha quattro schede: **Luci** (destinazioni, RGB e COB indipendenti, 6 segmenti RGB e 3 COB centrali, movimento, direzione, sfalsamento e colore), **Colpo** (curva con quattro maniglie, attacco/tenuta/rilascio e fondo/picco numerici), **Tempo** (anticipo/ritardo e salita) e **Mix** (più forte/somma, risposta dei colpi deboli all’Energia). Secco/Morbido/Lungo sono scorciatoie per i tempi. I riepiloghi delle altre schede mantengono visibili le impostazioni rilevanti.

**Impostazioni scena** raccoglie nome, palette, energia, velocità, bianco della scena, livelli Sinistra/Centro/Destra e coreografia sottostante. La base è modificabile nelle scene personali; gli slot House e Club rimangono indipendenti. Il ripristino di un preset Club riporta le sue tracce e i suoi colori di fabbrica nella sola bozza, con annulla disponibile.

Le vecchie scene senza tracce si aprono identiche: si sceglie esplicitamente se partire da un modello modificabile (approssimazione dichiarata) oppure aggiungere tracce sopra la coreografia originale. Il formato JSON e gli identificativi non cambiano. **Salva (⌘S)** è l’unico comando che scrive le scene; **Annulla (⌘.)** ripristina il precedente stato del motore. La cronologia conserva fino a 120 modifiche e raggruppa i gesti continui. Esc attiva il blackout e mantiene la bozza. L’editor non accende mai l’uscita: se è già attiva, le modifiche in anteprima raggiungono anche le luci.

Sotto il BPM, la **miniatura della scena** mostra le tracce (o gli inviluppi delle tre luci per le coreografie originali), battuta e cursore in diretta. Usa il tempo della scena realmente in esecuzione, inclusa la velocità del movimento; una scena in attesa non sostituisce prematuramente la struttura visibile. Il clic apre l’editor della scena in esecuzione, indipendentemente dal banco sfogliato. Mostra stato Stop/Blackout. Le etichette musicali descrivono la coreografia: l’app non analizza né riconosce l’audio.

## Xone K2

In Configurazione → Controller, **Disposizione** permette di scegliere **Classica** o **Live v2**. I file MIDI esistenti restano sulla Classica e i controlli personalizzati con Impara hanno sempre la precedenza. La guida mostra le assegnazioni effettive.

**Live v2** mantiene i quattro fader Sinistra/Centro/Destra/Master e le scene A–C / E–G. D sceglie House, H sceglie Club; il cambio banco lascia suonare la scena corrente. I–L e i pulsanti sullo schermo condividono l'ordine **¼× · ½× · 1× · 2×**. M è **Flash** (tieni, massimo 2 s), N riparte dal primo beat dell'intera scena, O annulla solo il lancio ancora in coda, P sfuma con Stop. Il grande tasto inferiore sinistro Layer esegue Build → Drop (tieni/rilascia); il destro Exit commuta Blackout. I due encoder inferiori regolano Energia e Livello Flash, con delta relativi; la pressione degli encoder resta libera. I LED dei due grandi tasti usano i loro indirizzi specifici, non l'offset della matrice.

La barra comandi usa tre colonne allineate: Luminosità generale/Luce calda/Energia sopra Sinistra/Centro/Destra. **Luce calda** regola l'intensità del bianco COB indipendentemente dai colori, non la temperatura colore. Blackout, uscita, Build → Drop, Flash e Stop sono raggruppati sulla destra. Le azioni di navigazione MIDI non sostituiscono la scena mentre è aperta una bozza nell'editor.

La disposizione **Classica** conserva le assegnazioni seguenti:

Preset automatico, riconoscimento del canale MIDI al primo messaggio e Learn per personalizzare. Una sola pagina, **Latching Layers OFF** sulla K2.

- Fader da sinistra: **Sinistra · Centro · Destra · Intensità**.
- Manopola in basso a destra: **Energia**. Quella subito sopra: **livello accento**.
- A/B/C: Ambra/Tramonto/Pulse; E/F/G: Chase/Build/Drop.
- **H: tieni Build, rilascia Drop**. Il rilascio sul primo battito non rimanda il drop di un’intera battuta.
- D: Stop con sfumatura; I/J/K/L: velocità ¼× / ½× / 1× / 2×.
- M: accento bianco caldo momentaneo, massimo 2 s; P: blackout.
- LED ambra: anteprima o in attesa; verde: scena realmente in uscita; rosso: blackout.

I fader usano soft takeover: si attivano raggiungendo il valore sullo schermo. Gli encoder infiniti usano delta relativi, così 127 significa un passo indietro, non piena intensità. Scelta scena, Learn e collegamento controller non armano l’uscita.

## Rete e tempo

Durante l’uscita luci attiva (anche in blackout o in attesa di riconnessione), RAYS impedisce lo stop automatico del Mac e App Nap usando l’attività di sistema di Foundation. Lo schermo può spegnersi e l’invio DMX continua. Spegnendo l’uscita o chiudendo l’app, la protezione viene rilasciata. Le impostazioni energetiche del Mac non vengono modificate; lo stop esplicito e la chiusura del coperchio restano gestiti da macOS.

Con un solo adattatore Ethernet attivo la preparazione avviene automaticamente, dopo il primo tentativo di scoperta. Se serve, macOS richiede l’autorizzazione amministratore per aggiungere **solo** l’indirizzo temporaneo 192.168.0.20/24. DHCP, Wi-Fi, DNS e gateway restano invariati. Nessun indirizzo viene aggiunto se la sottorete è già occupata su un’altra interfaccia. La scheda Rete può rimuovere l’alias dell’app. Dopo un riavvio del Mac l’alias temporaneo può richiedere nuovamente l’autorizzazione macOS.

Collega Mac, ODE e console allo switch; uno switch Ethernet normale non richiede configurazione. Con più adattatori Ethernet attivi scegli quello corretto in Rete. La console e il Mac possono mantenere anche gli indirizzi automatici 169.254.x.x, necessari su una rete senza DHCP.

**Automatico** usa la libreria Beat Link inclusa: DeviceFinder rileva le console, VirtualCdj riceve lo stato e BeatFinder riceve i battiti. Solo battiti recenti del deck master in riproduzione alimentano BPM e fase del vero SDK Ableton Link. Il componente non chiede di diventare master, non avvia brani e non usa metadati online. **Solo Link** disabilita il componente console; un deck manuale è disponibile come override. In assenza di console il tempo continua con Link o localmente. Non è necessario aprire Beat Link Trigger o Carabiner.

Il runtime headless incluso proviene dalla copia locale di Beat Link Trigger 7.4.1 (Beat Link 7.4.0). Il file originale in Applicazioni non viene modificato. Un conflitto sulle porte Pro DJ Link viene segnalato: chiudi eventuali altre applicazioni che le occupano. Il componente termina con l’app e ritenta dopo errori di avvio.

## Verifiche e limiti hardware

Provati fisicamente Mac → ODE MK3 → TRI180 08CH A008: rosso fisso confermato dall’utente, lettura buffer DMX delle due uscite e blackout. Provato anche lo switch con Mac+ODE: ODE raggiungibile e Internet HTTPS via Wi-Fi funzionante.

Console XDJ-XZ, cambio master, Xone K2 e rig completo restano da provare insieme quando collegati. Il componente Beat Link si avvia in circa 0,8 s senza console; testati errore porta occupata e chiusura con il processo padre. La preview è un modello vettoriale delle facce triangolari a specchio e delle strisce COB, con valori decodificati dagli stessi byte DMX. Non è una simulazione fotometrica; l’ordine fisico dei sei segmenti centrali richiede verifica sulla TRI380.

Scorciatoie: Esc blackout; B alterna blackout; Spazio uscita luci; 1–6 scene; R imposta il primo beat; ⌘. annulla l’editor o chiude Configurazione. In Configurazione → Luci ci sono prove rosso/bianco di 5 secondi.

## Sviluppo

```sh
swift test
Scripts/build-app.sh
```

Swift 6.2 / Xcode, linguaggio Swift 5.10. Il bundle firmato ad hoc viene creato in `dist/RAYS.app`, con icona, SDK Link, componente Beat Link autosufficiente e licenze. La build non cambia impostazioni di rete e non scarica dipendenze. Per creare una copia senza toccare l’app aperta: `LIGHT_SYSTEM_DIST="$PWD/dist-next" Scripts/build-app.sh`. Lo script rifiuta di sovrascrivere il bundle in uso. Richiede `Vendor/link` (con ASIO) e `Vendor/BeatLinkHelper` già presenti.

I moduli `RaysOutput` (Art-Net), `RaysTempo` (tempo), `RaysCore` (patch, DMX, coreografie, sequencer, scene personali), `RaysControl` (MIDI router e layout controller) e `RaysEngine` (motore e configurazione) sono solo Foundation e coperti da test. `LightEngine` lavora su coda seriale a 30 Hz. La preview decodifica gli stessi universi composti per l’uscita; blackout e master zero includono tutti i COB. Il sequencer gestisce fasi negative, salti della timeline, cambi scena e dissolvenze. `LinkBridge` usa l’SDK ufficiale Ableton. `Sources/BeatLinkHelper/LightSystemBeatLink.java` è l’adattatore headless al Beat Link reale; non carica Clojure durante l’uso. Il compilatore Java incluso nel runtime viene usato solo durante la build.

Configurazioni JSON atomiche in `~/Library/Application Support/Light System/`: patch, preferenze, show, MIDI e scene personali. Un file scene personali illeggibile non viene sovrascritto automaticamente.

## Fonti e licenze

- [TRI180, manuale ufficiale](https://images.thomann.de/pics/atg/atgdata/document/manual/585812_c_585812_en_online.pdf)
- [TRI380, manuale ufficiale](https://images.thomann.de/pics/atg/atgdata/document/manual/585819_c_585819_en_online.pdf)
- [Xone K2, manuale Allen & Heath](https://www.allen-heath.com/content/uploads/2023/06/XoneK2_UG_AP8509_3.pdf)
- [ENTTEC ODE MK3](https://support.enttec.com/user-manuals/ode-mk3)
- [Ableton Link](https://github.com/Ableton/link)
- [Beat Link](https://github.com/Deep-Symmetry/beat-link), [Beat Link Trigger](https://github.com/Deep-Symmetry/beat-link-trigger)

Build privata locale. Ableton Link è GPLv2+; ASIO Boost Software License. Beat Link/BLT e dipendenze conservano licenze e avvisi originali, estratti dal jar; runtime Java con cartella legal originale. Vedi `Vendor/BeatLinkHelper/Licenses/PROVENANCE.txt` e `Contents/Resources/Licenses` nel bundle. Per redistribuire occorre conservare licenze e fornire i sorgenti corrispondenti secondo le licenze applicabili, oppure ottenere una licenza commerciale Link da Ableton. Le foto prodotto sono solo riferimenti di ricerca e non sono incluse nell’interfaccia.

Revisione prestazioni1.1.1: preview CoreGraphics con geometrie e aloni riutilizzati, controlli velocità leggeri e consegna alla UI del solo fotogramma più recente. Il DMX resta a30Hz.

Controlli luminosità1.1.3: “Luminosità generale” limita insieme RGB e COB; “Bianco COB” regola soltanto il bianco caldo, anche durante gli accenti. Energia modella il ritmo e il contrasto, senza applicare un secondo dimmer globale. I picchi RGB e COB delle sei scene possono raggiungere255 a master100% anche a energia0/50/100%; i respiri e le pause rimangono musicali. Le palette vengono trattate come tinte a valore pieno; il nero rimane spento. I livelli di zona e il bianco della scena personale continuano ad applicarsi. All'apertura di una seconda copia viene portata in primo piano la precedente senza aprire un'altra portaDMX.

Prestazioni 1.5.1: fotogrammi consegnati direttamente alle viste AppKit; cursori come piccoli layer senza ridisegnare la matrice, navigazione separata dall’ispettore e ridisegni sospesi quando la finestra non è visibile. Motore, Link, beat e MIDI continuano alla cadenza originale. Aspetto della preview e dati delle scene conservati. Riferimento minimo richiesto: Mac M1 con 8 GB; le misure locali non sostituiscono una prova su quell’hardware.

Interazioni editor (dopo 1.5.1): l’editor si impagina con dimensioni esatte e ogni pannello osserva solo ciò che mostra, quindi slider, selezione tracce e pagine non ricalcolano più l’intera finestra; apertura e chiusura dell’editor animano la finestra sopra un contenuto già impaginato alla misura finale; le anteprime non riscrivono stato invariato e il motore decide da sé se rilanciare una scena ferma. Preview, motore, DMX, Link e dati invariati. Misurato in un harness isolato su M3 Max, non su M1.
