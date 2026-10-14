#!/usr/bin/env bash
# Compila o app e monta um bundle macOS (.app) com assinatura ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP_NAME="QCY H3 Control"
BUNDLE="${APP_NAME}.app"

echo ">> compilando (${CONFIG})"
swift build -c "${CONFIG}" --product QCYMenubar

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"

echo ">> montando ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_DIR}/QCYMenubar" "${BUNDLE}/Contents/MacOS/QCYMenubar"
cp Support/Info.plist "${BUNDLE}/Contents/Info.plist"
if [ -d Resources ]; then
    cp Resources/* "${BUNDLE}/Contents/Resources/"
fi

echo ">> assinatura ad-hoc"
if codesign --force --deep --sign - "${BUNDLE}" >/dev/null 2>&1; then
    echo "   assinado (ad-hoc)."
else
    echo "   AVISO: codesign falhou; o app deve rodar mesmo assim."
fi

echo "OK -> ${BUNDLE}"
echo "Rode com: open \"${BUNDLE}\""
