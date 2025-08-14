PKG := wnix

build: clean
	nix build
	docker load < result
	rm result
	docker run --rm -it -v nix:/nix $(PKG)

clean:
	@docker rmi $(PKG) 2>/dev/null || true
