# Native porte til Windows, macOS og iPhone

Vurdering pr. 20. november 2026 på [upstream v1.8.0, commit 854f200](https://github.com/jankeesvw/omarchy-meeting-recorder/tree/854f20098c2bdf3657712a27d36f6a94c944245d). Første mål er et møde, der kan optages, transskriberes lokalt og genåbnes. To adskilte lydspor er afgørende på desktop, fordi upstream bruger dem til at skelne mellem egen og modpartens stemme.

| Platform | Første version | Hvad skal demonstreres på hardware? |
| --- | --- | --- |
| Windows 11 x64 | WinUI 3. Optag den valgte afspilningsenhed med WASAPI loopback i shared mode og mikrofonen via en separat capture-klient. | At begge spor indeholder den rigtige kilde ved brug af headset og højttaler. Mødeappen kan bruge et andet kommunikationsoutput end systemets standard. Mål drift mellem enhedernes ure og afprøv enhedsskift. |
| macOS 13+, først Apple Silicon | SwiftUI. Brug ScreenCaptureKit til systemlyd og AVAudioEngine til mikrofonen. Udeluk optagerens egen afspilning. | At skærm-/systemlyd- og mikrofontilladelser håndteres separat. Afprøv nægtet og senere givet adgang, pause og skift af headset. |
| iPhone, foreslået minimum iOS 17 | SwiftUI. Optag møder i rummet med AVAudioSession/AVAudioEngine, eller importér en lydfil via Filer. Start med en lille flersproget Whisper-model. | At optagelsen kan gemmes ved opkaldsafbrydelse og skærmlås. Mål transskriptionstid, hukommelse og varme ved et længere møde på den ældste understøttede telefon. |
| iPhone, iOS 27+ | Separat forsøg med brugerstartet fuldskærmsoptagelse via ScreenCaptureKit. Apples eksempel viser systemvælger, mikrofon og fortsat optagelse i baggrunden. | Test fjernstemme og egen mikrofon under et faktisk Teams-, FaceTime- og telefonopkald med deltagernes accept. Registrér pr. app og lydrute hvilke spor systemet leverer. Lov kun de kombinationer, der virker. |

WASAPI loopback dækker lyden fra den valgte udgang, og Windows kan beskytte visse lydstrømme. På iPhone er Apples egen opkaldsoptagelse en særskilt brugerfunktion med regionale begrænsninger. En eksisterende optagelse kan importeres, hvis brugeren kan eksportere en lydfil. [Microsofts loopback-dokumentation](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording) · [ScreenCaptureKit-systemlyd](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio) · [Apples iOS-eksempel](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) · [Apples opkaldsoptagelse](https://support.apple.com/guide/iphone/record-and-transcribe-a-call-iph57c6590e9/ios)

## Hvad kan genbruges?

- Bevar mødemappens JSON-manifest, tidskoder, Markdown-transskript og spor. Brug en eksisterende Linux-mødemappe til at teste genåbning begge veje, herunder ældre felter i manifestet. [Mødeformatet i upstream](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/meeting.rs)
- Udskil Rust-koden til mødeformat, tidslinje og transskription i et bibliotek med et lille C-interface til Swift og Windows. Adskil filstier, progressignaler og dekodning fra GTK/GLib og ffmpeg-processen. Brug CPU som første reference. Mål senere Metal og eventuel Windows-acceleration. [Afhængigheder](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/Cargo.toml) · [Transskription](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/transcribe.rs)
- Modelpakken er et særskilt leverancevalg. Upstream tilbyder bl.a. flersprogede tiny/base på ca. 75/142 MB og large-v3-turbo på ca. 1,6 GB. Taleropdeling bruger desuden Nemotron via ONNX Runtime. Afprøv Whisper først og mål merforbruget ved taleropdeling. Upstream-koden har MIT-licens. Kontrollér licenserne for de konkrete modelvægte og mediebiblioteker før distribution. [Modeller](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/models.rs) · [Nemotron](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/nemotron.rs)
- Erstat PulseAudio-programmerne parec/pacat, Unix-sockets, V4L2-webcam, Omarchy-widget og shell-actions ved platformgrænsen. Afspilning og import kan anvende AVFoundation eller Windows Media Foundation. Start med WAV og M4A til import. Webcam, automatiske kapitler og scripts kan vurderes efter første lydforløb. [Lydoptagelse](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/audio.rs) · [Afspilning](https://github.com/jankeesvw/omarchy-meeting-recorder/blob/854f20098c2bdf3657712a27d36f6a94c944245d/src/player.rs)

## Kom i gang i skyen

Åbn branchen `native-port/setup` i en Dev Container eller GitHub Codespaces. Containeren indeholder Rust, GTK, libadwaita, ffmpeg og C/C++-værktøjer til den fælles kode og Linux-referencen. Fra repository-roden kan man også starte den med Docker.

```sh
docker build -t meeting-recorder-dev:native .devcontainer
docker run --rm -it -u vscode -v "$PWD:/work" -w /work meeting-recorder-dev:native bash
```

Inde i containeren kan de eksisterende enhedstests køres med `cargo test --locked --no-default-features`. Upstreams transskriptionsbenchmark og tærskler er beskrevet i [bench/README.md](../bench/README.md).

GitHub Actions-workflowet **Native audio SDK probes** bygger WASAPI-kald med Visual Studio på Windows og kompilerer Swift mod både macOS- og iPhoneOS-SDK'et på en Mac-runner. Det kan køres manuelt, når workflowet er på forkens standardbranch, eller via push af ændringer til proberne eller workflowet. Kontrollér, at Actions er slået til i forken. Hardwareoptagelse kræver test på de fysiske enheder.

## Første accepttest

1. Optag den samme korte sekvens med mikrofon alene, fjernlyd alene og overlappende tale på Windows og Mac. Gem sporene separat. Gentag med pause og enhedsskift og mål forskydning ved begyndelsen og slutningen af 30 minutter.
2. Importér samme danske lydfil på alle platforme. Hent en flersproget model én gang, transskriber offline, og kontrollér afspilning fra en tidskode og genåbning af mødemappen.
3. På iPhone testes rumoptagelse og filimport for sig. For iOS 27-forsøget skal det kunne høres i de gemte spor, om modparten og mikrofonen kom med, også med headset. Et gemt skærmklip alene opfylder ikke kravet.
