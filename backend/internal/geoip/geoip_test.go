package geoip

import (
	"math"
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

func TestCloudflareRequestIP(t *testing.T) {
	proxies, _ := ParseTrustedProxies("127.0.0.1/32,::1/128")
	for _, test := range []struct{ remote, forwarded, cf, want string }{
		// nginx: X-Forwarded-For $remote_addr (the Cloudflare edge) + CF-Connecting-IP passed through
		{"127.0.0.1:5000", "172.70.1.2", "8.8.8.8", "8.8.8.8"},
		// nginx: $proxy_add_x_forwarded_for
		{"127.0.0.1:5000", "8.8.8.8, 2606:4700::1", "8.8.8.8", "8.8.8.8"},
		// not from Cloudflare: a forged header is ignored
		{"127.0.0.1:5000", "203.0.113.10", "8.8.8.8", "203.0.113.10"},
		{"203.0.113.10:5000", "", "8.8.8.8", "203.0.113.10"},
		// nginx real_ip already resolved the visitor
		{"127.0.0.1:5000", "8.8.4.4", "8.8.4.4", "8.8.4.4"},
	} {
		if got := RequestIP(test.remote, test.forwarded, test.cf, proxies).String(); got != test.want {
			t.Fatalf("%+v: got %s, want %s", test, got, test.want)
		}
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

func TestDescribeChinaCity(t *testing.T) {
	sub := func(name string) []struct {
		IsoCode string            `maxminddb:"iso_code"`
		Names   map[string]string `maxminddb:"names"`
	} {
		return []struct {
			IsoCode string            `maxminddb:"iso_code"`
			Names   map[string]string `maxminddb:"names"`
		}{{Names: map[string]string{"zh-CN": name}}}
	}
	cn := map[string]string{"zh-CN": "中国"}
	for _, test := range []struct{ province, city, want string }{
		{"广东", "深圳市", "广东-深圳"},
		{"浙江省", "杭州", "浙江-杭州"},
		{"北京市", "北京", "北京"},
		{"山东省", "", "山东"},
		{"", "", "中国"},
	} {
		subs := sub(test.province)
		if test.province == "" {
			subs = nil
		}
		if got := describe("CN", cn, map[string]string{"zh-CN": test.city}, subs); got != test.want {
			t.Fatalf("%s/%s: got %s, want %s", test.province, test.city, got, test.want)
		}
	}
}

// Uses the databases in backend/ when present (they are not in every checkout).
func TestIP2RegionChina(t *testing.T) {
	mmdb := os.Getenv("GEOIP_TEST_CITY_DB")
	if mmdb == "" {
		mmdb = "../../GeoLite2-City2.mmdb"
	}
	v4, v6 := "../../ip2region_v4.xdb", "../../ip2region_v6.xdb"
	for _, path := range []string{mmdb, v4, v6} {
		if _, err := os.Stat(path); err != nil {
			t.Skip("database not present:", path)
		}
	}
	resolver, err := Open(mmdb, v4, v6)
	if err != nil {
		t.Fatal(err)
	}
	defer resolver.Close()
	for _, test := range []struct {
		ip, region string
		lat, lon   float64 // 0, 0: not checked
	}{
		{"114.114.114.114", "江苏-南京", 32.1, 118.8}, // GeoLite2 alone: 中国, middle of the country
		{"112.97.1.1", "广东-深圳", 22.6, 114.1},
		{"117.136.1.1", "天津", 39.1, 117.2},
		{"240e:3b7:3272:d8d0:db09:c067:8d59:539e", "广东-深圳", 22.6, 114.1},
		{"202.175.1.1", "澳门", 22.2, 113.5},
		{"8.8.8.8", "美国", 0, 0}, // abroad: GeoLite2
	} {
		region, geo, err := resolver.Locate(net.ParseIP(test.ip))
		if err != nil || !strings.HasPrefix(region, test.region) {
			t.Fatalf("%s: got %q %v, want %q", test.ip, region, err, test.region)
		}
		if test.lat != 0 && (len(geo) != 2 || math.Abs(geo[0]-test.lat) > 0.15 || math.Abs(geo[1]-test.lon) > 0.15) {
			t.Fatalf("%s: geo %v, want about [%v %v]", test.ip, geo, test.lat, test.lon)
		}
		t.Log(test.ip, region, geo)
	}
}

func TestCNPlacesHaveEveryProvince(t *testing.T) {
	for _, province := range []string{"北京", "上海", "天津", "重庆", "广东", "新疆", "西藏", "内蒙古", "香港", "澳门", "台湾"} {
		if _, ok := cnPlaces[province]; !ok {
			t.Fatal("missing province", province)
		}
	}
}
