#!/bin/bash
# ============================================================================
# POST-DEPLOY SCRIPT
# ============================================================================
# Run after terraform apply to patch generated documentation with dynamic data
# (nginx LoadBalancer URL, etc.)
#
# Usage: ./scripts/post-deploy.sh [--guide-path PATH]
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
GUIDE_PATH=""
DEPLOYMENT_PREFIX=""

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --guide-path) GUIDE_PATH="$2"; shift 2 ;;
        --prefix) DEPLOYMENT_PREFIX="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Auto-detect deployment prefix from terraform output
if [[ -z "$DEPLOYMENT_PREFIX" ]]; then
    DEPLOYMENT_PREFIX=$(cd "$BASE_DIR/terraform" && terraform output -raw deployment_prefix 2>/dev/null || echo "cloudlens-lab")
fi

# Auto-detect guide path
if [[ -z "$GUIDE_PATH" ]]; then
    GUIDE_PATH="$BASE_DIR/terraform/generated/${DEPLOYMENT_PREFIX}/$(echo "$DEPLOYMENT_PREFIX" | tr '[:lower:]' '[:upper:]')-GUIDE.md"
fi

echo ""
echo "============================================================================"
echo "  Post-Deploy: Patching Documentation with Dynamic Data"
echo "============================================================================"
echo ""
echo -e "${BLUE}[INFO]${NC} Deployment prefix: ${DEPLOYMENT_PREFIX}"
echo -e "${BLUE}[INFO]${NC} Guide path: ${GUIDE_PATH}"

if [[ ! -f "$GUIDE_PATH" ]]; then
    echo -e "${RED}[ERROR]${NC} Guide file not found: ${GUIDE_PATH}"
    echo "  Run 'terraform apply' first to generate documentation."
    exit 1
fi

# ============================================================================
# STEP 1: Patch nginx LoadBalancer URL
# ============================================================================

echo ""
echo -e "${BLUE}[INFO]${NC} Fetching nginx-demo LoadBalancer URL..."

NGINX_URL=$(kubectl get svc nginx-demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -z "$NGINX_URL" ]]; then
    echo -e "${YELLOW}[WARNING]${NC} nginx-demo service not found or no LoadBalancer URL yet."
    echo "  Deploy nginx-demo first, then re-run this script."
else
    echo -e "${GREEN}[SUCCESS]${NC} nginx LB URL: ${NGINX_URL}"

    # Check if already patched
    if grep -q "NGINX_URL_PLACEHOLDER" "$GUIDE_PATH" 2>/dev/null; then
        echo -e "${BLUE}[INFO]${NC} Patching guide with nginx URL..."

        # Build the replacement content
        NGINX_SECTION="Your nginx application is deployed and accessible at:

| Protocol | URL |
|----------|-----|
| **HTTP** | http://${NGINX_URL} |
| **HTTPS** | https://${NGINX_URL} |

**Open in browser:** [http://${NGINX_URL}](http://${NGINX_URL})

The page displays the **CloudLens K8s Visibility Lab** welcome page featuring:
- Keysight logo with pulse animation
- Rainbow gradient animated title
- Floating particle effects over Keysight background image
- Glassmorphism info card showing Lab, Namespace, Cluster, Platform, and Status
- \"Active & Monitored\" live status indicator
- Refresh button

**Test from terminal:**
\`\`\`bash
# HTTP
curl http://${NGINX_URL}

# HTTPS (self-signed cert)
curl -k https://${NGINX_URL}
\`\`\`

This nginx service runs in the default namespace on the EKS cluster. CyPerf traffic generator sends simulated app traffic (Netflix, YouTube, Discord, ChatGPT) through the cyperf-proxy to these nginx pods, which CloudLens sensors can then capture."

        # Use python for reliable multi-line sed replacement
        python3 -c "
import re, sys

with open('$GUIDE_PATH', 'r') as f:
    content = f.read()

# Replace the placeholder block
pattern = r'<!-- NGINX_URL_PLACEHOLDER_START -->.*?<!-- NGINX_URL_PLACEHOLDER_END -->'
replacement = '''$NGINX_SECTION'''

content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open('$GUIDE_PATH', 'w') as f:
    f.write(content)
"
        echo -e "${GREEN}[SUCCESS]${NC} Guide patched with nginx URL"
    else
        echo -e "${BLUE}[INFO]${NC} Guide already has nginx URL (no placeholder found). Skipping."
    fi
fi

# ============================================================================
# STEP 2: Show deployment summary
# ============================================================================

echo ""
echo "============================================================================"
echo "  Post-Deploy Complete"
echo "============================================================================"
echo ""
echo "  Generated Files:"
echo "    Guide:       ${GUIDE_PATH}"
echo "    Credentials: $(dirname "$GUIDE_PATH")/credentials.txt"
echo ""

if [[ -n "$NGINX_URL" ]]; then
    echo "  Nginx Web Page:"
    echo "    HTTP:  http://${NGINX_URL}"
    echo "    HTTPS: https://${NGINX_URL}"
    echo ""
fi

# Show all product URLs from terraform output
echo "  Product URLs:"
cd "$BASE_DIR/terraform"
CLMS_URL=$(terraform output -raw clms_url 2>/dev/null || echo "N/A")
KVO_URL=$(terraform output -raw kvo_url 2>/dev/null || echo "N/A")
CYPERF_URL=$(terraform output -raw cyperf_controller_ui_url 2>/dev/null || echo "N/A")

echo "    CLMS:   ${CLMS_URL}"
echo "    KVO:    ${KVO_URL}"
[[ "$CYPERF_URL" != "N/A" && -n "$CYPERF_URL" ]] && echo "    CyPerf: ${CYPERF_URL}"
echo ""
echo "============================================================================"
echo ""
