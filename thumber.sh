#!/bin/bash

# Thumbnail generator script
# Takes a directory or file as argument and generates thumbnails for all video files

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <directory|file>"
    exit 1
fi

target="$1"

# Resolve to absolute path if possible
if [[ -e "$target" ]]; then
    # readlink -f will resolve symlinks and produce an absolute path
    target=$(readlink -f -- "$target" 2>/dev/null || printf "%s" "$target")
elif [[ "$target" != /* ]]; then
    # If it doesn't exist yet but is a relative path, make it absolute relative to PWD
    target="$PWD/$target"
fi

# Safer pipeline behavior
set -o pipefail

# Check for required commands
check_deps() {
    local missing=()
    for cmd in ffmpeg ffprobe awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        echo "Error: missing required commands: ${missing[*]}"
        echo "Please install them (eg. sudo apt install ffmpeg)" >&2
        exit 2
    fi
}

check_deps

# Colors and emojis for nicer output (only when stdout is a TTY)
if [[ -t 1 ]]; then
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

EMOJI_OK="✅"
EMOJI_FAIL="❌"
# Function to generate thumbnail for a single video file
generate_thumbnail() {
    local video_file="$1"
    local filename="${video_file%.*}"
    local thumbnail="${filename}-backdrop.jpg"

    # Check if thumbnail already exists
    if [[ -f "$thumbnail" ]]; then
        echo "Thumbnail already exists: $thumbnail"
        return
    fi

    # Print a single-line progress indicator (will append Done/Failed)
    printf "%bGenerating %s...%b" "$BLUE$BOLD" "$(basename "$thumbnail")" "$RESET"

    # Get video duration in seconds
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null)

    # If duration cannot be read, skip this file
    if [[ -z "$duration" ]] || ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        printf " %bSkipped%b\n" "$YELLOW$BOLD" "$RESET"
        echo "Warning: Could not read duration for $video_file, skipping" >&2
        return
    fi

    # Calculate random timestamp (between 10% and 90% of the video)
    local start=$(awk -v dur="$duration" 'BEGIN { printf "%.2f", dur * 0.1 }')
    local end=$(awk -v dur="$duration" 'BEGIN { printf "%.2f", dur * 0.9 }')
    local random_time=$(awk -v start="$start" -v end="$end" 'BEGIN { srand(); printf "%.2f", start + (rand() * (end - start)) }')

    # Generate thumbnail using ffmpeg (silent unless an error occurs)
    local errfile
    errfile=$(mktemp) || errfile="/tmp/thumber_err.$$"
    if ffmpeg -ss "$random_time" -i "$video_file" -vframes 1 "$thumbnail" > /dev/null 2> "$errfile"; then
        printf "%b %bDone%b\n" "$EMOJI_OK" "$GREEN$BOLD" "$RESET"
        rm -f "$errfile"
    else
        printf "%b %bFailed%b\n" "$EMOJI_FAIL" "$RED$BOLD" "$RESET" >&2
        echo "ffmpeg error for $video_file:" >&2
        cat "$errfile" >&2
        rm -f "$errfile"
        echo "Error: Failed to generate thumbnail for $video_file" >&2
    fi
}

# Function to process all video files in a directory
process_directory() {
    local dir="$1"
    local count=0

    # Array of video extensions to look for
    local extensions=("mkv" "mp4" "mov" "avi" "flv" "wmv" "webm" "m4v" "mpg" "mpeg" "3gp")

    # Use bash globbing (nullglob) to safely iterate files including those with spaces
    local ext
    shopt -s nullglob
    for ext in "${extensions[@]}"; do
        for file in "$dir"/*."$ext"; do
            [[ -f "$file" ]] || continue
            generate_thumbnail "$file"
            ((count++))
        done
    done
    shopt -u nullglob

    if [[ $count -eq 0 ]]; then
        echo "No video files found in: $dir"
    else
        echo "Processed $count video file(s)"
    fi
}

# Main logic
if [[ -f "$target" ]]; then
    # Target is a file
    generate_thumbnail "$target"
elif [[ -d "$target" ]]; then
    # Target is a directory
    process_directory "$target"
else
    echo "Error: '$target' is not a valid file or directory"
    exit 1
fi
