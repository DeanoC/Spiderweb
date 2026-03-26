#!/usr/bin/env bash

spidervenoms_release_version="0.5.2"
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
    linux:x86_64)
      printf '%s' "https://github.com/DeanoC/SpiderVenoms/releases/download/v0.5.2/spidervenoms-managed-local-linux-x86_64.tar.gz"
      ;;
    macos:arm64)
      printf '%s' "https://github.com/DeanoC/SpiderVenoms/releases/download/v0.5.2/spidervenoms-managed-local-macos-arm64.tar.gz"
      ;;
    *)
      return 1
      ;;
  esac
}

spidervenoms_release_sha256_for_platform() {
  local os arch
  os="$(spidervenoms_normalize_os "${1:-}")" || return 1
  arch="$(spidervenoms_normalize_arch "${2:-}")" || return 1
  case "${os}:${arch}" in
    linux:x86_64)
      printf '%s' "cf52889516d968b06f45e29eed2796a1b535020b6e977345066e49f53c782719"
      ;;
    macos:arm64)
      printf '%s' "4dd2df98788d79c7dcd4a0794d0c95eebe2c71d2eff10c76fedd51ab0c5cc47f"
      ;;
    *)
      return 1
      ;;
  esac
}
