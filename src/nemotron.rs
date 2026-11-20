//! NVIDIA's Nemotron 3 Diarization, offline, through ONNX Runtime.
//!
//! The model is a Streaming Sortformer: a transformer that looks at a chunk of
//! audio together with a small memory of earlier frames (the speaker cache and
//! a FIFO of the latest ones), and gives every 10 ms frame a probability for
//! each of up to eight speakers, numbered in the order they are first heard.
//!
//! The network is the int8 ONNX export from the Hugging Face ONNX community,
//! which holds no state: it takes the log-mel features of one chunk and the
//! cached frames, and returns the logits and the chunk's frames for the cache.
//! The features, the chunk loop and the cache policy are here, and follow
//! `Nemotron3DiarizationSpeakerCache` in Hugging Face transformers step by step.

mod inference;
pub use inference::Model;
use std::path::PathBuf;
use crate::transcribe::{Abort, Events, download, models_dir};

mod files;
use files::{FILES, REPO};

fn dir() -> PathBuf {
    models_dir().join("nemotron-3-diarization")
}

/// The model files, downloaded first when needed (about 120 MB).
pub fn ensure(events: &Events, abort: &Abort) -> Result<PathBuf, String> {
    let dir = dir();
    for (file, min_bytes, sha256) in FILES {
        let path = dir.join(file);
        if std::fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() >= min_bytes) {
            continue;
        }
        download(
            &format!("{REPO}/{file}"),
            &path,
            "Downloading the speaker model",
            sha256,
            events,
            abort,
        )?;
    }
    Ok(dir.join(FILES[0].0))
}
