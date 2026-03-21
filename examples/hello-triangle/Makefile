HYPERVISOR = ../../.build/debug/hypervisor
KERNEL = target/aarch64-unknown-none/release/hello-triangle

build:
	cargo build --release

# Run on the hypervisor (builds both the example and hypervisor if needed)
run: build
	cd ../.. && make sign
	$(HYPERVISOR) $(KERNEL)

clean:
	cargo clean

.PHONY: build run clean
