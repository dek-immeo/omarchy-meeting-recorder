mod audio;
mod azure;
#[path = "../../../../src/nemotron/inference.rs"]
mod inference;
mod live;
mod models;
use std::{io::Write, path::Path};
use transcribe_cpp::{Model, RunOptions, TimestampKind};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
struct Turn {
    start: i64,
    end: i64,
    source: &'static str,
    speaker: Option<usize>,
    text: String,
}

// Combine the eight independent 10 ms activity channels over each word.
// Unvoiced intervals stay unattributed. Labels are scoped to one recording and source.
fn speaker(probs: &[f32], start: i64, end: i64) -> Option<usize> {
    let frames = probs.len() / 8;
    let first = (start.max(0) as usize / 10).min(frames);
    let last = (end.max(0) as usize)
        .div_ceil(10)
        .max(first + 1)
        .min(frames);
    let active = |frame: &[f32]| {
        let best = (0..8).max_by(|&i, &j| frame[i].total_cmp(&frame[j]))?;
        (frame[best] >= 0.5).then_some(best)
    };
    let mut votes = [0usize; 8];
    for frame in probs[first * 8..last * 8].chunks_exact(8) {
        if let Some(id) = active(frame) {
            votes[id] += 1;
        }
    }
    let best = (0..8).max_by_key(|&i| votes[i])?;
    if votes[best] > 0 {
        return Some(best + 1);
    }
    // ASR can place the first or last word just outside a detected turn.
    // Search only the nearby 350 ms so distant speech cannot claim a word.
    for distance in 0..35 {
        let before = first.checked_sub(distance + 1);
        let after = last.checked_add(distance).filter(|&i| i < frames);
        for i in [before, after].into_iter().flatten() {
            if let Some(id) = active(&probs[i * 8..(i + 1) * 8]) {
                return Some(id + 1);
            }
        }
    }
    None
}

fn sources(folder: &Path) -> Result<Vec<&'static str>> {
    if folder.join("Import.wav").is_file() {
        return Ok(vec!["Import"]);
    }
    for file in ["Mikrofon.wav", "Systemlyd.wav"] {
        if !folder.join(file).is_file() {
            return Err(format!("Mødemappen mangler {file}.").into());
        }
    }
    Ok(vec!["Mikrofon", "Systemlyd"])
}

fn transcript(folder: &Path, cache: &Path) -> Result<()> {
    let start = std::time::Instant::now();
    let sources = sources(folder)?;
    println!("Klargør sprog- og talemodeller …");
    let (asr, diar) = models::prepare(cache)?;
    let model = Model::load(asr)?;
    let options = RunOptions {
        timestamps: TimestampKind::Word,
        ..Default::default()
    };
    let mut turns = Vec::new();
    for source in sources {
        let mut track: Vec<Turn> = Vec::new();
        let pcm = audio::mono(&folder.join(format!("{source}.wav")))?;
        if !pcm.iter().any(|s| s.abs() > 0.0001) {
            continue;
        }
        println!("Finder stemmer · {source}");
        let probs = inference::Model::load(&diar)?.probabilities(&pcm, |_| Ok(()))?;
        println!("Transskriberer · {source}");
        let result = model.session()?.run(&pcm, &options)?;
        if !result.text.trim().is_empty() && result.words.is_empty() {
            return Err("Sprogmodellen returnerede tekst uden tidskoder.".into());
        }
        for word in result.words {
            let text = word.text.trim();
            if text.is_empty() {
                continue;
            }
            let id = speaker(&probs, word.t0_ms, word.t1_ms);
            // Token timings sometimes include the silence until the next utterance.
            // Bound the grouping gap so a reply follows the intervening question.
            let end = word.t1_ms.min(word.t0_ms + 700);
            if let Some(prev) = track.last_mut()
                && prev.speaker == id
                && word.t0_ms - prev.end < 1400
                && word.t0_ms - prev.start < 20_000
            {
                prev.text.push(' ');
                prev.text.push_str(text);
                prev.end = prev.end.max(end);
            } else {
                track.push(Turn {
                    start: word.t0_ms,
                    end,
                    source,
                    speaker: id,
                    text: text.to_owned(),
                });
            }
        }
        turns.extend(track);
    }
    save(
        folder,
        "Transskription.md",
        "Parakeet Ultra + Nemotron 3 (lokal)",
        start,
        turns,
    )
}

fn save(
    folder: &Path,
    filename: &str,
    method: &str,
    start: std::time::Instant,
    mut turns: Vec<Turn>,
) -> Result<()> {
    turns.sort_by_key(|t| t.start);
    let mut file = tempfile::NamedTempFile::new_in(folder)?;
    writeln!(file, "# Mødetransskription\n")?;
    writeln!(
        file,
        "{method} · {:.1} s samlet behandlingstid\n",
        start.elapsed().as_secs_f64()
    )?;
    if turns.is_empty() {
        writeln!(file, "Ingen tale genkendt.")?;
    }
    for t in turns {
        let total = t.start.max(0) / 1000;
        let label = t
            .speaker
            .map_or_else(|| "Ukendt taler".to_owned(), |s| format!("Taler {s}"));
        writeln!(
            file,
            "**[{:02}:{:02}:{:02}.{:03}] {} · {}**  \n{}\n",
            total / 3600,
            total / 60 % 60,
            total % 60,
            t.start.max(0) % 1000,
            t.source,
            label,
            t.text
        )?;
    }
    file.as_file().sync_all()?;
    file.persist(folder.join(filename))?;
    Ok(())
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let result = match args.as_slice() {
        [mode, folder, cache] if mode == "--live" => live::run(Path::new(folder), Path::new(cache)),
        [folder, cache] => transcript(Path::new(folder), Path::new(cache)),
        [mode, folder, scratch, resource] if mode == "--azure" => azure::run(
            Path::new(folder),
            Path::new(scratch),
            resource.to_str().unwrap_or(""),
        ),
        _ => std::process::exit(2),
    };
    if let Err(error) = result {
        if args.first().is_some_and(|mode| mode == "--live") {
            println!("LIVE_ERROR {error}");
        } else {
            eprintln!("Transskriptionen blev afbrudt: {error}");
        }
        std::process::exit(1);
    }
}
