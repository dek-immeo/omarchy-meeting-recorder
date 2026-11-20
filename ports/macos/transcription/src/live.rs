// The recorder publishes completed frame counts. Use these as the upper bound:
// an open WAV can have a provisional data size or preallocated space after the audio.
use super::{Result, audio, models};
use serde::Serialize;
use std::{
    fs::File,
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::Path,
};
use transcribe_cpp::{Model, RunOptions, TimestampKind};

const STEP: u64 = 4;
const CONTEXT: u64 = 1;

pub(super) struct TrackReader {
    file: File,
    spec: hound::WavSpec,
    data_offset: u64,
    next_second: u64,
}

impl TrackReader {
    pub(super) fn open(path: &Path) -> Result<Self> {
        let mut file = BufReader::new(File::open(path)?);
        hound::read_wave_header(&mut file)?;
        let mut spec = None;
        loop {
            let mut chunk = [0; 8];
            file.read_exact(&mut chunk)?;
            let size = u32::from_le_bytes(chunk[4..8].try_into()?) as u64;
            let start = file.stream_position()?;
            match &chunk[..4] {
                b"fmt " if size >= 16 => {
                    let mut fmt = [0; 16];
                    file.read_exact(&mut fmt)?;
                    let channels = u16::from_le_bytes(fmt[2..4].try_into()?);
                    let rate = u32::from_le_bytes(fmt[4..8].try_into()?);
                    let bits = u16::from_le_bytes(fmt[14..16].try_into()?);
                    if channels == 0 || rate == 0 || bits != 16 {
                        return Err("Uventet format i optagelsens WAV-spor.".into());
                    }
                    spec = Some(hound::WavSpec {
                        channels,
                        sample_rate: rate,
                        bits_per_sample: bits,
                        sample_format: hound::SampleFormat::Int,
                    });
                }
                b"data" => {
                    return Ok(Self {
                        file: file.into_inner(),
                        spec: spec.ok_or("WAV-format mangler.")?,
                        data_offset: start,
                        next_second: 0,
                    });
                }
                _ => {}
            }
            file.seek(SeekFrom::Start(start + size + size % 2))?;
        }
    }

    fn window(&mut self, written: u64) -> Result<Option<Vec<f32>>> {
        let rate = u64::from(self.spec.sample_rate);
        let stride = u64::from(self.spec.channels) * 2;
        let first = self.next_second.saturating_sub(CONTEXT) * rate;
        let end = (self.next_second + STEP + CONTEXT) * rate;
        if written < end || self.file.metadata()?.len() < self.data_offset + end * stride {
            return Ok(None);
        }
        Ok(Some(self.read(first, end)?))
    }

    pub(super) fn rate(&self) -> u64 {
        u64::from(self.spec.sample_rate)
    }

    pub(super) fn available(&self, written: u64) -> Result<u64> {
        let stride = u64::from(self.spec.channels) * 2;
        Ok(written.min(self.file.metadata()?.len().saturating_sub(self.data_offset) / stride))
    }

    pub(super) fn read(&mut self, first: u64, end: u64) -> Result<Vec<f32>> {
        let stride = u64::from(self.spec.channels) * 2;
        self.file
            .seek(SeekFrom::Start(self.data_offset + first * stride))?;
        let mut bytes = vec![0; ((end - first) * stride) as usize];
        self.file.read_exact(&mut bytes)?;
        let samples = bytes
            .chunks_exact(2)
            .map(|v| Ok(i16::from_le_bytes([v[0], v[1]])));
        audio::resample(self.spec, (end - first) as usize, samples)
    }
}

#[derive(Serialize)]
struct Caption<'a> {
    source: &'a str,
    ms: i64,
    text: String,
}

pub fn run(folder: &Path, cache: &Path) -> Result<()> {
    let model = Model::load(models::prepare_live(cache)?)?;
    let mut session = model.session()?;
    let options = RunOptions {
        timestamps: TimestampKind::Word,
        ..Default::default()
    };
    let sources = ["Mikrofon", "Systemlyd"];
    let mut tracks: [Option<TrackReader>; 2] = [None, None];
    println!("LIVE_READY");
    std::io::stdout().flush()?;
    for line in std::io::stdin().lock().lines() {
        let written: [u64; 2] = serde_json::from_str(&line?)?;
        let mut progressed = false;
        for (i, source) in sources.iter().enumerate() {
            if written[i] == 0 {
                continue;
            }
            if tracks[i].is_none() {
                tracks[i] = Some(TrackReader::open(&folder.join(format!("{source}.wav")))?);
            }
            let track = tracks[i].as_mut().unwrap();
            let Some(pcm) = track.window(written[i])? else {
                continue;
            };
            let start = track.next_second as i64 * 1000;
            let base = track.next_second.saturating_sub(CONTEXT) as i64 * 1000;
            track.next_second += STEP;
            progressed = true;
            if !pcm.iter().any(|s| s.abs() > 0.0001) {
                continue;
            }
            let result = session.run(&pcm, &options)?;
            // Decode with context on both sides; emit words from the middle just once.
            let mut words = result
                .words
                .iter()
                .filter(|w| {
                    let time = base + w.t0_ms;
                    (start..start + STEP as i64 * 1000).contains(&time)
                })
                .peekable();
            if let Some(first) = words.peek() {
                let ms = base + first.t0_ms;
                let text = words
                    .map(|w| w.text.trim())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                if !text.is_empty() {
                    println!(
                        "LIVE_LINE {}",
                        serde_json::to_string(&Caption { source, ms, text })?
                    );
                }
            }
        }
        println!("{}", if progressed { "LIVE_NEXT" } else { "LIVE_WAIT" });
        std::io::stdout().flush()?;
    }
    Ok(())
}
