#!/usr/bin/env bash
# prices.sh — show current spot prices + on-demand comparison for each flavor.
#
# Uses: aws ec2 describe-spot-price-history (latest entry per instance type)
# Also uses: AWS Pricing API (on-demand rates) for savings estimates.
# Requires: aws CLI configured, jq
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TFVARS="$REPO_DIR/terraform.tfvars"

default_region="us-west-2"
default_az="us-west-2a"

region="$default_region"
az="$default_az"

if [ -f "$TFVARS" ]; then
  # best-effort parse of simple tfvars assignments
  region="$(grep -E '^aws_region[[:space:]]*=[[:space:]]*"' "$TFVARS" | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)"
  az="$(grep -E '^availability_zone[[:space:]]*=[[:space:]]*"' "$TFVARS" | sed -E 's/.*"([^"]+)".*/\1/' | head -n1 || true)"
fi

region="${region:-$default_region}"
az="${az:-$default_az}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found." >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found." >&2
  exit 127
fi

# ---------------------------------------------------------------------------
# Resolve AWS region long name for Pricing API (e.g. "US West (Oregon)")
# ---------------------------------------------------------------------------
location=""
location="$(aws --region "$region" ssm get-parameter \
  --name "/aws/service/global-infrastructure/regions/$region/longName" \
  --query 'Parameter.Value' --output text 2>/dev/null || true)"

if [ -z "$location" ]; then
  case "$region" in
    us-west-2) location="US West (Oregon)" ;;
    us-west-1) location="US West (N. California)" ;;
    us-east-1) location="US East (N. Virginia)" ;;
    us-east-2) location="US East (Ohio)" ;;
    *) location="" ;;
  esac
fi

if [ -z "$location" ]; then
  echo "WARNING: couldn't resolve Pricing 'location' name for region '$region'; on-demand lookup may fail." >&2
fi

# ---------------------------------------------------------------------------
# On-demand pricing lookup via AWS Pricing API (queried in us-east-1)
# ---------------------------------------------------------------------------
get_ondemand_usd_per_hr() {
  local instance_type="$1"
  local pricing_region="us-east-1"

  if [ -z "$location" ]; then
    echo ""
    return 0
  fi

  local out
  out="$(aws --region "$pricing_region" pricing get-products \
    --service-code AmazonEC2 \
    --filters \
      Type=TERM_MATCH,Field=instanceType,Value="$instance_type" \
      Type=TERM_MATCH,Field=location,Value="$location" \
      Type=TERM_MATCH,Field=operatingSystem,Value="Linux" \
      Type=TERM_MATCH,Field=tenancy,Value="Shared" \
      Type=TERM_MATCH,Field=preInstalledSw,Value="NA" \
      Type=TERM_MATCH,Field=capacitystatus,Value="Used" \
    --max-results 1 \
    2>/dev/null || true)"

  if [ -z "$out" ]; then
    echo ""
    return 0
  fi

  echo "$out" | jq -r '
    .PriceList[0]?
    | fromjson
    | .terms.OnDemand
    | .. | objects
    | select(has("pricePerUnit") and has("unit"))
    | select(.unit == "Hrs")
    | .pricePerUnit.USD
  ' | awk 'NF{print; exit}'
}

# Keep this mapping in sync with variables.tf locals.flavors.
declare -A FLAVORS=(
  [small]="t3.large"
  [medium]="m7i.xlarge"
  [large]="r7i.xlarge"
  [xl]="r7i.2xlarge"
)

types=()
for k in "${!FLAVORS[@]}"; do
  types+=("${FLAVORS[$k]}")
done

json="$(aws --region "$region" ec2 describe-spot-price-history \
  --availability-zone "$az" \
  --product-descriptions "Linux/UNIX" \
  --instance-types "${types[@]}" \
  --max-items 100 \
  --start-time "$(date -Iseconds)" \
  2>/dev/null || true)"

if [ -z "$json" ]; then
  echo "No data returned. Are AWS credentials configured and is the region/AZ correct?" >&2
  exit 2
fi

# Build a latest-price map by instance type.
prices="$(echo "$json" | jq -r '
  (.SpotPriceHistory // [])
  | sort_by(.Timestamp) | reverse
  | group_by(.InstanceType)
  | map({(.[0].InstanceType): {price: (.[0].SpotPrice|tonumber), ts: .[0].Timestamp}})
  | add
')"

printf "Region: %s  AZ: %s\\n\\n" "$region" "$az"
printf "%-6s  %-12s  %10s  %10s  %10s  %7s  %9s  %9s  %9s  %s\\n" \
  "tier" "type" "spot/hr" "od/hr" "save/hr" "save%" "save@2h" "save@4h" "save@8h" "timestamp"
printf "%-6s  %-12s  %10s  %10s  %10s  %7s  %9s  %9s  %9s  %s\\n" \
  "------" "------------" "--------" "-----" "------" "-----" "-------" "-------" "-------" "---------"

for tier in small medium large xl; do
  t="${FLAVORS[$tier]}"
  p="$(echo "$prices" | jq -r --arg t "$t" '.[$t].price // empty')"
  ts="$(echo "$prices" | jq -r --arg t "$t" '.[$t].ts // empty')"
  if [ -z "$p" ]; then
    printf "%-6s  %-12s  %10s  %10s  %10s  %7s  %9s  %9s  %9s  %s\\n" \
      "$tier" "$t" "n/a" "n/a" "n/a" "n/a" "n/a" "n/a" "n/a" "n/a"
  else
    od="$(get_ondemand_usd_per_hr "$t")"
    if [ -z "${od:-}" ] || ! awk "BEGIN{exit !($od+0>0)}" 2>/dev/null; then
      printf "%-6s  %-12s  %10.4f  %10s  %10s  %7s  %9s  %9s  %9s  %s\\n" \
        "$tier" "$t" "$p" "n/a" "n/a" "n/a" "n/a" "n/a" "n/a" "$ts"
    else
      save_hr="$(awk -v od="$od" -v sp="$p" 'BEGIN{printf "%.4f", (od-sp)}')"
      save_pct="$(awk -v od="$od" -v sp="$p" 'BEGIN{printf "%.1f", (100.0*(1.0-(sp/od)))}')"
      save_2h="$(awk -v s="$save_hr" 'BEGIN{printf "%.2f", (s*2)}')"
      save_4h="$(awk -v s="$save_hr" 'BEGIN{printf "%.2f", (s*4)}')"
      save_8h="$(awk -v s="$save_hr" 'BEGIN{printf "%.2f", (s*8)}')"
      printf "%-6s  %-12s  %10.4f  %10.4f  %10.4f  %6s%%  %9.2f  %9.2f  %9.2f  %s\\n" \
        "$tier" "$t" "$p" "$od" "$save_hr" "$save_pct" "$save_2h" "$save_4h" "$save_8h" "$ts"
    fi
  fi
done

printf "\\nNotes:\\n"
printf " - spot/hr is the latest spot price observed in %s.\\n" "$az"
printf " - od/hr uses the AWS Pricing API for %s (Linux, shared tenancy).\\n" "${location:-unknown}"
printf " - savings are (on-demand - spot) * hours.\\n"
