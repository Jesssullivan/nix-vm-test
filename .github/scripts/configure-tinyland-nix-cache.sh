#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${ATTIC_SERVER:?ATTIC_SERVER is required}"
: "${ATTIC_CACHE:?ATTIC_CACHE is required}"
: "${ATTIC_PUBLIC_KEY:?ATTIC_PUBLIC_KEY is required}"

attic_url="${ATTIC_SERVER%/}/${ATTIC_CACHE}"
existing_config="${NIX_CONFIG:-}"

{
  echo "NIX_CONFIG<<EOF"
  if [ -n "${existing_config}" ]; then
    printf '%s\n' "${existing_config}"
  fi
  case "${existing_config}" in
    *experimental-features*) ;;
    *) printf '%s\n' "experimental-features = nix-command flakes" ;;
  esac
  printf '%s\n' "extra-substituters = ${attic_url}"
  printf '%s\n' "extra-trusted-public-keys = ${ATTIC_PUBLIC_KEY}"
  echo "EOF"
} >> "${GITHUB_ENV}"

printf 'Configured Nix cache substituter: %s\n' "${attic_url}"
