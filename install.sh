#!/usr/bin/env bash
set -euo pipefail

app_name="OpenCode Smart Free Launcher"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin_dir=${OPENCODE_SMART_BIN_DIR:-${XDG_BIN_HOME:-"$HOME/.local/bin"}}
config_root=${XDG_CONFIG_HOME:-"$HOME/.config"}
config_dir="$config_root/opencode-smart-launcher"
config_file="$config_dir/config.json"
installed_wrapper="$bin_dir/opencode-free"
shim="$bin_dir/opencode"

die() {
  printf '%s\n' "$app_name: $*" >&2
  exit 1
}

same_file() {
  [ -e "$1" ] && [ -e "$2" ] && [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ]
}

uninstall_launcher() {
  if [ -L "$shim" ] && same_file "$shim" "$installed_wrapper"; then
    rm -f -- "$shim"
  fi
  rm -f -- "$installed_wrapper" "$config_file"
  rmdir "$config_dir" 2>/dev/null || true
  printf '%s\n' "$app_name removed. The underlying OpenCode installation was kept."
}

if [ "${1:-}" = "--uninstall" ]; then
  uninstall_launcher
  exit 0
fi

command -v python3 >/dev/null 2>&1 || die "Python 3 is required. Install it with your distribution's package manager."
[ -f "$script_dir/opencode-free" ] || die "opencode-free is missing beside install.sh"

real_binary=""
if [ -f "$config_file" ]; then
  real_binary=$(python3 - "$config_file" <<'PY' || true
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("real_binary", "")
    print(value if isinstance(value, str) else "")
except (OSError, ValueError):
    pass
PY
)
  [ -f "$real_binary" ] || real_binary=""
fi

if [ -z "$real_binary" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then
  real_binary="$HOME/.opencode/bin/opencode"
fi

if [ -z "$real_binary" ] && command -v opencode >/dev/null 2>&1; then
  candidate=$(command -v opencode)
  if ! same_file "$candidate" "$script_dir/opencode-free" && ! same_file "$candidate" "$installed_wrapper"; then
    real_binary=$(readlink -f "$candidate")
  fi
fi

if [ -z "$real_binary" ]; then
  command -v curl >/dev/null 2>&1 || die "curl is required to install OpenCode"
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "$temp_dir"' EXIT
  printf '%s\n' "OpenCode was not found; installing it from opencode.ai..."
  curl -fsSL https://opencode.ai/v2/install -o "$temp_dir/opencode-install.sh"
  bash "$temp_dir/opencode-install.sh" --no-modify-path
  [ -x "$HOME/.opencode/bin/opencode" ] || die "OpenCode installed but its binary could not be located"
  real_binary="$HOME/.opencode/bin/opencode"
fi

version=$($real_binary --version 2>/dev/null || true)
[ -n "$version" ] || die "the detected OpenCode binary did not run: $real_binary"

mkdir -p -- "$bin_dir" "$config_dir"
install -m 0755 "$script_dir/opencode-free" "$installed_wrapper"

python3 - "$config_file" "$real_binary" <<'PY'
import json, os, sys
path, binary = sys.argv[1:]
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump({"schema": 1, "real_binary": os.path.realpath(binary)}, handle, indent=2)
    handle.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

if [ -e "$shim" ] && [ ! -L "$shim" ]; then
  die "$shim already exists and is not a symlink; refusing to overwrite it"
fi
ln -sfn -- "$installed_wrapper" "$shim"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    if [ "${OPENCODE_SMART_NO_MODIFY_PATH:-0}" != "1" ]; then
      profile="$HOME/.profile"
      marker='# OpenCode Smart Free Launcher'
      if ! grep -Fq "$marker" "$profile" 2>/dev/null; then
        {
          printf '\n%s\n' "$marker"
          printf 'export PATH="%s:$PATH"\n' "$bin_dir"
        } >> "$profile"
      fi
    fi
    ;;
esac

printf '%s\n' "$app_name installed."
printf 'Real OpenCode: %s (%s)\n' "$real_binary" "$version"
printf 'Wrapper: %s\n' "$shim"
printf '%s\n' "Open a new terminal, then run: opencode-free --smart-free-status"
