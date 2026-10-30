#!/bin/bash
set -euo pipefail

config="$HOME/.config/waybar/scripts/cities_config.json"
state_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}/waybar-$UID}"
state_file="$state_dir/waybar-city"
mkdir -p "$state_dir"

index=0
if [[ -r "$state_file" ]]; then
    read -r index < "$state_file" || index=0
fi
[[ "$index" =~ ^(0|[1-9][0-9]*)$ ]] || index=0

selection=$(jq -er --argjson index "$index" '
    .cities | select(length > 0) | length as $count |
    ($index % $count) as $index | .[$index] |
    [$count, $index, .short_code, .timezone,
     .weather_name, .latitude, .longitude] | @tsv
' "$config")
IFS=$'\t' read -r count index short_code timezone weather_name lat lon <<< "$selection"

case "${1:-selector}" in
    next)
        printf '%s\n' "$(((index + 1) % count))" > "$state_file"
        pkill -RTMIN+10 -x waybar || true
        exit
        ;;
    selector)
        text="$short_code"
        tooltip="$weather_name"$'\nClick to change city'
        class="city-selector"
        ;;
    clock)
        IFS='|' read -r text date_text < <(TZ="$timezone" date '+%a %H:%M|%Y-%m-%d (W%V) %H:%M')
        tooltip="$timezone"$'\n'"$date_text"
        class="multi-clock"
        ;;
    weather)
        class="multi-weather"
        cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/waybar/weather"
        cache_file="$cache_dir/${lat}_${lon}.json"
        mkdir -p "$cache_dir"

        # Parse once, rejecting responses without current conditions and an hourly forecast.
        weather_values() {
            jq -er '
                select(.current.temperature_2m | type == "number") |
                select(.current.weather_code | type == "number") |
                select((.hourly.time | type) == "array") |
                select((.hourly.time | length) > 0) |
                [.current.temperature_2m | trunc] +
                [.current.apparent_temperature // "—", .current.relative_humidity_2m // "—",
                 .current.wind_speed_10m // "—",
                 .current.weather_code, .current_units.wind_speed_10m // "km/h"] | @tsv
            ' 2>/dev/null
        }

        # Upcoming hours only, so the tooltip stays correct between refreshes.
        weather_hours() {
            jq -r --arg now "$now_local" '
                .hourly as $hourly |
                [range(0; ($hourly.time | length)) as $i |
                 select($hourly.time[$i] >= $now) |
                 [$hourly.time[$i][11:16],
                  (($hourly.temperature_2m[$i] // "—") |
                   if type == "number" then trunc else . end),
                  ($hourly.weather_code[$i] // -1),
                  ($hourly.precipitation_probability[$i] // 0)]] |
                .[:6][] | @tsv
            ' 2>/dev/null
        }

        condition_for() {
            case "$1" in
                0) icon="󰖨"; condition="Clear sky" ;;
                1|2) icon=""; condition="Partly cloudy" ;;
                3) icon=""; condition="Overcast" ;;
                45|48) icon="󱖆"; condition="Fog" ;;
                51|53|55) icon=""; condition="Drizzle" ;;
                56|57) icon=""; condition="Freezing drizzle" ;;
                61|63|65) icon=""; condition="Rain" ;;
                66|67) icon=""; condition="Freezing rain" ;;
                71|73|75|77|85|86) icon="󰖘"; condition="Snow" ;;
                80|81|82) icon=""; condition="Rain showers" ;;
                95|96|99) icon=""; condition="Thunderstorm" ;;
                *) icon=""; condition="Unknown conditions" ;;
            esac
        }

        values=""
        json=""
        if [[ -r "$cache_file" ]]; then
            json=$(<"$cache_file") || json=""
            values=$(weather_values <<< "$json") || values=""
        fi
        now_local=$(TZ="$timezone" date +%Y-%m-%dT%H:%M)

        url="https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,weather_code&hourly=temperature_2m,precipitation_probability,weather_code&forecast_hours=36&wind_speed_unit=ms&timezone=auto"
        if fresh=$(curl --fail --silent --connect-timeout 2 --max-time 5 "$url") &&
            new_values=$(weather_values <<< "$fresh"); then
            json="$fresh"
            values="$new_values"
            cache_tmp=$(mktemp "$cache_file.XXXXXX")
            trap 'rm -f "$cache_tmp"' EXIT
            printf '%s\n' "$fresh" > "$cache_tmp"
            mv -- "$cache_tmp" "$cache_file"
        fi

        if [[ -z "$values" ]]; then
            text="󰖐   N/A"
            tooltip="$weather_name"$'\nNo weather data.'
        else
            IFS=$'\t' read -r temp feels_like humidity wind code wind_unit <<< "$values"
            condition_for "$code"
            text="$icon   $temp°C"
            tooltip="$weather_name"$'\n'"$condition"$'\n'"Temperature: $temp°C"$'\n'"Feels like: $feels_like°C"$'\n'"Humidity: $humidity%"$'\n'"Wind: $wind $wind_unit"
            if hours=$(weather_hours <<< "$json") && [[ -n "$hours" ]]; then
                tooltip+=$'\n\n'"Next 6 hours"
                while IFS=$'\t' read -r htime htemp hcode hprecip; do
                    condition_for "$hcode"
                    tooltip+=$'\n'"$htime  $icon  ${htemp}°  ${hprecip}%"
                done <<< "$hours"
            fi
        fi
        ;;
    *)
        echo "Usage: $0 {selector|next|clock|weather}" >&2
        exit 2
        ;;
esac

jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$class" \
    '{text: ($text | @html), tooltip: ($tooltip | @html), class: ($class | split(" "))}'
