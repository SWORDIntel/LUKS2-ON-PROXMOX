#!/bin/bash

# Script to download .deb packages from a list of URLs

# Default target directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET_DIR="$SCRIPT_DIR/debs"
TARGET_DIR="${1:-$DEFAULT_TARGET_DIR}"

# Package URLs file
PACKAGE_URLS_FILE="$SCRIPT_DIR/debs/package_urls.txt"

# Create target directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Check if package_urls.txt exists
if [ ! -f "$PACKAGE_URLS_FILE" ]; then
  echo "Warning: Package URLs file not found at $PACKAGE_URLS_FILE"
  echo "Please create this file with a list of .deb package URLs."
  exit 0 # Exit gracefully as per requirement
fi

# Check if package_urls.txt is empty
if [ ! -s "$PACKAGE_URLS_FILE" ]; then
  echo "Warning: Package URLs file $PACKAGE_URLS_FILE is empty."
  echo "No packages to download."
  exit 0 # Exit gracefully
fi

echo "Starting download of .deb packages to $TARGET_DIR..."

# Read URLs and download
while IFS= read -r url || [[ -n "$url" ]]; do
  if [ -z "$url" ]; then # Skip empty lines
    continue
  fi
  echo "Downloading $url..."
  wget -P "$TARGET_DIR" "$url"
  if [ $? -ne 0 ]; then
    echo "Error: Failed to download $url"
    # Continue to try downloading other packages
  else
    echo "Successfully downloaded $url to $TARGET_DIR"
  fi
done < "$PACKAGE_URLS_FILE"

echo "All downloads attempted."
echo "Packages are located in $TARGET_DIR"

exit 0
