# vm-template — hardened Debian-family VM baseline.
# Usage:  make harden          full baseline (base tier)
#         make harden TIER=full   + auditd
#         make <module>        one module (preflight always runs first)
#         make audit           verify only, changes nothing; exits 1 on any
#                              mandatory control that is not in the expected state
#         make lint            shellcheck + shfmt (workstation)
#         make test            bats unit suite (workstation)
# Knobs:  ADMIN_USER=admin  DRY_RUN=1  TIER=base|full
#         EXTRA_PORTS="80/tcp 443/tcp"   ufw opens only SSH unless you pass this
#         SKIP_MODULES="docker"          modules to leave out (update user ssh firewall
#                                fail2ban sysctl hardening docker auditd); honoured by
#                                harden, by single-module targets and by audit/report,
#                                which prints their controls as [skip]. Unknown names
#                                fail preflight.
#         UPDATE_SKIP_DIST_UPGRADE=1  UPGRADE_HOLD_PACKAGES="raspi-firmware"
#         JOURNAL_STORAGE=persistent|volatile  FAIL2BAN_IGNOREIP="192.168.1.0/24"
#         SSH_ALLOW_FROM="192.168.1.0/24"   see docs/HARDENING.md and docs/RASPBERRY-PI.md

SHELL := /usr/bin/env bash
MODULES_DIR := modules
TIER ?= base
export TIER   # reaches the module environment so 80-auditd can self-gate

# SKIP_MODULES is read by every module (lib/common.sh skip_if_requested) and by 90-report,
# so a skipped module prints "skipped" here and the audit reports its controls as [skip].
export SKIP_MODULES

# 80-auditd self-gates on $TIER: base tier sets only journald persistence and
# exits; TIER=full additionally installs auditd + the rule set.
MODULES := 10-update 20-user 30-ssh 40-firewall 50-fail2ban 60-sysctl 65-hardening 70-docker 80-auditd

.PHONY: harden audit lint test preflight report \
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
	shfmt -d -i 2 -ci $(MODULES_DIR) lib scripts

# bats-core unit suite (tier 1/2 — see docs/TESTING.md). Needs bats and, for the
# module tests, a kernel that allows unshare -r; those tests skip themselves otherwise.
test:
	bats tests/
