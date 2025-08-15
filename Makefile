PKG := wnix
NIX := nix --print-build-logs

qemu: iso
	$(NIX) run .#qemu

iso:
	$(NIX) build .#iso

initrd:
	$(NIX) run .#initrd

docker:
	@docker rmi $(PKG) 2>/dev/null || true
	$(NIX) build .#docker
	docker load < result
	rm result
	docker run --rm -it $(PKG)
