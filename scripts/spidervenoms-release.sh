#!/usr/bin/env bash

spidervenoms_release_version="0.5.3"
spidervenoms_release_repo="DeanoC/SpiderVenoms"

spidervenoms_normalize_os() {
  local raw="${1:-}"
  case "${raw:-$(uname -s)}" in
    Linux|linux) printf '%s' "linux" ;;
    Darwin|darwin|macOS|macos) printf '%s' "macos" ;;
    *) return 1 ;;
  esac
}

spidervenoms_normalize_arch() {
  local raw="${1:-}"
  case "${raw:-$(uname -m)}" in
    x86_64|amd64) printf '%s' "x86_64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    *) return 1 ;;
  esac
}

spidervenoms_release_url_for_platform() {
  local os arch
  os="$(spidervenoms_normalize_os "${1:-}")" || return 1
  arch="$(spidervenoms_normalize_arch "${2:-}")" || return 1
  case "${os}:${arch}" in
    linux:arm64)
      printf '%s' "https://github.com/DeanoC/SpiderVenoms/releases/download/v0.5.3/spidervenoms-managed-local-linux-arm64.tar.gz"
      ;;
    linux:x86_64)
      printf '%s' "https://github.com/DeanoC/SpiderVenoms/releases/download/v0.5.3/spidervenoms-managed-local-linux-x86_64.tar.gz"
      ;;
    macos:arm64)
      printf '%s' "https://github.com/DeanoC/SpiderVenoms/releases/download/v0.5.3/spidervenoms-managed-local-macos-arm64.tar.gz"
      ;;
    *)
      return 1
      ;;
  esac
}

spidervenoms_release_checksum_url_for_platform() {
  local release_url
  release_url="$(spidervenoms_release_url_for_platform "${1:-}" "${2:-}")" || return 1
  printf '%s' "${release_url}.sha256"
}

spidervenoms_release_sha256_for_platform() {
  local os arch
  os="$(spidervenoms_normalize_os "${1:-}")" || return 1
  arch="$(spidervenoms_normalize_arch "${2:-}")" || return 1
  case "${os}:${arch}" in
    linux:arm64)
      printf '%s' "42f66f4423d8e7152ec93352311887364bb0b6c84c94fe632543ef58fabac628"
      ;;
    linux:x86_64)
      printf '%s' "cb11fa2060484f5fd7f55fae74047bb3c2a58f7cb947f429d2a099075f56893e"
      ;;
    macos:arm64)
      printf '%s' "19130cb6731aaa0dcbd5b8bbfc7e4853e729aa4acef5ce2c1f72369d1c435fcc"
      ;;
    *)
      return 1
      ;;
  esac
}

spidervenoms_verify_pinned_checksum_file() {
  local os arch expected_sha checksum_url tmp_file remote_sha
  os="$(spidervenoms_normalize_os "${1:-}")" || return 1
  arch="$(spidervenoms_normalize_arch "${2:-}")" || return 1
  expected_sha="$(spidervenoms_release_sha256_for_platform "$os" "$arch")" || return 1
  checksum_url="$(spidervenoms_release_checksum_url_for_platform "$os" "$arch")" || return 1

  command -v curl >/dev/null 2>&1 || {
    echo "error: curl is required to verify SpiderVenoms release checksum pins" >&2
    return 1
  }

  tmp_file="$(mktemp)"
  curl -fsSL "$checksum_url" -o "$tmp_file"
  remote_sha="$(awk 'NR == 1 { print $1 }' "$tmp_file")"
  rm -f "$tmp_file"

  if [[ -z "$remote_sha" ]]; then
    echo "error: SpiderVenoms checksum file was empty: $checksum_url" >&2
    return 1
  fi

  if [[ "$remote_sha" != "$expected_sha" ]]; then
    echo "error: SpiderVenoms checksum pin mismatch for ${os}/${arch}" >&2
    echo "  expected: $expected_sha" >&2
    echo "  remote:   $remote_sha" >&2
    echo "  source:   $checksum_url" >&2
    return 1
  fi
}
