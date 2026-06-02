package limit

import "sync"

type Limiter struct {
	ch chan struct{}
}

func New(maxConcurrent int) *Limiter {
	if maxConcurrent <= 0 {
		return nil
	}
	return &Limiter{ch: make(chan struct{}, maxConcurrent)}
}

func TryAcquire(limiter *Limiter) (func(), bool) {
	if limiter == nil {
		return func() {}, true
	}
	return limiter.TryAcquire()
}

func (l *Limiter) TryAcquire() (func(), bool) {
	select {
	case l.ch <- struct{}{}:
		var once sync.Once
		return func() {
			once.Do(func() {
				<-l.ch
			})
		}, true
	default:
		return nil, false
	}
}
