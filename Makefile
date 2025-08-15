PKG := wnix
NIX := nix --print-build-logs

qemu1:
	$(NIX) run .#qemu-initrd

qemu2: iso
	$(NIX) run .#qemu-iso

iso:
	$(NIX) build .#iso

docker:
	@docker rmi $(PKG) 2>/dev/null || true
	$(NIX) build .#docker
	docker load < result
	rm result
	docker run --rm -it $(PKG)
