use base64::{Engine as _, engine::general_purpose};
use clap::Parser;
use regex::Regex;
use reqwest;
use std::env;
use std::io::{self, Read};
use std::process;
use tokio::task::JoinSet;
use url::Url;

#[derive(Parser)]
#[command(name = "tktts")]
#[command(about = "Generate TikTok TTS URLs for audio playback")]
struct Args {
    /// Text to convert to speech
    text: Vec<String>,

    /// TikTok speaker voice (default: en_us_002)
    #[arg(short, long, default_value = "en_us_002")]
    speaker: String,

    /// Output the audio data URL instead of making HTTP request
    #[arg(short, long)]
    url_only: bool,
}

const API_BASE_URL: &str = "/media/api/text/speech/invoke/";
const USER_AGENT: &str = "com.zhiliaoapp.musically/2022600030 (Linux; U; Android 7.1.2; es_ES; SM-G988N; Build/NRD90M;tt-ok/3.12.13.1)";
const BYTE_LIMIT: usize = 300;

fn sanitize_text(text: &str) -> String {
    text.replace("+", "plus")
        .replace("&", "and")
        .replace("ä", "ae")
        .replace("ö", "oe")
        .replace("ü", "ue")
        .replace("ß", "ss")
}

fn split_text(text: &str, byte_limit: usize) -> Vec<String> {
    let mut merged_chunks = Vec::new();
    let mut current_chunk = String::new();
    let mut current_byte_length = 0;

    // Extended punctuation and symbols for chunk splitting
    let punctuation_regex = Regex::new(r".*?[.,!?:;\-—…(){}<>\[\]\n]|.+").unwrap();

    // Split text based on punctuation and symbols to maintain natural pauses
    let separated_chunks: Vec<&str> = punctuation_regex
        .find_iter(text)
        .map(|m| m.as_str())
        .collect();

    for chunk in separated_chunks {
        let chunk_byte_length = chunk.len();

        if chunk_byte_length > byte_limit {
            // Split the chunk further if it exceeds byte limit
            let words: Vec<&str> = chunk.split_whitespace().collect();
            for word in words {
                let word_byte_length = word.len();
                if current_byte_length + word_byte_length + 1 > byte_limit {
                    if !current_chunk.is_empty() {
                        merged_chunks.push(current_chunk.clone());
                        eprintln!(
                            "Chunk created: {} (Bytes: {})",
                            current_chunk, current_byte_length
                        );
                    }
                    current_chunk = word.to_string();
                    current_byte_length = word_byte_length;
                } else {
                    if !current_chunk.is_empty() {
                        current_chunk.push(' ');
                        current_chunk.push_str(word);
                        current_byte_length += word_byte_length + 1; // +1 for space
                    } else {
                        current_chunk = word.to_string();
                        current_byte_length = word_byte_length;
                    }
                }
            }
        } else {
            if current_byte_length + chunk_byte_length > byte_limit {
                if !current_chunk.is_empty() {
                    merged_chunks.push(current_chunk.clone());
                    eprintln!(
                        "Chunk created: {} (Bytes: {})",
                        current_chunk, current_byte_length
                    );
                }
                current_chunk = chunk.to_string();
                current_byte_length = chunk_byte_length;
            } else {
                current_chunk.push_str(chunk);
                current_byte_length += chunk_byte_length;
            }
        }
    }

    if !current_chunk.is_empty() {
        merged_chunks.push(current_chunk.clone());
        eprintln!(
            "Chunk created: {} (Bytes: {})",
            current_chunk, current_byte_length
        );
    }

    merged_chunks
}

async fn request_tts_chunk(
    text: &str,
    speaker: &str,
    session_id: &str,
    root_url: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let sanitized_text = sanitize_text(text);

    let mut url = Url::parse(&format!("{root_url}{API_BASE_URL}"))?;
    url.query_pairs_mut()
        .append_pair("text_speaker", speaker)
        .append_pair("req_text", &sanitized_text)
        .append_pair("speaker_map_type", "0")
        .append_pair("aid", "1233");

    let client = reqwest::Client::new();
    let response = client
        .post(url)
        .header("User-Agent", USER_AGENT)
        .header("Cookie", format!("sessionid={}", session_id))
        .send()
        .await?;

    let json: serde_json::Value = response.json().await?;

    dbg!(&json);

    if let Some(message) = json.get("message") {
        if message == "Couldn't load speech. Try again." {
            return Err("Invalid TikTok Session ID or API error.".into());
        }
    }

    // if we have "status_msg" output that

    let v_str = json["data"]["v_str"]
        .as_str()
        .ok_or("Missing v_str in response")?;

    Ok(v_str.to_string())
}

fn generate_tts_url(text: &str, speaker: &str) -> String {
    let sanitized_text = sanitize_text(text);
    let mut url = Url::parse(API_BASE_URL).unwrap();
    url.query_pairs_mut()
        .append_pair("text_speaker", speaker)
        .append_pair("req_text", &sanitized_text)
        .append_pair("speaker_map_type", "0")
        .append_pair("aid", "1233");

    url.to_string()
}

async fn process_tts(
    text: &str,
    speaker: &str,
    url_only: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if url_only {
        // Just output the URL for the first chunk
        let chunks = split_text(text, BYTE_LIMIT);
        if let Some(first_chunk) = chunks.first() {
            println!("{}", generate_tts_url(first_chunk, speaker));
        }
        return Ok(());
    }

    // Load session ID from environment
    dotenv::dotenv().ok();
    let session_id = env::var("TIKTOK_SESSIONID")
        .map_err(|_| "TIKTOK_SESSIONID environment variable not set. Please set it in .env file or export it.")?;

    let api_root_url = env::var("TIKTOK_API_BASEURL").map_err(|_| "Invalid API root URL")?;
    let chunks = split_text(text, BYTE_LIMIT);

    if chunks.len() > 1 {
        eprintln!("Processing {} chunks in parallel...", chunks.len());
    }

    // Process chunks in parallel
    let mut join_set = JoinSet::new();
    let mut audio_chunks: Vec<Option<String>> = vec![None; chunks.len()];
    let total_chunks = chunks.len();

    for (index, chunk) in chunks.iter().enumerate() {
        let chunk_text = chunk.clone();
        let speaker_voice = speaker.to_string();
        let session_id_clone = session_id.clone();
        let api_root_url = api_root_url.clone();

        join_set.spawn(async move {
            eprintln!(
                "Processing chunk {}/{}: {}",
                index + 1,
                total_chunks,
                chunk_text
            );
            match request_tts_chunk(
                &chunk_text,
                &speaker_voice,
                &session_id_clone,
                &api_root_url,
            )
            .await
            {
                Ok(base64_data) => (index, Some(base64_data)),
                Err(e) => {
                    eprintln!("Error processing chunk {}: {}", index + 1, e);
                    (index, None)
                }
            }
        });
    }

    // Collect results
    while let Some(result) = join_set.join_next().await {
        match result {
            Ok((index, data)) => {
                audio_chunks[index] = data;
            }
            Err(e) => {
                eprintln!("Task join error: {}", e);
            }
        }
    }

    // Check if any chunks failed
    if audio_chunks.iter().any(|chunk| chunk.is_none()) {
        return Err("Some audio chunks failed to generate".into());
    }

    // Concatenate all base64 strings and decode
    let concatenated_base64: String = audio_chunks
        .into_iter()
        .filter_map(|chunk| chunk)
        .collect::<Vec<String>>()
        .join("");

    let audio_data = general_purpose::STANDARD.decode(concatenated_base64)?;

    // Output raw audio data to stdout (can be piped to mpv/ffplay)
    use std::io::{self, Write};
    io::stdout().write_all(&audio_data)?;

    Ok(())
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    let text = if args.text.is_empty() {
        // Read from stdin if no arguments provided
        let mut buffer = String::new();
        match io::stdin().read_to_string(&mut buffer) {
            Ok(_) => {
                let trimmed = buffer.trim();
                if trimmed.is_empty() {
                    eprintln!("Error: No text provided via arguments or stdin");
                    process::exit(1);
                }
                trimmed.to_string()
            }
            Err(e) => {
                eprintln!("Error reading from stdin: {}", e);
                process::exit(1);
            }
        }
    } else {
        args.text.join(" ")
    };

    if let Err(e) = process_tts(&text, &args.speaker, args.url_only).await {
        eprintln!("Error: {}", e);
        process::exit(1);
    }
}
