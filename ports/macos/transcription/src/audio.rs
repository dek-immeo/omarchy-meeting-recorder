use rubato::{FftFixedInOut, Resampler};
use std::path::Path;

// Read the recorder's 16-bit WAV in blocks. Only the 16 kHz mono signal is retained.
pub fn mono(path: &Path) -> super::Result<Vec<f32>> {
    let mut wav = hound::WavReader::open(path)?;
    let spec = wav.spec();
    if spec.bits_per_sample != 16
        || spec.sample_format != hound::SampleFormat::Int
        || spec.channels == 0
    {
        return Err("Optagelsen skal være en 16-bit PCM WAV-fil.".into());
    }
    let channels = usize::from(spec.channels);
    let rate = spec.sample_rate as usize;
    let frames = wav.duration() as usize;
    let target_frames = (frames * 16000 + rate / 2) / rate;
    let mut converter = FftFixedInOut::<f32>::new(rate, 16000, 2048, 1)?;
    let delay = converter.output_delay();
    let mut input = converter.input_buffer_allocate(true);
    let mut output = converter.output_buffer_allocate(true);
    let mut samples = wav.samples::<i16>();
    let mut result = Vec::with_capacity(target_frames + delay + output[0].len());
    while result.len() < target_frames + delay {
        for frame in &mut input[0] {
            let mut sum = 0f32;
            for _ in 0..channels {
                if let Some(sample) = samples.next() {
                    sum += f32::from(sample?);
                }
            }
            *frame = sum / (32768.0 * channels as f32);
        }
        let (_, written) = converter.process_into_buffer(&input, &mut output, None)?;
        result.extend_from_slice(&output[0][..written]);
    }
    result.copy_within(delay..delay + target_frames, 0);
    result.truncate(target_frames);
    Ok(result)
}
