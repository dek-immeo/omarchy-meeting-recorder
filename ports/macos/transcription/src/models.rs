use curl::easy::Easy;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

const ASR: &str = "https://huggingface.co/handy-computer/parakeet-ultra-gguf/resolve/a1539be1b849ea7463b88343e5277b373d0c4ea9";
#[path = "../../../../src/nemotron/files.rs"]
mod nemotron;

fn ensure(dir: &Path, repo: &str, name: &str, expected: &str) -> super::Result<PathBuf> {
    let path = dir.join(name);
    if path.exists() {
        let mut hash = Sha256::new();
        io::copy(&mut fs::File::open(&path)?, &mut hash)?;
        if format!("{:x}", hash.finalize()) == expected {
            return Ok(path);
        }
    }
    println!("Henter {name} …");
    // All writers hold the cache lock. A retry also recovers an interrupted download.
    let part = path.with_extension("download");
    let mut file = fs::File::create(&part)?;
    let mut hash = Sha256::new();
    let mut request = Easy::new();
    request.url(&format!("{repo}/{name}"))?;
    request.follow_location(true)?;
    request.fail_on_error(true)?;
    request.connect_timeout(std::time::Duration::from_secs(30))?;
    request.low_speed_limit(256)?;
    request.low_speed_time(std::time::Duration::from_secs(90))?;
    request.progress(true)?;
    {
        let mut last_percent = 0;
        let mut transfer = request.transfer();
        transfer.progress_function(|total, done, _, _| {
            if total > 0.0 {
                let percent = (done * 100.0 / total) as u32;
                if percent >= last_percent + 5 {
                    println!("Henter {name} · {percent}%");
                    last_percent = percent;
                }
            }
            true
        })?;
        transfer.write_function(|chunk| {
            if file.write_all(chunk).is_err() {
                return Ok(0);
            }
            hash.update(chunk);
            Ok(chunk.len())
        })?;
        transfer
            .perform()
            .map_err(|e| format!("Kunne ikke hente {name}: {e}"))?;
    }
    file.sync_all()?;
    if format!("{:x}", hash.finalize()) != expected {
        return Err(format!("Kontrolsummen for {name} er forkert. Prøv igen.").into());
    }
    fs::rename(part, &path)?;
    Ok(path)
}

pub fn prepare(dir: &Path) -> super::Result<(PathBuf, PathBuf)> {
    fs::create_dir_all(dir)?;
    let lock = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join(".download.lock"))?;
    lock.lock()?;
    let asr = ensure(
        dir,
        ASR,
        "parakeet-ultra-Q4_K_M.gguf",
        "c69b7a5f9071a7afd8a1818ef7ae542c386c4b01ed0cac380c19a99947646bf9",
    )?;
    for (name, _, digest) in nemotron::FILES {
        ensure(dir, nemotron::REPO, name, digest)?;
    }
    Ok((asr, dir.join(nemotron::FILES[0].0)))
}
