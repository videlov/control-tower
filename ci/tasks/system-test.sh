#!/bin/bash

: "${IAAS:=AWS}"

set -e
[ "$VERBOSE" ] && { set -x; export BOSH_LOG_LEVEL=debug; export BOSH_LOG_PATH=bosh.log; }

if [ -z "$SYSTEM_TEST_ID" ]; then
  # ID constrained to a maximum of four characters to avoid exceeding character limit in GCP naming
  MAX_ID=9999
  SYSTEM_TEST_ID=$RANDOM
  (( SYSTEM_TEST_ID %= MAX_ID ))
fi
deployment="systest-$SYSTEM_TEST_ID"

set -u

# If we're testing GCP, we need credentials to be available as a file
if [ "$IAAS" = "GCP" ]; then
  echo "${GOOGLE_APPLICATION_CREDENTIALS_CONTENTS}" > googlecreds.json
  export GOOGLE_APPLICATION_CREDENTIALS=$PWD/googlecreds.json
fi

assertDbCorrect() {
  if [ "$IAAS" = "AWS" ]; then
  rds_instance_class=$(aws --region eu-west-1 rds describe-db-instances | jq -r ".DBInstances[] | select(.DBSubnetGroup.DBSubnetGroupName==\"concourse-up-$deployment\") | .DBInstanceClass")
    if [ "$rds_instance_class" != "db.t2.small" ]; then
      echo "Unexpected DB instance class: $rds_instance_class"
      exit 1
    fi
  elif [ "$IAAS" = "GCP" ]; then
    rds_instance_tier=$(gcloud sql instances list --filter="labels.deployment:concourse-up-$deployment" --format=json | jq '.[0].settings.tier')
    if [ "$rds_instance_tier" != "db-f1-micro" ]; then
      echo "Unexpected DB instance tier: $rds_instance_tier"
      exit 1
    else
      echo "Unknown iaas: $IAAS"
      exit 1
    fi
  fi
}

cleanup() {
  status=$?
  ./cup --non-interactive destroy $deployment
  exit $status
}
set +u
if [ -z "$SKIP_TEARDOWN" ]; then
  trap cleanup EXIT
else
  trap "echo Skipping teardown" EXIT
fi
set -u

cp "$BINARY_PATH" ./cup
chmod +x ./cup

echo "DEPLOY WITH AUTOGENERATED CERT, NO DOMAIN, DEFAULT WORKERS, AND DEFAULT DATABASE SIZE, AND DEFAULT WEB NODE SIZE"

./cup deploy $deployment

sleep 60


# Check we can log into the BOSH director and SSH into a VM
eval "$(./cup info --env $deployment)"
bosh vms
bosh ssh worker true

config=$(./cup info --json $deployment)
domain=$(echo "$config" | jq -r '.config.domain')
username=$(echo "$config" | jq -r '.config.concourse_username')
password=$(echo "$config" | jq -r '.config.concourse_password')
echo "$config" | jq -r '.config.concourse_ca_cert' > generated-ca-cert.pem

# Check RDS instance class is db.t2.small
assertDbCorrect


fly --target system-test login \
  --ca-cert generated-ca-cert.pem \
  --concourse-url "https://$domain" \
  --username "$username" \
  --password "$password"

curl -k "https://$domain:3000"

fly --target system-test sync

fly --target system-test set-pipeline \
  --non-interactive \
  --pipeline hello \
  --config "$(dirname "$0")/hello.yml"

fly --target system-test unpause-pipeline \
    --pipeline hello

fly --target system-test trigger-job \
  --job hello/hello \
  --watch

echo "DEPLOY WITH USER PROVIDED CERT, 2 LARGE WORKERS, FIREWALLED TO MY IP"

custom_domain="$deployment-user.concourse-up.engineerbetter.com"

certstrap init \
  --common-name "$deployment" \
  --passphrase "" \
  --organization "" \
  --organizational-unit "" \
  --country "" \
  --province "" \
  --locality ""

certstrap request-cert \
   --passphrase "" \
   --domain $custom_domain

certstrap sign "$custom_domain" --CA "$deployment"

./cup deploy $deployment \
  --domain $custom_domain \
  --tls-cert "$(cat out/$custom_domain.crt)" \
  --tls-key "$(cat out/$custom_domain.key)" \
  --allow-ips "$(dig +short myip.opendns.com @resolver1.opendns.com)" \
  --workers 2 \
  --worker-size large

sleep 60

# Check RDS instance class is still db.t2.small
assertDbCorrect

config=$(./cup info --json $deployment)
username=$(echo "$config" | jq -r '.config.concourse_username')
password=$(echo "$config" | jq -r '.config.concourse_password')
echo "$config" | jq -r '.config.concourse_ca_cert' > generated-ca-cert.pem

fly --target system-test-custom-domain-with-cert login \
  --ca-cert out/$deployment.crt \
  --concourse-url https://$custom_domain \
  --username "$username" \
  --password "$password"

curl -k "https://$custom_domain:3000"

fly --target system-test-custom-domain-with-cert sync

# Check that hello/hello job still exists and works
fly --target system-test-custom-domain-with-cert trigger-job \
  --job hello/hello \
  --watch


