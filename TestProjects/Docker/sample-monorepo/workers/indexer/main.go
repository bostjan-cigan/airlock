// The indexer turns note texts into a word index. It's a separate Go program so the
// monorepo has a third stack; it only uses the standard library.
package main

import (
	"fmt"
	"sort"
	"strings"
	"unicode"
)

// Index maps each lower-cased word to the IDs of the notes containing it.
func Index(notes map[int]string) map[string][]int {
	index := map[string][]int{}
	for id, text := range notes {
		seen := map[string]bool{}
		for _, word := range strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsNumber(r) }) {
			if !seen[word] {
				index[word] = append(index[word], id)
				seen[word] = true
			}
		}
	}
	for word := range index {
		sort.Ints(index[word])
	}
	return index
}

func main() {
	fmt.Println(Index(map[int]string{1: "Hello notes", 2: "more notes"}))
}
