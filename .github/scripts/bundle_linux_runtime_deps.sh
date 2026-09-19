#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <flutter-linux-bundle-dir>" >&2
  exit 2
fi

bundle_dir="$1"
lib_dir="$bundle_dir/lib"

if [ ! -d "$bundle_dir" ]; then
  echo "Linux bundle directory not found: $bundle_dir" >&2
  exit 1
fi

mkdir -p "$lib_dir"

copy_soname() {
  local soname="$1"
  local src
  src="$(ldconfig -p | awk -v name="$soname" '$1 == name && $NF ~ /^\// { print $NF; exit }')"
  if [ -z "$src" ] || [ ! -e "$src" ]; then
    echo "::warning ::Linux runtime library not found: $soname"
    return 0
  fi

  cp -Lv "$src" "$lib_dir/$soname"
}

runtime_libs=(
  libayatana-appindicator3.so.1
  libayatana-indicator3.so.7
  libayatana-ido3-0.4.so.0
  libdbusmenu-glib.so.4
  libdbusmenu-gtk3.so.4
  libsecret-1.so.0
  libjson-glib-1.0.so.0
)

for lib in "${runtime_libs[@]}"; do
  copy_soname "$lib"
done

targets=()
if [ -f "$bundle_dir/sena_repo" ]; then
  targets+=("$bundle_dir/sena_repo")
fi
while IFS= read -r -d '' lib_path; do
  targets+=("$lib_path")
done < <(find "$lib_dir" -maxdepth 1 -type f -name "*.so*" -print0)

if [ "${#targets[@]}" -gt 0 ]; then
  missing="$(
    for target in "${targets[@]}"; do
      LD_LIBRARY_PATH="$lib_dir:${LD_LIBRARY_PATH:-}" ldd "$target" \
        | awk '/not found/ { print $1 }'
    done | sort -u
  )"
  if [ -n "$missing" ]; then
    echo "Missing Linux runtime libraries after bundling:" >&2
    echo "$missing" >&2
    exit 1
  fi
fi
