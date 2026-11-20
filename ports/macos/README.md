# Meeting Recorder til Mac

Første testversion til Apple Silicon med macOS 13 eller nyere. Appen optager den valgte standardmikrofon og Mac’ens afspillede lyd som to lokale WAV-filer. Efter stop skriver appen en lokal transskription med tidskoder og talernumre i mødemappen.

1. Afslut en tidligere version med **⌘Q**. Åbn diskbilledet, træk **Meeting Recorder** over på **Applications (Programmer)**, og vælg **Erstat**, hvis Finder spørger. Åbn derefter **Programmer → Meeting Recorder**.
2. Vælg **Start optagelse**. Giv adgang til mikrofonen og til **Skærm- og systemlydoptagelse** i macOS. Tryk **Start optagelse** igen efter godkendelsen. Hvis macOS beder om genstart af appen, så afslut den med **⌘Q** og åbn samme kopi igen.
3. Brug gerne et headset til første prøve. Tal i mikrofonen, og afspil lyd i en anden app. De to målere viser, hvilken kilde der leverer signal.
4. Vælg **Stop optagelse → Vis seneste optagelse**. Afspil `Mikrofon.wav` og `Systemlyd.wav` hver for sig. Optagelser ligger under `~/Music/Meeting Recorder/` i en mappe pr. optagelse.

**Hvis tilladelsen står til, men optagelse bliver afvist:** Brug **Vis app i Finder** til at se den kørende kopi. Finder kan have døbt en ekstra kopi `Meeting Recorder 2.app`. Afslut alle åbne kopier, og brug appen i Programmer. Hvis problemet fortsætter, fjern kun Meeting Recorders gamle post under **Skærm- og systemlydoptagelse**, tilføj `/Applications/Meeting Recorder.app` med **+**, slå adgangen til og åbn appen igen. Behandling af eksisterende optagelser kræver ingen optagelsestilladelser.

Bygget er ad hoc-signeret. Hvis macOS blokerer en downloadet testversion, kan du efter første åbningsforsøg godkende denne app under **Systemindstillinger → Anonymitet & sikkerhed → Åbn alligevel**. [Apples vejledning](https://support.apple.com/da-dk/102445)

Efter en vellykket optagelse starter transskriptionen automatisk. **Åbn transskription** åbner `Transskription.md`. Vælg **Transskriber tidligere optagelse…** for at behandle en optagelse fra den første Mac-version eller prøve igen efter en afbrydelse. En færdig transskription udskiftes først, når det nye resultat er gemt.

Første kørsel henter ca. 607 MB modeldata til `~/Library/Application Support/Meeting Recorder/Models` og kontrollerer SHA-256. Senere kørsler virker offline. I lokal tilstand bliver begge WAV-filer på din Mac. Parakeet Ultra understøtter bl.a. dansk. Nemotron 3 Diarization følger op til otte stemmer på hvert spor. Talernumrene gælder inden for det enkelte spor og møde. Overlappende tale eller lyd fra højttalere i mikrofonen kan give fejl i talerfordelingen. [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) · [Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization)

Med Xcode Command Line Tools, stabil Rust, CMake og Python 3 på macOS kan du bygge fra repository-roden med `ports/macos/build.sh`. Den færdige app og zip-fil ligger i `dist/macos/`.

### Azure Foundry

Vælg **Azure Foundry**, indtast navnet på en Azure Speech-/Foundry-ressource i en region med MAI-Transcribe-2 og indsæt ressourcens Speech-nøgle. Brug selve ressourcenavnet fra `https://<navn>.cognitiveservices.azure.com`. Valget gælder for optagelse eller filvalg i denne app-session. Appen starter i lokal tilstand, husker ressourcenavnet og holder nøglen i hukommelsen.

Azure-tilstanden sender de to spor som separate monooptagelser på 16 kHz til din ressource via HTTPS. Tavse spor springes over. Anmodningerne kører samtidigt og kan faktureres hver for sig. MAI-Transcribe-2 registrerer sprog og talere, og appen samler svarene i `Transskription-Azure.md`. Du kan sammenligne filen med den lokale `Transskription.md`. Azure kan give en fordel på en Mac med begrænset regnekraft. Samlet tid afhænger bl.a. af uploadhastighed, region og Azure-kvote. Lange optagelser skal overholde tjenestens fil- og varighedsgrænser. Hvis en anmodning fejler, kan du vælge lokal behandling og åbne mødemappen igen. [Model, regioner og opsætning](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe)
