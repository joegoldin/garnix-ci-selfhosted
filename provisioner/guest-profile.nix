# Shared profile for garnix-deployed microVM guests.
#
# Fixed conventions (the daemon's base guest AND user-deployed
# nixosConfigurations must both use this profile so that
# switch-to-configuration inside the guest keeps a matching fstab):
#   - root volume root.img (20 GiB) mounted at /
#   - host store shared read-only (virtiofs, tag ro-store)
#   - writable store overlay on overlay.img (20 GiB) so nix-copy-closure into
#     the guest works
#   - DHCP on every ethernet (the provisioner's dnsmasq reserves the IP by MAC)
#   - sshd with the hosting public key for root and the garnix user;
#     passwordless sudo for wheel (redeploys run `sudo switch-to-configuration`
#     as the garnix user)
{ lib, config, ... }:
{
  options.garnix.guest = {
    sshPublicKey = lib.mkOption {
      type = lib.types.str;
      description = "Hosting SSH public key allowed for root and the garnix user.";
    };
  };
  config = {
    microvm = {
      hypervisor = "qemu";
      volumes = [
        {
          image = "root.img";
          mountPoint = "/";
          size = 20 * 1024;
        }
        {
          image = "overlay.img";
          mountPoint = "/nix/.rw-store";
          size = 20 * 1024;
        }
      ];
      shares = [
        {
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }
      ];
      writableStoreOverlay = "/nix/.rw-store";
    };
    networking.useNetworkd = true;
    systemd.network.networks."10-eth" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "yes";
    };
    services.openssh.enable = true;
    services.openssh.settings.PermitRootLogin = "prohibit-password";
    users.users.root.openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
    users.users.garnix = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
      # User SSH access (the three methods: tailscale/proxyjump/DNAT). The
      # backend drops the deployer's GitHub keys + garnix.yaml sshKeys here at
      # deploy time (copyAuthorizedKeys). sshd tolerates the file being absent.
      openssh.authorizedKeys.keyFiles = [ "/var/garnix/keys/authorized_keys" ];
    };
    security.sudo.wheelNeedsPassword = false;
    # Guests live on a host-only bridge; Traefik fronts them.
    networking.firewall.enable = false;
    system.stateVersion = "25.11";
  };
}
