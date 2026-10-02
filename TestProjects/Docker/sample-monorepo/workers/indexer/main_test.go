package main

import (
	"reflect"
	"testing"
)

func TestIndex(t *testing.T) {
	got := Index(map[int]string{1: "Hello, notes!", 2: "notes notes"})
	if !reflect.DeepEqual(got["notes"], []int{1, 2}) || !reflect.DeepEqual(got["hello"], []int{1}) {
		t.Fatalf("unexpected index: %v", got)
	}
}
