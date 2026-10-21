#!/bin/sh
# Reproducible release archives.
#
# A rebuild from the same tree must produce the same bytes. Both release
# builds stage one directory and call reproducible_tar, which fixes every
# entry's mtime to one epoch, adds entries in byte-sorted name order, stores
# uid and gid 0 with empty names, and compresses with gzip -n so no file name
# or timestamp is written.
#
# The epoch is SOURCE_DATE_EPOCH when set, else the HEAD commit time, else a
# constant derived from the release version, so a source tarball without git
# still builds deterministically.
#
# Usage:
#   . "$root/scripts/reproducible-archive.sh"
#   epoch=$(reproducible_epoch "$root" "$version")
#   reproducible_tar "$stage" "$name" "$out/$name.tar.gz" "$epoch"

# Prints the one mtime every archive entry carries.
reproducible_epoch() { # root version
  root=$1
  version=$2

  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    printf '%s\n' "$SOURCE_DATE_EPOCH"
    return 0
  fi

  epoch=$(git -C "$root" log -1 --format=%ct 2>/dev/null || true)
  case $epoch in
    '' | *[!0-9]*) version_epoch "$version" ;;
    *) printf '%s\n' "$epoch" ;;
  esac
}

# Without git, map major.minor.patch onto one fixed second: 1980-01-01 UTC
# (315532800) plus the release number, so one release always builds the same.
version_epoch() { # version
  version=$1
  major=${version%%.*}
  rest=${version#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  patch=${patch%%[!0-9]*}

  case $major$minor$patch in
    '' | *[!0-9]*) printf '%s\n' 315532800 ;;
    *) printf '%s\n' $((315532800 + major * 1000000 + minor * 1000 + patch)) ;;
  esac
}

# Writes one tar.gz whose bytes depend only on the staged content.
reproducible_tar() { # stage name outfile epoch
  stage=$1
  name=$2
  outfile=$3
  epoch=$4

  # One timestamp for every entry, set with the date tool of this system.
  # touch -t reads the stamp in local time, so pin UTC to land on the epoch.
  if date --version 2>/dev/null | grep -q 'GNU coreutils'; then
    stamp=$(date -u -d "@$epoch" +%Y%m%d%H%M.%S)
  else
    stamp=$(date -u -r "$epoch" +%Y%m%d%H%M.%S)
  fi
  TZ=UTC0 find "$stage" -exec touch -h -t "$stamp" {} +

  # The directory first, then every entry in byte order. No recursion, so the
  # archive holds them in exactly this order under every tar.
  entries=$stage/.entries
  {
    printf '%s\n' "$name"
    ( cd "$stage" && find "$name" -mindepth 1 -print | LC_ALL=C sort )
  } >"$entries"

  tarfile=$stage/.archive.tar
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner \
      --no-recursion -C "$stage" -cf "$tarfile" -T "$entries"
  else
    tar --format=ustar --uid 0 --gid 0 --uname '' --gname '' \
      -n -C "$stage" -cf "$tarfile" -T "$entries"
  fi
  gzip -n -9 <"$tarfile" >"$outfile"

  rm -f "$entries" "$tarfile"
}
