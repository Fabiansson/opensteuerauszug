#!/usr/bin/env bash
# ============================================================================
# Swiss Tax Report Generator (IBKR / Canton Bern)
# Run from the repo root. Sets up environment, downloads Kursliste,
# and generates your Steuerauszug for TaxMe import.
# ============================================================================
set -euo pipefail

# -- Colors --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
ask()   { echo -en "${BOLD}$*${NC}"; }

# ============================================================================
# 1. CONFIG
# ============================================================================
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
CANTON="${CANTON:-BE}"
LANGUAGE="${LANGUAGE:-de}"

# ============================================================================
# 2. CHECK PREREQUISITES
# ============================================================================
info "Checking prerequisites..."

if ! command -v git &>/dev/null; then
    err "git is not installed. Install it first."
    exit 1
fi

if ! command -v "$PYTHON" &>/dev/null; then
    err "$PYTHON is not installed. Install Python 3.10+ first."
    exit 1
fi

PY_VERSION=$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$("$PYTHON" -c 'import sys; print(sys.version_info.major)')
PY_MINOR=$("$PYTHON" -c 'import sys; print(sys.version_info.minor)')
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 10 ]; }; then
    err "Python 3.10+ required, found $PY_VERSION"
    exit 1
fi
ok "Python $PY_VERSION"

# ============================================================================
# 3. ASK FOR TAX YEAR
# ============================================================================
echo ""
ask "Tax year to process [$(( $(date +%Y) - 1 ))]: "
read -r TAX_YEAR
TAX_YEAR="${TAX_YEAR:-$(( $(date +%Y) - 1 ))}"

if ! [[ "$TAX_YEAR" =~ ^20[0-9]{2}$ ]]; then
    err "Invalid tax year: $TAX_YEAR"
    exit 1
fi
ok "Tax year: $TAX_YEAR"

# ============================================================================
# 4. UPDATE REPO
# ============================================================================
echo ""
info "Pulling latest changes..."
git -C "$INSTALL_DIR" pull --ff-only || warn "Pull failed, continuing with existing version"
ok "Repository ready at $INSTALL_DIR"

# ============================================================================
# 5. SET UP VIRTUALENV & INSTALL
# ============================================================================
echo ""
VENV_DIR="$INSTALL_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    info "Creating virtualenv..."
    "$PYTHON" -m venv "$VENV_DIR"
fi

info "Installing dependencies (this may take a minute on first run)..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -e "$INSTALL_DIR"
ok "Dependencies installed"

PYBIN="$VENV_DIR/bin/python"

# ============================================================================
# 6. CONFIGURE
# ============================================================================
echo ""
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opensteuerauszug"
CONFIG_FILE="$CONFIG_DIR/config.toml"

if [ ! -f "$CONFIG_FILE" ]; then
    info "Creating config at $CONFIG_FILE..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<TOML
[general]
canton = "$CANTON"
language = "$LANGUAGE"
TOML
    ok "Config created (canton=$CANTON, language=$LANGUAGE)"
else
    ok "Config already exists at $CONFIG_FILE"
fi

# ============================================================================
# 7. DOWNLOAD / UPDATE KURSLISTE
# ============================================================================
echo ""
info "Downloading latest Kursliste for $TAX_YEAR (this takes ~30s)..."
"$PYBIN" -m opensteuerauszug.kursliste download --year "$TAX_YEAR" 2>&1 | grep -E "^(INFO|SUCCESS|ERROR)" || true
ok "Kursliste for $TAX_YEAR is up to date"

# ============================================================================
# 8. LOCATE INPUT FILE
# ============================================================================
echo ""
PRIVATE_DIR="$INSTALL_DIR/private"
mkdir -p "$PRIVATE_DIR"
INPUT_FILE="$PRIVATE_DIR/ibkr_${TAX_YEAR}.xml"

if [ ! -f "$INPUT_FILE" ]; then
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${BOLD}  IBKR Flex Query XML not found!${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}How to get it:${NC}"
    echo ""
    echo "  1. Log into IBKR Account Management"
    echo "  2. Go to  Performance & Reports > Flex Queries"
    echo ""
    echo -e "  3. ${BOLD}First time only:${NC} Create a new Activity Flex Query:"
    echo "     - Name: \"Annual Tax Report\""
    echo "     - Format: XML"
    echo "     - Select these sections (all fields in each):"
    echo "       AccountInformation, Trades, OpenPositions,"
    echo "       Transfers, CorporateActions, CashTransactions,"
    echo "       CashReport"
    echo "     - Save"
    echo ""
    echo "  4. Run the query with date range:"
    echo -e "     ${BOLD}${TAX_YEAR}-01-01  to  ${TAX_YEAR}-12-31${NC}"
    echo ""
    echo "  5. Download the XML and save it as:"
    echo -e "     ${GREEN}${INPUT_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    ask "Press Enter once the file is in place (or Ctrl+C to abort)..."
    read -r

    if [ ! -f "$INPUT_FILE" ]; then
        err "File still not found: $INPUT_FILE"
        exit 1
    fi
fi
ok "Input file: $INPUT_FILE"

# ============================================================================
# 9. GENERATE STEUERAUSZUG
# ============================================================================
echo ""
OUTPUT_PDF="$PRIVATE_DIR/steuerauszug_${TAX_YEAR}.pdf"
OUTPUT_XML="$PRIVATE_DIR/steuerauszug_${TAX_YEAR}.xml"

info "Generating Steuerauszug for $TAX_YEAR..."
echo ""

"$PYBIN" -m opensteuerauszug.steuerauszug "$INPUT_FILE" \
    --importer ibkr \
    --tax-year "$TAX_YEAR" \
    -o "$OUTPUT_PDF" \
    --xml-output "$OUTPUT_XML" \
    2>&1

RESULT=$?
echo ""

if [ $RESULT -eq 0 ]; then
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  SUCCESS!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  PDF: ${BOLD}${OUTPUT_PDF}${NC}"
    echo -e "  XML: ${BOLD}${OUTPUT_XML}${NC}"
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "  1. Open the PDF and review positions, dividends, withholding taxes"
    echo "  2. Import the PDF into TaxMe (e-Steuerauszug upload)"
    echo "  3. Let TaxMe recalculate from its Kursliste"
    echo "  4. Fill in DA-1 for US withholding tax (VT etc.):"
    echo "     Country=USA, Rate=15%, amounts from the Steuerauszug"
    echo "  5. Submit your tax return"
    echo ""
else
    err "Generation failed (exit code $RESULT). Check the output above."
    exit $RESULT
fi
