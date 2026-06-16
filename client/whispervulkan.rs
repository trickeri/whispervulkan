//! Reference snippet for Tauri/Rust apps (e.g. Trik_Klip, voicechat).
//! Needs `reqwest` with the `multipart` + `blocking` features.
//!
//!   let text = whispervulkan_transcribe(&wav_bytes)?;
//!
//! WHISPER_HTTP_URL overrides the endpoint (default 127.0.0.1:48450).

pub fn whispervulkan_transcribe(wav: &[u8]) -> Result<String, Box<dyn std::error::Error>> {
    let url = std::env::var("WHISPER_HTTP_URL")
        .unwrap_or_else(|_| "http://127.0.0.1:48450/inference".to_string());
    let form = reqwest::blocking::multipart::Form::new()
        .text("response_format", "text")
        .part(
            "file",
            reqwest::blocking::multipart::Part::bytes(wav.to_vec())
                .file_name("audio.wav")
                .mime_str("audio/wav")?,
        );
    let text = reqwest::blocking::Client::new()
        .post(url)
        .multipart(form)
        .send()?
        .error_for_status()?
        .text()?;
    Ok(text.trim().to_string())
}
