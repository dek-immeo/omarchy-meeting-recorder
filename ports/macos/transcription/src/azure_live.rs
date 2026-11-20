use crate::{Result, live::TrackReader};
use libloading::Library;
use serde::Deserialize;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    io::{BufRead, Write},
    path::Path,
};

const SOURCES: [&str; 2] = ["Mikrofon", "Systemlyd"];

#[derive(Deserialize)]
struct Config {
    endpoint: String,
    key: String,
    language: String,
}

#[derive(Deserialize)]
struct Setup {
    connection: Config,
    start: [u64; 2],
}

type Event = extern "C" fn(u32, u32, u64, *const c_char);
type Open = unsafe extern "C" fn(
    *const c_char,
    *const c_char,
    *const c_char,
    u32,
    u64,
    Event,
) -> *mut c_void;
type WritePcm = unsafe extern "C" fn(*mut c_void, *const u8, u32) -> bool;

extern "C" fn event(kind: u32, source: u32, ms: u64, message: *const c_char) {
    let Some(source) = SOURCES.get(source as usize) else {
        return;
    };
    if message.is_null() {
        return;
    }
    // The SDK adapter owns the string for the duration of this callback.
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy();
    let mut stdout = std::io::stdout().lock();
    if kind == 2 {
        let _ = writeln!(
            stdout,
            "LIVE_ERROR Azure Speech ({source}, SDK-kode {text}). Kontrollér endpoint, nøgle, netforbindelse og kvote."
        );
    } else {
        let prefix = if kind == 0 {
            "LIVE_PARTIAL"
        } else {
            "LIVE_LINE"
        };
        let data = serde_json::json!({"source": source, "ms": ms, "text": text});
        let _ = writeln!(stdout, "{prefix} {data}");
    }
    let _ = stdout.flush();
}

struct Client {
    _library: Library,
    open: Open,
    write: WritePcm,
    url: CString,
    key: CString,
    language: CString,
    channels: [*mut c_void; 2],
}

impl Client {
    fn new(config: Config) -> Result<Self> {
        // Only load the signed adapter shipped alongside the app's worker.
        let exe = std::env::current_exe()?;
        let contents = exe
            .parent()
            .and_then(Path::parent)
            .ok_or("Appens Frameworks-mappe mangler.")?;
        let library = unsafe { Library::new(contents.join("Frameworks/libMeetingSpeech.dylib"))? };
        Ok(Self {
            open: unsafe { *library.get(b"meeting_speech_open")? },
            write: unsafe { *library.get(b"meeting_speech_write")? },
            _library: library,
            url: CString::new(config.endpoint)?,
            key: CString::new(config.key)?,
            language: CString::new(config.language)?,
            channels: [std::ptr::null_mut(); 2],
        })
    }

    fn send(&mut self, index: usize, start_ms: u64, pcm: &[f32]) -> Result<()> {
        if self.channels[index].is_null() {
            // Idle output devices may first publish minutes of timeline padding.
            if !pcm.iter().any(|v| v.abs() > 0.0001) {
                return Ok(());
            }
            self.channels[index] = unsafe {
                (self.open)(
                    self.url.as_ptr(),
                    self.key.as_ptr(),
                    self.language.as_ptr(),
                    index as u32,
                    start_ms,
                    event,
                )
            };
            if self.channels[index].is_null() {
                return Err("Azure Speech kunne ikke åbne forbindelsen. Kontrollér endpoint, talesprog og nøgle.".into());
            }
        }
        let bytes: Vec<u8> = pcm
            .iter()
            .flat_map(|f| ((*f * 32768.0).round() as i16).to_le_bytes())
            .collect();
        if !unsafe { (self.write)(self.channels[index], bytes.as_ptr(), bytes.len() as u32) } {
            return Err("Forbindelsen til Azure Speech blev afbrudt.".into());
        }
        Ok(())
    }
}

pub fn run(folder: &Path) -> Result<()> {
    let mut commands = std::io::stdin().lock().lines();
    // The key arrives via stdin. It is never passed in argv, logged, or stored on disk.
    let setup = commands.next().ok_or("Azure-indstillinger mangler.")??;
    let setup: Setup = serde_json::from_str(&setup)?;
    let mut client = Client::new(setup.connection)?;
    let result = stream(folder, &mut client, commands, setup.start);
    // Each unpaused recording interval owns a separate SDK process. Closing the UI pipe
    // must release its sockets even if the network is down and the SDK is awaiting a reply.
    if let Err(error) = result {
        println!("LIVE_ERROR {error}");
        std::io::stdout().flush()?;
        std::process::exit(1);
    }
    std::process::exit(0);
}

fn stream(
    folder: &Path,
    client: &mut Client,
    commands: impl Iterator<Item = std::io::Result<String>>,
    mut cursor: [u64; 2],
) -> Result<()> {
    let mut tracks: [Option<TrackReader>; 2] = [None, None];
    println!("LIVE_READY");
    std::io::stdout().flush()?;
    for line in commands {
        let written: [u64; 2] = serde_json::from_str(&line?)?;
        let mut advanced = false;
        for (i, source) in SOURCES.iter().enumerate() {
            if written[i] <= cursor[i] {
                continue;
            }
            if tracks[i].is_none() {
                tracks[i] = Some(TrackReader::open(&folder.join(format!("{source}.wav")))?);
            }
            let track = tracks[i].as_mut().unwrap();
            let available = track.available(written[i])?;
            let block = track.rate() / 2;
            let end = (cursor[i] + block).min(available);
            if end < cursor[i] + block {
                continue;
            }
            let pcm = track.read(cursor[i], end)?;
            client.send(i, cursor[i] * 1000 / track.rate(), &pcm)?;
            cursor[i] = end;
            advanced = true;
        }
        println!("{}", if advanced { "LIVE_NEXT" } else { "LIVE_WAIT" });
        std::io::stdout().flush()?;
    }
    Ok(())
}
