#!/bin/sh
set -eu

# Reuse the project's existing artwork; do not round its outer square or modify
# AppIcon.png. Requires ImageMagick 6 (convert) or 7 (magick).
if command -v magick >/dev/null 2>&1; then
  image_tool=magick
elif command -v convert >/dev/null 2>&1; then
  image_tool=convert
else
  echo "ImageMagick is required to generate the alternate app icons." >&2
  exit 1
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
asset_directory="$script_directory/../App/Resources/Assets.xcassets"
original_icon="$asset_directory/AppIcon.appiconset/AppIcon.png"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/tieba-app-icons.XXXXXX")
trap 'rm -rf -- "$temporary_directory"' EXIT HUP INT TERM

test "$($image_tool "$original_icon" -format '%wx%h' info:)" = "1024x1024" || {
  echo "The original app icon must be 1024 x 1024." >&2
  exit 1
}
test "$($image_tool "$original_icon" -format '%[pixel:p{0,0}]' info:)" = 'srgb(18,93,190)' || {
  echo "The original icon palette changed; review the mask colors before regenerating." >&2
  exit 1
}

# Recover continuous artwork coverage by projecting each source RGB pixel onto
# the line from its original blue (18, 93, 190) to white (255, 255, 255).
# 86638 = 237^2 + 162^2 + 65^2. Unlike a threshold/color replacement, this retains
# every antialiased edge pixel and uses all three source channels. This is a
# linear mask in the source's encoded sRGB values, matching the existing artwork.
$image_tool "$original_icon" -alpha off \
  -fx 'max(0,min(1,((255*r-18)*237+(255*g-93)*162+(255*b-190)*65)/86638))' \
  -colorspace Gray "$temporary_directory/coverage.miff"

mkdir -p "$asset_directory/AppIconLight.appiconset" "$asset_directory/AppIconDark.appiconset"
mkdir -p "$asset_directory/AppIconPreviewClassic.imageset" \
  "$asset_directory/AppIconPreviewLight.imageset" "$asset_directory/AppIconPreviewDark.imageset"

$image_tool "$temporary_directory/coverage.miff" -colorspace sRGB \
  +level-colors '#FFFFFF,#125DBE' -alpha off -depth 8 -strip \
  "PNG24:$asset_directory/AppIconLight.appiconset/AppIconLight.png"
$image_tool "$temporary_directory/coverage.miff" -colorspace sRGB \
  +level-colors '#171A21,#78B4FF' -alpha off -depth 8 -strip \
  "PNG24:$asset_directory/AppIconDark.appiconset/AppIconDark.png"

# Resize only the settings previews. App-icon assets remain full 1024px squares.
for variant in Classic Light Dark; do
  case "$variant" in
    Classic) preview_source="$original_icon" ;;
    *) preview_source="$asset_directory/AppIcon$variant.appiconset/AppIcon$variant.png" ;;
  esac
  $image_tool "$preview_source" -colorspace RGB -filter Lanczos -resize 160x160 \
    -colorspace sRGB -alpha off -depth 8 -strip \
    "PNG24:$asset_directory/AppIconPreview$variant.imageset/AppIconPreview$variant.png"
done

echo "Generated 2 alternate 1024px app icons and 3 opaque 160px settings previews."
