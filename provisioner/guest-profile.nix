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
    # Key-only, hardened sshd (no passwords), matching the garnix user-module.
    services.openssh.settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    # The deploy drops /var/garnix/keys/authorized_keys at RUNTIME when a
    # server opts in via authorizeDeployerGithubKeys / authorizedSSHKeys
    # (copyAuthorizedKeys), so sshd must read it at auth time — scoped to the
    # garnix user only. (authorizedKeys.keyFiles would read it at build time,
    # which both breaks pure eval and can never see the runtime file.) sshd
    # tolerates the file being absent: the garnix user stays login-closed
    # until it exists. Declare your own login users in the guest config for
    # the user-module pattern.
    services.openssh.extraConfig = ''
      Match User garnix
        AuthorizedKeysFile .ssh/authorized_keys /var/garnix/keys/authorized_keys
      Match all
    '';
    users.users.root.openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
    users.users.garnix = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      # The hosting key (for backend redeploys) is always authorized.
      openssh.authorizedKeys.keys = [ config.garnix.guest.sshPublicKey ];
    };
    security.sudo.wheelNeedsPassword = false;
    # Guests live on a host-only bridge; Traefik fronts them.
    networking.firewall.enable = false;
    system.stateVersion = "25.11";
  };
}
