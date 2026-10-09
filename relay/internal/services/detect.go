package services

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strings"
)

// Detect finds the operator a number belongs to. The supplier is asked (it knows
// the prefixes); the answer must be an operator of the directory, because
// anything else cannot be sold. In test mode without a supplier the operator is
// picked deterministically from the number, so the till can be developed offline.
func (s *Service) Detect(ctx context.Context, in PricingInput, country, phoneInput string) (Detection, *Refusal) {
	country = strings.ToUpper(strings.TrimSpace(country))
	if len(country) != 2 {
		return Detection{}, refuse(http.StatusBadRequest, CodeInvalidRequest, "country must be a two-letter code", nil)
	}
	snap, refusal := s.directoryFor(ctx)
	if refusal != nil {
		return Detection{}, refusal
	}
	entry, ok := snap.countries[country]
	if !ok || len(entry.operators) == 0 {
		return Detection{}, refuse(http.StatusNotFound, CodeOperatorNotDetected, "no operator serves this country", nil)
	}
	phone, err := ParsePhone(phoneInput, country, entry.dial)
	if err != nil {
		return Detection{}, refuseUnprocessable(CodeInvalidPhone, err.Error())
	}
	var id int64
	if s.cfg.Detector != nil {
		id, err = s.cfg.Detector.Detect(ctx, country, phone)
		switch {
		case errors.Is(err, ErrNotDetected):
			return Detection{}, refuse(http.StatusNotFound, CodeOperatorNotDetected, "no operator could be detected for this number", nil)
		case err != nil:
			s.logger().Warn("operator detection failed", "country", country,
				"error", RedactError(err, phone.Digits(), phone.National, phoneInput))
			return Detection{}, refuse(http.StatusServiceUnavailable, CodeServicesUnavailable, "the operator could not be detected right now", nil)
		}
	} else {
		id = detectOffline(entry, phone)
	}
	operator, ok := snap.operators[id]
	if !ok || operator.country != country {
		return Detection{}, refuse(http.StatusNotFound, CodeOperatorNotDetected, "the detected operator is not one this relay sells", nil)
	}
	view, ok := operator.view(viewContextFor(in))
	if !ok {
		return Detection{}, refuse(http.StatusNotFound, CodeOperatorNotDetected, "the detected operator has nothing to sell", nil)
	}
	return Detection{Operator: view, Phone: phone.Detected()}, nil
}

// detectOffline picks an operator of the country from the first digit of the
// number: stable, so a developer can predict it, and meaningless as detection.
func detectOffline(entry *countryEntry, phone Phone) int64 {
	operators := append([]*operatorEntry(nil), entry.operators...)
	sort.Slice(operators, func(i, j int) bool { return operators[i].id < operators[j].id })
	digit := 0
	if phone.National != "" {
		digit = int(phone.National[0] - '0')
	}
	return operators[digit%len(operators)].id
}
