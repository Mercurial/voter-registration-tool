
dev:
	nix-shell --run "ghcid -c 'cabal repl $(target) --project-file=cabal-nix.project'"

repl:
	nix-shell --run "cabal repl $(target) --project-file=cabal-nix.project"

build:
	nix-build default.nix -A haskellPackages.voter-registration.components.exes.voter-registration -o voter-registration

style: ## Apply stylish-haskell on all *.hs files
	nix-shell --pure --run 'find . -type f -name "*.hs" -not -path ".git" -not -path "*.stack-work*" -print0 | xargs -0 stylish-haskell -i'
