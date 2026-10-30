// Firefox settings for the test-VM browser profile (test/bin/browser).
// Every request goes through the SSH SOCKS proxy into the test VM, and the VM
// resolves the names, so *.lab.test works without a hosts file.
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 1080);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
