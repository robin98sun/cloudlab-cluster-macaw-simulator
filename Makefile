# Simulator testbed helpers. See docs/runbook.md.
#
# Rules T3/T4: exactly ONE host is contacted from this machine, over ONE
# long-lived link. Every target here talks to CTL and nothing else, and they
# all share a single multiplexed connection.
SHELL := /bin/bash

USER_ ?= robin98
CTL   ?=

# ControlMaster on purpose: repeated targets reuse one channel instead of
# dialling again. Never add -o ControlMaster=no or -F /dev/null here.
SSH := ssh -o ControlMaster=auto -o ControlPath=~/.ssh/cm/%C \
           -o ControlPersist=30m -o StrictHostKeyChecking=accept-new

.PHONY: help check-ctl verify config config-dry sync-hint clean

help:
	@echo "make verify     CTL=<host>   run the node check suite on ctl1"
	@echo "make config     CTL=<host>   generate + install + distribute mod_op.config"
	@echo "make config-dry CTL=<host>   generate only, print the apportionment"
	@echo "make sync-hint               print the sync command (run it yourself)"
	@echo
	@echo "USER_ defaults to robin98. Never the local account (rule T2)."
	@echo "CTL is ctl1's control-network name from THIS allocation's host"
	@echo "list (rule T1) -- never reused from a previous one."

check-ctl:
	@test -n "$(CTL)" || { \
	  echo "set CTL=<ctl1 control-network hostname from this allocation>"; \
	  echo "read it from the allocation notice; do not reuse an old one"; \
	  exit 1; }
	@mkdir -p ~/.ssh/cm

verify: check-ctl
	$(SSH) $(USER_)@$(CTL) 'bash /local/repository/cloudlab/verify-sim.sh'

config: check-ctl
	$(SSH) $(USER_)@$(CTL) 'bash /local/repository/cloudlab/make-sim-config.sh --install --distribute'

config-dry: check-ctl
	$(SSH) $(USER_)@$(CTL) 'bash /local/repository/cloudlab/make-sim-config.sh'

sync-hint:
	@echo "cd /Volumes/devessential/aces"
	@echo "./consolidated-dc-simulator/tests/sync.sh ./consolidated-dc-simulator $(USER_)@$(CTL)"
	@echo
	@echo "Then fan out from ctl1 to the other nodes (rule T5), never from here."

clean:
	rm -f manifest.xml topology.json mod_op.config
