#!/bin/sh

# USAGE: ./modmaps.sh <balance pack> <file of map IDs>
#
# Adds rules in map mod pack to any maps you want. Also
# optionally adds an overlay to maps.

# Configuration
max_workers=4  # maximum number of workers at once (e.g. downloading, OpenRA.Utility)
patched_dest="patched"  # where to place patched maps
ora_install="/usr/lib/openra"  # location of OpenRA installation

# ===============================
# Patch the maps
# ===============================

# Take stuff from args
{ [ "$1" ] && [ "$2" ] ; } || { >&2 echo "USAGE: ./modmaps.sh <balance pack> <file of map IDs>"; exit 1; }
bal_pack="$1"
map_ids_file="$2"

# unzip but STFU
unzip_() {
	unzip "$1" >/dev/null
}

# Some output escape codes
t_clrln="\r\033[K"
t_bold=$(tput bold)
t_ital=$(tput sitm)
t_norm=$(tput sgr0)

# Create temporary working structures
mkdir -p .work
mkdir -p .work/maps_fresh
mkdir -p .work/maps_unpacked
mkdir -p .work/balpack
rm -rf "$patched_dest"
mkdir -p "$patched_dest"

# Read map ids and download
# Only numbers starting exactly on a new line will be considered; the rest of the line
# will be treated as a comment
map_ids=$(cut -d' ' -f1 "$map_ids_file")
touch .work/dlcmds  # don't break if there's no IDs
# Command-lines for downloading the files
for id in $map_ids; do
	# We grab the title first, then use that as the filename with which to save the map,
	# replacing all spaces with underscores
	cat <<-EOF >>.work/dlcmds
	printf "#$id, "
	mapname=".work/maps_fresh/\$(curl -s "https://resource.openra.net/map/id/$id/yaml/" | \
		grep 'title:' | tr -d '\t' | cut -d' ' -f2- | tr ' ' '_').oramap" && \
	curl -s -o"\$mapname" "https://resource.openra.net/maps/$id/oramap" && \
	"$ora_install/OpenRA.Utility" ra --refresh-map "$(pwd)/\$mapname" &
	EOF
done

# Batch downloads
max_workers=$((max_workers * 2))	# *2 because each dl is actually two lines
split -l$max_workers .work/dlcmds .work/dlcmds_batch
for script in .work/dlcmds_batch*; do
	printf "%s\n" "printf '\x1b[2D)';wait" >>"$script"
	printf "${t_clrln}${t_bold}Downloading maps${t_norm}... ("
	sh "$script"
done
printf "${t_clrln}${t_bold}Downloading maps${t_norm}... ${t_ital}done.${t_norm}\n"

# Unzip all maps
for map in .work/maps_fresh/*; do
	mkdir ".work/maps_unpacked/$(basename "$map" .oramap)"
	cp "$map" ".work/maps_unpacked/$(basename "$map" .oramap)"
	(cd ".work/maps_unpacked/$(basename "$map" .oramap)" || exit; unzip_ ./*; rm "$(basename "$map")")
done

# Unzip balance pack
# Each top-level directory in the balance pack represents a key to add to
# or modify in map.yaml, and the filenames of each file in there will be
# added
cp "$bal_pack" .work/balpack/
(cd .work/balpack || exit; unzip_ ./*;)
rm ".work/balpack/$(basename "$bal_pack")"

# Look at all the top-level dirs, representing top-level YAML keys
keys="$(find .work/balpack -mindepth 1 -maxdepth 1 -type 'd' -exec basename {} \;)"
# Get all the default rules and weapons
baserules=$(find "$ora_install/mods/ra/rules" "$ora_install/mods/ra/weapons" \
	-name '*.yaml' -exec grep -E '^[^[:space:]]+:[ \t]?$' {} \;)

# Process each map
for mapdir in .work/maps_unpacked/*; do
	printf "${t_clrln}${t_bold}Patching map YAML(s)${t_norm}... (%s)" "$(basename "$mapdir")"
	mapyaml="$mapdir/map.yaml"

	# Go through yamls and delete keys that exist in baserules
	for key in $baserules; do
		printf "%s\n" "/^$key[^ \t]\?$/,/^[^[:blank:]]/-1d" >>.work/edscript
	done
	printf "wq\n" >>.work/edscript
	find "$mapdir" -name "*.yaml" -exec sh -c 'ed $1 <.work/edscript 2&>/dev/null' sh {} \;

	# Copy YAMLs over
	find ".work/balpack/" -type 'f' -exec cp {} "$mapdir" \;
	# Include them in map.yaml
	for key in $keys; do
		# Remove stupid carriage returns
		tr -d '\r' <"$mapyaml" >"$mapyaml"_
		mv "$mapyaml"_ "$mapyaml"
		yamls="$(find ".work/balpack/$key" -type 'f' -exec basename {} \; | tr '\n' ',')"
		# If there is no such key, add it
		grep "^$key:" "$mapyaml" >/dev/null || printf "\n%s: " "$key" >>"$mapyaml"
		# Append all YAML filenames to that key and remove duplicates
		ed "$mapyaml" <<-EOF >/dev/null
			/^$key:/a
			,$yamls
			.
			-1,.j
			s/:,\?/:/
			s/,\?[[:space:]]*$//
			s/\(.\)\(,\)\? \?/\1\2/g
			w
			\$a
			/^$key:/s/\([:,]\)\(.\+\.yaml\)\(.\+\)\2/\1\2\3/
			w
			!exec ed "%" <.work/rgxp
			q
			.
			-3,\$w .work/rgxp
			!exec ed "%" <.work/rgxp
			E
			/^$key:/s/:,\?/:/
			s/,*$//
			w
			s/,\+/,/g
			wq
		EOF
	done
done
printf "${t_clrln}${t_bold}Patching map YAMLs${t_norm}... ${t_ital}done.${t_norm}\n"

# Composite the map preview overlay on
if [ -f ".work/balpack/overlay.png" ]; then
	for mapdir in .work/maps_unpacked/*; do
		printf "${t_clrln}${t_bold}Compositing map previews${t_norm}... (%s)" "$(basename "$mapdir")"
		(cd "$mapdir" || exit; zip -r "$(basename "$mapdir")".oramap ./* >/dev/null)
		magick "$mapdir/map.png" "$mapdir/overlay.png" -resize "%[fx:u.w]x%[fx:u.w]" -gravity center -composite "$mapdir/map.png"
	done
	printf "${t_clrln}${t_bold}Compositing map previews${t_norm}... ${t_ital}done.${t_norm}\n"
fi

# Zip the patched maps
for mapdir in .work/maps_unpacked/*; do
	printf "${t_clrln}${t_bold}Zipping patched maps${t_norm}... (%s)" "$(basename "$mapdir")"
	(cd "$mapdir" || exit; zip -r "$(basename "$mapdir")".oramap ./* >/dev/null)
	mv "$mapdir/$(basename "$mapdir")".oramap "$patched_dest"
done
printf "${t_clrln}${t_bold}Zipping patched maps${t_norm}... ${t_ital}done.${t_norm}\n"

# All done
printf "\n${t_ital}All done. Patched ${t_bold}%d${t_norm}${t_ital} maps.${t_norm}\n" "$(find .work/maps_unpacked -mindepth 1 -maxdepth 1 | wc -l)"

# Clean up
rm -rf .work
