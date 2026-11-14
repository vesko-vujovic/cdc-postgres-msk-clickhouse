DBZ_VERSION ?= 3.6.2.Final
TF := terraform -chdir=terraform
TF_VARS := -var debezium_version=$(DBZ_VERSION)
BOX := ./scripts/box.sh

.PHONY: plugin infra init connector up seed churn compare latency slot flood \
        stop-connector start-connector logs drop-slot top-merchants shell destroy

## --- setup -------------------------------------------------------------

plugin:            ## download Debezium and repackage it as a ZIP for MSK Connect
	./scripts/build_plugin.sh $(DBZ_VERSION)

infra: plugin      ## VPC, RDS, MSK, ClickHouse box (no connector yet), ~30 min
	$(TF) init -upgrade
	$(TF) apply $(TF_VARS) -var create_connector=false

init:              ## create table, debezium user, publication, ClickHouse objects, seed 10k rows
	$(BOX) init

connector:         ## create the Debezium connector on MSK Connect, ~5-10 min
	$(TF) apply $(TF_VARS) -var create_connector=true

up: infra init connector

## --- demo --------------------------------------------------------------

seed:              ## make seed N=50000
	$(BOX) seed $(or $(N),10000)

churn:             ## make churn N=5000
	$(BOX) churn $(or $(N),1000)

compare:           ## PostgreSQL vs ClickHouse row counts and totals
	$(BOX) compare

latency:           ## p50 / p99 end-to-end lag of recent changes
	$(BOX) latency

top-merchants:
	$(BOX) top-merchants

slot:              ## WAL retained by the replication slot
	$(BOX) slot

## --- break it ------------------------------------------------------------

stop-connector:    ## delete the connector, the slot stays behind
	$(TF) apply $(TF_VARS) -var create_connector=false

flood:             ## make flood N=1000000, then watch `make slot`
	$(BOX) flood $(or $(N),1000000)

start-connector: connector  ## recreate it, it resumes from the stored offset

drop-slot:         ## emergency brake: frees WAL, loses the CDC position
	$(BOX) drop-slot

## --- misc ----------------------------------------------------------------

logs:              ## tail MSK Connect worker logs
	aws logs tail $$($(TF) output -raw connector_log_group) --follow --region $$($(TF) output -raw region)

shell:             ## interactive shell on the ClickHouse box
	aws ssm start-session --target $$($(TF) output -raw box_instance_id) --region $$($(TF) output -raw region)

destroy:
	$(TF) destroy $(TF_VARS) -var create_connector=false
