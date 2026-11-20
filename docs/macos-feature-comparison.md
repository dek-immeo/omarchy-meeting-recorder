# Meeting Recorder på Mac og Wispr Flow Notetaker

Status 20. november 2026. Sammenligningen gælder Meeting Recorder 0.3.0 på Apple Silicon og funktioner, Wispr dokumenterer for Notetaker. Der er ingen fælles måling af dansk ordfejlrate, talerfordeling eller behandlingstid.

| Arbejdsgang | Meeting Recorder på Mac | Wispr Flow Notetaker |
| --- | --- | --- |
| Optagelse | Manuel start uden bot. Mikrofon og systemlyd gemmes som separate WAV-filer. Pause og genoptag udelader pausen fra begge spor. | Optager uden bot på Mac og Windows og fra mikrofonen på iPhone. Understøtter pause og genoptag. [Optagelse](https://docs.wisprflow.ai/articles/9238501024-recording-a-meeting-with-notetaker-beta) |
| Før mødet | Åbn appen og start selv. | Kan opdage opkald og minde om kalendermøder. Google Kalender og, for understøttede konti, Outlook. [Kalender og påmindelser](https://docs.wisprflow.ai/articles/8955305188-meeting-detection-reminders-and-calendar-in-notetaker-beta) |
| Dansk og flere stemmer | Dansk tekst efter stop. Hvert spor får sin egen række talernumre, også når flere taler gennem samme mikrofon. Numrene gælder kun i det møde og på det spor. | Dansk er understøttet. Under mødet adskilles mikrofon og mødeaudio. Efter mødet kan kalenderdeltagere, ordbog og tiltale i samtalen give navne. Brugeren kan rette et navn i hele teksten. [Talere og sprog](https://wisprflow.ai/notetaker) |
| Under mødet | Viser lydniveau, optagetid og pause. Teksten bliver tilgængelig efter stop. | Viser løbende tekst og giver plads til egne noter. Kan opsummere de seneste minutter under samtalen. [Live-transskription](https://docs.wisprflow.ai/articles/4091106439-the-live-transcript-in-notetaker-beta) · [Notetaker](https://wisprflow.ai/notetaker) |
| Offline og cloud | Efter første modeldownload kan optagelse, transskription og taleropdeling afsluttes uden net. Azure Foundry kan vælges eksplicit med egen Speech-ressource. | Kan optage offline, hvis organisationens indstillinger tillader det. Når forbindelsen vender tilbage, uploades lyden til efterbehandling. [Offlineoptagelse](https://docs.wisprflow.ai/articles/5810080970-offline-meeting-recording-in-notetaker) |
| Gennemgang og rettelser | Klik på en tidskode for at høre den originale passage. Søg i tekst og talernumre, kopiér Markdown, eller redigér filen i en teksteditor. | Søg i teksten, ret og slet replikker, fortryd sletning, og ret talernavne. Wispr dokumenterer tider i teksten. Det er uafklaret, om et klik kan afspille originallyden fra replikken. [Transskription og rettelser](https://docs.wisprflow.ai/articles/4091106439-the-live-transcript-in-notetaker-beta) |
| Beslutninger og opfølgning | Leverer den tidskodede transskription. Resumé og opgaver kræver i dag manuel behandling. | Genererer resumé med beslutninger og næste skridt. Brugeren kan stille spørgsmål til mødehistorikken og følge svar tilbage til kilden. [Resumé](https://docs.wisprflow.ai/articles/1422535682-flow-summaries-in-notetaker-beta) · [Spørgsmål til møder](https://wisprflow.ai/notetaker) |
| Import | En lokal lydfil, fx M4A eller WAV, bliver til et møde med talernumre og afspilning. | Dokumenterede importforløb for Granola, Otter og Zoom. Det er uafklaret, om en vilkårlig lokal M4A-fil kan importeres direkte. [Granola og Otter](https://docs.wisprflow.ai/articles/4484290718-import-your-past-meetings-from-granola-or-otter-into-notetaker) · [Zoom](https://docs.wisprflow.ai/articles/6678227245-import-your-zoom-meetings-into-wispr-flow-notetaker) |
| Arkiv, deling og platforme | Lokale mødemapper med WAV og Markdown. Genåbn en mappe i appen eller del filerne selv. Den aktuelle app er til Mac. | Mødeoversigt, synkronisering og deling med adgangskontrol. Mac, Windows og iPhone. Mødehistorik kan også bruges i AI-værktøjer via MCP. [Mødeoversigt](https://docs.wisprflow.ai/articles/9247277218-the-notetaker-hub-your-meetings-in-one-place-beta) · [Deling](https://docs.wisprflow.ai/articles/5073796184-sharing-meeting-notes-from-notetaker-beta) · [Platforme og MCP](https://wisprflow.ai/notetaker) |

## Hvad mangler fra Omarchy på Mac?

| Område | Tilbage for at matche originalen |
| --- | --- |
| Sikker optagelse | Lydtjek på begge spor før start og tilbud om gendannelse ved næste start efter strømsvigt eller nedbrud. |
| Optagelse og import | Mødetitel før og under optagelse, valg af lydformat, transskriptionssprog og forventet talerantal, træk-og-slip samt bredere formatunderstøttelse via ffmpeg. |
| Gennemgang | Bølgeform, fremhævning og automatisk rulning under afspilning, klip et udsnit ud som nyt møde, og ret tekst, taler eller mødetitel direkte i appen. Omdøb og sammenlæg talere, slet en replik og fortryd. |
| Noter og video | Løbende gemte mødenoter ved siden af optagelsen og valgfri synkroniseret webcamvideo. |
| Efterbehandling | Kapitler via en valgfri agent, genberegning af kapitler og brugerdefinerede handlinger efter transskriptionen. |
| Mac-integration og arkiv | Kompakt optagevindue, status i menulinjen, globale genveje/kommandostyring, uafhængige mødevinduer og et mødedokument med metadata, der kan åbnes direkte fra Finder. Linux-originalens temafarver og statuslinje kræver en platformspecifik oversættelse. |

[Omarchy-funktionerne i den gennemgåede revision](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/README.md)
