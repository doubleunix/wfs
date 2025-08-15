PKG := wnix
NIX := nix --print-build-logs

build: clean
	$(NIX) build
	docker load < result
	rm result
	docker run --rm -it -v nix:/nix $(PKG)

initrd:
	$(NIX) run .#runQemuInitrd

iso:
	$(NIX) build .#iso

qemu: iso
	$(NIX) run .#runQemuIso

clean:
	@docker rmi $(PKG) 2>/dev/null || true
