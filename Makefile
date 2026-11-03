SHELL := /bin/bash

.PHONY: check prepare-hub image-nlb image-check image-route53 provision discover dns install status destroy

check:
	bash scripts/check.sh

prepare-hub:
	bash scripts/prepare-hub.sh

image-nlb:
	bash scripts/image-nlb.sh

image-check:
	bash scripts/image-check.sh

image-route53:
	bash scripts/image-route53.sh

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
