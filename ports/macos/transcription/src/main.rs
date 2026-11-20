mod audio;
mod models;
#[path = "../../../../src/nemotron/inference.rs"]
mod inference;
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
    let last = ((end.max(0) as usize).div_ceil(10)).max(first + 1).min(frames);
    if first >= last { return None; }
    let mut sums = [0.0; 8];
    for frame in probs[first*8..last*8].chunks_exact(8) {
        for (sum, p) in sums.iter_mut().zip(frame) { *sum += p; }
    }
    let best = (0..8).max_by(|&i, &j| sums[i].total_cmp(&sums[j]))?;
    (sums[best] >= 0.3 * (last - first) as f32).then_some(best + 1)
}

fn transcript(folder: &Path, cache: &Path) -> Result<()> {
    for file in ["Mikrofon.wav", "Systemlyd.wav"] {
        if !folder.join(file).is_file() { return Err(format!("Mødemappen mangler {file}.").into()); }
    }
    println!("Klargør sprog- og talemodeller …");
    let (asr, diar) = models::prepare(cache)?;
    let model = Model::load(asr)?;
    let options = RunOptions { timestamps: TimestampKind::Word, ..Default::default() };
    let mut turns = Vec::new();
    for source in ["Mikrofon", "Systemlyd"] {
        let mut track: Vec<Turn> = Vec::new();
        let pcm = audio::mono(&folder.join(format!("{source}.wav")))?;
        if !pcm.iter().any(|s| s.abs() > 0.0001) { continue; }
        println!("Finder stemmer · {source}");
        let probs = inference::Model::load(&diar)?.probabilities(&pcm, |_| Ok(()))?;
        println!("Transskriberer · {source}");
        let result = model.session()?.run(&pcm, &options)?;
        if !result.text.trim().is_empty() && result.words.is_empty() {
            return Err("Sprogmodellen returnerede tekst uden tidskoder.".into());
        }
        for word in result.words {
            let text = word.text.trim();
            if text.is_empty() { continue; }
            let id = speaker(&probs, word.t0_ms, word.t1_ms);
            if let Some(prev) = track.last_mut()
                && prev.speaker == id && word.t0_ms - prev.end < 1400 && word.t0_ms - prev.start < 20_000 {
                prev.text.push(' ');
                prev.text.push_str(text);
                prev.end = prev.end.max(word.t1_ms);
            } else {
                track.push(Turn { start: word.t0_ms, end: word.t1_ms, source, speaker: id, text: text.to_owned() });
            }
        }
        turns.extend(track);
    }
    turns.sort_by_key(|t| t.start);
    let mut file = tempfile::NamedTempFile::new_in(folder)?;
    writeln!(file, "# Mødetransskription\n")?;
    if turns.is_empty() { writeln!(file, "Ingen tale genkendt.")?; }
    for t in turns {
        let total = t.start.max(0) / 1000;
        let label = t.speaker.map_or_else(|| "Ukendt taler".to_owned(), |s| format!("Taler {s}"));
        writeln!(file, "**[{:02}:{:02}:{:02}] {} · {}**  \n{}\n", total / 3600, total / 60 % 60, total % 60, t.source, label, t.text)?;
    }
    file.as_file().sync_all()?;
    file.persist(folder.join("Transskription.md"))?;
    Ok(())
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let [folder, cache] = args.as_slice() else { std::process::exit(2) };
    if let Err(error) = transcript(Path::new(folder), Path::new(cache)) {
        eprintln!("Transskriptionen blev afbrudt: {error}");
        std::process::exit(1);
    }
}
