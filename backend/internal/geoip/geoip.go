package geoip

import (
	"fmt"
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

func (r *Resolver) Region(ip net.IP) (string, error) {
	if r.db == nil || ip == nil || ip.IsPrivate() || ip.IsLoopback() {
		return "地区未知", nil
	}
	var record struct {
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
		return "", fmt.Errorf("GeoIP lookup: %w", err)
	}

	getName := func(names map[string]string) string {
		if val := names["zh-CN"]; val != "" {
			return val
		}
		return names["en"]
	}

	countryCode := strings.ToUpper(strings.TrimSpace(record.Country.IsoCode))
	countryName := getName(record.Country.Names)
	cityName := getName(record.City.Names)

	var subName string
	if len(record.Subdivisions) > 0 {
		subName = getName(record.Subdivisions[0].Names)
	}

	// 1. 国内（中国）：仅显示具体省份/直辖市/特别行政区
	if countryCode == "CN" {
		if subName != "" {
			return subName, nil
		}
		if cityName != "" {
			return cityName, nil
		}
		if countryName != "" {
			return countryName, nil
		}
		return "中国", nil
	}

	// 2. 国外：显示“国家-城市”
	if countryName != "" {
		detail := cityName
		if detail == "" {
			detail = subName
		}
		if detail != "" && detail != countryName {
			return countryName + "-" + detail, nil
		}
		return countryName, nil
	}

	// 兜底：若只有城市或省份
	if cityName != "" {
		return cityName, nil
	}
	if subName != "" {
		return subName, nil
	}

	return "地区未知", nil
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
