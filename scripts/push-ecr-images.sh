#!/bin/bash
# ============================================================================
# PUSH CLOUDLENS SENSOR TO ALL ECR REPOSITORIES
# ============================================================================
# Loads CloudLens sensor from tar file and pushes to ECR repositories
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_PROFILE="${AWS_PROFILE:-cloudlens-lab}"
CLOUDLENS_SENSOR_VERSION="${CLOUDLENS_SENSOR_VERSION:-6.13.0-359}"
SOURCE_IMAGE="${SOURCE_IMAGE:-cloudlens/sensor:${CLOUDLENS_SENSOR_VERSION}}"

# CloudLens Sensor tar file location
SENSOR_TAR_FILE="${SENSOR_TAR_FILE:-$HOME/Downloads/CloudLens-Sensor-6.13.0-359.tar}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "============================================================================"
echo "  CloudLens Sensor ECR Push"
echo "============================================================================"
echo ""
echo "Source Image:  $SOURCE_IMAGE"
echo "Tar File:      $SENSOR_TAR_FILE"
echo "AWS Region:    $AWS_REGION"
echo "AWS Profile:   $AWS_PROFILE"
echo ""

# Get AWS account ID
log_info "Getting AWS account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log_info "ECR Registry: $ECR_REGISTRY"

# Login to ECR
log_info "Logging into ECR..."
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

log_success "ECR login successful"

# Get list of all CloudLens sensor ECR repositories
log_info "Finding CloudLens sensor repositories..."
REPOS=$(aws ecr describe-repositories \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query 'repositories[?contains(repositoryName, `cloudlens-sensor`)].repositoryName' \
  --output text 2>/dev/null || echo "")

if [ -z "$REPOS" ]; then
  log_warning "No CloudLens sensor repositories found"
  log_info "Repositories are created when EKS is enabled for SE labs"
  exit 0
fi

# Count repositories
REPO_COUNT=$(echo "$REPOS" | wc -w | tr -d ' ')
log_info "Found $REPO_COUNT CloudLens sensor repositories:"
echo "$REPOS" | tr '\t' '\n' | sed 's/^/  - /'
echo ""

# Check if source image exists locally
if ! docker image inspect "$SOURCE_IMAGE" &>/dev/null; then
  log_warning "Source image $SOURCE_IMAGE not found locally"
  echo ""

  # Check if tar file exists
  if [ -f "$SENSOR_TAR_FILE" ]; then
    log_info "Found CloudLens sensor tar file: $SENSOR_TAR_FILE"
    log_info "Loading image from tar file..."

    docker load -i "$SENSOR_TAR_FILE" || {
      log_error "Failed to load image from $SENSOR_TAR_FILE"
      exit 1
    }

    log_success "Image loaded from tar file"

    # Check what image was loaded and tag it correctly
    LOADED_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -i cloudlens | grep -i sensor | head -1)
    if [ -n "$LOADED_IMAGE" ] && [ "$LOADED_IMAGE" != "$SOURCE_IMAGE" ]; then
      log_info "Tagging $LOADED_IMAGE as $SOURCE_IMAGE"
      docker tag "$LOADED_IMAGE" "$SOURCE_IMAGE"
    fi
  else
    log_warning "Tar file not found at: $SENSOR_TAR_FILE"
    echo ""
    echo "Options:"
    echo "  1. Place CloudLens-Sensor-6.13.0-359.tar in ~/Downloads/"
    echo "  2. Set SENSOR_TAR_FILE env var to the correct path"
    echo "  3. Pull from Docker Hub (requires access)"
    echo ""

    read -p "Attempt to pull from Docker Hub? (yes/no): " pull_confirm
    if [[ "$pull_confirm" == "yes" ]]; then
      log_info "Pulling from Docker Hub..."
      docker pull "$SOURCE_IMAGE" || {
        log_error "Failed to pull $SOURCE_IMAGE"
        log_info "Please ensure you have access to the CloudLens sensor image"
        exit 1
      }
    else
      exit 0
    fi
  fi
fi

log_success "Source image available: $SOURCE_IMAGE"
echo ""

read -p "Push to all $REPO_COUNT repositories? (yes/no): " push_confirm
if [[ "$push_confirm" != "yes" ]]; then
  log_warning "Push cancelled"
  exit 0
fi

echo ""

# Push to each repository
PUSHED=0
FAILED=0

for REPO in $REPOS; do
  TARGET_IMAGE="${ECR_REGISTRY}/${REPO}:${CLOUDLENS_SENSOR_VERSION}"
  TARGET_LATEST="${ECR_REGISTRY}/${REPO}:latest"

  log_info "Pushing to $REPO..."

  # Tag and push versioned
  if docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE" && docker push "$TARGET_IMAGE"; then
    # Tag and push latest
    if docker tag "$SOURCE_IMAGE" "$TARGET_LATEST" && docker push "$TARGET_LATEST"; then
      log_success "Pushed to $REPO"
      ((PUSHED++))
    else
      log_warning "Failed to push :latest tag to $REPO"
      ((FAILED++))
    fi
  else
    log_error "Failed to push to $REPO"
    ((FAILED++))
  fi
done

echo ""
echo "============================================================================"
echo "  Summary"
echo "============================================================================"
echo ""
echo "  Successful: $PUSHED"
echo "  Failed:     $FAILED"
echo "  Total:      $REPO_COUNT"
echo ""

if [ $FAILED -eq 0 ]; then
  log_success "All ECR repositories updated with CloudLens sensor image"
else
  log_warning "Some repositories failed to update"
fi
