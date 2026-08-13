PROFILE ?= desktop

.PHONY: audit audit-history bootstrap check doctor dry-run link seed uninstall

bootstrap:
	./bootstrap.sh --profile "$(PROFILE)"

dry-run:
	./bootstrap.sh --profile "$(PROFILE)" --dry-run

link:
	./scripts/link-dotfiles.sh --backup-conflicts
	./scripts/seed-runtime.sh

seed:
	./scripts/seed-runtime.sh

check:
	./scripts/check.sh

audit:
	./scripts/audit.sh

audit-history:
	./scripts/audit.sh --history

doctor:
	./scripts/doctor.sh --profile "$(PROFILE)"

uninstall:
	./scripts/uninstall.sh
