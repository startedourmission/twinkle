#!/bin/bash
# 내레이션(audio/take1.mp3)을 문장 단위로 잘라 장면 시점에 맞춰 놓고 영상에 입힘
# 형식: "원본 시작초 끝초 영상에서 시작할 초"
set -e
cd "$(dirname "$0")"
SEGS=(
  "0.00 6.10 0.40"     # Meet Twinkle. … it gets to work.
  "6.20 10.10 7.20"    # Claude, Codex, Grok. Every note can have its own.
  "10.24 12.60 12.30"  # If an agent has a question, just reply.
  "12.73 15.88 19.00"  # Drag a task on the calendar…
  "15.97 19.63 25.20"  # Tag a few notes…
  "19.78 20.72 31.80"  # Write it down.
  "20.79 21.92 32.75"  # It gets done.
  "22.08 22.80 35.55"  # Twinkle.
)
F=""; L=""; i=0
for s in "${SEGS[@]}"; do set -- $s
  ms=$(awk "BEGIN{print int($3*1000)}")
  F+="[0:a]atrim=$1:$2,asetpts=PTS-STARTPTS,afade=t=in:d=0.03,afade=t=out:st=$(awk "BEGIN{print $2-$1-0.05}"):d=0.05,adelay=$ms:all=1[a$i];"; L+="[a$i]"; i=$((i+1))
done
ffmpeg -y -loglevel error -i audio/take1.mp3 -filter_complex "${F}${L}amix=inputs=$i:normalize=0,apad=whole_dur=39.5[a]" -map "[a]" -t 39.5 out/narration.wav
ffmpeg -y -loglevel error -i out/twinkle-minimal.mp4 -i out/narration.wav -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart out/twinkle-minimal-voice.mp4
echo "완료: out/twinkle-minimal-voice.mp4"
