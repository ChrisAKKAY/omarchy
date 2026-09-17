echo "Prefer Omarchy packages over the delayed Arch repositories"

(
  set -euo pipefail

  config=$(readlink -f "${OMARCHY_PACMAN_CONF:-/etc/pacman.conf}")
  repos=$(pacman-conf --config "$config" --repo-list)
  grep -qx 'omarchy' <<<"$repos" || exit 0

  updated=$(mktemp)
  trap 'rm -f "$updated"' EXIT

  # Move the complete repository block, keeping custom repositories and options.
  awk '
    {
      lines[NR] = $0
      header = $0
      sub(/#.*/, "", header)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", header)
      if (header ~ /^\[[^]]+\]$/) {
        if (start && !end) end = NR - 1
        if (header == "[omarchy]") {
          if (start) exit 1
          start = NR
        }
        if (!arch && header ~ /^\[(core|extra|multilib|community)(-testing|-staging)?\]$/) arch = NR
      }
    }
    END {
      if (!end) end = NR
      for (i = 1; i <= NR; i++) {
        if (start && arch && start > arch) {
          if (i == arch) for (j = start; j <= end; j++) print lines[j]
          if (i >= start && i <= end) continue
        }
        print lines[i]
      }
    }
  ' "$config" >"$updated"

  # Includes can define repositories too; refuse a partial reorder in that case.
  repos=$(pacman-conf --config "$updated" --repo-list)
  if ! awk '
    $0 == "omarchy" { found = 1 }
    /^(core|extra|multilib|community)(-testing|-staging)?$/ && !found { exit 1 }
    END { if (!found) exit 1 }
  ' <<<"$repos"; then
    echo "Could not move [omarchy] before Arch repositories. Move it in the included pacman configuration, then rerun the migration." >&2
    exit 1
  fi

  if ! cmp -s "$config" "$updated"; then
    sudo cp --preserve=all --backup=numbered "$config" "$config.omarchy-priority.bak"
    staged=$(sudo mktemp "${config}.omarchy-priority.XXXXXX")
    trap 'rm -f "$updated"; sudo rm -f "$staged"' EXIT
    sudo cp --preserve=all "$config" "$staged"
    sudo tee "$staged" <"$updated" >/dev/null
    sudo mv -f "$staged" "$config"
  fi
)
