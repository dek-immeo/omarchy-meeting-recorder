use super::{Result, Turn, audio, save};
use curl::easy::{Easy, Form, List};
use serde::Deserialize;
use std::{
    io::{self, Read},
    path::Path,
    time::Duration,
};

const DEFINITION: &str = r#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"timestamps":"segment"}},"diarization":{"enabled":true}}"#;

fn endpoint(resource: &str) -> Result<String> {
    if resource.is_empty()
        || resource.len() > 63
        || resource.starts_with('-')
        || resource.ends_with('-')
        || !resource
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("Angiv ressource­navnet fra Azure, fx firma-speech.".into());
    }
    Ok(format!(
        "https://{resource}.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
    ))
}

#[derive(Deserialize)]
struct Response {
    phrases: Vec<Phrase>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Phrase {
    offset_milliseconds: u64,
    duration_milliseconds: u64,
    speaker: Option<usize>,
    text: String,
}

fn submit(url: &str, key: &str, wav: &Path, source: &'static str) -> Result<Vec<Turn>> {
    let mut parts = Form::new();
    parts
        .part("definition")
        .contents(DEFINITION.as_bytes())
        .content_type("application/json")
        .add()?;
    parts
        .part("audio")
        .file(wav)
        .filename("audio.wav")
        .content_type("audio/wav")
        .add()?;
    let mut headers = List::new();
    headers.append(&format!("Ocp-Apim-Subscription-Key: {key}"))?;
    let mut http = Easy::new();
    http.url(url)?;
    http.http_headers(headers)?;
    http.httppost(parts)?;
    http.connect_timeout(Duration::from_secs(30))?;
    http.timeout(Duration::from_secs(60 * 60))?;
    let mut response = Vec::new();
    {
        let mut transfer = http.transfer();
        transfer.write_function(|slice| {
            response.extend_from_slice(slice);
            Ok(slice.len())
        })?;
        transfer
            .perform()
            .map_err(|e| format!("Azure ({source}): {e}"))?;
    }
    let code = http.response_code()?;
    if !(200..300).contains(&code) {
        let hint = match code {
            401 | 403 => "Kontrollér ressource, nøgle og adgang.",
            404 | 400 => {
                "Kontrollér at ressourcen og regionen understøtter MAI-Transcribe-2 med taleropdeling."
            }
            413 => "Filen overskrider Azures grænse. Brug lokal transskription.",
            429 => "Azure-kvoten er nået. Prøv senere.",
            _ => "Prøv igen, eller vælg lokal transskription.",
        };
        return Err(format!("Azure ({source}) svarede HTTP {code}. {hint}").into());
    }
    let result: Response = serde_json::from_slice(&response)?;
    Ok(result
        .phrases
        .into_iter()
        .filter(|p| !p.text.trim().is_empty())
        .map(|p| Turn {
            start: p.offset_milliseconds as i64,
            end: (p.offset_milliseconds + p.duration_milliseconds) as i64,
            source,
            speaker: p.speaker.map(|s| s + 1),
            text: p.text,
        })
        .collect())
}

pub fn run(folder: &Path, scratch: &Path, resource: &str) -> Result<()> {
    let start = std::time::Instant::now();
    let url = endpoint(resource)?;
    let mut key = String::new();
    io::stdin().take(1024).read_to_string(&mut key)?;
    if key.is_empty() || !key.bytes().all(|c| c.is_ascii_graphic()) {
        return Err("Indtast en gyldig Azure Speech-nøgle.".into());
    }
    println!("Klargør lyd til Azure …");
    let mut uploads = Vec::new();
    for source in ["Mikrofon", "Systemlyd"] {
        let original = folder.join(format!("{source}.wav"));
        let reader = hound::WavReader::open(&original)?;
        // 16 kHz mono, two bytes per frame. Check both tracks before sending either one.
        if u64::from(reader.duration()) * 32_000 / u64::from(reader.spec().sample_rate) + 44
            >= 500_000_000
        {
            return Err(
                "Optagelsen er for stor til Azure Fast Transcription. Vælg lokal transskription."
                    .into(),
            );
        }
        let samples = audio::mono(&original)?;
        if !samples.iter().any(|s| s.abs() > 0.0001) {
            continue;
        }
        let path = scratch.join(format!("{source}.wav"));
        let spec = hound::WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        let mut wav = hound::WavWriter::create(&path, spec)?;
        for sample in samples {
            wav.write_sample((sample * 32768.0).round() as i16)?;
        }
        wav.finalize()?;
        uploads.push((path, source));
    }
    println!("Transskriberer · Azure MAI-Transcribe-2");
    let mut turns = Vec::new();
    // The two requests have separate speaker scopes. Preserve both time origins.
    std::thread::scope(|scope| -> Result<()> {
        let jobs: Vec<_> = uploads
            .iter()
            .map(|(path, source)| {
                scope.spawn(|| submit(&url, &key, path, source).map_err(|e| e.to_string()))
            })
            .collect();
        for job in jobs {
            turns.extend(
                job.join()
                    .map_err(|_| "Azure-forbindelsen blev afbrudt")??,
            );
        }
        Ok(())
    })?;
    save(
        folder,
        "Transskription-Azure.md",
        "MAI-Transcribe-2 (Azure)",
        start,
        turns,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
    };

    #[test]
    fn resource_is_a_single_azure_dns_label() {
        assert!(
            endpoint("my-speech")
                .unwrap()
                .starts_with("https://my-speech.cognitiveservices.azure.com/")
        );
        for bad in ["", "a.b", "a/b", "a@b", "-a", "a-", "https://other.example"] {
            assert!(endpoint(bad).is_err());
        }
    }

    #[test]
    fn submits_diarization_and_decodes_per_phrase_speakers() {
        let server = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let url = format!("http://{}", server.local_addr().unwrap());
        let listener = std::thread::spawn(move || {
            let (mut conn, _) = server.accept().unwrap();
            let mut input = BufReader::new(conn.try_clone().unwrap());
            let mut header = String::new();
            let mut size = 0;
            loop {
                let mut line = String::new();
                input.read_line(&mut line).unwrap();
                if line == "\r\n" {
                    break;
                }
                if let Some(n) = line.to_lowercase().strip_prefix("content-length:") {
                    size = n.trim().parse().unwrap();
                }
                header.push_str(&line);
            }
            assert!(header.contains("Ocp-Apim-Subscription-Key: test-key"));
            let mut body = vec![0; size];
            input.read_exact(&mut body).unwrap();
            let payload = String::from_utf8_lossy(&body);
            assert!(
                payload.contains(DEFINITION)
                    && payload.contains("name=\"audio\"")
                    && payload.contains("RIFF")
            );
            let json = r#"{"phrases":[{"offsetMilliseconds":320,"durationMilliseconds":520,"speaker":0,"text":"Hej"},{"offsetMilliseconds":1000,"durationMilliseconds":550,"speaker":2,"text":"Godmorgen"}]}"#;
            write!(
                conn,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                json.len(),
                json
            )
            .unwrap();
        });
        let mut wav = tempfile::NamedTempFile::new().unwrap();
        wav.write_all(b"RIFF").unwrap();
        let turns = submit(&url, "test-key", wav.path(), "Systemlyd").unwrap();
        listener.join().unwrap();
        assert_eq!(
            (turns[0].speaker, turns[1].speaker, turns[1].start),
            (Some(1), Some(3), 1000)
        );
    }
}
