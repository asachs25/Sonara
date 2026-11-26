#!/usr/bin/env bash
# =============================================================================
# organize_splits.sh — create raw_data/train, raw_data/val and raw_data/test
#
# Reads the conversation IDs and their split from data/conversation_splits.csv
# and puts each conversation's audio from raw_data/new_flac/ into its split
# folder. Conversations labelled "excluded" are skipped.
#
#   raw_data/new_flac/conv_x/speaker_a.flac  ->  raw_data/train/conv_x/speaker_a.flac
#
# By default it uses hard links: the files appear in both places but are only
# stored once (no extra disk space, takes seconds). new_flac stays as it is.
#
# Usage (from anywhere; the script finds the repo root itself, so it can live
# in the repo root or in a subfolder like scripts/):
#   bash organize_splits.sh            # hard links (copies if linking isn't possible)
#   bash organize_splits.sh --move     # move the folders out of new_flac instead
#
# Expects (repo root):
#   data/conversation_splits.csv      conversation_id,split
#   raw_data/new_flac/conv_*/         speaker_a.flac, speaker_b.flac (already 16 kHz)
#
# Safe to rerun: anything already in place is skipped.
# =============================================================================
set -euo pipefail

MODE="link"
case "${1:-}" in
  "") ;;
  --move) MODE="move" ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (use --move or nothing)"; exit 1 ;;
esac

# Find the repo root: the first folder, going up from this script, that has
# data/conversation_splits.csv. Works whether the script sits in the repo root
# or in a subfolder such as scripts/.
ROOT="$(cd "$(dirname "$0")" && pwd)"
while [ ! -f "$ROOT/data/conversation_splits.csv" ] && [ "$ROOT" != "/" ]; do
  ROOT="$(dirname "$ROOT")"
done
if [ "$ROOT" = "/" ]; then
  echo "Could not find data/conversation_splits.csv in this folder or any folder above it."
  echo "Put the script inside the repo (e.g. Sonara/ or Sonara/scripts/) and git pull."
  exit 1
fi
SPLITS="$ROOT/data/conversation_splits.csv"
SRC="$ROOT/raw_data/new_flac"
RAW="$ROOT/raw_data"
FILES="speaker_a.flac speaker_b.flac"

# ---------------------------------------------------------------- checks
[ -f "$SPLITS" ] || { echo "Missing $SPLITS (git pull?)"; exit 1; }
[ -d "$SRC" ]    || { echo "Missing $SRC (convert the audio to 16 kHz first)"; exit 1; }
# Clean copy of the CSV (no Windows line endings, no header) that every step
# reads directly. Reading a file avoids pipes like `tr | grep -q`, which can
# fail under `set -o pipefail` when grep stops early.
CLEAN="$(mktemp "${TMPDIR:-/tmp}/splits.XXXXXX")"
trap 'rm -f "$CLEAN"' EXIT
tr -d '\r' < "$SPLITS" > "$CLEAN"
[ "$(head -1 "$CLEAN")" = "conversation_id,split" ] \
  || { echo "Unexpected header in $SPLITS (expected: conversation_id,split)"; exit 1; }
sed -i.bak '1d' "$CLEAN" && rm -f "$CLEAN.bak"
[ -n "$(tail -c 1 "$CLEAN")" ] && echo >> "$CLEAN"     # make sure the last line ends with a newline

echo "Splits: $SPLITS"
echo "Source: $SRC"
echo "Mode:   $MODE"
echo

# ---------------------------------------------------------------- organize
linked=0; copied=0; moved=0; skipped=0; missing=0
MISSING_LIST="$RAW/.missing_conversations.txt"
: > "$MISSING_LIST"

# read the CSV in this shell (not a pipe) so the counters survive the loop
while IFS=, read -r id split || [ -n "$id" ]; do
  case "$split" in train|val|test) ;; *) continue ;; esac

  if [ "$MODE" = "move" ]; then
    if [ -d "$RAW/$split/$id" ] && [ ! -d "$SRC/$id" ]; then
      skipped=$((skipped + 1)); continue
    fi
    if [ ! -d "$SRC/$id" ]; then
      echo "$id" >> "$MISSING_LIST"; missing=$((missing + 1)); continue
    fi
    mkdir -p "$RAW/$split"
    if [ -d "$RAW/$split/$id" ]; then          # partly done earlier: move file by file
      for f in $FILES; do
        [ -e "$SRC/$id/$f" ] && [ ! -e "$RAW/$split/$id/$f" ] && mv "$SRC/$id/$f" "$RAW/$split/$id/$f"
      done
      rmdir "$SRC/$id" 2>/dev/null || true
    else
      mv "$SRC/$id" "$RAW/$split/$id"
    fi
    moved=$((moved + 1))
    continue
  fi

  # link mode
  if [ ! -d "$SRC/$id" ] && [ ! -d "$RAW/$split/$id" ]; then
    echo "$id" >> "$MISSING_LIST"; missing=$((missing + 2)); continue
  fi
  mkdir -p "$RAW/$split/$id"
  for f in $FILES; do
    src="$SRC/$id/$f"
    dst="$RAW/$split/$id/$f"
    if [ -e "$dst" ]; then
      skipped=$((skipped + 1))
    elif [ ! -f "$src" ]; then
      echo "$id/$f" >> "$MISSING_LIST"; missing=$((missing + 1))
    elif ln "$src" "$dst" 2>/dev/null; then
      linked=$((linked + 1))
    else
      cp "$src" "$dst"; copied=$((copied + 1))
    fi
  done
done < "$CLEAN"

if [ "$MODE" = "move" ]; then
  echo "Folders moved: $moved   already there: $skipped   missing in new_flac: $missing"
else
  echo "Files linked: $linked   copied: $copied   already there: $skipped   missing in new_flac: $missing"
fi
[ "$missing" -gt 0 ] && echo "  list of missing: $MISSING_LIST" || rm -f "$MISSING_LIST"

# ---------------------------------------------------------------- check
echo
echo "Check:"
OK=1
for s in train val test; do
  expected=$(grep -c ",$s\$" "$CLEAN" || true)
  complete=0; extra=0
  if [ -d "$RAW/$s" ]; then
    for d in "$RAW/$s"/conv_*; do
      [ -d "$d" ] || continue
      if ! grep -q "^$(basename "$d"),$s\$" "$CLEAN"; then
        extra=$((extra + 1)); continue                 # folder not labelled $s in the CSV
      fi
      [ -f "$d/speaker_a.flac" ] && [ -f "$d/speaker_b.flac" ] && complete=$((complete + 1))
    done
  fi
  if [ "$complete" -eq "$expected" ] && [ "$extra" -eq 0 ]; then mark="OK"; else mark="INCOMPLETE"; OK=0; fi
  printf "  %-5s %5s / %-5s conversations complete   %s\n" "$s" "$complete" "$expected" "$mark"
  [ "$extra" -gt 0 ] && echo "        $extra folder(s) in raw_data/$s are not labelled '$s' in the CSV (old split?)"
done

# no conversation may sit in two split folders
dupes=$(for s in train val test; do if [ -d "$RAW/$s" ]; then ls "$RAW/$s"; fi; done | sort | uniq -d | wc -l | tr -d ' ')
if [ "$dupes" -eq 0 ]; then
  echo "  no conversation in more than one split        OK"
else
  echo "  $dupes conversations appear in more than one split   PROBLEM"; OK=0
fi

echo
if [ "$OK" -eq 1 ]; then
  echo "Done: raw_data/train, raw_data/val and raw_data/test are ready."
else
  echo "Not complete. Check the messages above."
  exit 1
fi
