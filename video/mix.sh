#!/bin/bash
# 내레이션(audio/v2-take1.mp3)을 문장 단위로 잘라 장면 시점에 맞춰 놓고 영상에 입힘
# 형식: "원본 시작초 끝초 영상에서 시작할 초"
set -e
cd "$(dirname "$0")"
SEGS=(
  "0.00 6.80 0.30"     # Meet Twinkle. … it's already on it.
  "7.15 12.10 7.20"    # Claude, Codex, Grok. Use whichever you like…
  "12.43 17.00 12.30"  # Got a question back? Reply right under the task…
  "17.36 22.65 17.10"  # Your deadlines land on a calendar. Drag a task…
  "23.01 29.72 22.90"  # Spread your notes out, tag a few…
  "30.05 31.95 30.25"  # Write it down. It gets done.
  "32.25 33.50 33.20"  # This is Twinkle.
)
F=""; L=""; i=0
for s in "${SEGS[@]}"; do set -- $s
  ms=$(awk "BEGIN{print int($3*1000)}")
  F+="[0:a]atrim=$1:$2,asetpts=PTS-STARTPTS,afade=t=in:d=0.03,afade=t=out:st=$(awk "BEGIN{print $2-$1-0.05}"):d=0.05,adelay=$ms:all=1[a$i];"; L+="[a$i]"; i=$((i+1))
done
ffmpeg -y -loglevel error -i audio/v2-take1.mp3 -filter_complex "${F}${L}amix=inputs=$i:normalize=0,apad=whole_dur=36[a]" -map "[a]" -t 36 out/narration.wav
ffmpeg -y -loglevel error -i out/twinkle-minimal.mp4 -i out/narration.wav -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart out/twinkle-minimal-voice.mp4
echo "완료: out/twinkle-minimal-voice.mp4"
