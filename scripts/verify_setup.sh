#!/usr/bin/env bash
# verify_setup.sh - Verify dev box setup is complete
# Run this script on the dev box after first launch to verify everything works

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
  echo -e "${GREEN}✓${NC} $1"
}

fail() {
  echo -e "${RED}✗${NC} $1"
}

warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

info() {
  echo -e "${NC}ℹ${NC} $1"
}

echo "=========================================="
echo "  Dev Box Setup Verification"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0

# Check 1: Persistent storage mounted
echo "1. Checking persistent storage..."
if mountpoint -q /data; then
  pass "/data is mounted"
  df -h /data | tail -1
else
  fail "/data is NOT mounted"
  ((ERRORS++))
fi
echo ""

# Check 2: Claude API key
echo "2. Checking Claude authentication..."
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  KEY_PREFIX=$(echo "$ANTHROPIC_API_KEY" | head -c 15)
  pass "Claude API key is set: ${KEY_PREFIX}..."
  if command -v claude >/dev/null 2>&1; then
    pass "claude command available at $(command -v claude)"
  else
    warn "claude command not found in PATH"
    ((WARNINGS++))
  fi
else
  fail "ANTHROPIC_API_KEY is not set"
  info "Run: claude_key_refresh"
  ((ERRORS++))
fi
echo ""

# Check 3: Conda and sr environment
echo "3. Checking conda and 'sr' environment..."
if [ -d "/data/miniforge3" ]; then
  pass "Miniforge installed at /data/miniforge3"
  
  # Source conda
  if [ -f "/data/miniforge3/etc/profile.d/conda.sh" ]; then
    source "/data/miniforge3/etc/profile.d/conda.sh"
    pass "Conda sourced successfully"
    
    # Check sr environment
    if conda env list | grep -q "^sr "; then
      pass "'sr' conda environment exists"
      
      # Activate and check packages
      conda activate sr 2>/dev/null || true
      
      # Check Jupyter
      if command -v jupyter >/dev/null 2>&1; then
        JUPYTER_VER=$(jupyter --version 2>&1 | head -1 || echo "unknown")
        pass "Jupyter installed: $JUPYTER_VER"
      else
        fail "Jupyter not found in sr environment"
        ((ERRORS++))
      fi
      
      # Check pandas
      if python -c "import pandas" 2>/dev/null; then
        PANDAS_VER=$(python -c "import pandas; print(pandas.__version__)")
        pass "pandas installed: $PANDAS_VER"
      else
        fail "pandas not found in sr environment"
        ((ERRORS++))
      fi
      
      # Check other common packages
      for pkg in numpy matplotlib seaborn scikit-learn; do
        if python -c "import $pkg" 2>/dev/null; then
          pass "$pkg installed"
        else
          warn "$pkg not found"
          ((WARNINGS++))
        fi
      done
      
    else
      fail "'sr' conda environment does not exist"
      info "Create it with: conda create -y -n sr python=3.11 jupyter jupyterlab pandas numpy matplotlib seaborn scikit-learn"
      ((ERRORS++))
    fi
  else
    fail "Conda init script not found"
    ((ERRORS++))
  fi
else
  fail "Miniforge not installed at /data/miniforge3"
  ((ERRORS++))
fi
echo ""

# Check 4: SSH keys
echo "4. Checking SSH keys..."
if [ -f "$HOME/.ssh/authorized_keys" ]; then
  KEY_COUNT=$(wc -l < "$HOME/.ssh/authorized_keys")
  pass "authorized_keys exists with $KEY_COUNT key(s)"
  
  # Show first few characters of each key for verification
  echo "   Keys:"
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      KEY_TYPE=$(echo "$line" | awk '{print $1}')
      KEY_START=$(echo "$line" | awk '{print substr($2, 1, 20)}')
      KEY_COMMENT=$(echo "$line" | awk '{print $NF}')
      echo "   - $KEY_TYPE ${KEY_START}... $KEY_COMMENT"
    fi
  done < "$HOME/.ssh/authorized_keys"
  
  if [ "$KEY_COUNT" -lt 2 ]; then
    warn "Only 1 SSH key found. Additional keys from DEVBOX_ADDITIONAL_SSH_KEYS may not be synced."
    ((WARNINGS++))
  fi
else
  fail "authorized_keys not found"
  ((ERRORS++))
fi
echo ""

# Check 5: Gas Town and Beads
echo "5. Checking Gas Town and Beads..."
if command -v gt >/dev/null 2>&1; then
  pass "gt (Gas Town) available at $(command -v gt)"
else
  warn "gt command not found"
  ((WARNINGS++))
fi

if command -v bd >/dev/null 2>&1; then
  pass "bd (Beads) available at $(command -v bd)"
else
  warn "bd command not found"
  ((WARNINGS++))
fi

if [ -d "$HOME/gt" ] || [ -L "$HOME/gt" ]; then
  pass "Gas Town workspace exists at ~/gt"
else
  warn "Gas Town workspace not found at ~/gt"
  ((WARNINGS++))
fi
echo ""

# Check 6: Docker
echo "6. Checking Docker..."
if command -v docker >/dev/null 2>&1; then
  pass "Docker installed: $(docker --version)"
  
  if groups | grep -q docker; then
    pass "User is in docker group"
    
    if docker ps >/dev/null 2>&1; then
      pass "Docker daemon is running"
    else
      warn "Docker daemon not accessible (may need re-login)"
      ((WARNINGS++))
    fi
  else
    warn "User not in docker group (may need re-login)"
    ((WARNINGS++))
  fi
else
  fail "Docker not installed"
  ((ERRORS++))
fi
echo ""

# Check 7: Dotfiles
echo "7. Checking dotfiles..."
for file in .bashrc .bash_aliases .vimrc; do
  if [ -f "$HOME/$file" ] || [ -L "$HOME/$file" ]; then
    if [ -L "$HOME/$file" ]; then
      TARGET=$(readlink "$HOME/$file")
      pass "$file → $TARGET"
    else
      pass "$file exists"
    fi
  else
    warn "$file not found"
    ((WARNINGS++))
  fi
done
echo ""

# Check 8: NVM and Node
echo "8. Checking NVM and Node..."
if [ -d "$HOME/.nvm" ]; then
  pass "NVM directory exists"
  
  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    source "$NVM_DIR/nvm.sh"
    pass "NVM loaded"
    
    if command -v node >/dev/null 2>&1; then
      pass "Node.js installed: $(node --version)"
    else
      warn "Node.js not found (run: nvm install --lts)"
      ((WARNINGS++))
    fi
  else
    warn "NVM script not found"
    ((WARNINGS++))
  fi
else
  warn "NVM not installed"
  ((WARNINGS++))
fi
echo ""

# Summary
echo "=========================================="
echo "  Summary"
echo "=========================================="

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  pass "All checks passed! Dev box is ready to use."
  echo ""
  echo "Quick start:"
  echo "  1. Activate conda: conda activate sr"
  echo "  2. Start Jupyter: jupyter lab --ip=0.0.0.0 --no-browser"
  echo "  3. Clone repos: mkdir -p /data/repos && cd /data/repos"
  echo "  4. Use Claude: claude"
  exit 0
elif [ $ERRORS -eq 0 ]; then
  warn "All critical checks passed with $WARNINGS warning(s)."
  echo ""
  echo "The dev box is functional but some optional components may need attention."
  exit 0
else
  fail "$ERRORS error(s) and $WARNINGS warning(s) found."
  echo ""
  echo "Please fix the errors above before using the dev box."
  exit 1
fi
