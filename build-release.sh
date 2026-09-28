#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
version=$(tr -d '[:space:]' < "$script_dir/VERSION")
[ -n "$version" ] || { printf '%s\n' "VERSION is empty" >&2; exit 1; }

dist_dir="$script_dir/dist"
linux_archive="$dist_dir/opencode-smart-launcher-linux-$version.tar.gz"
windows_archive="$dist_dir/opencode-smart-launcher-windows-$version.zip"
checksums="$dist_dir/SHA256SUMS"
package_root="opencode-smart-launcher-$version"

mkdir -p -- "$dist_dir"
rm -f -- "$linux_archive" "$windows_archive" "$checksums"

tar -C "$script_dir" \
  --transform "s,^,$package_root/," \
  -czf "$linux_archive" \
  install.sh opencode-free README.md LICENSE THIRD_PARTY_NOTICES.md VERSION

python3 - "$script_dir" "$windows_archive" "$package_root" <<'PY'
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
destination = Path(sys.argv[2])
package_root = sys.argv[3]
files = [
    "install.ps1",
    "windows/opencode-smart.ps1",
    "windows/opencode.cmd",
    "windows/opencode-free.cmd",
    "README.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "VERSION",
]
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for relative in files:
        archive.write(root / relative, f"{package_root}/{relative}")
PY

(
  cd "$dist_dir"
  sha256sum "$(basename -- "$linux_archive")" "$(basename -- "$windows_archive")" > SHA256SUMS
)

printf 'Built %s\n' "$linux_archive"
printf 'Built %s\n' "$windows_archive"
printf 'Checksums: %s\n' "$checksums"
