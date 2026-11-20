package geoip

import (
	"fmt"
	"math"
	"net"
	"strings"

	"github.com/oschwald/maxminddb-golang"
)

type Resolver struct{ db *maxminddb.Reader }

func Open(path string) (*Resolver, error) {
	if path == "" {
		return &Resolver{}, nil
	}
	db, err := maxminddb.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open GeoIP database: %w", err)
	}
	return &Resolver{db: db}, nil
}

func (r *Resolver) Close() error {
	if r.db == nil {
		return nil
	}
	return r.db.Close()
}

// Region returns a display name for the client's location.
func (r *Resolver) Region(ip net.IP) (string, error) {
	region, _, err := r.Locate(ip)
	return region, err
}

// Locate returns the display region plus coarse coordinates [lat, lon] rounded to
// 0.1° (city level, as precise as GeoLite2 itself), or nil when unknown.
func (r *Resolver) Locate(ip net.IP) (string, []float64, error) {
	if r.db == nil || ip == nil || ip.IsPrivate() || ip.IsLoopback() {
		return "地区未知", nil, nil
	}
	var record struct {
		Location struct {
			Latitude  *float64 `maxminddb:"latitude"`
			Longitude *float64 `maxminddb:"longitude"`
		} `maxminddb:"location"`
		Country struct {
			IsoCode string            `maxminddb:"iso_code"`
			Names   map[string]string `maxminddb:"names"`
		} `maxminddb:"country"`
		Subdivisions []struct {
			IsoCode string            `maxminddb:"iso_code"`
			Names   map[string]string `maxminddb:"names"`
		} `maxminddb:"subdivisions"`
		City struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"city"`
	}
	if err := r.db.Lookup(ip, &record); err != nil {
		return "", nil, fmt.Errorf("GeoIP lookup: %w", err)
	}
	var geo []float64
	if lat, lon := record.Location.Latitude, record.Location.Longitude; lat != nil && lon != nil {
		geo = []float64{math.Round(*lat*10) / 10, math.Round(*lon*10) / 10}
	}
	region := describe(record.Country.IsoCode, record.Country.Names, record.City.Names, record.Subdivisions)
	return region, geo, nil
}

func describe(isoCode string, country, city map[string]string, subdivisions []struct {
	IsoCode string            `maxminddb:"iso_code"`
	Names   map[string]string `maxminddb:"names"`
}) string {

	getName := func(names map[string]string) string {
		if val := names["zh-CN"]; val != "" {
			return val
		}
		return names["en"]
	}

	countryCode := strings.ToUpper(strings.TrimSpace(isoCode))
	countryName := getName(country)
	cityName := getName(city)

	var subName string
	if len(subdivisions) > 0 {
		subName = getName(subdivisions[0].Names)
	}

	// 1. 国内（中国）：仅显示具体省份/直辖市/特别行政区
	if countryCode == "CN" {
		if subName != "" {
			return subName
		}
		if cityName != "" {
			return cityName
		}
		if countryName != "" {
			return countryName
		}
		return "中国"
	}

	// 2. 国外：显示“国家-城市”
	if countryName != "" {
		detail := cityName
		if detail == "" {
			detail = subName
		}
		if detail != "" && detail != countryName {
			return countryName + "-" + detail
		}
		return countryName
	}

	// 兜底：若只有城市或省份
	if cityName != "" {
		return cityName
	}
	if subName != "" {
		return subName
	}

	return "地区未知"
}

func ParseTrustedProxies(value string) ([]*net.IPNet, error) {
	proxies := []*net.IPNet{}
	if strings.TrimSpace(value) == "" {
		return proxies, nil
	}
	for _, item := range strings.Split(value, ",") {
		_, network, err := net.ParseCIDR(strings.TrimSpace(item))
		if err != nil {
			return nil, fmt.Errorf("invalid trusted proxy CIDR: %w", err)
		}
		proxies = append(proxies, network)
	}
	return proxies, nil
}

func ClientIP(remoteAddress, forwarded string, proxies []*net.IPNet) net.IP {
	host, _, err := net.SplitHostPort(remoteAddress)
	if err != nil {
		host = remoteAddress
	}
	ip := net.ParseIP(host)
	chain := strings.Split(forwarded, ",")
	for index := len(chain) - 1; index >= 0; index-- {
		trusted := false
		for _, network := range proxies {
			if network.Contains(ip) {
				trusted = true
				break
			}
		}
		if !trusted {
			break
		}
		next := net.ParseIP(strings.TrimSpace(chain[index]))
		if next == nil {
			break
		}
		ip = next
	}
	return ip
}

// cloudflare lists Cloudflare's edge ranges (https://www.cloudflare.com/ips/). A request whose
// nearest untrusted hop is one of these came through the Cloudflare proxy, which overwrites
// CF-Connecting-IP with the visitor's address, so that header is the real client.
var cloudflare = mustCIDRs(
	"173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
	"108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
	"162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
	"2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
	"2a06:98c0::/29", "2c0f:f248::/32",
)

func mustCIDRs(values ...string) []*net.IPNet {
	result := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic(err)
		}
		result = append(result, network)
	}
	return result
}

// IsCloudflare reports whether ip belongs to a Cloudflare edge range.
func IsCloudflare(ip net.IP) bool {
	for _, network := range cloudflare {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// RequestIP is ClientIP plus Cloudflare: when the trusted proxy chain ends at a Cloudflare edge
// (nginx without real_ip forwards the edge address), the visitor is CF-Connecting-IP.
func RequestIP(remoteAddress, forwarded, cfConnecting string, proxies []*net.IPNet) net.IP {
	ip := ClientIP(remoteAddress, forwarded, proxies)
	if ip != nil && IsCloudflare(ip) {
		if visitor := net.ParseIP(strings.TrimSpace(cfConnecting)); visitor != nil {
			return visitor
		}
	}
	return ip
}
