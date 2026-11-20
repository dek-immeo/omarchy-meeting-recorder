# Meeting Recorder til Mac

Første testversion til Apple Silicon med macOS 13 eller nyere. Appen optager den valgte standardmikrofon og Mac’ens afspillede lyd som to lokale WAV-filer. Denne version fokuserer på optagelse og afspilning af sporene i Finder. Transskription hører til en senere version.

1. Pak `Meeting-Recorder-macOS-arm64.zip` ud og flyt **Meeting Recorder** til Programmer. Ved download fra GitHub Actions skal du først åbne den ydre artefakt-zip.
2. Åbn appen, og vælg **Start optagelse**. Giv mikrofontilladelse og tillad skærm-/systemlydoptagelse under **Systemindstillinger → Anonymitet & sikkerhed**. Apple kan bede om at genåbne appen. Appen gemmer kun lyd.
3. Brug gerne et headset til første prøve. Tal i mikrofonen, og afspil lyd i en anden app. De to målere viser, hvilken kilde der leverer signal.
4. Vælg **Stop optagelse → Vis seneste optagelse**. Afspil `Mikrofon.wav` og `Systemlyd.wav` hver for sig. Optagelser ligger under `~/Music/Meeting Recorder/` i en mappe pr. optagelse.

Bygget er ad hoc-signeret. Hvis macOS blokerer en downloadet testversion, kan du efter første åbningsforsøg godkende denne app under **Systemindstillinger → Anonymitet & sikkerhed → Åbn alligevel**. [Apples vejledning](https://support.apple.com/da-dk/102445)

Med Xcode Command Line Tools på macOS kan du bygge fra repository-roden med `ports/macos/build.sh`. Den færdige app og zip-fil ligger i `dist/macos/`.
