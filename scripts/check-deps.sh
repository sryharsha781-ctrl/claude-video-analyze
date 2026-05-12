#!/usr/bin/env bash
# Detect which dependencies are present and print install commands for what's missing.
# Pure detection — never installs anything itself.

set -u

missing=()
have=()

check() {
  if command -v "$1" >/dev/null 2>&1; then
    have+=("$1")
  else
    missing+=("$1")
  fi
}

check ffmpeg
check ffprobe
check yt-dlp
if   command -v whisper-cli >/dev/null 2>&1; then have+=("whisper-cli")
elif command -v whisper-cpp >/dev/null 2>&1; then have+=("whisper-cpp")
elif command -v whisper     >/dev/null 2>&1; then have+=("whisper")
else missing+=("whisper-cpp")
fi

echo "Found:   ${have[*]:-(none)}"
echo "Missing: ${missing[*]:-(none)}"

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "All dependencies present."
  exit 0
fi

os="$(uname -s)"
echo
echo "To install the missing tools:"
case "$os" in
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      echo "  brew install ${missing[*]}"
    else
      echo "  Install Homebrew first: https://brew.sh"
      echo "  Then: brew install ${missing[*]}"
    fi
    ;;
  Linux)
    if   command -v apt-get >/dev/null 2>&1; then
      # whisper-cpp is rarely packaged on apt; flag it
      pkgs=()
      for m in "${missing[@]}"; do
        case "$m" in
          whisper-cpp)
            echo "  # whisper-cpp: build from source — https://github.com/ggerganov/whisper.cpp" ;;
          *) pkgs+=("$m") ;;
        esac
      done
      [[ ${#pkgs[@]} -gt 0 ]] && echo "  sudo apt-get update && sudo apt-get install -y ${pkgs[*]}"
    elif command -v dnf >/dev/null 2>&1; then
      echo "  sudo dnf install -y ${missing[*]}"
    elif command -v pacman >/dev/null 2>&1; then
      echo "  sudo pacman -S --needed ${missing[*]}"
    else
      echo "  Use your distro's package manager to install: ${missing[*]}"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if command -v winget >/dev/null 2>&1; then
      echo "  winget install Gyan.FFmpeg yt-dlp.yt-dlp"
      echo "  # whisper-cpp: build from source — https://github.com/ggerganov/whisper.cpp"
    elif command -v scoop >/dev/null 2>&1; then
      echo "  scoop install ffmpeg yt-dlp"
      echo "  # whisper-cpp: build from source — https://github.com/ggerganov/whisper.cpp"
    else
      echo "  Install winget or scoop, then re-run."
    fi
    ;;
  *) echo "  Unknown OS ($os) — install manually: ${missing[*]}" ;;
esac

exit 1
