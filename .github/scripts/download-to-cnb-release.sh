#!/usr/bin/env bash
set -euo pipefail

DOWNLOAD_LINK_FILE="${DOWNLOAD_LINK_FILE:-download_link}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-downloads}"
TMP_DIR="${TMP_DIR:-.download-tmp}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
CNB_REPO_SLUG="${CNB_REPO_SLUG:?CNB_REPO_SLUG is required}"
CNB_TARGET_COMMITISH="${CNB_TARGET_COMMITISH:-main}"
CNB_ASSET_TTL_DAYS="${CNB_ASSET_TTL_DAYS:-0}"

if [[ ! -f "$DOWNLOAD_LINK_FILE" ]]; then
  echo "::error::Download link file not found: $DOWNLOAD_LINK_FILE" >&2
  exit 1
fi

if [[ -z "${CNB_TOKEN:-}" ]]; then
  echo "::error::CNB_TOKEN is required. Add it as a GitHub Actions repository secret." >&2
  exit 1
fi

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "::error::Missing required command: $name" >&2
    exit 1
  fi
}

require_command aria2c
require_command cnb
require_command curl
require_command jq
require_command node

mapfile -t URLS < <(
  sed 's/\r$//' "$DOWNLOAD_LINK_FILE" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | awk 'length($0) && $0 !~ /^#/'
)

if [[ "${#URLS[@]}" -eq 0 ]]; then
  echo "::error::No download URLs found in $DOWNLOAD_LINK_FILE" >&2
  exit 1
fi

cnb_status() {
  jq -r '.status // empty' <<<"$1"
}

cnb_data_id() {
  jq -r '.data.id // .id // empty' <<<"$1"
}

ensure_release() {
  local response status release_id

  echo "Checking CNB release: ${CNB_REPO_SLUG}@${RELEASE_TAG}" >&2
  response="$(cnb releases get-release-by-tag --repo "$CNB_REPO_SLUG" --tag "$RELEASE_TAG" --verbose)"
  status="$(cnb_status "$response")"

  if [[ "$status" == "200" ]]; then
    release_id="$(cnb_data_id "$response")"
    if [[ -z "$release_id" ]]; then
      echo "::error::CNB release exists but no id was returned." >&2
      echo "$response" >&2
      exit 1
    fi

    cnb releases patch-release \
      --repo "$CNB_REPO_SLUG" \
      --release-id "$release_id" \
      --name "$RELEASE_TAG" \
      --body "Downloaded by GitHub Actions from ${GITHUB_REPOSITORY:-unknown}." \
      --make-latest true \
      --verbose >/dev/null

    printf '%s\n' "$release_id"
    return
  fi

  echo "Creating CNB release: ${CNB_REPO_SLUG}@${RELEASE_TAG}" >&2
  response="$(
    cnb releases post-release \
      --repo "$CNB_REPO_SLUG" \
      --tag-name "$RELEASE_TAG" \
      --target-commitish "$CNB_TARGET_COMMITISH" \
      --name "$RELEASE_TAG" \
      --body "Downloaded by GitHub Actions from ${GITHUB_REPOSITORY:-unknown}." \
      --make-latest true \
      --verbose
  )"
  status="$(cnb_status "$response")"
  release_id="$(cnb_data_id "$response")"

  if [[ "$status" != "201" && "$status" != "200" ]] || [[ -z "$release_id" ]]; then
    echo "::error::Failed to create CNB release." >&2
    echo "$response" >&2
    exit 1
  fi

  printf '%s\n' "$release_id"
}

RELEASE_ID="$(ensure_release)"
echo "CNB release id: $RELEASE_ID"

rm -rf "$DOWNLOAD_DIR" "$TMP_DIR"
mkdir -p "$DOWNLOAD_DIR" "$TMP_DIR"

unique_dest() {
  local desired="$1"
  local dir base stem ext candidate index

  dir="$(dirname "$desired")"
  base="$(basename "$desired")"
  stem="$base"
  ext=""

  if [[ "$base" == *.* && "$base" != .* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  fi

  candidate="$desired"
  index=1
  while [[ -e "$candidate" ]]; do
    candidate="${dir}/${stem}-${index}${ext}"
    index=$((index + 1))
  done

  printf '%s\n' "$candidate"
}

move_downloaded_files() {
  local source_dir="$1"
  local moved=0
  local source name destination

  while IFS= read -r -d '' source; do
    name="$(basename "$source")"
    [[ -n "$name" ]] || name="download"
    destination="$(unique_dest "${DOWNLOAD_DIR}/${name}")"
    mv "$source" "$destination"
    echo "Downloaded: $destination"
    moved=$((moved + 1))
  done < <(find "$source_dir" -type f ! -name '*.aria2' -print0)

  [[ "$moved" -gt 0 ]]
}

download_with_aria2() {
  local url="$1"
  local target_dir="$2"

  aria2c \
    --dir="$target_dir" \
    --continue=true \
    --allow-overwrite=true \
    --auto-file-renaming=false \
    --content-disposition=true \
    --file-allocation=none \
    --split=16 \
    --max-connection-per-server=16 \
    --min-split-size=1M \
    --max-tries=5 \
    --retry-wait=5 \
    --connect-timeout=30 \
    --timeout=60 \
    --summary-interval=0 \
    --console-log-level=warn \
    --download-result=hide \
    "$url"
}

download_with_playwright() {
  local url="$1"
  local target_dir="$2"
  local index="$3"

  node .github/scripts/playwright-download.mjs "$url" "$target_dir" "download-${index}"
}

FAILED_DOWNLOADS=()

for index in "${!URLS[@]}"; do
  url="${URLS[$index]}"
  human_index=$((index + 1))
  target_dir="${TMP_DIR}/${human_index}"

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  echo "Downloading #${human_index} with aria2: $url"
  if download_with_aria2 "$url" "$target_dir" && move_downloaded_files "$target_dir"; then
    continue
  fi

  echo "::warning::aria2 failed for #${human_index}; retrying with Playwright"
  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  if download_with_playwright "$url" "$target_dir" "$human_index" && move_downloaded_files "$target_dir"; then
    continue
  fi

  FAILED_DOWNLOADS+=("$url")
done

if [[ "${#FAILED_DOWNLOADS[@]}" -gt 0 ]]; then
  echo "::error::The following downloads failed after aria2 and Playwright fallback:" >&2
  printf '%s\n' "${FAILED_DOWNLOADS[@]}" >&2
  exit 1
fi

mapfile -d '' DOWNLOADED_FILES < <(find "$DOWNLOAD_DIR" -type f -print0 | sort -z)
if [[ "${#DOWNLOADED_FILES[@]}" -eq 0 ]]; then
  echo "::error::No downloaded files found in $DOWNLOAD_DIR" >&2
  exit 1
fi

parse_verify_url() {
  node - "$1" <<'NODE'
const raw = process.argv[2];
const url = new URL(raw, 'https://placeholder.invalid');
const marker = '/asset-upload-confirmation/';
const markerIndex = url.pathname.indexOf(marker);

if (markerIndex < 0) {
  throw new Error(`verify_url does not contain ${marker}`);
}

const tail = url.pathname.slice(markerIndex + marker.length);
const firstSlash = tail.indexOf('/');

if (firstSlash < 0) {
  throw new Error('verify_url does not contain asset_path');
}

console.log(JSON.stringify({
  uploadToken: tail.slice(0, firstSlash),
  assetPath: tail.slice(firstSlash + 1),
}));
NODE
}

upload_asset() {
  local release_id="$1"
  local file="$2"
  local asset_name size response status upload_url verify_url parsed upload_token asset_path upload_response

  asset_name="$(basename "$file")"
  size="$(wc -c <"$file" | tr -d '[:space:]')"

  echo "Uploading to CNB release: $asset_name ($size bytes)"
  response="$(
    cnb releases post-release-asset-upload-url \
      --repo "$CNB_REPO_SLUG" \
      --release-id "$release_id" \
      --asset-name "$asset_name" \
      --size "$size" \
      --ttl "$CNB_ASSET_TTL_DAYS" \
      --overwrite \
      --verbose
  )"
  status="$(cnb_status "$response")"
  upload_url="$(jq -r '.data.upload_url // .upload_url // empty' <<<"$response")"
  verify_url="$(jq -r '.data.verify_url // .verify_url // empty' <<<"$response")"

  if [[ "$status" != "201" && "$status" != "200" ]] || [[ -z "$upload_url" || -z "$verify_url" ]]; then
    echo "::error::Failed to request CNB asset upload URL for $asset_name." >&2
    echo "$response" >&2
    exit 1
  fi

  upload_response="$(mktemp "${TMP_DIR}/curl-upload-response.XXXXXX")"
  if ! curl \
    --fail-with-body \
    --show-error \
    --location \
    --request PUT \
    --upload-file "$file" \
    --progress-bar \
    --retry 3 \
    --retry-delay 5 \
    --retry-all-errors \
    --output "$upload_response" \
    "$upload_url"; then
    echo "::error::Failed to upload $asset_name to CNB asset storage." >&2
    if [[ -s "$upload_response" ]]; then
      cat "$upload_response" >&2
    fi
    rm -f "$upload_response"
    exit 1
  fi
  rm -f "$upload_response"
  echo "Upload complete: $asset_name"

  parsed="$(parse_verify_url "$verify_url")"
  upload_token="$(jq -r '.uploadToken' <<<"$parsed")"
  asset_path="$(jq -r '.assetPath' <<<"$parsed")"

  response="$(
    cnb releases post-release-asset-upload-confirmation \
      --repo "$CNB_REPO_SLUG" \
      --release-id "$release_id" \
      --upload-token "$upload_token" \
      --asset-path "$asset_path" \
      --ttl "$CNB_ASSET_TTL_DAYS" \
      --verbose
  )"
  status="$(cnb_status "$response")"

  if [[ "$status" != "200" && "$status" != "201" ]]; then
    echo "::error::Failed to confirm CNB asset upload for $asset_name." >&2
    echo "$response" >&2
    exit 1
  fi
}

for file in "${DOWNLOADED_FILES[@]}"; do
  upload_asset "$RELEASE_ID" "$file"
done

echo "Uploaded ${#DOWNLOADED_FILES[@]} file(s) to ${CNB_REPO_SLUG}@${RELEASE_TAG}."
