package main

import (
	"fmt"

	"mycalc/math"
)

func main() {
	fmt.Println(math.Add(2, 3), math.Clamp(9, 0, 5))
}
