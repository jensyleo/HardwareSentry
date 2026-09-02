import SignalCore

/// What this monitor can tell you about.
///
/// Every one of these is declared in `NetworkMonitor.events`, and a test insists on it.
/// It did not used to be: eighteen of them fired without a row in the settings window, so
/// they could not be switched off or given an icon, and the generated help never listed
/// them. An event that arrives with nowhere to turn it off is worse than one that does not
/// exist, and nothing about firing it required declaring it — hence the test.
public enum NetworkEvent: String, NotificationEventKey, CaseIterable {
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
    case bondMemberStatusChanged = "NetworkBondMemberStatusChanged"
    case wifiHostAPModeChanged = "WifiHostAPModeChanged"
    // The same four facts the reachability message can carry as lines, offered as events
    // as well. Not a duplication in practice: the lines describe the path at the moment
    // connectivity changed, while these fire when one of them moves on its own — a
    // hotspot becoming metered without the Internet going anywhere. Both are off by
    // default, so nobody gets both unless they ask.
    case pathStatusChanged = "NetworkPathStatusChanged"
    case pathExpensiveChanged = "NetworkPathExpensiveChanged"
    case pathConstrainedChanged = "NetworkPathConstrainedChanged"
    case pathQualityChanged = "NetworkPathQualityChanged"
    case ipAddressChanged = "IPAddressChange"

    public static let category: NotificationCategory = "Network"
}
