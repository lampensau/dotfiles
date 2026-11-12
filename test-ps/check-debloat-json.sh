#!/usr/bin/env bash
# Checks windows/debloat*.json against Win11Debloat's own config files at the pinned tag.
# Needs bash, curl, jq. Set W11D_CONFIG_DIR to a directory holding Apps.json and Features.json to skip the download.
set -euo pipefail

TAG=2026.10.30
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${W11D_CONFIG_DIR:-}
if [ -z "$DIR" ]; then
    DIR=$(mktemp -d)
    trap 'rm -rf "$DIR"' EXIT
    for f in Apps Features; do
        curl -fsSL "https://raw.githubusercontent.com/Raphire/Win11Debloat/$TAG/Config/$f.json" -o "$DIR/$f.json"
    done
fi

KEEP='["MSTeams","MicrosoftTeams","MicrosoftCorporationII.QuickAssist","Microsoft.MicrosoftStickyNotes"]'
DEPLOY='["UserSelectionIndex","OtherUsername","AppRemovalScopeIndex","CreateRestorePoint","SkipRegistryBackup","RestartExplorer"]'
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# Apps.json entries have a string or an array in AppId; the import flattens them (Import-AppDetailsFromJson).
ALL=$(jq -c '[.Apps[]|.AppId|if type=="array" then .[] else . end]' "$DIR/Apps.json")
SAFE=$(jq -c '[.Apps[]|select(.Recommendation=="safe")|.AppId|if type=="array" then .[] else . end]' "$DIR/Apps.json")
SAFE_ENTRIES=$(jq '[.Apps[]|select(.Recommendation=="safe")]|length' "$DIR/Apps.json")
EXPECT=$(jq -c --argjson k "$KEEP" 'map(select(. as $i|$k|index($i)|not))|sort' <<<"$SAFE")
FEATURES=$(jq -c '[.Features[].FeatureId]' "$DIR/Features.json")

echo "Apps.json: $(jq length <<<"$ALL") ids, $SAFE_ENTRIES safe entries ($(jq length <<<"$SAFE") safe ids); Features.json: $(jq length <<<"$FEATURES") features"

for k in $(jq -r '.[]' <<<"$KEEP"); do
    jq -e --arg k "$k" 'index($k)' <<<"$SAFE" >/dev/null || bad "kept app $k is not a safe app at $TAG"
done

for f in debloat debloat-company; do
    J="$ROOT/windows/$f.json"
    jq -e '.Version=="1.0"' "$J" >/dev/null || bad "$f: Version is not 1.0"
    jq -e '.Apps|all(type=="string")' "$J" >/dev/null || bad "$f: Apps must be strings"
    jq -e '.Tweaks|all(.Value==true)' "$J" >/dev/null || bad "$f: a tweak is not true"

    for id in $(jq -r '.Apps[]' "$J"); do
        jq -e --arg i "$id" 'index($i)' <<<"$ALL" >/dev/null || bad "$f: app $id not in Apps.json"
    done
    for n in $(jq -r '.Tweaks[].Name' "$J"); do
        jq -e --arg i "$n" 'index($i)' <<<"$FEATURES" >/dev/null || bad "$f: setting $n not in Features.json"
    done
    for n in $(jq -r '.Deployment[].Name' "$J"); do
        jq -e --arg i "$n" 'index($i)' <<<"$DEPLOY" >/dev/null || bad "$f: deployment name $n unknown"
    done
    [ "$(jq -c '.Apps|sort' "$J")" = "$EXPECT" ] || bad "$f: Apps differ from safe set minus the four kept apps"
    [ "$(jq '.Apps|length-(unique|length)' "$J")" = 0 ] || bad "$f: duplicate app ids"
    [ "$(jq '.Tweaks|length-(map(.Name)|unique|length)' "$J")" = 0 ] || bad "$f: duplicate settings"

    echo "$f.json: $(jq '.Apps|length' "$J") apps (expected $(jq length <<<"$EXPECT")), $(jq '.Tweaks|length' "$J") settings, $(jq '.Deployment|length' "$J") deployment entries"
done

[ "$(jq -c 'del(.Tweaks[]|select(.Name=="DisableTelemetry"))' "$ROOT/windows/debloat.json")" = "$(jq -c . "$ROOT/windows/debloat-company.json")" ] \
    || bad "debloat-company.json is not debloat.json minus DisableTelemetry"
jq -e '.Tweaks|any(.Name=="DisableTelemetry")|not' "$ROOT/windows/debloat-company.json" >/dev/null || bad "company file still has DisableTelemetry"

[ "$fail" = 0 ] && echo OK
exit "$fail"
