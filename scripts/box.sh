#!/usr/bin/env bash
# Run a `cdc` command on the ClickHouse box through SSM Run Command and print the output.
# Usage: scripts/box.sh compare
#        scripts/box.sh churn 5000
set -euo pipefail

cd "$(dirname "$0")/../terraform"
INSTANCE_ID="$(terraform output -raw box_instance_id)"
REGION="$(terraform output -raw region)"

COMMAND="/opt/cdc/cdc.sh $*"

CMD_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --timeout-seconds 3600 \
  --parameters "{\"commands\":[\"$COMMAND\"],\"executionTimeout\":[\"3600\"]}" \
  --query Command.CommandId --output text)"

while true; do
  STATUS="$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Pending|InProgress|Delayed) sleep 3 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text

ERR="$(aws ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardErrorContent --output text)"
if [ -n "$ERR" ] && [ "$ERR" != "None" ]; then
  echo "--- stderr ---" >&2
  echo "$ERR" >&2
fi

[ "$STATUS" = "Success" ] || { echo "command finished with status $STATUS" >&2; exit 1; }
