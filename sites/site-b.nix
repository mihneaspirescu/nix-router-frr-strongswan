{
  router = {
    hostName = "site-b";
    asn = 65002;
    wan = { address = "192.0.2.2/24"; };
    lan = { address = "10.10.2.1/24"; prefix = "10.10.2.0/24"; };
    tunnel = {
      address = "10.255.0.1/31";
      peerAddress = "10.255.0.0";
      peerAsn = 65001;
      peerPublicIp = "192.0.2.1";
      psk = "lab-only-preshared-key-change-me";
    };
  };
}
