#!/bin/zsh
# 영어 번역이 빠진 화면 문구 찾기: 컴파일러가 뽑은 한국어 문구 중 Resources/en.lproj에 없는 것을 보여 줌
# (SwiftUI 글자와 String(localized:)만 뽑힘. 그냥 "…" 문자열로 화면에 보내는 글은 String(localized:)로 감쌀 것)
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swift build --build-path "$OUT/build" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/strings" >/dev/null
plutil -convert json -o "$OUT/en.json" Resources/en.lproj/Localizable.strings
python3 - "$OUT/strings" "$OUT/en.json" <<'PY'
import glob, json, os, re, sys
strings, english = sys.argv[1], json.load(open(sys.argv[2]))
missing = {}
for path in glob.glob(os.path.join(strings, "*.stringsdata")):
    data = json.load(open(path))
    for entries in data["tables"].values():
        for entry in entries:
            key = entry["key"]
            if re.search("[가-힣]", key) and key not in english:
                missing.setdefault(key, f'{os.path.basename(data["source"])}:{entry["location"]["startingLine"]}')
for key, where in sorted(missing.items(), key=lambda item: item[1]):
    print(f"{where}\t{json.dumps(key, ensure_ascii=False)}")
print(f"번역 없음: {len(missing)}개" if missing else "모든 문구에 영어 번역이 있어요")
PY
