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
