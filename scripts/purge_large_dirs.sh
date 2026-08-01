#!/usr/bin/env bash
#
# purge_large_dirs.sh — recursively search a directory tree for files larger
# than a threshold (default 52GB), and delete the IMMEDIATE PARENT directory
# of each such file (and everything inside it).
#
# SAFE BY DEFAULT: runs as a dry-run unless you pass --force. Always review
# the dry-run output before forcing.
#
# Usage:
#   ./purge_large_dirs.sh <start_directory> [--threshold 50G] [--force]
#
# Examples:
#   ./purge_large_dirs.sh /mnt/data                     # dry run, 52G threshold
#   ./purge_large_dirs.sh /mnt/data --threshold 10G      # dry run, 10G threshold
#   ./purge_large_dirs.sh /mnt/data --force              # actually deletes
#
# Notes:
# - If multiple oversized files share the same parent directory, that
#   directory is only listed/deleted once.
# - Symlinks are not followed by find's default behavior here.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <start_directory> [--threshold SIZE] [--force]

  <start_directory>   Directory to search recursively
  --threshold SIZE    Size threshold, find-style (default: 52G)
                       e.g. 52G, 10G, 500M
  --force             Actually delete. Without this flag, it's a dry run.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage

start_dir="$1"
shift

threshold="52G"
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)
      threshold="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

[[ -d "$start_dir" ]] || { echo "Error: '$start_dir' is not a directory" >&2; exit 1; }

echo "Searching '$start_dir' for files larger than $threshold ..."
echo

# Find oversized files, get their parent dirs, dedupe.
mapfile -t parent_dirs < <(
  find "$start_dir" -type f -size "+${threshold}" -print0 \
    | xargs -0 -r -n1 dirname \
    | sort -u
)

if [[ ${#parent_dirs[@]} -eq 0 ]]; then
  echo "No files larger than $threshold found. Nothing to do."
  exit 0
fi

echo "Found ${#parent_dirs[@]} director(ies) containing file(s) over $threshold:"
echo

total_reclaim=0
for d in "${parent_dirs[@]}"; do
  size_human=$(du -sh "$d" 2>/dev/null | cut -f1)
  size_bytes=$(du -sb "$d" 2>/dev/null | cut -f1)
  total_reclaim=$((total_reclaim + size_bytes))
  echo "  $d   (total size: $size_human)"
  # Show which file(s) in it triggered the match
  find "$d" -maxdepth 1 -type f -size "+${threshold}" -printf '      -> %f (%s bytes)\n'
done

echo
total_human=$(numfmt --to=iec "$total_reclaim")
echo "Total space that would be reclaimed: $total_human"
echo

if [[ "$force" == false ]]; then
  echo "DRY RUN — nothing was deleted."
  echo "Re-run with --force to actually delete these directories."
  exit 0
fi

echo "About to PERMANENTLY delete ${#parent_dirs[@]} director(ies) listed above."
echo "Press Ctrl+C now to abort."
echo
for i in $(seq 10 -1 1); do
  printf "\rDeleting in %2d seconds... " "$i"
  sleep 1
done
printf "\rDeleting now...              \n"
echo

echo "Deleting ${#parent_dirs[@]} director(ies) ..."
for d in "${parent_dirs[@]}"; do
  echo "  Removing: $d"
  rm -rf -- "$d"
done

echo
echo "Done. Reclaimed approximately $total_human."