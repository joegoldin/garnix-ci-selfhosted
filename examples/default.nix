{ pkgs, ... }: {
  commands = {
    spinUpVms = pkgs.writeShellApplication
      {
        meta.description = "spins up a set of example vms for a garnix deployment";
        name = "exampleSpinUpVms";
        text = ''
          nixos-compose up -v exampleDb exampleGarnixServer exampleOpenSearch
          nixos-compose status
        '';
      };
  };
}
