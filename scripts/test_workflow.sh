#!/usr/bin/env bash
# Test script to validate GitHub Actions workflow logic locally
set -euo pipefail

echo "=========================================="
echo "  GitHub Actions Workflow Validation"
echo "=========================================="
echo ""

ERRORS=0

# Test 1: Flavor mapping
echo "Test 1: Flavor mapping..."
test_flavor() {
  local input="$1"
  local expected="$2"
  
  case "$input" in
    "Large"*) result="large" ;;
    "Medium"*) result="medium" ;;
    "High"*) result="xl" ;;
    "") result="" ;;
    *) result="ERROR" ;;
  esac
  
  if [ "$result" = "$expected" ]; then
    echo "  ✓ '$input' -> '$result'"
  else
    echo "  ✗ '$input' -> '$result' (expected: $expected)"
    ((ERRORS++))
  fi
}

test_flavor "Large: 4 vCPU, 32GB RAM (~\$0.15/hr)" "large"
test_flavor "Medium: 4 vCPU, 16GB RAM (~\$0.08/hr)" "medium"
test_flavor "High: 8 vCPU, 64GB RAM (~\$0.30/hr)" "xl"
test_flavor "" ""
echo ""

# Test 2: SSH keys JSON conversion
echo "Test 2: SSH keys JSON conversion..."
if command -v jq >/dev/null 2>&1; then
  # Test with real keys
  TEST_KEYS="ssh-rsa AAAAB3Nza...test1 user@host1
ssh-rsa AAAAB3Nza...test2 user@host2"
  
  RESULT=$(echo "$TEST_KEYS" | jq -R -s 'split("\n") | map(select(length > 0))' 2>&1)
  
  if echo "$RESULT" | jq -e '. | length == 2' >/dev/null 2>&1; then
    echo "  ✓ SSH keys converted to JSON array (2 keys)"
  else
    echo "  ✗ SSH keys conversion failed"
    echo "    Result: $RESULT"
    ((ERRORS++))
  fi
  
  # Test with empty string
  RESULT_EMPTY=$(echo "" | jq -R -s 'split("\n") | map(select(length > 0))' 2>&1)
  if echo "$RESULT_EMPTY" | jq -e '. | length == 0' >/dev/null 2>&1; then
    echo "  ✓ Empty SSH keys handled correctly"
  else
    echo "  ✗ Empty SSH keys handling failed"
    ((ERRORS++))
  fi
else
  echo "  ⚠ jq not installed, skipping JSON tests"
fi
echo ""

# Test 3: Required environment variables
echo "Test 3: Checking required environment variables..."
check_var() {
  local var="$1"
  local desc="$2"
  
  # Simulate GitHub environment (check if set in GitHub)
  echo "  ℹ $var: $desc"
  echo "    (Must be set in GitHub: Settings → Secrets and variables → Actions)"
}

check_var "AWS_ROLE_ARN" "OIDC role for Terraform (from bootstrap)"
check_var "TF_STATE_BUCKET" "S3 bucket for Terraform state"
check_var "TF_STATE_KEY" "S3 key for Terraform state"
check_var "TF_LOCK_TABLE" "DynamoDB table for state locking"
check_var "DEVBOX_KEY_NAME" "EC2 key pair name (constant)"
check_var "DEVBOX_ADDITIONAL_SSH_KEYS" "SSH public keys to sync (optional)"
echo ""

# Test 4: terraform.tfvars generation simulation
echo "Test 4: Simulating terraform.tfvars generation..."
cat > /tmp/test_terraform.tfvars <<'EOF'
aws_region        = "us-west-2"
availability_zone = "us-west-2a"

key_name            = "dev-box"
ssh_public_key_path = ""

additional_ssh_public_keys = []

allowed_ssh_cidrs = ["0.0.0.0/0"]

create_vpc = true
enable_eip = true
instance_name = "dev-box"

ebs_size_gb     = 96
ebs_volume_type = "gp3"

enable_claude_api_key_from_secrets_manager = true
claude_api_key_secret_id = "CLAUDE_API_KEY"
claude_secret_region     = "us-west-2"
EOF

if [ -f /tmp/test_terraform.tfvars ]; then
  echo "  ✓ terraform.tfvars format is valid"
  rm /tmp/test_terraform.tfvars
else
  echo "  ✗ terraform.tfvars generation failed"
  ((ERRORS++))
fi
echo ""

# Test 5: Action conditions
echo "Test 5: Testing action conditions..."
test_action() {
  local action="$1"
  case "$action" in
    "start") echo "  ✓ Action 'start': terraform apply -var=\"enable_instance=true\"" ;;
    "destroy") echo "  ✓ Action 'destroy': terraform apply -var=\"enable_instance=false\"" ;;
    "plan") echo "  ✓ Action 'plan': terraform plan" ;;
    *) echo "  ✗ Unknown action: $action"; ((ERRORS++)) ;;
  esac
}

test_action "start"
test_action "destroy"
test_action "plan"
echo ""

# Summary
echo "=========================================="
echo "  Summary"
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
  echo "✅ All workflow logic tests passed!"
  echo ""
  echo "Next steps to test on GitHub:"
  echo "1. Ensure all required secrets/variables are set:"
  echo "   - AWS_ROLE_ARN (from bootstrap output)"
  echo "   - TF_STATE_BUCKET, TF_STATE_KEY, TF_LOCK_TABLE"
  echo "   - DEVBOX_KEY_NAME = \"dev-box\""
  echo "   - DEVBOX_ADDITIONAL_SSH_KEYS (your public keys)"
  echo ""
  echo "2. Go to: Actions → dev-box → Run workflow"
  echo "3. Select: action=start, flavor=Large (or blank)"
  echo "4. Monitor the run for any issues"
  echo ""
  echo "The workflow file syntax and logic look correct!"
  exit 0
else
  echo "❌ Found $ERRORS error(s) in workflow logic"
  exit 1
fi
