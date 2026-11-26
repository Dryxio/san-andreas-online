package transport

import (
	"crypto/tls"
	"encoding/xml"
	"errors"
	"io"
	"strings"
)

// The issuer signs this URI into the leaf only for a Google-decoded device verdict.
const deviceIntegrityURI = "https://identity.mta-neon.com/claims/play-device-integrity-v1"

type AdmissionPolicy struct {
	MobileIntegrity bool
}

func ReadAdmissionPolicy(r io.Reader) (AdmissionPolicy, error) {
	var config struct {
		XMLName xml.Name `xml:"config"`
		Setting []struct {
			Text     string     `xml:",chardata"`
			Children []struct{} `xml:",any"`
		} `xml:"mobile_integrity"`
	}
	if err := xml.NewDecoder(r).Decode(&config); err != nil {
		return AdmissionPolicy{}, err
	}
	switch len(config.Setting) {
	case 0:
		return AdmissionPolicy{}, nil
	case 1:
		setting := config.Setting[0]
		if len(setting.Children) == 0 {
			switch strings.TrimSpace(setting.Text) {
			case "", "no":
				return AdmissionPolicy{}, nil
			case "yes":
				return AdmissionPolicy{MobileIntegrity: true}, nil
			}
		}
	}
	return AdmissionPolicy{}, errors.New("expected a single mobile_integrity setting (blank, no, or yes)")
}

func verifyDeviceIntegrity(state tls.ConnectionState) error {
	if len(state.VerifiedChains) != 0 && len(state.VerifiedChains[0]) >= 2 {
		leaf := state.VerifiedChains[0][0]
		if !leaf.IsCA {
			for _, uri := range leaf.URIs {
				if uri.String() == deviceIntegrityURI {
					return nil
				}
			}
		}
	}
	return errors.New("Android install certificate lacks verified Play device integrity")
}
