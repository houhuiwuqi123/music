package geoip

import (
	"net"
	"os"
	"strings"
	"testing"
)

func TestTrustedProxyClientIP(t *testing.T) {
	proxies, err := ParseTrustedProxies("127.0.0.1/32,::1/128")
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ remote, forwarded, want string }{
		{"203.0.113.10:5000", "1.2.3.4", "203.0.113.10"},
		{"127.0.0.1:5000", "1.2.3.4, 203.0.113.10", "203.0.113.10"},
		{"[::1]:5000", "2001:4860:4860::8888", "2001:4860:4860::8888"},
		{"127.0.0.1:5000", "invalid", "127.0.0.1"},
	} {
		if got := ClientIP(test.remote, test.forwarded, proxies).String(); got != test.want {
			t.Fatalf("got %s, want %s", got, test.want)
		}
	}
	if _, err := ParseTrustedProxies("not-a-cidr"); err == nil {
		t.Fatal("invalid proxy accepted")
	}
}

func TestUnknownAndInvalidDatabase(t *testing.T) {
	resolver, err := Open("")
	if err != nil {
		t.Fatal(err)
	}
	defer resolver.Close()
	region, err := resolver.Region(net.ParseIP("8.8.8.8"))
	if err != nil || region != "地区未知" {
		t.Fatalf("unexpected region: %s, %v", region, err)
	}
	if _, err := Open("missing-geoip-database.mmdb"); err == nil {
		t.Fatal("missing database accepted")
	}
}

func TestConfiguredDatabase(t *testing.T) {
	path := os.Getenv("GEOIP_TEST_DB")
	if path == "" {
		t.Skip("set GEOIP_TEST_DB to MaxMind GeoIP2-City-Test.mmdb fixture")
	}
	resolver, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer resolver.Close()
	region, err := resolver.Region(net.ParseIP("81.2.69.160"))
	if err != nil || !strings.Contains(region, "London") {
		t.Fatalf("failed database lookup: %s, %v", region, err)
	}
	t.Log("resolved fixture region:", region)
}
