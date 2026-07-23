{
  description = "A very basic flake";
  inputs.privateDep = {
    url = "github:joegoldin/garnix-integration-private-input";
    flake = false;
  };
  outputs = { self, nixpkgs, privateDep }: { };
}
