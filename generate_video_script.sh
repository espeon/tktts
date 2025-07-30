#!/bin/bash

# Video Script Generator for "What kind of X is this?" videos
# Uses AI CLI tool and TikTok TTS with dual voices
# Requires https://github.com/david-crespo/llm-cli, and the function `ai` in your environment

set -e

# Configuration
QUESTION_VOICE="zh_male_zhubajie_clone2"
ANSWER_VOICE="zh_male_sunwukong_clone2"
OUTPUT_DIR="output"
DEBUG=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat << EOF
Usage: $0 [OPTIONS] "topic"

Generate 'What kind of X is this?' video scripts with dual TikTok TTS voices.

OPTIONS:
    -o, --output-dir DIR    Output directory (default: output)
    -d, --debug            Enable debug output
    -h, --help             Show this help message

EXAMPLES:
    $0 "red cardinal"
    $0 "monarch butterfly" -o butterfly_videos
    $0 "golden retriever" --output-dir dog_videos --debug

OUTPUT:
    - Individual question and answer audio files
    - Combined audio file (requires ffmpeg)
    - Script text file with voice assignments

VOICES:
    Question: $QUESTION_VOICE (Zhu Bajie)
    Answer: $ANSWER_VOICE (Sun Wukong)

REQUIREMENTS:
    - 'ai' zsh function must be available
    - 'tktts' binary must be built and available
    - ffmpeg for audio combination (optional but recommended)
EOF
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

debug() {
    if [ "$DEBUG" = true ]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1" >&2
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if required tools are available
check_requirements() {
    log "Checking requirements..."

    # Check for ai function (try both .zprofile and .zshrc)
    if ! zsh -c "source ~/.zprofile 2>/dev/null || source ~/.zshrc 2>/dev/null || true; type ai" &>/dev/null; then
        error "ai function not found in zsh environment"
        error "Make sure you have the 'ai' function defined in your ~/.zprofile or ~/.zshrc"
        exit 1
    fi
    debug "ai function found"

    # Check for tktts
    TKTTS_PATH=""
    if [ -f "./target/release/tktts" ]; then
        TKTTS_PATH="./target/release/tktts"
    elif [ -f "./tktts" ]; then
        TKTTS_PATH="./tktts"
    elif command -v tktts &>/dev/null; then
        TKTTS_PATH="tktts"
    else
        error "tktts binary not found. Please build it first with: cargo build --release"
        exit 1
    fi
    debug "tktts found at: $TKTTS_PATH"

    # Check for ffmpeg (for combining) and ffplay (for playback)
    if ! command -v ffmpeg &>/dev/null; then
        echo -e "${YELLOW}[WARN]${NC} ffmpeg not found. Audio combination won't work."
        echo "       Install ffmpeg to enable audio combination: brew install ffmpeg"
    fi
}

# Generate AI content
generate_ai_content() {
    local topic="$1"
    local ai_prompt="Generate a short funny but very educational script about \"$topic\" in this exact format:

QUESTION: What kind of [category] is this?
ANSWER: This is a [name]. [One sentence description]. [One sentence about interesting characteristics or behavior].

Rules:
- Replace [category] with the appropriate broad category (e.g., bird, animal, insect, plant, etc.)
- Replace [name] with the specific name/type
- Keep the answer to exactly 2 sentences
- Make it educational and interesting
- Use simple, clear language
- Make it easy for a basic TTS to read the script out loud.

Example format:
QUESTION: What kind of bird is this?
ANSWER: This is a cardinal. Cardinals are bright red songbirds found throughout North America. Male cardinals are more vibrant in color than females and are known for their distinctive crest and powerful song.

Topic: $topic"

    debug "AI Prompt: $ai_prompt"

    # Run AI command through zsh (try both .zprofile and .zshrc)
    local ai_response
    ai_response=$(zsh -c "source ~/.zprofile 2>/dev/null || source ~/.zshrc 2>/dev/null || true; ai --model flash --raw '$ai_prompt'")

    if [ $? -ne 0 ] || [ -z "$ai_response" ]; then
        error "Failed to generate AI content"
        exit 1
    fi

    debug "AI Response: $ai_response"
    echo "$ai_response"
}

# Parse AI response to extract question and answer
parse_ai_response() {
    local ai_response="$1"
    local question=""
    local answer=""

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [[ "$line" =~ ^QUESTION:[[:space:]]*(.*) ]]; then
            question="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^ANSWER:[[:space:]]*(.*) ]]; then
            answer="${BASH_REMATCH[1]}"
        fi
    done <<< "$ai_response"

    if [ -z "$question" ] || [ -z "$answer" ]; then
        error "Could not parse AI response properly"
        error "Expected format: QUESTION: ... and ANSWER: ..."
        error "Got: $ai_response"
        exit 1
    fi

    echo "$question|$answer"
}

# Generate TTS audio
generate_tts() {
    local text="$1"
    local voice="$2"
    local output_file="$3"

    debug "Generating TTS: voice=$voice, file=$output_file"
    debug "Text: $text"

    if echo "$text" | "$TKTTS_PATH" -s "$voice" > "$output_file" 2>/dev/null; then
        success "Generated audio: $output_file"
        return 0
    else
        error "Failed to generate TTS for: $text"
        return 1
    fi
}

# Main script generation function
generate_video_script() {
    local topic="$1"
    local safe_topic="${topic//[^a-zA-Z0-9 _-]/_}"
    safe_topic="${safe_topic// /_}"

    log "Generating script for topic: $topic"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Generate AI content
    log "Generating AI content..."
    local ai_response
    ai_response=$(generate_ai_content "$topic")

    # Parse response
    local parsed
    parsed=$(parse_ai_response "$ai_response")
    local question="${parsed%|*}"
    local answer="${parsed#*|}"

    log "Script generated:"
    echo "  Question: $question"
    echo "  Answer: $answer"

    # Generate audio files
    log "Generating audio files..."

    local question_file="$OUTPUT_DIR/${safe_topic}_question.mp3"
    local answer_file="$OUTPUT_DIR/${safe_topic}_answer.mp3"

    if ! generate_tts "$question" "$QUESTION_VOICE" "$question_file"; then
        exit 1
    fi

    if ! generate_tts "$answer" "$ANSWER_VOICE" "$answer_file"; then
        exit 1
    fi

    # Create script text file
    local script_file="$OUTPUT_DIR/${safe_topic}_script.txt"
    cat > "$script_file" << EOF
Topic: $topic

QUESTION ($QUESTION_VOICE):
$question

ANSWER ($ANSWER_VOICE):
$answer
EOF

    # Combine audio files with ffmpeg using highest quality settings
    local combined_file="$OUTPUT_DIR/${safe_topic}_combined.mp3"
    log "Combining audio files with ffmpeg..."

    if command -v ffmpeg &>/dev/null; then
        # Use concat protocol with copy codec to avoid re-encoding
        if ffmpeg -i "concat:$question_file|$answer_file" -c copy "$combined_file" -y 2>/dev/null; then
            success "Combined audio created: $combined_file"
        else
            # Fallback: Use filter with highest quality settings
            if ffmpeg -i "$question_file" -i "$answer_file" \
               -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[out]" \
               -map "[out]" -c:a copy "$combined_file" -y 2>/dev/null; then
                success "Combined audio created: $combined_file"
            else
                # Last resort: re-encode with maximum quality
                if ffmpeg -i "$question_file" -i "$answer_file" \
                   -filter_complex "[0:a][1:a]concat=n=2:v=0:a=1[out]" \
                   -map "[out]" -c:a libmp3lame -q:a 0 "$combined_file" -y 2>/dev/null; then
                    success "Combined audio created: $combined_file"
                else
                    error "Failed to combine audio files with ffmpeg"
                fi
            fi
        fi
    else
        echo "⚠️  ffmpeg not found. Skipping audio combination."
        echo "   Install ffmpeg to enable audio combination: brew install ffmpeg"
    fi

    # Summary
    success "Script generation complete!"
    echo "📁 Output directory: $OUTPUT_DIR"
    echo "🎤 Question audio: $question_file"
    echo "🎤 Answer audio: $answer_file"
    if [ -f "$combined_file" ]; then
        echo "🎵 Combined audio: $combined_file"
    fi
    echo "📝 Script text: $script_file"
    echo ""
    if [ -f "$combined_file" ]; then
        echo "To play the complete video script: ffplay '$combined_file'"
        echo "Or pipe to another player: ffplay '$combined_file' || mpv '$combined_file'"
    else
        echo "To play individual files:"
        echo "  ffplay '$question_file' && ffplay '$answer_file'"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -z "$TOPIC" ]; then
                TOPIC="$1"
            else
                error "Multiple topics provided. Please provide only one topic."
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [ -z "$TOPIC" ]; then
    error "No topic provided"
    usage
    exit 1
fi

if [ -z "$(echo "$TOPIC" | tr -d '[:space:]')" ]; then
    error "Topic cannot be empty"
    exit 1
fi

# Main execution
main() {
    check_requirements
    generate_video_script "$TOPIC"
}

# Run main function
main
