# The appliance itself. Owned by the network team; sites only set `router.*` values.
#
#   lan (red, VRF "red") ── FRR/BGP ── ipsec0 (xfrm, VRF "red") ══ ESP ══ wan (black, main table)
#
# Red and black never share a routing table: the only way out of VRF red toward
# another site is ipsec0, and ipsec0 only carries traffic that strongSwan encrypts.
# With the tunnel down, BGP withdraws the remote prefixes and red traffic has no
# route, so it is dropped instead of leaking onto the wan in clear.
{ config, lib, pkgs, ... }:
let
  cfg = config.router;
  ip = cidr: builtins.head (lib.splitString "/" cidr);
  ifId = "42"; # binds the IPsec SAs to the ipsec0 interface
in
{
  options.router = with lib; {
    hostName = mkOption { type = types.str; };
    asn = mkOption { type = types.int; description = "Local BGP AS number."; };

    wan = {
      address = mkOption { type = types.str; example = "192.0.2.1/24"; };
      gateway = mkOption { type = types.nullOr types.str; default = null; };
    };
    lan = {
      address = mkOption { type = types.str; example = "10.10.1.1/24"; };
      prefix = mkOption { type = types.str; example = "10.10.1.0/24"; description = "Prefix advertised to the peer site."; };
    };
    tunnel = {
      address = mkOption { type = types.str; example = "10.255.0.0/31"; description = "Inner address on ipsec0."; };
      peerAddress = mkOption { type = types.str; description = "Peer's inner address on ipsec0 (BGP neighbor)."; };
      peerAsn = mkOption { type = types.int; };
      peerPublicIp = mkOption { type = types.str; };
      psk = mkOption { type = types.str; description = "LAB ONLY: lands in the Nix store. Use certificates or a runtime secret in production."; };
    };
  };

  config = {
    networking.hostName = cfg.hostName;

    # ---------- interfaces: `wan`/`lan` are named by the hardware profile (hardware/*.nix) ----------
    systemd.network = {
      netdevs."20-red" = {
        netdevConfig = { Kind = "vrf"; Name = "red"; };
        vrfConfig.Table = 100;
      };
      netdevs."30-ipsec0" = {
        netdevConfig = { Kind = "xfrm"; Name = "ipsec0"; MTUBytes = "1400"; };
        xfrmConfig = { InterfaceId = lib.toInt ifId; Independent = true; };
      };

      # Without a default in the VRF table, Linux falls through to the main table and
      # red traffic for unknown destinations would leave on wan in clear. Close that.
      networks."20-red" = {
        matchConfig.Name = "red";
        linkConfig.RequiredForOnline = "no";
        routes = [{ Type = "unreachable"; Destination = "0.0.0.0/0"; Table = 100; Metric = 4278198272; }];
        # The kernel's "lookup local" rule (pref 0) runs before the VRF rule (pref 1000),
        # so red could reach the router's own wan/mgmt addresses. Re-add it after the VRF
        # rule here; vrf-local-rule (below) then removes the pref 0 one.
        routingPolicyRules = [{ Priority = 32765; Table = 255; Family = "both"; }];
      };
      networks."30-wan" = {
        matchConfig.Name = "wan";
        address = [ cfg.wan.address ];
        routes = lib.optional (cfg.wan.gateway != null) { Gateway = cfg.wan.gateway; };
      };
      networks."30-lan" = {
        matchConfig.Name = "lan";
        address = [ cfg.lan.address ];
        networkConfig = { VRF = "red"; ConfigureWithoutCarrier = true; };
        linkConfig.RequiredForOnline = "no";
      };
      networks."30-ipsec0" = {
        matchConfig.Name = "ipsec0";
        address = [ cfg.tunnel.address ];
        networkConfig = { VRF = "red"; ConfigureWithoutCarrier = true; };
        linkConfig.RequiredForOnline = "no";
      };
    };

    # Drop the kernel's pref-0 local rule once networkd has installed its replacement at 32765.
    systemd.services.vrf-local-rule = {
      description = "Move the local-table lookup after the VRF rule";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-networkd.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      path = [ pkgs.iproute2 ];
      script = ''
        for fam in -4 -6; do
          for _ in $(seq 1 60); do ip $fam rule show pref 32765 | grep -q local && break; sleep 0.5; done
          ip $fam rule show pref 32765 | grep -q local || { echo "replacement rule missing ($fam), keeping pref 0"; continue; }
          ip $fam rule del pref 0 table local 2>/dev/null || true
        done
      '';
    };

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.tcp_l3mdev_accept" = 1; # let BGP sessions work inside the VRF
    };

    # ---------- IPsec: IKEv2, route-based via if_id, fail-closed ----------
    services.strongswan-swanctl = {
      enable = true;
      # This is the whole strongswan.conf; charon falls back to its built-in plugin list.
      strongswan.extraConfig = ''
        charon {
          install_routes = no   # FRR owns routing; SAs are bound to ipsec0 by if_id
          routing_table = 0     # and don't add strongSwan's own policy rule/table 220 either
        }
      '';
      swanctl = {
        connections.peer = {
          version = 2;
          local_addrs = [ (ip cfg.wan.address) ];
          remote_addrs = [ cfg.tunnel.peerPublicIp ];
          proposals = [ "aes256gcm16-prfsha384-ecp384" ];
          if_id_in = ifId;
          if_id_out = ifId;
          dpd_delay = "10s";
          unique = "replace"; # both sides initiate; keep one IKE SA
          local.main = { auth = "psk"; id = ip cfg.wan.address; };
          remote.main = { auth = "psk"; id = cfg.tunnel.peerPublicIp; };
          children.red = {
            local_ts = [ "0.0.0.0/0" ];
            remote_ts = [ "0.0.0.0/0" ];
            esp_proposals = [ "aes256gcm16-ecp384" ];
            start_action = "start";
            dpd_action = "restart";
            close_action = "start";
          };
        };
        secrets.ike.peer = {
          id.main = cfg.tunnel.peerPublicIp;
          secret = cfg.tunnel.psk;
        };
      };
    };

    # ---------- Routing: eBGP over the tunnel, inside VRF red only ----------
    services.frr = {
      bgpd.enable = true;
      config = ''
        vrf red
        exit-vrf
        !
        router bgp ${toString cfg.asn} vrf red
         bgp router-id ${ip cfg.lan.address}
         no bgp ebgp-requires-policy
         neighbor ${cfg.tunnel.peerAddress} remote-as ${toString cfg.tunnel.peerAsn}
         neighbor ${cfg.tunnel.peerAddress} timers 3 9
         address-family ipv4 unicast
          network ${cfg.lan.prefix}
         exit-address-family
        !
      '';
    };

    # ---------- Firewall: IKE/ESP on wan, forwarding only lan <-> ipsec0 ----------
    networking.firewall = {
      checkReversePath = false; # rpfilter and VRFs don't mix; VRF isolation does the job
      interfaces.wan.allowedUDPPorts = [ 500 4500 ];
      extraInputRules = ''
        iifname "wan" meta l4proto esp accept
        iifname { "ipsec0", "red" } tcp dport 179 accept
        iifname { "lan", "ipsec0", "red" } icmp type echo-request accept
      '';
      filterForward = true;
      # Inside a VRF the forward hook sees iif = the VRF device ("red"); the physical
      # port is only visible as sdif. So match sdifname, not iifname.
      extraForwardRules = ''
        meta sdifname "lan" oifname "ipsec0" accept
        meta sdifname "ipsec0" oifname "lan" accept
      '';
    };

    environment.systemPackages = with pkgs; [ tcpdump iproute2 strongswan ];
  };
}
