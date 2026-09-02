import SignalCore

/// What this monitor can tell you about.
///
/// This is the "is my network up, and on what" core: general Internet reachability, joining/
/// leaving a Wi-Fi network, a wired/other link coming up or down, and which interface carries
/// default traffic. Everything else HG4MAC's Network Monitor covers — Wi-Fi signal bars,
/// radio power, DHCP renewal, hostname/location, VPN, DNS, proxy, promiscuous mode, adapter
/// bonding, service order — is not ported at all; see the porting notes for why and what
/// each would take.
public enum NetworkEvent: String, NotificationEventKey {
    case reachabilityChanged = "NetworkReachabilityChanged"
    case wifiConnected = "AirportConnected"
    case wifiDisconnected = "AirportDisconnected"
    case linkUp = "NetworkLinkUp"
    case linkDown = "NetworkLinkDown"
    case primaryInterfaceChanged = "PrimaryInterfaceChanged"
    case dhcpRenewed = "NetworkDHCPLeaseRenewed"
    case hostnameChanged = "NetworkHostnameChanged"
    case dnsServersChanged = "DNSServersChanged"
    case proxyConfigChanged = "ProxyConfigChanged"
    case locationChanged = "NetworkLocationChanged"
    case serviceOrderChanged = "NetworkServiceOrderChanged"
    case wifiRadioOn = "WifiRadioOn"
    case wifiRadioOff = "WifiRadioOff"
    case vpnConnected = "VPNConnected"
    case vpnDisconnected = "VPNDisconnected"
    case wifiSignalChanged = "AirportSignalChange"
    case linkSpeedChanged = "NetworkLinkSpeedChanged"
    case promiscuousModeChanged = "NetworkPromiscuousModeChanged"
    case adapterDetaching = "NetworkAdapterDetaching"
    case ipAddressChanged = "IPAddressChange"

    public static let category: NotificationCategory = "Network"
}
