#!/usr/bin/env bash
set -e

BIN_NAME="frogpwd"
ZIP_NAME="frogpwd-linux-x86_64.zip"

GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

echo -e "${GREEN}frogpwd installer${RESET}"
echo

# Check architecture
ARCH="$(uname -m)"
if [[ "$ARCH" != "x86_64" ]]; then
  echo -e "${RED}Error:${RESET} Unsupported architecture: $ARCH"
  echo "frogpwd supports Linux x86-64 only."
  exit 1
fi

# If binary does not exist, try unzip
if [[ ! -f "./${BIN_NAME}" ]]; then
  if [[ -f "./${ZIP_NAME}" ]]; then
    echo -e "${YELLOW}Extracting ${ZIP_NAME}...${RESET}"
    unzip -o "$ZIP_NAME"
  else
    echo -e "${RED}Error:${RESET} Neither '${BIN_NAME}' nor '${ZIP_NAME}' found."
    echo "Download the release zip first:"
    echo "https://github.com/victormeloasm/frogpwd/releases"
    exit 1
  fi
fi

# Ensure executable
chmod +x "./${BIN_NAME}"

# Ask install mode
echo
echo "Choose installation mode:"
echo "  1) System-wide (/usr/local/bin)  [requires sudo]"
echo "  2) User-only   (~/.local/bin)    [no sudo]"
echo
read -rp "Select [1/2]: " MODE

case "$MODE" in
  1)
    TARGET="/usr/local/bin/${BIN_NAME}"
    echo
    echo -e "${YELLOW}Installing system-wide to ${TARGET}${RESET}"
    sudo install -m 0755 "./${BIN_NAME}" "$TARGET"
    ;;
  2)
    TARGET="$HOME/.local/bin/${BIN_NAME}"
    echo
    echo -e "${YELLOW}Installing for user to ${TARGET}${RESET}"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "./${BIN_NAME}" "$TARGET"

    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
      echo
      echo -e "${YELLOW}Note:${RESET} ~/.local/bin is not in your PATH."
      echo "Add this line to your shell config (~/.bashrc, ~/.zshrc):"
      echo
      echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    ;;
  *)
    echo -e "${RED}Invalid selection.${RESET}"
    exit 1
    ;;
esac

echo
echo -e "${GREEN}Installation complete!${RESET}"
echo
echo "Test it:"
echo "  frogpwd 24"
echo
echo "Help:"
echo "  frogpwd --help"
