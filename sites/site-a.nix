# Everything a site team owns for this router: names, addresses, peer. Nothing else.
{
  router = {
    hostName = "site-a";
    asn = 65001;
    wan = { address = "192.0.2.1/24"; };
    lan = { address = "10.10.1.1/24"; prefix = "10.10.1.0/24"; };
    tunnel = {
      address = "10.255.0.0/31";
      peerAddress = "10.255.0.1";
      peerAsn = 65002;
      peerPublicIp = "192.0.2.2";
      psk = "lab-only-preshared-key-change-me";
    };
  };
}
