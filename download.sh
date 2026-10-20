#!/usr/bin/env bash
set -e

# ==========================================
# CONFIGURATION & ENVIRONMENT
# ==========================================
export TZ="Europe/Oslo"

VIDEO_URL="${1:-}"
TARGET_DATE="${2:-2026-10-04 13:00}"

if [ -z "$VIDEO_URL" ]; then
  echo "Feil: Ingen video-URL ble oppgitt."
  echo "Bruk: $0 '<video_url(er)>' '[target_date]'"
  exit 1
fi

echo "=== 1. INSTALLING SYSTEM DEPENDENCIES (ARCH) ==="
# Sørg for at ffmpeg og python er installert via pacman
sudo pacman -S --needed --noconfirm ffmpeg python

echo "=== 2. SETTING UP PYTHON VIRTUAL ENVIRONMENT ==="
python -m venv venv
source venv/bin/activate.fish

# Oppgrader pip inne i venv og installer yt-dlp med curl-cffi støtte
pip install --upgrade pip
pip install "yt-dlp[default,curl-cffi]"

echo "=== 3. DOWNLOADING VIDEOS ==="
mkdir -p downloads
cd downloads

# Håndter cookies hvis miljøvariabelen PORNHUB_COOKIES er satt
if [ -n "${PORNHUB_COOKIES:-}" ]; then
  echo "$PORNHUB_COOKIES" > cookies.txt
  COOKIE_PARAM="--cookies cookies.txt"
else
  COOKIE_PARAM=""
fi

# Normaliser input ved å bytte ut kommaer med mellomrom
NORMALIZED_URLS=$(echo "$VIDEO_URL" | tr ',' ' ')

# Kjør yt-dlp inne i venv med cookies og impersonate
yt-dlp $COOKIE_PARAM --impersonate chrome -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" $NORMALIZED_URLS

# Rydd opp cookie-filen
rm -f cookies.txt
cd ..

echo "=== 4. INJECTING NORWAY METADATA & TIMESTAMPS ==="
mkdir -p processed_downloads

python3 -c '
import os, glob, subprocess
from datetime import datetime, timedelta

raw_input = "'"$TARGET_DATE"'"

base_date = None
matched_fmt = None
for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
    try:
        base_date = datetime.strptime(raw_input, fmt)
        matched_fmt = fmt
        break
    except ValueError:
        pass

if base_date is None:
    base_date = datetime.utcnow().replace(hour=13, minute=0, second=0)
elif matched_fmt == "%Y-%m-%d":
    base_date = base_date.replace(hour=13, minute=0, second=0)

current_dt = base_date
raw_files = sorted(glob.glob("downloads/*"))

for file_path in raw_files:
    if os.path.isfile(file_path):
        orig_filename = os.path.basename(file_path)
        out_path = os.path.join("processed_downloads", orig_filename)
        
        iso_creation_time = current_dt.strftime("%Y-%m-%dT%H:%M:%S") + "+02:00"

        cmd = [
            "ffmpeg", "-i", file_path,
            "-map_metadata", "-1",
            "-metadata", f"creation_time={iso_creation_time}",
            "-metadata", "location=59.9139+10.7522/",
            "-metadata", "location-eng=Norway",
            "-c", "copy",
            "-fflags", "+bitexact",
            out_path, "-y"
        ]
        res = subprocess.run(cmd)
        if res.returncode != 0:
            subprocess.run(["cp", file_path, out_path])

        touch_time_str = current_dt.strftime("%Y-%m-%d %H:%M:%S")
        subprocess.run(["touch", "-d", touch_time_str, out_path], check=True)

        current_dt += timedelta(seconds=1)
'

# Deaktiver venv når vi er ferdige
deactivate

echo "=== 5. VERIFYING PROCESSED FILES ==="
ls -la --time-style=full-iso processed_downloads/

echo "Ferdig! Alle filer ligger klart i mappen 'processed_downloads/'."
