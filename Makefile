BINARY = .build/debug/hypervisor
ENTITLEMENTS = hypervisor.entitlements

build:
	swift build 2>&1

sign: build
	codesign --entitlements $(ENTITLEMENTS) --force -s - $(BINARY)

# Run with Metal GPU display — pass KERNEL=path/to/kernel.elf
run: sign
	@if [ -z "$(KERNEL)" ]; then \
		echo "Usage: make run KERNEL=path/to/kernel.elf"; \
		exit 1; \
	fi
	$(BINARY) $(KERNEL) $(ARGS)

# Run with verbose logging
run-verbose: sign
	@if [ -z "$(KERNEL)" ]; then \
		echo "Usage: make run-verbose KERNEL=path/to/kernel.elf"; \
		exit 1; \
	fi
	$(BINARY) $(KERNEL) --verbose $(ARGS)

# Run without GPU (serial output only, no window)
run-serial: sign
	@if [ -z "$(KERNEL)" ]; then \
		echo "Usage: make run-serial KERNEL=path/to/kernel.elf"; \
		exit 1; \
	fi
	$(BINARY) $(KERNEL) --no-gpu $(ARGS)

clean:
	swift package clean

.PHONY: build sign run run-verbose run-serial clean
