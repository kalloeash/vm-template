# vm-template — hardened Debian-family VM baseline.
# Usage:  make harden          full baseline (base tier)
#         make harden TIER=full   + auditd
#         make <module>        one module (preflight always runs first)
#         make audit           verify only, changes nothing
#         make lint            shellcheck + shfmt (workstation)
# Knobs:  ADMIN_USER=admin  EXTRA_PORTS="80/tcp 443/tcp"  DRY_RUN=1  TIER=base|full

SHELL := /usr/bin/env bash
MODULES_DIR := modules
TIER ?= base
export TIER   # reaches the module environment so 80-auditd can self-gate

# 80-auditd self-gates on $TIER: base tier sets only journald persistence and
# exits; TIER=full additionally installs auditd + the rule set.
MODULES := 10-update 20-user 30-ssh 40-firewall 50-fail2ban 60-sysctl 65-hardening 70-docker 80-auditd

.PHONY: harden audit lint preflight report \
        update user ssh firewall fail2ban sysctl hardening docker auditd

harden: preflight
	@for m in $(MODULES); do bash $(MODULES_DIR)/$$m.sh || exit 1; done
	@bash $(MODULES_DIR)/90-report.sh

preflight:
	@bash $(MODULES_DIR)/00-preflight.sh

audit:
	@AUDIT_ONLY=1 bash $(MODULES_DIR)/90-report.sh

report:
	@bash $(MODULES_DIR)/90-report.sh

# individual modules (each depends on preflight's guards)
update: preflight ;    @bash $(MODULES_DIR)/10-update.sh
user: preflight ;      @bash $(MODULES_DIR)/20-user.sh
ssh: preflight ;       @bash $(MODULES_DIR)/30-ssh.sh
firewall: preflight ;  @bash $(MODULES_DIR)/40-firewall.sh
fail2ban: preflight ;  @bash $(MODULES_DIR)/50-fail2ban.sh
sysctl: preflight ;    @bash $(MODULES_DIR)/60-sysctl.sh
hardening: preflight ; @bash $(MODULES_DIR)/65-hardening.sh
docker: preflight ;    @bash $(MODULES_DIR)/70-docker.sh
auditd: preflight ;    @bash $(MODULES_DIR)/80-auditd.sh

# workstation-side
lint:
	shellcheck $(MODULES_DIR)/*.sh lib/*.sh
	shfmt -d -i 2 -ci $(MODULES_DIR) lib
