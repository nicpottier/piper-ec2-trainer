#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/../config.env"

echo "=== Launching EC2 Spot Instance for Sinhala TTS Training ==="
echo ""

# Find the latest Deep Learning AMI (GPU, Ubuntu)
echo "Finding latest Deep Learning AMI (GPU, Ubuntu) in ${EC2_REGION} ..."
AMI_ID=$(aws ec2 describe-images \
    --region "${EC2_REGION}" \
    --owners amazon \
    --filters \
        "Name=name,Values=Deep Learning OSS Nvidia Driver AMI GPU PyTorch*Ubuntu*" \
        "Name=state,Values=available" \
        "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    # Fallback: try broader search
    echo "  Trying broader AMI search..."
    AMI_ID=$(aws ec2 describe-images \
        --region "${EC2_REGION}" \
        --owners amazon \
        --filters \
            "Name=name,Values=Deep Learning*GPU*Ubuntu*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text)
fi

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
    echo "ERROR: Could not find a suitable Deep Learning AMI."
    echo "You can manually set EC2_AMI in config.env and re-run."
    exit 1
fi

echo "  Using AMI: $AMI_ID"

# Check if key pair exists
echo "Checking key pair: ${EC2_KEY_NAME} ..."
if ! aws ec2 describe-key-pairs --key-names "${EC2_KEY_NAME}" --region "${EC2_REGION}" &>/dev/null; then
    echo "  WARNING: Key pair '${EC2_KEY_NAME}' not found in ${EC2_REGION}."
    echo "  Create it with: aws ec2 create-key-pair --key-name ${EC2_KEY_NAME} --region ${EC2_REGION}"
    echo "  Or update EC2_KEY_NAME in config.env."
    exit 1
fi

# Create security group if needed
SG_NAME="sinhala-tts-training-sg"
SG_ID=$(aws ec2 describe-security-groups \
    --region "${EC2_REGION}" \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
    echo "Creating security group: ${SG_NAME} ..."
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "Security group for Sinhala TTS training" \
        --region "${EC2_REGION}" \
        --output text --query 'GroupId')

    # Allow SSH
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "${EC2_REGION}"
    echo "  Created security group: ${SG_ID}"
else
    echo "  Using existing security group: ${SG_ID}"
fi

# Create IAM instance profile check (for S3 access)
echo ""
echo "NOTE: Ensure the instance has an IAM role with S3 access."
echo "  You can attach a role with AmazonS3FullAccess policy."
echo ""

# Launch instance (on-demand or spot based on EC2_USE_SPOT)
EC2_USE_SPOT="${EC2_USE_SPOT:-false}"

SPOT_OPTS=()
if [ "${EC2_USE_SPOT}" = "true" ]; then
    echo "Launching ${EC2_INSTANCE_TYPE} spot instance (max price: \$${EC2_SPOT_MAX_PRICE}/hr) ..."
    SPOT_OPTS=(--instance-market-options '{
        "MarketType": "spot",
        "SpotOptions": {
            "MaxPrice": "'"${EC2_SPOT_MAX_PRICE}"'",
            "SpotInstanceType": "persistent",
            "InstanceInterruptionBehavior": "stop"
        }
    }')
else
    echo "Launching ${EC2_INSTANCE_TYPE} on-demand instance ..."
fi

# Try multiple AZs if capacity is unavailable
SUBNETS=$(aws ec2 describe-subnets \
    --region "${EC2_REGION}" \
    --filters "Name=default-for-az,Values=true" \
    --query 'Subnets[*].SubnetId' \
    --output text)

INSTANCE_ID=""
for SUBNET in ${SUBNETS}; do
    AZ=$(aws ec2 describe-subnets --subnet-ids "${SUBNET}" --region "${EC2_REGION}" \
        --query 'Subnets[0].AvailabilityZone' --output text)
    echo "  Trying ${AZ} (subnet ${SUBNET}) ..."

    INSTANCE_ID=$(aws ec2 run-instances \
        --region "${EC2_REGION}" \
        --image-id "${AMI_ID}" \
        --instance-type "${EC2_INSTANCE_TYPE}" \
        --key-name "${EC2_KEY_NAME}" \
        --security-group-ids "${SG_ID}" \
        --subnet-id "${SUBNET}" \
        --associate-public-ip-address \
        ${SPOT_OPTS[@]+"${SPOT_OPTS[@]}"} \
        --block-device-mappings '[{
            "DeviceName": "/dev/sda1",
            "Ebs": {
                "VolumeSize": 200,
                "VolumeType": "gp3",
                "DeleteOnTermination": true
            }
        }]' \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=sinhala-tts-training}]' \
        --query 'Instances[0].InstanceId' \
        --output text 2>/dev/null) && break || INSTANCE_ID=""

    echo "    No capacity in ${AZ}, trying next..."
done

if [ -z "${INSTANCE_ID}" ]; then
    echo "ERROR: Could not launch instance in any availability zone."
    exit 1
fi

echo "  Instance ID: ${INSTANCE_ID}"
echo "${INSTANCE_ID}" > "$PROJECT_DIR/.instance_id"

# Wait for instance to be running
echo "Waiting for instance to enter 'running' state ..."
aws ec2 wait instance-running \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${EC2_REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "=== Instance Ready ==="
echo "  Instance ID: ${INSTANCE_ID}"
echo "  Public IP:   ${PUBLIC_IP}"
echo "  Instance ID saved to .instance_id"
echo ""
echo "Connect with:"
echo "  ssh -i ~/.ssh/${EC2_KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo ""
echo "Next steps:"
echo "  1. scp config.env and scripts/ to the instance"
echo "  2. Run scripts/ec2-setup.sh on the instance"
echo "  3. Run scripts/train.sh to start training"
