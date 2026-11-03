SHELL := /bin/bash

.PHONY: check prepare-hub provision discover dns install status destroy

check:
	bash scripts/check.sh

prepare-hub:
	bash scripts/prepare-hub.sh

provision:
	bash scripts/provision.sh

discover:
	bash scripts/discover.sh

dns:
	bash scripts/cloudflare-dns.sh

install:
	bash scripts/install.sh

status:
	bash scripts/status.sh

destroy:
	bash scripts/destroy.sh
