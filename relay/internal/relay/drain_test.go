package relay

func drainingNode() *NodeDrain {
	drain := &NodeDrain{}
	drain.Begin()
	return drain
}
