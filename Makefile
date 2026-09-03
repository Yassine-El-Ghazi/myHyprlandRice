PROFILE ?= desktop

.PHONY: audit audit-history baseline bootstrap capture check doctor dry-run link seed status uninstall update update-plan update-system

bootstrap:
	./bootstrap.sh --profile "$(PROFILE)"

dry-run:
	./bootstrap.sh --profile "$(PROFILE)" --dry-run

link:
	./scripts/link-dotfiles.sh --backup-conflicts
	./scripts/seed-runtime.sh

seed:
	./scripts/seed-runtime.sh

capture:
	./scripts/capture-runtime.sh

baseline:
	./scripts/capture-baseline.sh

check:
	./scripts/check.sh

audit:
	./scripts/audit.sh

audit-history:
	./scripts/audit.sh --history

doctor:
	./scripts/doctor.sh --profile "$(PROFILE)"

update-plan:
	./scripts/maintenance.sh plan dotfiles --profile "$(PROFILE)"

update:
	./scripts/maintenance.sh apply dotfiles --profile "$(PROFILE)"

update-system:
	./scripts/maintenance.sh apply system --profile "$(PROFILE)"

status:
	./scripts/maintenance.sh status

uninstall:
	./scripts/uninstall.sh
