with import <nixpkgs> { };
haskell.lib.buildStackProject {
   ghc = haskell.packages.ghc7103.ghc;
   name = "haskoin";
   buildInputs = [ncurses autoreconfHook pkgconfig czmq zlib];
}
