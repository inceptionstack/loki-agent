#!/usr/bin/env bash
# scripts/build-installer.sh
#
# Inlines lib/telemetry.sh into install.sh between marker comments so that
# `curl -sfL install.lowkey.run | bash` works without a second network fetch
# or on-disk file lookup.
#
# Edit telemetry ONLY in lib/telemetry.sh. Run this script (or commit — CI
# runs the build on push) to regenerate the inlined block in install.sh.

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")/.."

INSTALLER="install.sh"
LIB="lib/telemetry.sh"

for f in "$INSTALLER" "$LIB"; do
  [[ -f "$f" ]] || { echo "ERROR: $f not found" >&2; exit 1; }
done

python3 - "$INSTALLER" "$LIB" <<'PY'
import re, sys, pathlib

installer_path, lib_path = sys.argv[1], sys.argv[2]
installer = pathlib.Path(installer_path).read_text()
lib = pathlib.Path(lib_path).read_text()

BEGIN = "# >>> INLINE: lib/telemetry.sh (generated — do not edit; see scripts/build-installer.sh) <<<"
END   = "# >>> END INLINE <<<"

if BEGIN not in installer:
    print(f"ERROR: begin marker not found in {installer_path}:\n  {BEGIN}", file=sys.stderr)
    sys.exit(1)
if END not in installer:
    print(f"ERROR: end marker not found in {installer_path}:\n  {END}", file=sys.stderr)
    sys.exit(1)

# Strip shebang from lib
lib_lines = lib.splitlines(keepends=True)
if lib_lines and lib_lines[0].startswith("#!"):
    lib_lines = lib_lines[1:]
lib_body = "".join(lib_lines).rstrip() + "\n"

# Replace everything between (and including) the markers
pattern = re.compile(
    r"^" + re.escape(BEGIN) + r"\n.*?^" + re.escape(END) + r"$",
    re.DOTALL | re.MULTILINE,
)
replacement = BEGIN + "\n" + lib_body + END
new = pattern.sub(lambda m: replacement, installer, count=1)

if new == installer:
    # Only markers present with no body yet; still treat as a rewrite
    pass

pathlib.Path(installer_path).write_text(new)
PY

if ! bash -n "$INSTALLER"; then
  echo "ERROR: built $INSTALLER failed syntax check" >&2
  exit 1
fi

chmod +x "$INSTALLER"
echo "$INSTALLER: regenerated from $LIB"
